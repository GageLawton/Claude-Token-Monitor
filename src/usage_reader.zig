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

// Default grace window: any entry whose timestamp falls within the last
// 5h + 10min is kept. Anything older is discarded at parse time.
pub const WINDOW_SECONDS: i64 = 5 * 60 * 60;
pub const GRACE_SECONDS: i64 = 10 * 60;
pub const DEFAULT_MAX_AGE_SECONDS: i64 = WINDOW_SECONDS + GRACE_SECONDS;

pub const ParseOptions = struct {
    // Reject entries older than (now - max_age_seconds). 0 disables the filter.
    max_age_seconds: i64 = DEFAULT_MAX_AGE_SECONDS,
    now_s: ?i64 = null, // override for tests
};

pub const UsageReader = struct {
    allocator: std.mem.Allocator,
    data_path: []const u8,
    options: ParseOptions,

    pub fn init(allocator: std.mem.Allocator, data_path: []const u8) UsageReader {
        return .{ .allocator = allocator, .data_path = data_path, .options = .{} };
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        data_path: []const u8,
        options: ParseOptions,
    ) UsageReader {
        return .{ .allocator = allocator, .data_path = data_path, .options = options };
    }

    // Reads every JSONL file under data_path. Streams line-by-line, so peak
    // memory is bounded by the longest single line rather than file size.
    // Returns a deduplicated slice; caller owns and must call deinit on each.
    pub fn readAll(self: *UsageReader) ![]UsageEntry {
        var entries = std.ArrayList(UsageEntry).init(self.allocator);
        errdefer {
            for (entries.items) |e| e.deinit(self.allocator);
            entries.deinit();
        }

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

                self.streamJsonlFile(proj_dir, file_entry.name, &entries, &seen) catch |err| {
                    std.log.warn("skipping {s}: {}", .{ file_entry.name, err });
                };
            }
        }

        return entries.toOwnedSlice();
    }

    fn streamJsonlFile(
        self: *UsageReader,
        dir: std.fs.Dir,
        filename: []const u8,
        entries: *std.ArrayList(UsageEntry),
        seen: *std.StringHashMap(void),
    ) !void {
        const file = try dir.openFile(filename, .{});
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var line_buf = std.ArrayList(u8).init(self.allocator);
        defer line_buf.deinit();

        while (true) {
            line_buf.clearRetainingCapacity();
            buf_reader.reader().streamUntilDelimiter(line_buf.writer(), '\n', null) catch |err| {
                if (err == error.EndOfStream) {
                    if (line_buf.items.len == 0) break;
                    // fall through to process the final un-newlined line
                } else {
                    return err;
                }
            };
            const trimmed = std.mem.trim(u8, line_buf.items, " \t\r");
            if (trimmed.len == 0) continue;
            self.consumeLine(trimmed, entries, seen) catch {};
        }
    }

    fn consumeLine(
        self: *UsageReader,
        line: []const u8,
        entries: *std.ArrayList(UsageEntry),
        seen: *std.StringHashMap(void),
    ) !void {
        const entry = (try parseEntryFromLine(self.allocator, line, self.options)) orelse return;
        if (seen.contains(entry.uuid)) {
            entry.deinit(self.allocator);
            return;
        }
        const owned_key = try self.allocator.dupe(u8, entry.uuid);
        errdefer self.allocator.free(owned_key);
        try seen.put(owned_key, {});
        try entries.append(entry);
    }
};

// JSONL line shape written by Claude Code. Only the fields we need.
// All optional so missing/unknown fields don't fail the parse.
const RawLine = struct {
    type: ?[]const u8 = null,
    uuid: ?[]const u8 = null,
    sessionId: ?[]const u8 = null,
    timestamp: ?[]const u8 = null,
    costUSD: ?f64 = null,
    message: ?MessageBlock = null,

    const MessageBlock = struct {
        usage: ?UsageBlock = null,
    };

    const UsageBlock = struct {
        input_tokens: ?u64 = null,
        output_tokens: ?u64 = null,
        cache_creation_input_tokens: ?u64 = null,
        cache_read_input_tokens: ?u64 = null,
    };
};

// Parses a single JSONL line into a UsageEntry. Returns null for:
//   - non-assistant entries
//   - malformed JSON
//   - entries older than options.max_age_seconds
// Caller owns the returned entry and must call deinit.
pub fn parseEntryFromLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    options: ParseOptions,
) !?UsageEntry {
    var parsed = std.json.parseFromSlice(RawLine, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const raw = parsed.value;

    const type_str = raw.type orelse return null;
    if (!std.mem.eql(u8, type_str, "assistant")) return null;

    const uuid = raw.uuid orelse return null;
    const session_id = raw.sessionId orelse return null;
    const ts_str = raw.timestamp orelse return null;
    const message = raw.message orelse return null;
    const usage = message.usage orelse return null;

    const ts_s = parseIso8601(ts_str) catch return null;

    if (options.max_age_seconds > 0) {
        const now = options.now_s orelse std.time.timestamp();
        if (ts_s < now - options.max_age_seconds) return null;
    }

    return .{
        .timestamp_s = ts_s,
        .session_id = try allocator.dupe(u8, session_id),
        .uuid = try allocator.dupe(u8, uuid),
        .input_tokens = usage.input_tokens orelse 0,
        .output_tokens = usage.output_tokens orelse 0,
        .cache_create_tokens = usage.cache_creation_input_tokens orelse 0,
        .cache_read_tokens = usage.cache_read_input_tokens orelse 0,
        .cost_usd = raw.costUSD orelse 0,
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

// Howard Hinnant's civil_from_days, reversed.
fn civilToDays(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "parseIso8601 known values" {
    const ts = try parseIso8601("2024-01-15T10:30:00.000Z");
    try std.testing.expectEqual(@as(i64, 1705314600), ts);
}

test "civilToDays epoch" {
    try std.testing.expectEqual(@as(i64, 0), civilToDays(1970, 1, 1));
}

test "parseEntryFromLine drops entries older than max_age_seconds" {
    const allocator = std.testing.allocator;
    const old_line =
        \\{"type":"assistant","uuid":"u1","sessionId":"s","timestamp":"2000-01-01T00:00:00Z","message":{"usage":{"input_tokens":10}}}
    ;
    // now=2024 with default max_age means a 2000 entry must be dropped.
    const opts = ParseOptions{ .now_s = 1705314600, .max_age_seconds = DEFAULT_MAX_AGE_SECONDS };
    const result = try parseEntryFromLine(allocator, old_line, opts);
    try std.testing.expect(result == null);
}

test "parseEntryFromLine keeps recent entries" {
    const allocator = std.testing.allocator;
    const line =
        \\{"type":"assistant","uuid":"u2","sessionId":"s","timestamp":"2024-01-15T10:30:00Z","message":{"usage":{"input_tokens":100,"output_tokens":200}}}
    ;
    const opts = ParseOptions{ .now_s = 1705314600 + 60, .max_age_seconds = DEFAULT_MAX_AGE_SECONDS };
    const entry = (try parseEntryFromLine(allocator, line, opts)) orelse return error.UnexpectedNull;
    defer entry.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 300), entry.totalTokens());
}
