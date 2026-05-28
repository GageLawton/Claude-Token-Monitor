// ctm-agent: runs on the dev machine (wherever Claude Code runs).
// Watches ~/.claude/projects/**/*.jsonl and ships new lines to the Pi over HTTP.
// On ship failure, lines are spooled to disk and retried with exponential backoff.
//
// Config: ~/.config/ctm/agent.json  or  ~/.ctm-agent.json

const std = @import("std");
const AgentConfig = @import("../../src/config.zig").AgentConfig;
const Watcher = @import("watcher").Watcher;
const shipper = @import("shipper.zig");

const Mode = enum { run, status, ping, install_launchd, uninstall_launchd, help };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var mode: Mode = .run;
    var config_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) and i + 1 < args.len) {
            i += 1;
            config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--status") or std.mem.eql(u8, arg, "-s")) {
            mode = .status;
        } else if (std.mem.eql(u8, arg, "--ping")) {
            mode = .ping;
        } else if (std.mem.eql(u8, arg, "--install-launchd")) {
            mode = .install_launchd;
        } else if (std.mem.eql(u8, arg, "--uninstall-launchd")) {
            mode = .uninstall_launchd;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            mode = .help;
        }
    }

    if (mode == .help) {
        printHelp();
        return;
    }

    var cfg = loadConfig(allocator, config_path);
    defer cfg.deinit(allocator);

    switch (mode) {
        .run => try runAgent(allocator, cfg),
        .status => try runStatus(allocator, cfg),
        .ping => try runPing(allocator, cfg),
        .install_launchd => try installLaunchd(allocator, config_path),
        .uninstall_launchd => try uninstallLaunchd(allocator),
        .help => unreachable,
    }
}

// ── Config loading ────────────────────────────────────────────────────────────

fn loadConfig(allocator: std.mem.Allocator, explicit_path: ?[]const u8) AgentConfig {
    const paths_to_try = [_]?[]const u8{
        explicit_path,
        blk: {
            const home = std.posix.getenv("HOME") orelse break :blk null;
            break :blk std.fs.path.join(allocator, &.{ home, ".config", "ctm", "agent.json" }) catch null;
        },
        blk: {
            const home = std.posix.getenv("HOME") orelse break :blk null;
            break :blk std.fs.path.join(allocator, &.{ home, ".ctm-agent.json" }) catch null;
        },
    };
    defer {
        for (paths_to_try[1..]) |maybe_path| {
            if (maybe_path) |p| allocator.free(p);
        }
    }

    for (paths_to_try) |maybe_path| {
        const path = maybe_path orelse continue;
        const loaded = AgentConfig.load(allocator, path) catch continue;
        std.log.info("agent: loaded config from {s}", .{path});
        return loaded;
    }

    std.log.info("agent: no config found — using defaults (Pi at raspberrypi.local:7373)", .{});
    return AgentConfig{};
}

fn resolveProjectsPath(allocator: std.mem.Allocator, cfg: AgentConfig) ![]const u8 {
    if (cfg.claude_data_path) |p| return allocator.dupe(u8, p);

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    const primary = try std.fs.path.join(allocator, &.{ home, ".claude", "projects" });
    if (std.fs.openDirAbsolute(primary, .{}) catch null) |dir| {
        dir.close();
        return primary;
    }
    allocator.free(primary);

    return std.fs.path.join(allocator, &.{ home, ".config", "claude", "projects" });
}

// ── Status file ───────────────────────────────────────────────────────────────
//
// Written atomically after each successful ship so --status can read it
// without IPC or a running agent.

const StatusFile = struct {
    pid: u32,
    start_s: i64,
    last_ship_s: i64,
    total_shipped: u64,
    spool_lines: u64,
};

fn statusFilePath(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const p = std.fs.path.join(allocator, &.{ home, ".cache", "ctm", "agent-status.json" }) catch return null;
    if (std.fs.path.dirname(p)) |dir| std.fs.makeDirAbsolute(dir) catch {};
    return p;
}

fn writeStatusFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    start_s: i64,
    total_shipped: u64,
    spool_path: []const u8,
) void {
    const pid: u32 = @intCast(std.c.getpid());
    const spool_lines = countSpoolLines(allocator, spool_path);

    const json = std.fmt.allocPrint(allocator,
        "{{\"pid\":{d},\"start_s\":{d},\"last_ship_s\":{d},\"total_shipped\":{d},\"spool_lines\":{d}}}\n",
        .{ pid, start_s, std.time.timestamp(), total_shipped, spool_lines },
    ) catch return;
    defer allocator.free(json);

    // Atomic write via temp file + rename.
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return;
    const f = std.fs.createFileAbsolute(tmp, .{}) catch return;
    f.writeAll(json) catch { f.close(); return; };
    f.close();
    std.fs.renameAbsolute(tmp, path) catch {};
}

