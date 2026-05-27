// Email notification via SMTP.
//
// Uses curl as the transport because Zig 0.13's TLS client requires manual
// certificate-bundle wiring that varies across distros. curl is always present
// on Raspberry Pi OS and handles TLS correctly out of the box.
// A native Zig SMTPS implementation can replace this later.

const std = @import("std");
const EmailConfig = @import("config.zig").EmailConfig;

pub const EmailEvent = enum {
    tokens_reset,
    threshold_reached,
};

pub fn sendNotification(
    allocator: std.mem.Allocator,
    cfg: EmailConfig,
    event: EmailEvent,
    tokens_used: u64,
    token_limit: u64,
) !void {
    if (!cfg.enabled) return;
    if (cfg.to.len == 0 or cfg.username.len == 0) return error.EmailNotConfigured;

    const subject = switch (event) {
        .tokens_reset => "Claude tokens have reset — you're good to go!",
        .threshold_reached => "Claude token warning: approaching limit",
    };

    const pct = if (token_limit > 0)
        @as(f64, @floatFromInt(tokens_used)) / @as(f64, @floatFromInt(token_limit)) * 100.0
    else
        0.0;

    const body = switch (event) {
        .tokens_reset => try std.fmt.allocPrint(
            allocator,
            "Your Claude 5-hour token window has reset.\n" ++
                "Tokens used: {d} / {d} ({d:.1}%)\n\n" ++
                "Sent by Claude Token Monitor (ctm).\n",
            .{ tokens_used, token_limit, pct },
        ),
        .threshold_reached => try std.fmt.allocPrint(
            allocator,
            "Warning: Claude token usage is at {d:.1}%.\n" ++
                "Tokens used: {d} / {d}\n\n" ++
                "Sent by Claude Token Monitor (ctm).\n",
            .{ pct, tokens_used, token_limit },
        ),
    };
    defer allocator.free(body);

    try sendViaCurl(allocator, cfg, subject, body);
}

// Writes a minimal RFC 5322 message to a temp file and hands it to curl.
fn sendViaCurl(
    allocator: std.mem.Allocator,
    cfg: EmailConfig,
    subject: []const u8,
    body: []const u8,
) !void {
    // Build the raw email
    const raw = try std.fmt.allocPrint(
        allocator,
        "From: {s}\r\nTo: {s}\r\nSubject: {s}\r\n\r\n{s}",
        .{ cfg.from, cfg.to, subject, body },
    );
    defer allocator.free(raw);

    // Write to a temp file
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "/tmp/ctm_mail_{d}.txt", .{std.time.timestamp()});

    {
        const tmp = try std.fs.createFileAbsolute(tmp_path, .{});
        defer tmp.close();
        try tmp.writeAll(raw);
    }
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Build curl command arguments
    const smtp_url = try std.fmt.allocPrint(
        allocator,
        "smtps://{s}:{d}",
        .{ cfg.smtp_host, cfg.smtp_port },
    );
    defer allocator.free(smtp_url);

    const user_pass = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ cfg.username, cfg.password });
    defer allocator.free(user_pass);

    const argv = [_][]const u8{
        "curl",
        "--silent",
        "--show-error",
        "--url", smtp_url,
        "--ssl-reqd",
        "--mail-from", cfg.from,
        "--mail-rcpt", cfg.to,
        "--upload-file", tmp_path,
        "--user", user_pass,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const stderr_content = try child.stderr.?.readToEndAlloc(allocator, 4096);
    defer allocator.free(stderr_content);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.err("curl smtp failed (exit {d}): {s}", .{ code, stderr_content });
                return error.EmailSendFailed;
            }
        },
        else => return error.EmailSendFailed,
    }
}

// Convenience: test whether email is reachable. Call at startup to warn the user early.
pub fn testConnection(allocator: std.mem.Allocator, cfg: EmailConfig) !void {
    if (!cfg.enabled) return;
    const argv = [_][]const u8{
        "curl", "--silent", "--show-error",
        "--connect-timeout", "5",
        "--url", cfg.smtp_host,
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = try child.wait();
}
