const std = @import("std");
const testing = std.testing;
const tracker_mod = @import("session_tracker");
const usage = @import("usage_reader");
const config = @import("config");

const SessionTracker = tracker_mod.SessionTracker;
const UsageEntry = usage.UsageEntry;

fn makeEntry(ts: i64, session: []const u8, uuid: []const u8, in: u64, out: u64, cost: f64) UsageEntry {
    return .{
        .timestamp_s = ts,
        .session_id = session,
        .uuid = uuid,
        .input_tokens = in,
        .output_tokens = out,
        .cache_create_tokens = 0,
        .cache_read_tokens = 0,
        .cost_usd = cost,
    };
}

test "currentWindowStats includes entries from last 5 hours" {
    const now = std.time.timestamp();
    const entries = [_]UsageEntry{
        makeEntry(now - 60, "s1", "u1", 100, 200, 0.05),
        makeEntry(now - 3600, "s1", "u2", 50, 50, 0.02),
    };

    const t = SessionTracker.init(testing.allocator, &entries, .pro);
    const stats = t.currentWindowStats();

    try testing.expectEqual(@as(u64, 400), stats.tokens_used);
    try testing.expectApproxEqAbs(@as(f64, 0.07), stats.window_cost_usd, 0.0001);
    try testing.expectEqual(@as(usize, 2), stats.entry_count);
}

test "currentWindowStats excludes entries older than 5 hours" {
    const now = std.time.timestamp();
    const six_hours = 6 * 60 * 60;
    const entries = [_]UsageEntry{
        makeEntry(now - 60, "s1", "u1", 100, 100, 0.05),
        makeEntry(now - six_hours, "s1", "u_old", 99999, 99999, 99.99),
    };

    const t = SessionTracker.init(testing.allocator, &entries, .pro);
    const stats = t.currentWindowStats();

    try testing.expectEqual(@as(u64, 200), stats.tokens_used);
    try testing.expectEqual(@as(usize, 1), stats.entry_count);
}

test "currentWindowStats with no entries returns zero usage" {
    const entries = [_]UsageEntry{};
    const t = SessionTracker.init(testing.allocator, &entries, .pro);
    const stats = t.currentWindowStats();

    try testing.expectEqual(@as(u64, 0), stats.tokens_used);
    try testing.expectEqual(@as(usize, 0), stats.entry_count);
    try testing.expectEqual(@as(f64, 0), stats.burn_rate_per_hour);
    try testing.expect(!stats.is_at_limit);
}

test "reset_at is window_start + 5 hours" {
    const now = std.time.timestamp();
    const entries = [_]UsageEntry{
        makeEntry(now - 1000, "s1", "u1", 10, 10, 0),
    };
    const t = SessionTracker.init(testing.allocator, &entries, .pro);
    const stats = t.currentWindowStats();

    const expected_reset = (now - 1000) + 5 * 60 * 60;
    try testing.expectEqual(expected_reset, stats.reset_at_s);
}

test "is_at_limit flips true when tokens_used >= limit" {
    const now = std.time.timestamp();
    const entries = [_]UsageEntry{
        makeEntry(now - 60, "s1", "u1", 50_000, 50_000, 0),
    };
    const t = SessionTracker.init(testing.allocator, &entries, .pro);
    const stats = t.currentWindowStats();

    try testing.expect(stats.is_at_limit);
    try testing.expectEqual(@as(u64, 0), stats.tokensRemaining());
}

test "usagePercent is computed correctly" {
    const now = std.time.timestamp();
    // Pro limit is 88_000; 44_000 = 50%
    const entries = [_]UsageEntry{
        makeEntry(now - 60, "s1", "u1", 22_000, 22_000, 0),
    };
    const t = SessionTracker.init(testing.allocator, &entries, .pro);
    const stats = t.currentWindowStats();

    try testing.expectApproxEqAbs(@as(f64, 50.0), stats.usagePercent(), 0.01);
}

