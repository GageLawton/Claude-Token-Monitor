// Thread-safe in-memory store for usage entries pushed by ctm-agent.
// Replaces local JSONL file reading when running in ingest (Pi) mode.

const std = @import("std");
const UsageEntry = @import("usage_reader.zig").UsageEntry;
const parseEntryFromLine = @import("usage_reader.zig").parseEntryFromLine;

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

    // Accepts a slice of raw JSONL lines sent by ctm-agent.
    // Returns the number of new unique entries added.
    pub fn addLines(self: *IngestState, lines: []const []const u8) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var added: u32 = 0;
        for (lines) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            const entry = parseEntryFromLine(self.allocator, trimmed) catch continue orelse continue;

            if (self.seen_uuids.contains(entry.uuid)) {
                entry.deinit(self.allocator);
                continue;
            }

            self.seen_uuids.put(
                self.allocator.dupe(u8, entry.uuid) catch {
                    entry.deinit(self.allocator);
                    continue;
                },
                {},
            ) catch {
                entry.deinit(self.allocator);
                continue;
            };

            self.entries.append(entry) catch {
                entry.deinit(self.allocator);
                continue;
            };
            added += 1;
        }

        if (added > 0) self.last_updated_s = std.time.timestamp();
        return added;
    }

    // Returns a snapshot of all entries allocated on `allocator`.
    // Caller owns the returned slice and each entry's strings — call UsageEntry.deinit.
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

    // Drop entries older than cutoff_s to keep memory bounded on Pi Zero.
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
};
