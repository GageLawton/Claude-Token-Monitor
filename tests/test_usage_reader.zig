const std = @import("std");
const testing = std.testing;
const usage = @import("usage_reader");

test "parseIso8601 converts basic timestamp to unix seconds" {
    const ts = try usage.parseIso8601("2024-01-15T10:30:00.000Z");
    // 2024-01-15T10:30:00 UTC = 1705314600
    try testing.expectEqual(@as(i64, 1705314600), ts);
}

test "parseIso8601 handles second precision without millis" {
    const ts = try usage.parseIso8601("2024-01-15T10:30:00Z");
    try testing.expectEqual(@as(i64, 1705314600), ts);
}

test "parseIso8601 rejects malformed input" {
    try testing.expectError(error.InvalidTimestamp, usage.parseIso8601("nope"));
    try testing.expectError(error.InvalidTimestamp, usage.parseIso8601("2024/01/15T10:30:00Z"));
}

test "parseIso8601 epoch is zero" {
    const ts = try usage.parseIso8601("1970-01-01T00:00:00Z");
    try testing.expectEqual(@as(i64, 0), ts);
}

test "parseIso8601 handles year boundary" {
    const ts_end = try usage.parseIso8601("2023-12-31T23:59:59Z");
    const ts_start = try usage.parseIso8601("2024-01-01T00:00:00Z");
    try testing.expectEqual(@as(i64, 1), ts_start - ts_end);
}

test "UsageEntry totalTokens sums all four token types" {
    const e = usage.UsageEntry{
        .timestamp_s = 0,
        .session_id = "",
        .uuid = "",
        .input_tokens = 100,
        .output_tokens = 200,
        .cache_create_tokens = 50,
        .cache_read_tokens = 25,
        .cost_usd = 0,
    };
    try testing.expectEqual(@as(u64, 375), e.totalTokens());
}

test "UsageEntry totalTokens handles zeros" {
    const e = usage.UsageEntry{
        .timestamp_s = 0,
        .session_id = "",
        .uuid = "",
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_create_tokens = 0,
        .cache_read_tokens = 0,
        .cost_usd = 0,
    };
    try testing.expectEqual(@as(u64, 0), e.totalTokens());
}

// End-to-end: write a fake JSONL file and verify the reader parses it.
test "UsageReader parses real-shaped JSONL and deduplicates by uuid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create projects/<dir>/<file>.jsonl structure
    try tmp.dir.makePath("projects/myproj");
    var proj_dir = try tmp.dir.openDir("projects/myproj", .{});
    defer proj_dir.close();

    const file = try proj_dir.createFile("session.jsonl", .{});
    defer file.close();

    // Two assistant entries (one duplicate uuid) + a non-assistant entry that should be ignored
    const jsonl =
        \\{"type":"assistant","uuid":"u1","sessionId":"s1","timestamp":"2024-06-01T10:00:00.000Z","costUSD":0.05,"message":{"usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":10,"cache_read_input_tokens":5}}}
        \\{"type":"user","uuid":"u-user","sessionId":"s1","timestamp":"2024-06-01T10:00:01.000Z"}
        \\{"type":"assistant","uuid":"u2","sessionId":"s1","timestamp":"2024-06-01T10:05:00.000Z","costUSD":0.10,"message":{"usage":{"input_tokens":50,"output_tokens":75}}}
        \\{"type":"assistant","uuid":"u1","sessionId":"s1","timestamp":"2024-06-01T10:00:00.000Z","costUSD":0.05,"message":{"usage":{"input_tokens":100,"output_tokens":200}}}
        \\
    ;
    try file.writeAll(jsonl);

    // Resolve absolute path to the tmp projects dir
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const projects_path = try tmp.dir.realpath("projects", &path_buf);

    var reader = usage.UsageReader.init(testing.allocator, projects_path);
    const entries = try reader.readAll();
    defer {
        for (entries) |e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    // Should have 2 unique assistant entries (u1 deduped, user entry skipped)
    try testing.expectEqual(@as(usize, 2), entries.len);

    var total_tokens: u64 = 0;
    var total_cost: f64 = 0;
    for (entries) |e| {
        total_tokens += e.totalTokens();
        total_cost += e.cost_usd;
    }
    // u1: 100+200+10+5 = 315; u2: 50+75 = 125; total = 440
    try testing.expectEqual(@as(u64, 440), total_tokens);
    try testing.expectApproxEqAbs(@as(f64, 0.15), total_cost, 0.0001);
}

test "UsageReader returns empty when data path does not exist" {
    var reader = usage.UsageReader.init(testing.allocator, "/nonexistent/path/that/should/not/exist");
    const entries = try reader.readAll();
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "UsageReader skips malformed JSON lines without failing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("projects/p");
    var proj_dir = try tmp.dir.openDir("projects/p", .{});
    defer proj_dir.close();

    const file = try proj_dir.createFile("s.jsonl", .{});
    defer file.close();
    try file.writeAll(
        \\not json at all
        \\{"type":"assistant","uuid":"u1","sessionId":"s","timestamp":"2024-06-01T10:00:00Z","message":{"usage":{"input_tokens":10,"output_tokens":20}}}
        \\{"incomplete":
        \\
    );

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const projects_path = try tmp.dir.realpath("projects", &path_buf);

    var reader = usage.UsageReader.init(testing.allocator, projects_path);
    const entries = try reader.readAll();
    defer {
        for (entries) |e| e.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u64, 30), entries[0].totalTokens());
}

test "UsageReader ignores non-jsonl files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("projects/p");
    var proj_dir = try tmp.dir.openDir("projects/p", .{});
    defer proj_dir.close();

    const f = try proj_dir.createFile("notes.txt", .{});
    defer f.close();
    try f.writeAll("this is not a jsonl file");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const projects_path = try tmp.dir.realpath("projects", &path_buf);

    var reader = usage.UsageReader.init(testing.allocator, projects_path);
    const entries = try reader.readAll();
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}