fn countSpoolLines(allocator: std.mem.Allocator, spool_path: []const u8) u64 {
    if (spool_path.len == 0) return 0;
    const file = std.fs.openFileAbsolute(spool_path, .{}) catch return 0;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return 0;
    defer allocator.free(content);
    return @intCast(std.mem.count(u8, content, "\n"));
}

// ── Spool: buffer failed shipments on disk, retry with exponential backoff ────

const Spool = struct {
    path: []const u8,
    allocator: std.mem.Allocator,
    fail_count: u32 = 0,
    next_retry_ns: i128 = 0,

    const BACKOFFS_MS = [_]i128{ 2_000, 4_000, 8_000, 16_000, 32_000, 60_000 };

    fn hasData(self: *const Spool) bool {
        if (self.path.len == 0) return false;
        const file = std.fs.openFileAbsolute(self.path, .{}) catch return false;
        defer file.close();
        const stat = file.stat() catch return false;
        return stat.size > 0;
    }

    fn append(self: *const Spool, lines: []const []const u8) void {
        if (self.path.len == 0 or lines.len == 0) return;
        const file = std.fs.openFileAbsolute(self.path, .{ .mode = .write_only }) catch
            std.fs.createFileAbsolute(self.path, .{}) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;
        for (lines) |line| {
            file.writeAll(line) catch return;
            file.writeAll("\n") catch return;
        }
        std.log.warn("agent: spooled {d} lines to {s}", .{ lines.len, self.path });
    }

    fn readLines(self: *const Spool, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) void {
        if (self.path.len == 0) return;
        const file = std.fs.openFileAbsolute(self.path, .{}) catch return;
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var line_buf = std.ArrayList(u8).init(alloc);

        while (true) {
            line_buf.clearRetainingCapacity();
            buf_reader.reader().streamUntilDelimiter(line_buf.writer(), '\n', null) catch break;
            const trimmed = std.mem.trim(u8, line_buf.items, " \t\r");
            if (trimmed.len == 0) continue;
            const owned = alloc.dupe(u8, trimmed) catch continue;
            out.append(owned) catch {};
        }
    }

    fn shouldRetry(self: *const Spool) bool {
        return std.time.nanoTimestamp() >= self.next_retry_ns;
    }

    fn onFailure(self: *Spool) void {
        self.fail_count +|= 1;
        const idx: usize = @min(@as(usize, self.fail_count) - 1, BACKOFFS_MS.len - 1);
        self.next_retry_ns = std.time.nanoTimestamp() +
            BACKOFFS_MS[idx] * std.time.ns_per_ms;
        std.log.warn("agent: next retry in {d}ms", .{BACKOFFS_MS[idx]});
    }

    fn onSuccess(self: *Spool) void {
        self.fail_count = 0;
        self.next_retry_ns = 0;
        if (self.path.len > 0) std.fs.deleteFileAbsolute(self.path) catch {};
    }
};

// ── Main watcher loop ─────────────────────────────────────────────────────────

