const std = @import("std");
const UsageEntry = @import("usage_reader.zig").UsageEntry;
const Plan = @import("config.zig").Plan;

// Claude's rate limit window is 5 hours.
const WINDOW_SECONDS: i64 = 5 * 60 * 60;

pub const WindowStats = struct {
    tokens_used: u64,
    token_limit: u64,
    window_cost_usd: f64,
    // Oldest entry in the current window; reset happens at oldest + 5h.
    window_start_s: i64,
    reset_at_s: i64,
    // Tokens/hour based on the last hour of activity.
    burn_rate_per_hour: f64,
    entry_count: usize,
    is_at_limit: bool,

    pub fn usagePercent(self: WindowStats) f64 {
        if (self.token_limit == 0) return 0;
        return @as(f64, @floatFromInt(self.tokens_used)) /
            @as(f64, @floatFromInt(self.token_limit)) * 100.0;
    }

    pub fn secondsUntilReset(self: WindowStats) i64 {
        const now = std.time.timestamp();
        if (self.reset_at_s <= now) return 0;
        return self.reset_at_s - now;
    }

    pub fn tokensRemaining(self: WindowStats) u64 {
        if (self.tokens_used >= self.token_limit) return 0;
        return self.token_limit - self.tokens_used;
    }

    // Human-readable countdown: "2h 34m" or "45m 12s" or "Ready"
    pub fn resetInHuman(self: WindowStats, buf: []u8) []const u8 {
        const secs = self.secondsUntilReset();
        if (secs <= 0) return "Ready";
        const h = @divFloor(secs, 3600);
        const m = @divFloor(@mod(secs, 3600), 60);
        const s = @mod(secs, 60);
        if (h > 0) {
            return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ h, m }) catch "?";
        } else if (m > 0) {
            return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ m, s }) catch "?";
        } else {
            return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "?";
        }
    }
};

pub const SessionTracker = struct {
    allocator: std.mem.Allocator,
    entries: []const UsageEntry,
    plan: Plan,

    pub fn init(allocator: std.mem.Allocator, entries: []const UsageEntry, plan: Plan) SessionTracker {
        return .{ .allocator = allocator, .entries = entries, .plan = plan };
    }

    pub fn currentWindowStats(self: SessionTracker) WindowStats {
        const now = std.time.timestamp();
        const window_start = now - WINDOW_SECONDS;

        var tokens_used: u64 = 0;
        var cost: f64 = 0;
        var count: usize = 0;
        var oldest_in_window: i64 = now;

        for (self.entries) |e| {
            if (e.timestamp_s < window_start) continue;
            tokens_used += e.totalTokens();
            cost += e.cost_usd;
            count += 1;
            if (e.timestamp_s < oldest_in_window) {
                oldest_in_window = e.timestamp_s;
            }
        }

        const reset_at = if (count > 0) oldest_in_window + WINDOW_SECONDS else now;
        const limit = self.plan.tokenLimit();

        return .{
            .tokens_used = tokens_used,
            .token_limit = limit,
            .window_cost_usd = cost,
            .window_start_s = if (count > 0) oldest_in_window else now,
            .reset_at_s = reset_at,
            .burn_rate_per_hour = self.calcBurnRate(now),
            .entry_count = count,
            .is_at_limit = tokens_used >= limit,
        };
    }

    // Compute tokens/hour over the most recent hour of activity.
    fn calcBurnRate(self: SessionTracker, now: i64) f64 {
        const one_hour_ago = now - 3600;
        var tokens: u64 = 0;
        var earliest: i64 = now;
        var latest: i64 = one_hour_ago;

        for (self.entries) |e| {
            if (e.timestamp_s < one_hour_ago) continue;
            tokens += e.totalTokens();
            if (e.timestamp_s < earliest) earliest = e.timestamp_s;
            if (e.timestamp_s > latest) latest = e.timestamp_s;
        }

        if (tokens == 0) return 0;
        const span_hours = @as(f64, @floatFromInt(latest - earliest)) / 3600.0;
        if (span_hours < 0.001) return @as(f64, @floatFromInt(tokens));
        return @as(f64, @floatFromInt(tokens)) / span_hours;
    }

    // Returns per-session breakdown sorted newest-first.
    pub fn sessionSummaries(self: SessionTracker, allocator: std.mem.Allocator) ![]SessionSummary {
        var map = std.StringHashMap(SessionSummary).init(allocator);
        defer map.deinit();

        for (self.entries) |e| {
            const gop = try map.getOrPut(e.session_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .session_id = e.session_id,
                    .tokens = 0,
                    .cost_usd = 0,
                    .start_s = e.timestamp_s,
                    .end_s = e.timestamp_s,
                    .entry_count = 0,
                };
            }
            gop.value_ptr.tokens += e.totalTokens();
            gop.value_ptr.cost_usd += e.cost_usd;
            gop.value_ptr.entry_count += 1;
            if (e.timestamp_s < gop.value_ptr.start_s) gop.value_ptr.start_s = e.timestamp_s;
            if (e.timestamp_s > gop.value_ptr.end_s) gop.value_ptr.end_s = e.timestamp_s;
        }

        var summaries = std.ArrayList(SessionSummary).init(allocator);
        var it = map.valueIterator();
        while (it.next()) |v| try summaries.append(v.*);

        const S = struct {
            fn desc(_: void, a: SessionSummary, b: SessionSummary) bool {
                return a.end_s > b.end_s;
            }
        };
        std.sort.pdq(SessionSummary, summaries.items, {}, S.desc);

        return summaries.toOwnedSlice();
    }
};

pub const SessionSummary = struct {
    session_id: []const u8,
    tokens: u64,
    cost_usd: f64,
    start_s: i64,
    end_s: i64,
    entry_count: usize,
};
