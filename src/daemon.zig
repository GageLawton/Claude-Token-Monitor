// Background daemon: monitors token usage and sends email/webhook alerts.
//
// Local mode  — Watcher tails ~/.claude/projects/*.jsonl on this machine.
//               Uses inotify on Linux / kqueue on macOS for ~0% idle CPU.
// Ingest mode — HTTP server receives data pushed by ctm-agent over the LAN.

const std = @import("std");
const Config = @import("config.zig").Config;
const usage = @import("usage_reader.zig");
const UsageEntry = usage.UsageEntry;
const SessionTracker = @import("session_tracker.zig").SessionTracker;
const WindowStats = @import("session_tracker.zig").WindowStats;
const IngestState = @import("ingest_state.zig").IngestState;
const IngestServer = @import("ingest_server.zig").Server;
const Watcher = @import("watcher.zig").Watcher;
const notify = @import("notify.zig");

const PID_FILE = "/var/run/ctm.pid";

const PRUNE_CUTOFF_SECONDS: i64 = usage.DEFAULT_MAX_AGE_SECONDS + 60 * 60;

pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    try daemonize();
    try writePidFile();
    defer std.fs.deleteFileAbsolute(PID_FILE) catch {};

    var logger = Logger.init(config.log_file, config.log_max_size_mb, config.log_keep_files);
    defer logger.deinit();

    logger.info("ctm daemon started", .{});

    if (config.ingest_server.enabled) {
        try runIngestMode(allocator, config, &logger);
    } else {
        try runLocalMode(allocator, config, &logger);
    }
}

// ── Logger with log rotation ──────────────────────────────────────────────────
//
// Writes timestamped lines to a log file, rotating when it exceeds max_bytes.
// Rotation renames: log → log.1 → log.2 → … → log.N (N is deleted).

const Logger = struct {
    path: ?[]const u8,
    file: ?std.fs.File,
    max_bytes: u64,
    keep_files: u8,

    fn init(path: ?[]const u8, max_mb: u32, keep: u8) Logger {
        const file: ?std.fs.File = if (path) |p|
            std.fs.createFileAbsolute(p, .{ .truncate = false }) catch null
        else
            null;
        return .{
            .path = path,
            .file = file,
            .max_bytes = @as(u64, max_mb) * 1024 * 1024,
            .keep_files = keep,
        };
    }

    fn deinit(self: *Logger) void {
        if (self.file) |f| f.close();
        self.file = null;
    }

    fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const ts = std.time.timestamp();
        const line = std.fmt.bufPrint(&buf, "[{d}] ctm: " ++ fmt ++ "\n", .{ts} ++ args) catch return;
        const f = self.file orelse return;

        const stat = f.stat() catch {
            f.seekFromEnd(0) catch {};
            f.writeAll(line) catch {};
            return;
        };
        if (self.max_bytes > 0 and stat.size + line.len > self.max_bytes) {
            self.rotate();
        }
        if (self.file) |ff| {
            ff.seekFromEnd(0) catch {};
            ff.writeAll(line) catch {};
        }
    }

    fn rotate(self: *Logger) void {
        const path = self.path orelse return;
        if (self.file) |f| { f.close(); self.file = null; }

        // Shift files: delete .N, rename .N-1 → .N, … , base → .1
        var i: u8 = self.keep_files;
        while (i > 0) : (i -= 1) {
            var src_buf: [std.fs.max_path_bytes]u8 = undefined;
            var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
            const src: []const u8 = if (i == 1)
                path
            else
                std.fmt.bufPrint(&src_buf, "{s}.{d}", .{ path, i - 1 }) catch continue;
            const dst = std.fmt.bufPrint(&dst_buf, "{s}.{d}", .{ path, i }) catch continue;
            std.fs.renameAbsolute(src, dst) catch {};
        }

        self.file = std.fs.createFileAbsolute(path, .{}) catch null;
    }
};

// ── Ingest mode (Pi receives pushed data) ────────────────────────────────────

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
        .rate_limit_per_minute = args.config.ingest_server.rate_limit_per_minute,
    };
    srv.run(args.config.ingest_server.bind_host, args.config.ingest_server.bind_port) catch |err| {
        std.log.err("ingest server crashed: {}", .{err});
    };
}

fn runIngestMode(allocator: std.mem.Allocator, config: Config, logger: *Logger) !void {
    var state = IngestState.init(allocator);
    defer state.deinit();

    const state_path = config.getStateFilePath(allocator) catch null;
    defer if (state_path) |p| config.freeStateFilePath(allocator, p);
    if (state_path) |p| {
        state.enablePersistence(p);
        logger.info("state persistence: {s}", .{p});
    }

    var thread_args = ServerThreadArgs{
        .allocator = allocator,
        .state = &state,
        .config = config,
    };
    const srv_thread = try std.Thread.spawn(.{}, serverThread, .{&thread_args});
    srv_thread.detach();

    logger.info("ingest mode: listening on {s}:{d}", .{
        config.ingest_server.bind_host, config.ingest_server.bind_port,
    });

    const ctx = IngestCtx{ .state = &state };
    try monitorLoop(allocator, config, logger, IngestCtx, ctx);
}