fn runAgent(allocator: std.mem.Allocator, cfg: AgentConfig) !void {
    if (cfg.shared_secret.len == 0) {
        std.log.warn("agent: no shared_secret set — Pi will accept data from anyone on the LAN", .{});
    }

    const projects_path = try resolveProjectsPath(allocator, cfg);
    defer allocator.free(projects_path);

    std.log.info("agent: watching {s}", .{projects_path});
    std.log.info("agent: pushing to http://{s}:{d}/ingest", .{ cfg.pi_host, cfg.pi_port });

    var watcher = Watcher.init(allocator, projects_path);
    defer watcher.deinit();

    const ship_cfg = shipper.ShipperConfig{
        .pi_host = cfg.pi_host,
        .pi_port = cfg.pi_port,
        .shared_secret = cfg.shared_secret,
    };

    const maybe_spool_path: ?[]const u8 = blk: {
        const home = std.posix.getenv("HOME") orelse break :blk null;
        const p = std.fs.path.join(allocator, &.{ home, ".cache", "ctm", "spool.jsonl" }) catch break :blk null;
        if (std.fs.path.dirname(p)) |dir| std.fs.makeDirAbsolute(dir) catch {};
        break :blk p;
    };
    defer if (maybe_spool_path) |p| allocator.free(p);

    const status_path = statusFilePath(allocator);
    defer if (status_path) |p| allocator.free(p);

    var spool = Spool{
        .path = maybe_spool_path orelse "",
        .allocator = allocator,
    };

    const start_s = std.time.timestamp();
    var total_shipped: u64 = 0;

    while (true) {
        std.time.sleep(std.time.ns_per_ms * cfg.poll_interval_ms);

        var new_data = watcher.poll() catch |err| {
            std.log.warn("agent: poll error: {} — retrying", .{err});
            continue;
        };
        defer new_data.deinit();

        const has_new = new_data.lines.items.len > 0;
        const has_spool = spool.hasData();

        if (!has_new and !has_spool) continue;

        if (has_spool and !spool.shouldRetry()) {
            if (has_new) spool.append(new_data.lines.items);
            continue;
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var combined = std.ArrayList([]const u8).init(a);
        if (has_spool) spool.readLines(a, &combined);
        for (new_data.lines.items) |l| combined.append(l) catch {};

        if (combined.items.len == 0) continue;

        const backlog = combined.items.len - new_data.lines.items.len;
        if (backlog > 0) {
            std.log.info("agent: shipping {d} lines ({d} from spool)", .{ combined.items.len, backlog });
        } else {
            std.log.info("agent: shipping {d} new lines", .{combined.items.len});
        }

        shipper.ship(allocator, ship_cfg, combined.items) catch |err| {
            std.log.warn("agent: ship failed: {} — spooling", .{err});
            spool.onFailure();
            if (has_new) spool.append(new_data.lines.items);
            continue;
        };

        total_shipped += combined.items.len;
        spool.onSuccess();

        if (status_path) |sp| {
            writeStatusFile(allocator, sp, start_s, total_shipped, spool.path);
        }
    }
}

// ── --status ─────────────────────────────────────────────────────────────────

fn runStatus(allocator: std.mem.Allocator, cfg: AgentConfig) !void {
    const stdout = std.io.getStdOut().writer();
    const now = std.time.timestamp();

    try stdout.print("\n  ctm-agent status\n\n", .{});

    // Read the status file written by the running agent.
    const sp = statusFilePath(allocator);
    defer if (sp) |p| allocator.free(p);

    if (sp) |path| {
        const content = std.fs.openFileAbsolute(path, .{}) catch null;
        if (content) |f| {
            defer f.close();
            const raw = f.readToEndAlloc(allocator, 4096) catch null;
            if (raw) |bytes| {
                defer allocator.free(bytes);
                const parsed = std.json.parseFromSlice(StatusFile, allocator, bytes, .{
                    .ignore_unknown_fields = true,
                }) catch null;
                if (parsed) |p| {
                    defer p.deinit();
                    const s = p.value;
                    const uptime_s = now - s.start_s;
                    const last_ship_s = now - s.last_ship_s;
                    try stdout.print("  Agent PID:   {d} (uptime {d}h {d}m)\n", .{
                        s.pid, uptime_s / 3600, (uptime_s % 3600) / 60,
                    });
                    try stdout.print("  Last ship:   {d}m ago  ({d} total lines)\n", .{
                        last_ship_s / 60, s.total_shipped,
                    });
                    try stdout.print("  Spool:       {d} lines pending\n", .{s.spool_lines});
                }
            }
        } else {
            try stdout.print("  Agent:       not running (no status file)\n", .{});
        }
    }

    // Ping Pi for live status.
    try stdout.print("\n  Pi ({s}:{d}):\n", .{ cfg.pi_host, cfg.pi_port });
    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/health", .{ cfg.pi_host, cfg.pi_port });
    defer allocator.free(url);

    const argv = [_][]const u8{
        "curl", "--silent", "--show-error", "--connect-timeout", "5", "--max-time", "8", url,
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 4096);
    defer allocator.free(out);
    const err_out = try child.stderr.?.readToEndAlloc(allocator, 1024);
    defer allocator.free(err_out);
    const term = try child.wait();
    const code: u8 = switch (term) { .Exited => |c| c, else => 1 };

    if (code == 0) {
        try stdout.print("  {s}\n", .{std.mem.trim(u8, out, " \t\r\n")});
    } else {
        try stdout.print("  unreachable — {s}\n", .{std.mem.trim(u8, err_out, " \t\r\n")});
    }
    try stdout.print("\n", .{});
}

// ── --ping ────────────────────────────────────────────────────────────────────

fn runPing(allocator: std.mem.Allocator, cfg: AgentConfig) !void {
    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/health", .{ cfg.pi_host, cfg.pi_port });
    defer allocator.free(url);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Pinging {s} ...\n", .{url});

    const argv = [_][]const u8{
        "curl", "--silent", "--show-error", "--connect-timeout", "5", "--max-time", "10", url,
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const out = try child.stdout.?.readToEndAlloc(allocator, 8192);
    defer allocator.free(out);
    const err_out = try child.stderr.?.readToEndAlloc(allocator, 4096);
    defer allocator.free(err_out);

    const term = try child.wait();
    const code: u8 = switch (term) { .Exited => |c| c, else => 1 };

    if (code == 0) {
        try stdout.print("Pi is reachable:\n  {s}\n", .{std.mem.trim(u8, out, " \t\r\n")});
    } else {
        try stdout.print("Could not reach Pi at {s}:{d}\n", .{ cfg.pi_host, cfg.pi_port });
        if (err_out.len > 0) try stdout.print("  {s}\n", .{std.mem.trim(u8, err_out, " \t\r\n")});
        std.process.exit(1);
    }
}

// ── --install-launchd / --uninstall-launchd ───────────────────────────────────

fn installLaunchd(allocator: std.mem.Allocator, config_path: ?[]const u8) !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    const la_dir = try std.fs.path.join(allocator, &.{ home, "Library", "LaunchAgents" });
    defer allocator.free(la_dir);
    std.fs.makeDirAbsolute(la_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const plist_path = try std.fs.path.join(allocator, &.{ la_dir, "com.ctm.agent.plist" });
    defer allocator.free(plist_path);

    const log_path = try std.fs.path.join(allocator, &.{ home, "Library", "Logs", "ctm-agent.log" });
    defer allocator.free(log_path);

    var args_xml = std.ArrayList(u8).init(allocator);
    defer args_xml.deinit();
    try args_xml.writer().print("    <string>{s}</string>\n", .{exe_path});
    if (config_path) |cp| {
        try args_xml.writer().print(
            "    <string>--config</string>\n    <string>{s}</string>\n", .{cp},
        );
    }

    const plist = try std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>com.ctm.agent</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\{s}  </array>
        \\  <key>KeepAlive</key>
        \\  <true/>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>StandardOutPath</key>
        \\  <string>{s}</string>
        \\  <key>StandardErrorPath</key>
        \\  <string>{s}</string>
        \\  <key>ThrottleInterval</key>
        \\  <integer>5</integer>
        \\</dict>
        \\</plist>
        \\
    , .{ args_xml.items, log_path, log_path });
    defer allocator.free(plist);

    const f = try std.fs.createFileAbsolute(plist_path, .{});
    defer f.close();
    try f.writeAll(plist);

    const launchctl_argv = [_][]const u8{ "launchctl", "load", "-w", plist_path };
    var child = std.process.Child.init(&launchctl_argv, allocator);
    _ = try child.spawnAndWait();

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        "Installed com.ctm.agent\n  Plist: {s}\n  Log:   {s}\n  Run 'ctm-agent --ping' to verify Pi connectivity.\n",
        .{ plist_path, log_path },
    );
}

