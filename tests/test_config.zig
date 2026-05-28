const std = @import("std");
const testing = std.testing;
const config = @import("config");

test "default config has sensible values" {
    const c = config.Config.default();
    try testing.expectEqual(config.Plan.pro, c.plan);
    try testing.expectEqual(@as(u32, 30), c.refresh_interval_seconds);
    try testing.expect(c.notify_on_reset);
    try testing.expectEqual(@as(u8, 80), c.notify_threshold_percent);
    try testing.expect(!c.email.enabled);
}

test "Config.load returns ConfigNotFound for missing file" {
    const result = config.Config.load(testing.allocator, "/nonexistent/config.json");
    try testing.expectError(error.ConfigNotFound, result);
}

test "Config.load parses a full config from JSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("config.json", .{});
    defer file.close();
    try file.writeAll(
        \\{
        \\  "plan": "max5",
        \\  "refresh_interval_seconds": 60,
        \\  "notify_on_reset": false,
        \\  "notify_threshold_percent": 90,
        \\  "email": {
        \\    "enabled": true,
        \\    "smtp_host": "smtp.example.com",
        \\    "smtp_port": 587,
        \\    "username": "user@example.com",
        \\    "password": "secret",
        \\    "from": "from@example.com",
        \\    "to": "to@example.com"
        \\  }
        \\}
    );

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("config.json", &path_buf);

    var c = try config.Config.load(testing.allocator, path);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(config.Plan.max5, c.plan);
    try testing.expectEqual(@as(u32, 60), c.refresh_interval_seconds);
    try testing.expect(!c.notify_on_reset);
    try testing.expectEqual(@as(u8, 90), c.notify_threshold_percent);
    try testing.expect(c.email.enabled);
    try testing.expectEqualStrings("smtp.example.com", c.email.smtp_host);
    try testing.expectEqual(@as(u16, 587), c.email.smtp_port);
    try testing.expectEqualStrings("user@example.com", c.email.username);
    try testing.expectEqualStrings("to@example.com", c.email.to);
}

test "Config.load applies defaults when fields are missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("config.json", .{});
    defer file.close();
    try file.writeAll("{\"plan\": \"max20\"}");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("config.json", &path_buf);

    var c = try config.Config.load(testing.allocator, path);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(config.Plan.max20, c.plan);
    // Defaults preserved
    try testing.expectEqual(@as(u32, 30), c.refresh_interval_seconds);
    try testing.expectEqual(@as(u8, 80), c.notify_threshold_percent);
    try testing.expect(!c.email.enabled);
}

test "Config.load rejects non-object root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("bad.json", .{});
    defer file.close();
    try file.writeAll("[1, 2, 3]");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("bad.json", &path_buf);

    try testing.expectError(error.InvalidConfig, config.Config.load(testing.allocator, path));
}

test "Plan.displayName returns human-readable label" {
    try testing.expectEqualStrings("Pro", config.Plan.pro.displayName());
    try testing.expectEqualStrings("Max 5x", config.Plan.max5.displayName());
    try testing.expectEqualStrings("Max 20x", config.Plan.max20.displayName());
}