const IngestCtx = struct {
    state: *IngestState,

    pub fn tick(self: IngestCtx, timeout_s: u32, alloc: std.mem.Allocator) ![]UsageEntry {
        std.time.sleep(std.time.ns_per_s * timeout_s);
        self.state.pruneOlderThan(std.time.timestamp() - PRUNE_CUTOFF_SECONDS);
        return self.state.snapshot(alloc);
    }
};

// ── Local mode (read JSONL files on this machine) ────────────────────────────

fn runLocalMode(allocator: std.mem.Allocator, config: Config, logger: *Logger) !void {
    var state = IngestState.init(allocator);
    defer state.deinit();

    const state_path = config.getStateFilePath(allocator) catch null;
    defer if (state_path) |p| config.freeStateFilePath(allocator, p);
    if (state_path) |p| {
        state.enablePersistence(p);
        logger.info("state persistence: {s}", .{p});
    }

    const data_path = try config.getClaudeDataPath(allocator);
    defer config.freeClaudeDataPath(allocator, data_path);

    logger.info("local mode: watching {s}", .{data_path});

    var watcher = Watcher.init(allocator, data_path);
    defer watcher.deinit();

    if (watcher.inotify_fd >= 0) {
        logger.info("local mode: inotify enabled (idle CPU ~0%)", .{});
    } else if (watcher.kqueue_fd >= 0) {
        logger.info("local mode: kqueue enabled (idle CPU ~0%)", .{});
    } else {
        logger.info("local mode: using stat-polling fallback", .{});
    }

    const ctx = LocalCtx{ .state = &state, .watcher = &watcher };
    try monitorLoop(allocator, config, logger, LocalCtx, ctx);
}

const LocalCtx = struct {
    state: *IngestState,
    watcher: *Watcher,

    pub fn tick(self: LocalCtx, timeout_s: u32, alloc: std.mem.Allocator) ![]UsageEntry {
        const timeout_ms: i32 = @intCast(@min(@as(u32, std.math.maxInt(i32) / 1000), timeout_s) * 1000);
        self.watcher.waitForEvent(timeout_ms);

        var new_data = self.watcher.poll() catch |err| {
            std.log.warn("watcher.poll: {}", .{err});
            return self.state.snapshot(alloc);
        };
        defer new_data.deinit();

        if (new_data.lines.items.len > 0) {
            _ = self.state.addLines(new_data.lines.items) catch |err| {
                std.log.warn("state.addLines: {}", .{err});
            };
        }

        self.state.pruneOlderThan(std.time.timestamp() - PRUNE_CUTOFF_SECONDS);
        return self.state.snapshot(alloc);
    }
};

// ── Shared monitoring loop ───────────────────────────────────────────────────

fn monitorLoop(
    allocator: std.mem.Allocator,
    config: Config,
    logger: *Logger,
    comptime CtxT: type,
    ctx: CtxT,
) !void {
    var prev_stats: ?WindowStats = null;
    var notified_limit = false;
    var notified_threshold = false;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const entries = ctx.tick(config.refresh_interval_seconds, a) catch {
            logger.info("tick failed; retrying", .{});
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
                    logger.info("token window reset — sending notifications", .{});
                    notify.sendNotification(
                        a, config.email, config.webhook,
                        .tokens_reset, stats.tokens_used, stats.token_limit,
                    );
                }
            }
        }

        if (!notified_threshold and pct >= @as(f64, @floatFromInt(config.notify_threshold_percent))) {
            notified_threshold = true;
            logger.info("threshold {d}% reached — sending notifications", .{config.notify_threshold_percent});
            notify.sendNotification(
                a, config.email, config.webhook,
                .threshold_reached, stats.tokens_used, stats.token_limit,
            );
        }

        if (stats.is_at_limit and !notified_limit) {
            notified_limit = true;
            logger.info("limit reached ({d}/{d})", .{ stats.tokens_used, stats.token_limit });
        }

        logger.info("usage: {d}/{d} ({d:.1}%) reset_in={d}s", .{
            stats.tokens_used, stats.token_limit, pct, stats.secondsUntilReset(),
        });

        prev_stats = stats;
    }
}

// ── Process management ───────────────────────────────────────────────────────

fn daemonize() !void {
    const child1 = try std.posix.fork();
    if (child1 > 0) std.process.exit(0);

    _ = try std.posix.setsid();

    const child2 = try std.posix.fork();
    if (child2 > 0) std.process.exit(0);

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