fn uninstallLaunchd(allocator: std.mem.Allocator) !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const plist_path = try std.fs.path.join(
        allocator, &.{ home, "Library", "LaunchAgents", "com.ctm.agent.plist" },
    );
    defer allocator.free(plist_path);

    const launchctl_argv = [_][]const u8{ "launchctl", "unload", "-w", plist_path };
    var child = std.process.Child.init(&launchctl_argv, allocator);
    _ = child.spawnAndWait() catch {};

    std.fs.deleteFileAbsolute(plist_path) catch {};

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Unloaded and removed com.ctm.agent\n", .{});
}

// ── Help ──────────────────────────────────────────────────────────────────────

fn printHelp() void {
    std.debug.print(
        \\ctm-agent v0.1 — ships Claude Code usage data to a Raspberry Pi
        \\
        \\USAGE
        \\  ctm-agent [options]
        \\
        \\OPTIONS
        \\  -c, --config PATH       Use a specific config file
        \\  -s, --status            Show agent health, spool size, and Pi reachability
        \\      --ping              Check Pi connectivity (GET /health)
        \\      --install-launchd   Install as macOS launch agent (auto-start)
        \\      --uninstall-launchd Remove launch agent
        \\  -h, --help              Show this help
        \\
        \\CONFIG (searched in order)
        \\  ~/.config/ctm/agent.json
        \\  ~/.ctm-agent.json
        \\
        \\EXAMPLE CONFIG
        \\  {
        \\    "pi_host": "raspberrypi.local",
        \\    "pi_port": 7373,
        \\    "shared_secret": "$(ctm --gen-secret)",
        \\    "poll_interval_ms": 500
        \\  }
        \\
        \\  Run ctm --daemon on the Pi with ingest_server.enabled = true.
        \\  On ship failure, lines are spooled to ~/.cache/ctm/spool.jsonl
        \\  and retried automatically with exponential backoff (2s–60s).
        \\
    , .{});
}
