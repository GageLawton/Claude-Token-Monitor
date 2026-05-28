// Notification dispatch: email (SMTPS) and/or webhook (HTTP POST / ntfy.sh).
// Both channels can be enabled simultaneously. Failures are logged but never
// propagated — a missed notification must never crash the daemon.

const std = @import("std");
const email_mod = @import("email.zig");
const EmailConfig = @import("config.zig").EmailConfig;
const WebhookConfig = @import("config.zig").WebhookConfig;

pub const NotifyEvent = email_mod.EmailEvent;

pub fn sendNotification(
    allocator: std.mem.Allocator,
    email_cfg: EmailConfig,
    webhook_cfg: WebhookConfig,
    event: NotifyEvent,
    tokens_used: u64,
    token_limit: u64,
) void {
    email_mod.sendNotification(allocator, email_cfg, event, tokens_used, token_limit) catch |err| {
        std.log.warn("email notification failed: {}", .{err});
    };

    sendWebhook(allocator, webhook_cfg, event, tokens_used, token_limit) catch |err| {
        std.log.warn("webhook notification failed: {}", .{err});
    };
}

fn sendWebhook(
    allocator: std.mem.Allocator,
    cfg: WebhookConfig,
    event: NotifyEvent,
    tokens_used: u64,
    token_limit: u64,
) !void {
    if (!cfg.enabled or cfg.url.len == 0) return;

    const pct = if (token_limit > 0)
        @as(f64, @floatFromInt(tokens_used)) / @as(f64, @floatFromInt(token_limit)) * 100.0
    else
        0.0;

    const title = switch (event) {
        .tokens_reset => "Claude Tokens Reset",
        .threshold_reached => "Claude Token Warning",
    };

    const body = switch (event) {
        .tokens_reset => try std.fmt.allocPrint(
            allocator,
            "Token window reset — {d} tokens available ({d:.1}% remaining)",
            .{ token_limit - tokens_used, 100.0 - pct },
        ),
        .threshold_reached => try std.fmt.allocPrint(
            allocator,
            "Token usage at {d:.1}% — {d}/{d} used",
            .{ pct, tokens_used, token_limit },
        ),
    };
    defer allocator.free(body);

    // Build argv — include the title header only if title_header is non-empty.
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.appendSlice(&.{
        "curl",
        "--silent",
        "--show-error",
        "--fail",
        "--connect-timeout", "10",
        "--max-time",        "15",
        "-X", cfg.method,
        "-H", "Content-Type: text/plain",
        "--data-binary", body,
    });

    const title_hdr = if (cfg.title_header.len > 0)
        try std.fmt.allocPrint(allocator, "{s}: {s}", .{ cfg.title_header, title })
    else
        null;
    defer if (title_hdr) |h| allocator.free(h);

    if (title_hdr) |h| {
        try argv.appendSlice(&.{ "-H", h });
    }

    try argv.append(cfg.url);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stderr_out = try child.stderr.?.readToEndAlloc(allocator, 4096);
    defer allocator.free(stderr_out);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.log.warn("webhook curl exit {d}: {s}", .{ code, std.mem.trim(u8, stderr_out, " \t\r\n") });
            return error.WebhookFailed;
        },
        else => return error.WebhookFailed,
    }
}
