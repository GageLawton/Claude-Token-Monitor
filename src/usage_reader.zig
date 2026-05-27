const std = @import("std");

pub const UsageEntry = struct {
    timestamp_s: i64,
    session_id: []const u8,
    uuid: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_create_tokens: u64,
    cache_read_tokens: u64,
    cost_usd: f64,

    pub fn totalTokens(self: UsageEntry) u64 {
        return self.input_tokens + self.output_tokens +
            self.cache_create_tokens + self.cache_read_tokens;
    }

    pub fn deinit(self: UsageEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.uuid);
    }
};

pub const UsageReader = struct {
    allocator: std.mem.Allocator,
    data_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, data_path: []const u8) UsageReader {
        return .{ .allocator = allocator, .data_path = data_path };
    }

    // Reads all usage entries from ~/.claude/projects/**/*.jsonl
    // Caller owns the returned slice and must call deinit on each entry.
    pub fn readAll(self: *UsageReader) ![]UsageEntry {
        var entries = std.ArrayList(UsageEntry).init(self.allocator);
        errdefer {
            for (entries.items) |e| e.deinit(self.allocator);
            entries.deinit();
        }

        // Use a StringHashMap to deduplicate by UUID
        var seen = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = seen.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            seen.deinit();
        }

        var projects_dir = std.fs.openDirAbsolute(self.data_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound or err == error.NotDir) return entries.toOwnedSlice();
            return err;
        };
        defer projects_dir.close();

        var proj_iter = projects_dir.iterate();
        while (try proj_iter.next()) |proj_entry| {
            if (proj_entry.kind != .directory) continue;

            var proj_dir = projects_dir.openDir(proj_entry.name, .{ .iterate = true }) catch continue;
            defer proj_dir.close();

            var file_iter = proj_dir.iterate();
            while (try file_iter.next()) |file_entry| {
                if (file_entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, file_entry.name, ".jsonl")) continue;

                self.readJsonlFile(proj_dir, file_entry.name, &entries, &seen) catch |err| {
                    std.log.warn("skipping {s}: {}", .{ file_entry.name, err });
                };
            }
        }

        return entries.toOwnedSlice();
    }

    fn readJsonlFile(
        self: *UsageReader,
        dir: std.fs.Dir,
        filename: []const u8,
        entries: *std.ArrayList(UsageEntry),
        seen: *std.StringHashMap(void),
    ) !void {
        const file = try dir.openFile(filename, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 32 * 1024 * 1024);
        defer self.allocator.free(content);

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            self.parseLine(trimmed, entries, seen) catch {};
        }
    }

    fn parseLine(
        self: *UsageReader,
        line: []const u8,
        entries: *std.ArrayList(UsageEntry),
        seen: *std.StringHashMap(void),
    ) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;
        const obj = root.object;

        // Claude Code writes assistant turn entries with type = "assistant"
        const type_val = obj.get("type") orelse return;
        if (type_val != .string) return;
        if (!std.mem.eql(u8, type_val.string, "assistant")) return;

        // UUID for deduplication
        const uuid_val = obj.get("uuid") orelse return;
        if (uuid_val != .string) return;
        if (seen.contains(uuid_val.string)) return;

        const ts_val = obj.get("timestamp") orelse return;
        if (ts_val != .string) return;
        const ts_s = parseIso8601(ts_val.string) catch return;

        const session_val = obj.get("sessionId") orelse return;
        if (session_val != .string) return;

        var cost: f64 = 0;
        if (obj.get("costUSD")) |v| {
            cost = switch (v) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => 0,
            };
        }

        // Usage lives in message.usage
        const msg_val = obj.get("message") orelse return;
        if (msg_val != .object) return;
        const msg = msg_val.object;

        const usage_val = msg.get("usage") orelse return;
        if (usage_val != .object) return;
        const usage = usage_val.object;

        const uuid_owned = try self.allocator.dupe(u8, uuid_val.string);
        errdefer self.allocator.free(uuid_owned);

        try seen.put(try self.allocator.dupe(u8, uuid_val.string), {});

        try entries.append(.{
            .timestamp_s = ts_s,
            .session_id = try self.allocator.dupe(u8, session_val.string),
            .uuid = uuid_owned,
            .input_tokens = jsonUint(usage, "input_tokens"),
            .output_tokens = jsonUint(usage, "output_tokens"),
            .cache_create_tokens = jsonUint(usage, "cache_creation_input_tokens"),
            .cache_read_tokens = jsonUint(usage, "cache_read_input_tokens"),
            .cost_usd = cost,
        });
    }
};

fn jsonUint(obj: std.json.ObjectMap, key: []const u8) u64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        else => 0,
    };
}

// Parses "YYYY-MM-DDTHH:MM:SS[.mmm]Z" -> Unix seconds.
pub fn parseIso8601(s: []const u8) !i64 {
    if (s.len < 19) return error.InvalidTimestamp;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') {
        return error.InvalidTimestamp;
    }

    const year = try std.fmt.parseInt(i64, s[0..4], 10);
    const month = try std.fmt.parseInt(i64, s[5..7], 10);
    const day = try std.fmt.parseInt(i64, s[8..10], 10);
    const hour = try std.fmt.parseInt(i64, s[11..13], 10);
    const minute = try std.fmt.parseInt(i64, s[14..16], 10);
    const second = try std.fmt.parseInt(i64, s[17..19], 10);

    const days = civilToDays(year, month, day);
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

// Howard Hinnant's civil_from_days in reverse.
fn civilToDays(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "parseIso8601" {
    const ts = try parseIso8601("2024-01-15T10:30:00.000Z");
    try std.testing.expect(ts > 0);
}

test "civilToDays epoch" {
    // 1970-01-01 should be day 0
    try std.testing.expectEqual(@as(i64, 0), civilToDays(1970, 1, 1));
}
