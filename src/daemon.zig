// Background daemon mode: polls for usage changes, sends email notifications.
// Designed to run as a systemd service on Raspberry Pi.

const std = @import("std");
const Config = @import("config.zig").Config;
const UsageReader = @import("usage_reader.zig").UsageReader;
const SessionTracker = @import("session_tracker.zig").SessionTracker;
const WindowStats = @import("session_tracker.zig").WindowStats;
const email = @import("email.zig");

const PID_FILE = "/var/run/ctm.pid";

pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    try daemonize();
    try writePidFile();
    defer std.fs.deleteFileAbsolute(PID_FILE) catch {};

    const log_file: ?std.fs.File = blk: {
        if (config.log_file) |path| {
            break :blk std.fs.createFileAbsolute(path, .{ .truncate = false }) catch null;
        }
        break :blk null;
    };
    defer if (log_file) |f| f.close();

    logInfo(log_file, "ctm daemon started", .{});

    const data_path = try config.getClaudeDataPath(allocator);
    defer if (config.claude_data_path == null) allocator.free(data_path);

    var prev_stats: ?WindowStats = null;
    var notified_limit = false;
    var notified_threshold = false;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var reader = UsageReader.init(a, data_path);
        const entries = reader.readAll() catch {
            logInfo(log_file, "failed to read usage data", .{});
            std.time.sleep(std.time.ns_per_s * config.refresh_interval_seconds);
            continue;
        };

        const tracker = SessionTracker.init(a, entries, config.plan);
        const stats = tracker.currentWindowStats();

        const pct = stats.usagePercent();

        // Detect reset: was at limit last cycle, now tokens are available again.
        if (config.notify_on_reset) {
            if (prev_stats) |prev| {
                if (prev.is_at_limit and !stats.is_at_limit) {
                    notified_limit = false;
                    notified_threshold = false;
                    logInfo(log_file, "token window reset detected — sending email", .{});
                    email.sendNotification(a, config.email, .tokens_reset, stats.tokens_used, stats.token_limit) catch |err| {
                        logInfo(log_file, "email send failed: {}", .{err});
                    };
                }
            }
        }

        // Threshold notification (once per window)
        if (!notified_threshold and pct >= @as(f64, @floatFromInt(config.notify_threshold_percent))) {
            notified_threshold = true;
            logInfo(log_file, "threshold {d}% reached — sending email", .{config.notify_threshold_percent});
            email.sendNotification(a, config.email, .threshold_reached, stats.tokens_used, stats.token_limit) catch |err| {
                logInfo(log_file, "email send failed: {}", .{err});
            };
        }

        if (stats.is_at_limit and !notified_limit) {
            notified_limit = true;
            logInfo(log_file, "token limit reached ({d}/{d})", .{ stats.tokens_used, stats.token_limit });
        }

        logInfo(log_file, "usage: {d}/{d} ({d:.1}%) reset_in={}s", .{
            stats.tokens_used, stats.token_limit, pct, stats.secondsUntilReset(),
        });

        // Copy relevant fields for next iteration (arena will be freed)
        prev_stats = WindowStats{
            .tokens_used = stats.tokens_used,
            .token_limit = stats.token_limit,
            .window_cost_usd = stats.window_cost_usd,
            .window_start_s = stats.window_start_s,
            .reset_at_s = stats.reset_at_s,
            .burn_rate_per_hour = stats.burn_rate_per_hour,
            .entry_count = stats.entry_count,
            .is_at_limit = stats.is_at_limit,
        };

        std.time.sleep(std.time.ns_per_s * config.refresh_interval_seconds);
    }
}

fn daemonize() !void {
    // Double-fork to fully detach from terminal.
    const child1 = try std.posix.fork();
    if (child1 > 0) std.process.exit(0); // parent exits

    _ = try std.posix.setsid();

    const child2 = try std.posix.fork();
    if (child2 > 0) std.process.exit(0); // first child exits

    // Redirect stdin/stdout/stderr to /dev/null
    const null_fd = try std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer std.posix.close(null_fd);
    try std.posix.dup2(null_fd, std.posix.STDIN_FILENO);
    try std.posix.dup2(null_fd, std.posix.STDOUT_FILENO);
    try std.posix.dup2(null_fd, std.posix.STDERR_FILENO);
}

fn writePidFile() !void {
    const pid = std.os.linux.getpid();
    var buf: [32]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch return;

    const f = std.fs.createFileAbsolute(PID_FILE, .{}) catch {
        // Fall back to home dir if /var/run isn't writable (non-root)
        const home = std.posix.getenv("HOME") orelse return;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.ctm.pid", .{home}) catch return;
        const f2 = std.fs.createFileAbsolute(path, .{}) catch return;
        defer f2.close();
        f2.writeAll(pid_str) catch {};
        return;
    };
    defer f.close();
    try f.writeAll(pid_str);
}

fn logInfo(file: ?std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var ts_buf: [32]u8 = undefined;
    const ts = std.time.timestamp();
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{ts}) catch "0";

    const line = std.fmt.allocPrint(
        std.heap.page_allocator,
        "[{s}] ctm: " ++ fmt ++ "\n",
        .{ts_str} ++ args,
    ) catch return;
    defer std.heap.page_allocator.free(line);

    if (file) |f| {
        _ = f.pwrite(line, std.math.maxInt(u64)) catch {};
        f.seekFromEnd(0) catch {};
        f.writeAll(line) catch {};
    }

    // Also write to syslog via stderr before it's redirected
    std.io.getStdErr().writeAll(line) catch {};
}
