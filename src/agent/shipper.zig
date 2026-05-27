// Ships new JSONL lines to the Pi's HTTP ingest endpoint via curl.
// curl handles connection keep-alive, TLS if the user upgrades the Pi endpoint,
// and retry logic — all without bringing in an HTTP client dependency.

const std = @import("std");

pub const ShipperConfig = struct {
    pi_host: []const u8,
    pi_port: u16,
    shared_secret: []const u8,
};

// POST the given lines to http://<pi_host>:<pi_port>/ingest.
// Returns the number of lines shipped, or an error.
pub fn ship(
    allocator: std.mem.Allocator,
    cfg: ShipperConfig,
    lines: []const []const u8,
) !void {
    if (lines.len == 0) return;

    // Serialize {"lines":["...",...]} using std.json for correct escaping.
    const Payload = struct { lines: []const []const u8 };
    const payload = try std.json.stringifyAlloc(
        allocator,
        Payload{ .lines = lines },
        .{},
    );
    defer allocator.free(payload);

    const url = try std.fmt.allocPrint(
        allocator,
        "http://{s}:{d}/ingest",
        .{ cfg.pi_host, cfg.pi_port },
    );
    defer allocator.free(url);

    const auth_header = try std.fmt.allocPrint(
        allocator,
        "Authorization: Bearer {s}",
        .{cfg.shared_secret},
    );
    defer allocator.free(auth_header);

    const argv = [_][]const u8{
        "curl",
        "--silent",
        "--show-error",
        "--fail",           // non-2xx = error exit code
        "--connect-timeout", "5",
        "--max-time",        "10",
        "-X", "POST",
        "-H", auth_header,
        "-H", "Content-Type: application/json",
        "--data-binary", payload,
        url,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stderr_out = try child.stderr.?.readToEndAlloc(allocator, 4096);
    defer allocator.free(stderr_out);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.warn("agent: ship failed (curl exit {d}): {s}", .{ code, stderr_out });
                return error.ShipFailed;
            }
        },
        else => return error.ShipFailed,
    }
}
