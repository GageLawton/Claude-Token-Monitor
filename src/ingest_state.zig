// Thread-safe in-memory store for usage entries. Used both by the Pi's HTTP
// ingest endpoint and by the local-mode daemon (which feeds it via Watcher).
//
// Optional disk persistence: call enablePersistence(path) after init.
// Accepted entries are appended to the file; on startup the file is loaded
// (with age-filtering) so token history survives daemon restarts and reboots.

const std = @import("std");
const usage = @import("usage_reader.zig");
const UsageEntry = usage.UsageEntry;
const parseEntryFromLine = usage.parseEntryFromLine;
const ParseOptions = usage.ParseOptions;
const DEFAULT_MAX_AGE_SECONDS = usage.DEFAULT_MAX_AGE_SECONDS;

// Compact on-disk format. Avoids an ISO-8601 serializer by storing Unix seconds.
const PersistedLine = struct {
    ts: i64,
    sid: []const u8,
    uuid: []const u8,
    in: u64 = 0,
    out: u64 = 0,
    cc: u64 = 0,
    cr: u64 = 0,
    cost: f64 = 0,
};

pub const IngestState = struct {
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,
    entries: std.ArrayList(UsageEntry),
    seen_uuids: std.StringHashMap(void),
    last_updated_s: i64 = 0,
    persist_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) IngestState {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(UsageEntry).init(allocator),
            .seen_uuids = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *IngestState) void {
        for (self.entries.items) |e| e.deinit(self.allocator);
        self.entries.deinit();
        var it = self.seen_uuids.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.seen_uuids.deinit();
    }

    // Enable disk persistence. Loads any surviving entries from `path` first
    // (age-filtered so old entries are discarded), then appends every newly
    // accepted entry to the file going forward.
    pub fn enablePersistence(self: *IngestState, path: []const u8) void {
        self.persist_path = path;
        // Ensure the parent directory exists.
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch {};
        }
        self.loadFromFile(path) catch |err| {
            std.log.warn("state: could not load {s}: {}", .{ path, err });
        };
    }

    // Adds raw JSONL lines. Drops duplicates and entries older than
    // ParseOptions.max_age_seconds (default: 5h + 10min grace).
    pub fn addLines(self: *IngestState, lines: []const []const u8) !u32 {
        return self.addLinesWithOptions(lines, .{});
    }

    pub fn addLinesWithOptions(
        self: *IngestState,
        lines: []const []const u8,
        options: ParseOptions,
    ) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var added: u32 = 0;
        for (lines) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            const maybe_entry = parseEntryFromLine(self.allocator, trimmed, options) catch continue;
            const entry = maybe_entry orelse continue;

            if (self.seen_uuids.contains(entry.uuid)) {
                entry.deinit(self.allocator);
                continue;
            }

            const key_copy = self.allocator.dupe(u8, entry.uuid) catch {
                entry.deinit(self.allocator);
                continue;
            };
            self.seen_uuids.put(key_copy, {}) catch {
                self.allocator.free(key_copy);
                entry.deinit(self.allocator);
                continue;
            };
            self.entries.append(entry) catch {
                entry.deinit(self.allocator);
                continue;
            };
            if (self.persist_path) |p| self.appendEntryToDisk(p, entry);
            added += 1;
        }

        if (added > 0) self.last_updated_s = std.time.timestamp();
        return added;
    }

    // Returns a snapshot of all entries allocated on `allocator`.
    pub fn snapshot(self: *IngestState, allocator: std.mem.Allocator) ![]UsageEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = try std.ArrayList(UsageEntry).initCapacity(allocator, self.entries.items.len);
        for (self.entries.items) |e| {
            result.appendAssumeCapacity(.{
                .timestamp_s = e.timestamp_s,
                .session_id = try allocator.dupe(u8, e.session_id),
                .uuid = try allocator.dupe(u8, e.uuid),
                .input_tokens = e.input_tokens,
                .output_tokens = e.output_tokens,
                .cache_create_tokens = e.cache_create_tokens,
                .cache_read_tokens = e.cache_read_tokens,
                .cost_usd = e.cost_usd,
            });
        }
        return result.toOwnedSlice();
    }

    // Drop entries older than cutoff_s. Keeps memory bounded on Pi Zero.
    pub fn pruneOlderThan(self: *IngestState, cutoff_s: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].timestamp_s < cutoff_s) {
                const e = self.entries.orderedRemove(i);
                e.deinit(self.allocator);
            } else {
                i += 1;
            }
        }
    }

    pub fn entryCount(self: *IngestState) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }

    pub fn lastUpdatedS(self: *IngestState) i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.last_updated_s;
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    // Append one entry to the persist file. Called under mutex; errors are
    // silently dropped so a disk issue never breaks the in-memory store.
    fn appendEntryToDisk(self: *IngestState, path: []const u8, entry: UsageEntry) void {
        _ = self;
        const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch
            std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;

        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&buf,
            "{{\"ts\":{d},\"sid\":\"{s}\",\"uuid\":\"{s}\",\"in\":{d},\"out\":{d},\"cc\":{d},\"cr\":{d},\"cost\":{d:.8}}}\n",
            .{
                entry.timestamp_s,
                entry.session_id,
                entry.uuid,
                entry.input_tokens,
                entry.output_tokens,
                entry.cache_create_tokens,
                entry.cache_read_tokens,
                entry.cost_usd,
            },
        ) catch return;
        file.writeAll(line) catch {};
    }

    // Read the persist file, age-filter, and populate entries/seen_uuids.
    // Must NOT be called while the mutex is held.
    fn loadFromFile(self: *IngestState, path: []const u8) !void {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const now = std.time.timestamp();
        const cutoff = now - DEFAULT_MAX_AGE_SECONDS;

        var buf_reader = std.io.bufferedReader(file.reader());
        var line_buf = std.ArrayList(u8).init(self.allocator);
        defer line_buf.deinit();

        var loaded: u32 = 0;
        while (true) {
            line_buf.clearRetainingCapacity();
            buf_reader.reader().streamUntilDelimiter(line_buf.writer(), '\n', null) catch |err| {
                if (err == error.EndOfStream) {
                    if (line_buf.items.len == 0) break;
                } else break;
            };
            const trimmed = std.mem.trim(u8, line_buf.items, " \t\r");
            if (trimmed.len == 0) continue;

            const parsed = std.json.parseFromSlice(PersistedLine, self.allocator, trimmed, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();
            const pl = parsed.value;

            if (pl.ts < cutoff) continue;
            if (self.seen_uuids.contains(pl.uuid)) continue;

            const entry = UsageEntry{
                .timestamp_s = pl.ts,
                .session_id = self.allocator.dupe(u8, pl.sid) catch continue,
                .uuid = self.allocator.dupe(u8, pl.uuid) catch continue,
                .input_tokens = pl.in,
                .output_tokens = pl.out,
                .cache_create_tokens = pl.cc,
                .cache_read_tokens = pl.cr,
                .cost_usd = pl.cost,
            };

            const key_copy = self.allocator.dupe(u8, entry.uuid) catch {
                entry.deinit(self.allocator);
                continue;
            };
            self.seen_uuids.put(key_copy, {}) catch {
                self.allocator.free(key_copy);
                entry.deinit(self.allocator);
                continue;
            };
            self.entries.append(entry) catch {
                entry.deinit(self.allocator);
                continue;
            };
            loaded += 1;
        }

        if (loaded > 0) {
            self.last_updated_s = std.time.timestamp();
            std.log.info("state: restored {d} entries from {s}", .{ loaded, path });
        }
    }
};
