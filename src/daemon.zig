// Background daemon mode: monitors token usage and sends email alerts.
// Two data sources are supported:
//   local mode  — reads ~/.claude/projects/*.jsonl directly (dev machine)
//   ingest mode — receives data pushed by ctm-agent (Pi Zero deployment)

const std = @import("std");
const Config = @import("config.zig").Config;
const UsageReader = @import("usage_reader.zig").UsageReader;
const SessionTracker = @import("session_tracker.zig").SessionTracker;
const WindowStats = @import("session_tracker.zig").WindowStats;
const IngestState = @import("ingest_state.zig").IngestState;
const IngestServer = @import("ingest_server.zig").Server;
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

    if (config.ingest_server.enabled) {
        try runIngestMode(allocator, config, log_file);
    } else {
        try runLocalMode(allocator, config, log_file);
    }
}

// ── Ingest mode (Pi Zero): receive data from ctm-agent over HTTP ─────────────

const ServerThreadArgs = struct {
    allocator: std.mem.Allocator,
    state: *IngestState,
    config: Config,
};

fn serverThread(args: *ServerThreadArgs) void {
    var srv = IngestServer{
        .allocator = args.allocator,
        .state = args.state,
        .shared_secret = args.config.ingest_server.shared_secret,
    };
    srv.run(args.config.ingest_server.bind_host, args.config.ingest_server.bind_port) catch |err| {
        std.log.err("ingest server crashed: {}", .{err});
    };
}

fn runIngestMode(allocator: std.mem.Allocator, config: Config, log_file: ?std.fs.File) !void {
    var state = IngestState.init(allocator);
    defer state.deinit();

    var thread_args = ServerThreadArgs{
        .allocator = allocator,
        .state = &state,
        .config = config,
    };
    const srv_thread = try std.Thread.spawn(.{}, serverThread, .{&thread_args});
    srv_thread.detach();

    logInfo(log_file, "ingest mode: listening on {s}:{d}", .{
        config.ingest_server.bind_host, config.ingest_server.bind_port,
    });

    try monitorLoop(allocator, config, log_file, struct {
        state: *IngestState,
        alloc: std.mem.Allocator,

        pub fn getEntries(self: @This(), arena: std.mem.Allocator) ![]const @import("usage_reader.zig").UsageEntry {
            _ = arena;
            return self.state.snapshot(self.alloc);
        }
    }{ .state = &state, .alloc = allocator });
}

// ── Local mode (dev machine): read JSONL files directly ──────────────────────

fn runLocalMode(allocator: std.mem.Allocator, config: Config, log_file: ?std.fs.File) !void {
    const data_path = try config.getClaudeDataPath(allocator);
    defer if (config.claude_data_path == null) allocator.free(data_path);

    logInfo(log_file, "local mode: reading {s}", .{data_path});

    try monitorLoop(allocator, config, log_file, struct {
        path: []const u8,

        pub fn getEntries(self: @This(), arena: std.mem.Allocator) ![]const @import("usage_reader.zig").UsageEntry {
            var reader = UsageReader.init(arena, self.path);
            return reader.readAll();
        }
    }{ .path = data_path });
}

// ── Shared monitoring loop ────────────────────────────────────────────────────

fn monitorLoop(
    allocator: std.mem.Allocator,
    config: Config,
    log_file: ?std.fs.File,
    source: anytype,
) !void {
    var prev_stats: ?WindowStats = null;
    var notified_limit = false;
    var notified_threshold = false;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const entries = source.getEntries(a) catch {
            logInfo(log_file, "failed to read usage data", .{});
            std.time.sleep(std.time.ns_per_s * config.refresh_interval_seconds);
            continue;
        };

        const tracker = SessionTracker.init(a, entries, config.plan);
        const stats = tracker.currentWindowStats();
        const pct = stats.usagePercent();

        if (config.notify_on_reset) {
            if (prev_stats) |prev| {
                if (prev.is_at_limit and !stats.is_at_limit) {
                    notified_limit = false;
                    notified_threshold = false;
                    logInfo(log_file, "token window reset — sending email", .{});
                    email.sendNotification(a, config.email, .tokens_reset, stats.tokens_used, stats.token_limit) catch |err| {
                        logInfo(log_file, "email send failed: {}", .{err});
                    };
                }
            }
        }

        if (!notified_threshold and pct >= @as(f64, @floatFromInt(config.notify_threshold_percent))) {
            notified_threshold = true;
            logInfo(log_file, "threshold {d}% reached — sending email", .{config.notify_threshold_percent});
            email.sendNotification(a, config.email, .threshold_reached, stats.tokens_used, stats.token_limit) catch |err| {
                logInfo(log_file, "email send failed: {}", .{err});
            };
        }

        if (stats.is_at_limit and !notified_limit) {
            notified_limit = true;
            logInfo(log_file, "limit reached ({d}/{d})", .{ stats.tokens_used, stats.token_limit });
        }

        logInfo(log_file, "usage: {d}/{d} ({d:.1}%) reset_in={d}s", .{
            stats.tokens_used, stats.token_limit, pct, stats.secondsUntilReset(),
        });

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
    var buf: [512]u8 = undefined;
    const ts = std.time.timestamp();
    const line = std.fmt.bufPrint(&buf, "[{d}] ctm: " ++ fmt ++ "\n", .{ts} ++ args) catch return;
    if (file) |f| {
        f.seekFromEnd(0) catch {};
        f.writeAll(line) catch {};
    }
}
