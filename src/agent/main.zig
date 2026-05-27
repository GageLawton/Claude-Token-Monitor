// ctm-agent: runs on the dev machine (wherever Claude Code runs).
// Watches ~/.claude/projects/**/*.jsonl and ships new lines to the Pi over HTTP.
//
// Config: ~/.config/ctm/agent.json  or  ~/.ctm-agent.json
// Example: see config.example.agent.json in the repo root.

const std = @import("std");
const AgentConfig = @import("../../src/config.zig").AgentConfig;
const Watcher = @import("watcher.zig").Watcher;
const shipper = @import("shipper.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if ((std.mem.eql(u8, args[i], "--config") or std.mem.eql(u8, args[i], "-c")) and i + 1 < args.len) {
            i += 1;
            config_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printHelp();
            return;
        }
    }

    const cfg = loadConfig(allocator, config_path);

    if (cfg.shared_secret.len == 0) {
        std.log.warn("agent: no shared_secret set — the Pi will accept data from anyone on the LAN", .{});
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

    while (true) {
        var new_data = watcher.poll() catch |err| {
            std.log.warn("agent: poll error: {} — retrying", .{err});
            std.time.sleep(std.time.ns_per_ms * cfg.poll_interval_ms);
            continue;
        };
        defer new_data.deinit();

        if (new_data.lines.items.len > 0) {
            std.log.info("agent: shipping {d} new lines", .{new_data.lines.items.len});
            shipper.ship(allocator, ship_cfg, new_data.lines.items) catch |err| {
                std.log.warn("agent: ship error: {} — will retry next poll", .{err});
            };
        }

        std.time.sleep(std.time.ns_per_ms * cfg.poll_interval_ms);
    }
}

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

    for (paths_to_try) |maybe_path| {
        const path = maybe_path orelse continue;
        const cfg = AgentConfig.load(allocator, path) catch continue;
        std.log.info("agent: loaded config from {s}", .{path});
        return cfg;
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

fn printHelp() void {
    std.debug.print(
        \\ctm-agent v0.1 — ships Claude Code usage data to a Raspberry Pi
        \\
        \\USAGE
        \\  ctm-agent [options]
        \\
        \\OPTIONS
        \\  -c, --config PATH   Use a specific config file
        \\  -h, --help          Show this help
        \\
        \\CONFIG (searched in order)
        \\  ~/.config/ctm/agent.json
        \\  ~/.ctm-agent.json
        \\
        \\EXAMPLE CONFIG
        \\  {
        \\    "pi_host": "raspberrypi.local",
        \\    "pi_port": 7373,
        \\    "shared_secret": "change-me",
        \\    "poll_interval_ms": 500
        \\  }
        \\
        \\  Run ctm --daemon on the Pi with ingest_server.enabled = true.
        \\
    , .{});
}
