const std = @import("std");

pub const Plan = enum {
    pro,
    max5,
    max20,

    // Approximate token limits per 5-hour rolling window.
    // These match Claude's published rate limits; adjust if Anthropic changes them.
    pub fn tokenLimit(self: Plan) u64 {
        return switch (self) {
            .pro => 88_000,
            .max5 => 440_000,
            .max20 => 1_760_000,
        };
    }

    pub fn displayName(self: Plan) []const u8 {
        return switch (self) {
            .pro => "Pro",
            .max5 => "Max 5x",
            .max20 => "Max 20x",
        };
    }

    pub fn fromString(s: []const u8) Plan {
        if (std.mem.eql(u8, s, "max5")) return .max5;
        if (std.mem.eql(u8, s, "max20")) return .max20;
        return .pro;
    }
};

// Config for the ctm-agent binary (runs on dev machine, ships data to Pi).
pub const AgentConfig = struct {
    pi_host: []const u8 = "raspberrypi.local",
    pi_port: u16 = 7373,
    shared_secret: []const u8 = "",
    poll_interval_ms: u32 = 500,
    claude_data_path: ?[]const u8 = null,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !AgentConfig {
        const file = std.fs.openFileAbsolute(path, .{}) catch return error.ConfigNotFound;
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(content);
        const p = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer p.deinit();
        if (p.value != .object) return error.InvalidConfig;
        const obj = p.value.object;
        var cfg = AgentConfig{};
        if (obj.get("pi_host")) |v| if (v == .string) {
            cfg.pi_host = try allocator.dupe(u8, v.string);
        };
        if (obj.get("pi_port")) |v| if (v == .integer) {
            cfg.pi_port = @intCast(v.integer);
        };
        if (obj.get("shared_secret")) |v| if (v == .string) {
            cfg.shared_secret = try allocator.dupe(u8, v.string);
        };
        if (obj.get("poll_interval_ms")) |v| if (v == .integer) {
            cfg.poll_interval_ms = @intCast(v.integer);
        };
        if (obj.get("claude_data_path")) |v| if (v == .string) {
            cfg.claude_data_path = try allocator.dupe(u8, v.string);
        };
        return cfg;
    }
};

// Config for the HTTP ingest server embedded in ctm (runs on Pi).
pub const IngestServerConfig = struct {
    enabled: bool = false,
    bind_host: []const u8 = "0.0.0.0",
    bind_port: u16 = 7373,
    shared_secret: []const u8 = "",
};

pub const EmailConfig = struct {
    enabled: bool = false,
    smtp_host: []const u8 = "smtp.gmail.com",
    smtp_port: u16 = 465,
    username: []const u8 = "",
    password: []const u8 = "",
    from: []const u8 = "",
    to: []const u8 = "",
};

pub const Config = struct {
    plan: Plan = .pro,
    refresh_interval_seconds: u32 = 30,
    notify_on_reset: bool = true,
    notify_threshold_percent: u8 = 80,
    email: EmailConfig = .{},
    ingest_server: IngestServerConfig = .{},
    claude_data_path: ?[]const u8 = null,
    log_file: ?[]const u8 = null,

    pub fn default() Config {
        return .{};
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = std.fs.openFileAbsolute(path, .{}) catch return error.ConfigNotFound;
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidConfig;
        const obj = root.object;

        var cfg = Config{};

        if (obj.get("plan")) |v| {
            if (v == .string) cfg.plan = Plan.fromString(v.string);
        }
        if (obj.get("refresh_interval_seconds")) |v| {
            if (v == .integer and v.integer > 0) cfg.refresh_interval_seconds = @intCast(v.integer);
        }
        if (obj.get("notify_on_reset")) |v| {
            if (v == .bool) cfg.notify_on_reset = v.bool;
        }
        if (obj.get("notify_threshold_percent")) |v| {
            if (v == .integer) cfg.notify_threshold_percent = @intCast(v.integer);
        }
        if (obj.get("claude_data_path")) |v| {
            if (v == .string) cfg.claude_data_path = try allocator.dupe(u8, v.string);
        }
        if (obj.get("log_file")) |v| {
            if (v == .string) cfg.log_file = try allocator.dupe(u8, v.string);
        }
        if (obj.get("ingest_server")) |iv| {
            if (iv == .object) {
                const io = iv.object;
                var isc = IngestServerConfig{};
                if (io.get("enabled")) |v| if (v == .bool) { isc.enabled = v.bool; };
                if (io.get("bind_host")) |v| if (v == .string) {
                    isc.bind_host = try allocator.dupe(u8, v.string);
                };
                if (io.get("bind_port")) |v| if (v == .integer) { isc.bind_port = @intCast(v.integer); };
                if (io.get("shared_secret")) |v| if (v == .string) {
                    isc.shared_secret = try allocator.dupe(u8, v.string);
                };
                cfg.ingest_server = isc;
            }
        }
        if (obj.get("email")) |email_val| {
            if (email_val == .object) {
                const em = email_val.object;
                var email = EmailConfig{};
                if (em.get("enabled")) |v| {
                    if (v == .bool) email.enabled = v.bool;
                }
                if (em.get("smtp_host")) |v| {
                    if (v == .string) email.smtp_host = try allocator.dupe(u8, v.string);
                }
                if (em.get("smtp_port")) |v| {
                    if (v == .integer) email.smtp_port = @intCast(v.integer);
                }
                if (em.get("username")) |v| {
                    if (v == .string) email.username = try allocator.dupe(u8, v.string);
                }
                if (em.get("password")) |v| {
                    if (v == .string) email.password = try allocator.dupe(u8, v.string);
                }
                if (em.get("from")) |v| {
                    if (v == .string) email.from = try allocator.dupe(u8, v.string);
                }
                if (em.get("to")) |v| {
                    if (v == .string) email.to = try allocator.dupe(u8, v.string);
                }
                cfg.email = email;
            }
        }

        return cfg;
    }

    // Returns the path to Claude's projects directory, caller must free if not claude_data_path.
    pub fn getClaudeDataPath(self: *const Config, allocator: std.mem.Allocator) ![]const u8 {
        if (self.claude_data_path) |p| return p;

        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

        // Try ~/.claude/projects first (standard Claude Code location)
        const path = try std.fs.path.join(allocator, &.{ home, ".claude", "projects" });
        if (std.fs.openDirAbsolute(path, .{}) catch null) |dir| {
            dir.close();
            return path;
        }
        allocator.free(path);

        // Fall back to ~/.config/claude/projects (XDG path)
        return std.fs.path.join(allocator, &.{ home, ".config", "claude", "projects" });
    }
};
