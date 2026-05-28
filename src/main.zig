const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Config;
const Dashboard = @import("dashboard.zig").Dashboard;
const UsageReader = @import("usage_reader.zig").UsageReader;
const SessionTracker = @import("session_tracker.zig").SessionTracker;
const daemon = @import("daemon.zig");

const Mode = enum { monitor, daemon_mode, status, gen_secret, help };

// Release builds use c_allocator (low overhead, libc malloc/free).
// Debug/test builds use GeneralPurposeAllocator for leak detection.
var debug_gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn pickAllocator() std.mem.Allocator {
    return switch (builtin.mode) {
        .Debug => debug_gpa.allocator(),
        else => std.heap.c_allocator,
    };
}

fn deinitAllocator() void {
    if (builtin.mode == .Debug) _ = debug_gpa.deinit();
}

pub fn main() !void {
    const allocator = pickAllocator();
    defer deinitAllocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var mode: Mode = .monitor;
    var config_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--daemon") or std.mem.eql(u8, arg, "-d")) {
            mode = .daemon_mode;
        } else if (std.mem.eql(u8, arg, "--status") or std.mem.eql(u8, arg, "-s")) {
            mode = .status;
        } else if (std.mem.eql(u8, arg, "--gen-secret")) {
            mode = .gen_secret;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            mode = .help;
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i < args.len) config_path = args[i];
        }
    }

    if (mode == .gen_secret) { genSecret(); return; }
    if (mode == .help) { printHelp(); return; }

    var config = loadConfig(allocator, config_path);
    defer config.deinit(allocator);

    switch (mode) {
        .status => try runStatus(allocator, config),
        .daemon_mode => try daemon.run(allocator, config),
        .monitor => try Dashboard.run(allocator, config),
        .gen_secret, .help => unreachable,
    }
}

fn loadConfig(allocator: std.mem.Allocator, explicit_path: ?[]const u8) Config {
    const paths_to_try = [_]?[]const u8{
        explicit_path,
        blk: {
            const home = std.posix.getenv("HOME") orelse break :blk null;
            break :blk std.fs.path.join(allocator, &.{ home, ".config", "ctm", "config.json" }) catch null;
        },
        blk: {
            const home = std.posix.getenv("HOME") orelse break :blk null;
            break :blk std.fs.path.join(allocator, &.{ home, ".ctm.json" }) catch null;
        },
    };
    defer {
        // Free the joined paths we built above (skip the explicit one — caller owns it).
        for (paths_to_try[1..]) |maybe_path| {
            if (maybe_path) |p| allocator.free(p);
        }
    }

    for (paths_to_try) |maybe_path| {
        const path = maybe_path orelse continue;
        const cfg = Config.load(allocator, path) catch continue;
        std.log.info("loaded config from {s}", .{path});
        return cfg;
    }

    return Config.default();
}

fn runStatus(allocator: std.mem.Allocator, config: Config) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const data_path = try config.getClaudeDataPath(a);

    var reader = UsageReader.init(a, data_path);
    const entries = try reader.readAll();

    const tracker = SessionTracker.init(a, entries, config.plan);
    const stats = tracker.currentWindowStats();

    const stdout = std.io.getStdOut().writer();
    const pct = stats.usagePercent();
    const color = if (pct >= 90.0) "\x1b[31m" else if (pct >= 70.0) "\x1b[33m" else "\x1b[32m";

    var reset_buf: [32]u8 = undefined;
    const reset_str = stats.resetInHuman(&reset_buf);

    try stdout.print("\n  Claude Token Monitor — current status\n\n", .{});
    try stdout.print("  Plan:        {s}\n", .{config.plan.displayName()});
    try stdout.print("  Tokens used: {s}{d}{s} / {d} ({d:.1}%)\n", .{
        color, stats.tokens_used, "\x1b[0m", stats.token_limit, pct,
    });
    try stdout.print("  Remaining:   {d} tokens\n", .{stats.tokensRemaining()});
    try stdout.print("  Resets in:   {s}\n", .{reset_str});
    try stdout.print("  Cost:        ${d:.4}\n", .{stats.window_cost_usd});
    if (stats.burn_rate_per_hour > 0) {
        try stdout.print("  Burn rate:   ~{d:.0} tokens/hour\n", .{stats.burn_rate_per_hour});
    }
    try stdout.print("\n", .{});
}

fn genSecret() void {
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const stdout = std.io.getStdOut().writer();
    for (bytes) |b| stdout.print("{x:0>2}", .{b}) catch {};
    stdout.print("\n", .{}) catch {};
}

fn printHelp() void {
    std.debug.print(
        \\Claude Token Monitor (ctm) v0.1
        \\Monitor Claude Code API token usage in real time.
        \\
        \\USAGE
        \\  ctm [options]
        \\
        \\OPTIONS
        \\  -d, --daemon       Run as background daemon (email alerts)
        \\  -s, --status       Print current status and exit
        \\      --gen-secret   Print a random 256-bit hex secret and exit
        \\  -c, --config PATH  Use a specific config file
        \\  -h, --help         Show this help
        \\
        \\CONFIG
        \\  Searched in order:
        \\    ~/.config/ctm/config.json
        \\    ~/.ctm.json
        \\  See config.example.json for all options.
        \\
        \\EXAMPLES
        \\  ctm                  # live dashboard
        \\  ctm -s               # one-shot status
        \\  ctm -d               # background daemon with email alerts
        \\  ctm -c ~/my.json     # custom config
        \\  ctm --gen-secret     # generate a shared secret for Pi setup
        \\
        \\DATA
        \\  Reads from ~/.claude/projects/**/*.jsonl (written by Claude Code CLI).
        \\  For the Pi Zero deployment, enable ingest_server in config.json and
        \\  run ctm-agent on your dev machine to push data over the LAN.
        \\
    , .{});
}
