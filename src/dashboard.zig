const std = @import("std");
const Config = @import("config.zig").Config;
const UsageReader = @import("usage_reader.zig").UsageReader;
const SessionTracker = @import("session_tracker.zig").SessionTracker;
const WindowStats = @import("session_tracker.zig").WindowStats;

// ANSI escape sequences
const ESC = "\x1b[";
const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const GREEN = "\x1b[32m";
const CYAN = "\x1b[36m";
const WHITE = "\x1b[97m";
const CLEAR_SCREEN = "\x1b[2J\x1b[H";
const HIDE_CURSOR = "\x1b[?25l";
const SHOW_CURSOR = "\x1b[?25h";

const BAR_WIDTH = 36;

pub const Dashboard = struct {
    pub fn run(allocator: std.mem.Allocator, config: Config) !void {
        const stdout = std.io.getStdOut();
        const writer = stdout.writer();

        // Hide cursor for clean display
        try writer.writeAll(HIDE_CURSOR);
        defer writer.writeAll(SHOW_CURSOR) catch {};

        // Handle Ctrl+C gracefully
        const orig_action = try setSignalHandler();
        defer restoreSignalHandler(orig_action);

        const data_path = try config.getClaudeDataPath(allocator);
        defer if (config.claude_data_path == null) allocator.free(data_path);

        while (g_running) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var reader = UsageReader.init(a, data_path);
            const entries = reader.readAll() catch &[_]@import("usage_reader.zig").UsageEntry{};

            const tracker = SessionTracker.init(a, entries, config.plan);
            const stats = tracker.currentWindowStats();

            try renderFrame(writer, stats, config, a);

            std.time.sleep(std.time.ns_per_s * config.refresh_interval_seconds);
        }

        // Final clear on exit
        try writer.writeAll(CLEAR_SCREEN);
        try writer.writeAll("Claude Token Monitor stopped.\n");
    }

    fn renderFrame(
        writer: anytype,
        stats: WindowStats,
        config: Config,
        allocator: std.mem.Allocator,
    ) !void {
        _ = allocator;
        const now_s = std.time.timestamp();

        var time_buf: [32]u8 = undefined;
        const time_str = formatTime(now_s, &time_buf);

        var reset_buf: [32]u8 = undefined;
        const reset_str = stats.resetInHuman(&reset_buf);

        const pct = stats.usagePercent();
        const color = if (pct >= 90.0) RED else if (pct >= 70.0) YELLOW else GREEN;

        try writer.writeAll(CLEAR_SCREEN);

        // ╔════ Header ════╗
        try writer.writeAll(BOLD ++ CYAN);
        try writer.writeAll("╔══════════════════════════════════════════════════╗\n");
        try writer.writeAll("║        CLAUDE TOKEN MONITOR  (ctm)               ║\n");
        try writer.writeAll("╠══════════════════════════════════════════════════╣\n");
        try writer.writeAll(RESET);

        // Plan / window info
        try writer.print("║  " ++ BOLD ++ "Plan:    " ++ RESET ++ "  {s:<40}║\n", .{config.plan.displayName()});
        try writer.print("║  " ++ BOLD ++ "Window:  " ++ RESET ++ "  5h rolling  (resets in {s:<19})║\n", .{reset_str});

        try writer.writeAll(CYAN ++ "╠══════════════════════════════════════════════════╣\n" ++ RESET);

        // Progress bar
        var bar_buf: [BAR_WIDTH * 4 + 8]u8 = undefined;
        const bar = makeProgressBar(stats.tokens_used, stats.token_limit, BAR_WIDTH, &bar_buf);

        try writer.print("║  " ++ BOLD ++ "Usage:   " ++ RESET ++ " {s}{s}" ++ RESET ++ " {d:.1}%  " ++ DIM ++ "           ║\n", .{
            color, bar, pct,
        });
        try writer.print("║           {s}{d:>10}{s} / {d:<10} tokens      ║\n", .{
            color, stats.tokens_used, RESET, stats.token_limit,
        });
        try writer.print("║           Remaining: {s}{d:<10}{s} tokens           ║\n", .{
            color, stats.tokensRemaining(), RESET,
        });

        try writer.writeAll(CYAN ++ "╠══════════════════════════════════════════════════╣\n" ++ RESET);

        // Cost & burn rate
        try writer.print("║  " ++ BOLD ++ "Cost:    " ++ RESET ++ "  ${d:.4} (this window){s:<20}║\n", .{ stats.window_cost_usd, "" });
        if (stats.burn_rate_per_hour > 0) {
            try writer.print("║  " ++ BOLD ++ "Burn:    " ++ RESET ++ "  ~{d:.0} tokens/hour{s:<22}║\n", .{ stats.burn_rate_per_hour, "" });
        } else {
            try writer.writeAll("║  " ++ BOLD ++ "Burn:    " ++ RESET ++ "  idle{s:<45}║\n");
        }

        if (stats.is_at_limit) {
            try writer.writeAll("║  " ++ RED ++ BOLD ++ "  *** LIMIT REACHED — waiting for reset ***" ++ RESET ++ "     ║\n");
        }

        try writer.writeAll(CYAN ++ "╠══════════════════════════════════════════════════╣\n" ++ RESET);
        try writer.print("║  " ++ DIM ++ "Updated: {s:<42}" ++ RESET ++ "║\n", .{time_str});
        try writer.print("║  " ++ DIM ++ "Entries: {d:<42}" ++ RESET ++ "║\n", .{stats.entry_count});
        try writer.writeAll(CYAN ++ "╚══════════════════════════════════════════════════╝\n" ++ RESET);
        try writer.writeAll(DIM ++ "  Press Ctrl+C to exit.\n" ++ RESET);
    }
};

fn makeProgressBar(used: u64, total: u64, width: usize, buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    const filled: usize = if (total == 0)
        0
    else
        @intFromFloat(@min(
            @as(f64, @floatFromInt(width)),
            @round(@as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(total)) * @as(f64, @floatFromInt(width))),
        ));

    w.writeByte('[') catch return "?";
    for (0..width) |i| {
        if (i < filled) {
            w.writeAll("█") catch break;
        } else {
            w.writeAll("░") catch break;
        }
    }
    w.writeByte(']') catch {};

    return fbs.getWritten();
}

fn formatTime(ts: i64, buf: []u8) []const u8 {
    // Simple HH:MM:SS UTC display
    const secs = @mod(ts, 86400);
    const h = @divFloor(secs, 3600);
    const m = @divFloor(@mod(secs, 3600), 60);
    const s = @mod(secs, 60);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2} UTC", .{ h, m, s }) catch "??:??:??";
}

// Signal handling for clean Ctrl+C exit
var g_running: bool = true;

fn setSignalHandler() !std.posix.Sigaction {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    var old: std.posix.Sigaction = undefined;
    try std.posix.sigaction(std.posix.SIG.INT, &action, &old);
    try std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    return old;
}

fn restoreSignalHandler(old: std.posix.Sigaction) void {
    std.posix.sigaction(std.posix.SIG.INT, &old, null) catch {};
}

fn handleSigint(_: c_int) callconv(.C) void {
    g_running = false;
}