test "different plans yield different limits" {
    const now = std.time.timestamp();
    const entries = [_]UsageEntry{
        makeEntry(now - 60, "s1", "u1", 100_000, 100_000, 0),
    };

    const pro = SessionTracker.init(testing.allocator, &entries, .pro).currentWindowStats();
    const max5 = SessionTracker.init(testing.allocator, &entries, .max5).currentWindowStats();
    const max20 = SessionTracker.init(testing.allocator, &entries, .max20).currentWindowStats();

    try testing.expect(pro.token_limit < max5.token_limit);
    try testing.expect(max5.token_limit < max20.token_limit);
    try testing.expect(pro.is_at_limit); // 200k > 88k
    try testing.expect(!max5.is_at_limit); // 200k < 440k
}

test "secondsUntilReset returns 0 when reset is in the past" {
    const stats = tracker_mod.WindowStats{
        .tokens_used = 0,
        .token_limit = 1000,
        .window_cost_usd = 0,
        .window_start_s = 0,
        .reset_at_s = 0,
        .burn_rate_per_hour = 0,
        .entry_count = 0,
        .is_at_limit = false,
    };
    try testing.expectEqual(@as(i64, 0), stats.secondsUntilReset());
}

test "resetInHuman formats hours, minutes, and seconds" {
    var buf: [32]u8 = undefined;
    const now = std.time.timestamp();

    const hours_left = tracker_mod.WindowStats{
        .tokens_used = 0,
        .token_limit = 1,
        .window_cost_usd = 0,
        .window_start_s = 0,
        .reset_at_s = now + 7325, // 2h 02m 05s
        .burn_rate_per_hour = 0,
        .entry_count = 0,
        .is_at_limit = false,
    };
    const s = hours_left.resetInHuman(&buf);
    try testing.expect(std.mem.indexOf(u8, s, "h") != null);

    var buf2: [32]u8 = undefined;
    const ready = tracker_mod.WindowStats{
        .tokens_used = 0,
        .token_limit = 1,
        .window_cost_usd = 0,
        .window_start_s = 0,
        .reset_at_s = now - 10,
        .burn_rate_per_hour = 0,
        .entry_count = 0,
        .is_at_limit = false,
    };
    try testing.expectEqualStrings("Ready", ready.resetInHuman(&buf2));
}

test "sessionSummaries groups entries by session_id" {
    const now = std.time.timestamp();
    const entries = [_]UsageEntry{
        makeEntry(now - 60, "session-a", "u1", 100, 100, 0.01),
        makeEntry(now - 120, "session-a", "u2", 50, 50, 0.005),
        makeEntry(now - 30, "session-b", "u3", 200, 200, 0.02),
    };

    const t = SessionTracker.init(testing.allocator, &entries, .pro);
    const summaries = try t.sessionSummaries(testing.allocator);
    defer testing.allocator.free(summaries);

    try testing.expectEqual(@as(usize, 2), summaries.len);
    // Newest end_s first -> session-b
    try testing.expectEqualStrings("session-b", summaries[0].session_id);
    try testing.expectEqual(@as(u64, 400), summaries[0].tokens);
    try testing.expectEqualStrings("session-a", summaries[1].session_id);
    try testing.expectEqual(@as(u64, 300), summaries[1].tokens);
    try testing.expectEqual(@as(usize, 2), summaries[1].entry_count);
}

test "burn rate is positive when there is recent activity" {
    const now = std.time.timestamp();
    const entries = [_]UsageEntry{
        makeEntry(now - 1800, "s1", "u1", 1000, 1000, 0),
        makeEntry(now - 60, "s1", "u2", 1000, 1000, 0),
    };
    const t = SessionTracker.init(testing.allocator, &entries, .pro);
    const stats = t.currentWindowStats();

    try testing.expect(stats.burn_rate_per_hour > 0);
}

test "Plan.fromString and tokenLimit" {
    try testing.expectEqual(config.Plan.pro, config.Plan.fromString("pro"));
    try testing.expectEqual(config.Plan.max5, config.Plan.fromString("max5"));
    try testing.expectEqual(config.Plan.max20, config.Plan.fromString("max20"));
    try testing.expectEqual(config.Plan.pro, config.Plan.fromString("unknown"));

    try testing.expect(config.Plan.pro.tokenLimit() < config.Plan.max5.tokenLimit());
    try testing.expect(config.Plan.max5.tokenLimit() < config.Plan.max20.tokenLimit());
}
