// Thread-safe in-memory store for usage entries. Used both by the Pi's HTTP
// ingest endpoint and by the local-mode daemon (which feeds it via Watcher).

const std = @import("std");
const usage = @import("usage_reader.zig");
const UsageEntry = usage.UsageEntry;
const parseEntryFromLine = usage.parseEntryFromLine;
const ParseOptions = usage.ParseOptions;

pub const IngestState = struct {
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,
    entries: std.ArrayList(UsageEntry),
    seen_uuids: std.StringHashMap(void),
    last_updated_s: i64 = 0,

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
                // The uuid is already in the map; leaving it there is harmless
                // because the entry is gone — the worst case is rejecting a
                // legitimate retry of the same uuid. Acceptable.
                entry.deinit(self.allocator);
                continue;
            };
            added += 1;
        }

        if (added > 0) self.last_updated_s = std.time.timestamp();
        return added;
    }

    // Returns a snapshot of all entries allocated on `allocator`.
    // Caller owns the returned slice and each entry's strings.
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
};
