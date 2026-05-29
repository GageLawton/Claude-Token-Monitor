// Minimal HTTP/1.1 server for the Pi.
// Accepts POST /ingest from ctm-agent and GET /health from anyone on the LAN.
// No TLS — assumes a trusted LAN. A shared secret prevents rogue pushes.
// Per-source-IP rate limiting (configurable, default 120 req/min) protects the Pi Zero.

const std = @import("std");
const IngestState = @import("ingest_state.zig").IngestState;

const MAX_HEADERS_BYTES = 8 * 1024;
const MAX_BODY_BYTES = 512 * 1024;

// Per-IP request tracking for rate limiting.
const IpState = struct {
    window_start_s: i64,
    count: u32,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    state: *IngestState,
    shared_secret: []const u8,
    start_time_s: i64 = 0,
    rate_limit_per_minute: u32 = 120,

    // Rate-limit table — keyed by source-IP string, keys are heap-allocated.
    ip_rate: std.StringHashMap(IpState) = undefined,
    ip_rate_mutex: std.Thread.Mutex = .{},
    request_count: u64 = 0,

    pub fn run(self: *Server, bind_host: []const u8, bind_port: u16) !void {
        self.start_time_s = std.time.timestamp();
        self.ip_rate = std.StringHashMap(IpState).init(self.allocator);
        defer {
            var it = self.ip_rate.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            self.ip_rate.deinit();
        }

        const address = try std.net.Address.parseIp(bind_host, bind_port);
        var net_server = try address.listen(.{ .reuse_address = true });
        defer net_server.deinit();

        std.log.info("ingest server listening on {s}:{d}", .{ bind_host, bind_port });

        while (true) {
            const conn = net_server.accept() catch |err| {
                std.log.warn("accept error: {}", .{err});
                continue;
            };
            self.handleConn(conn) catch |err| {
                std.log.warn("request error: {}", .{err});
            };
            conn.stream.close();
        }
    }

    fn handleConn(self: *Server, conn: std.net.Server.Connection) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const stream = conn.stream;

        var header_buf: [MAX_HEADERS_BYTES]u8 = undefined;
        const header_end = try readUntilDoubleNewline(stream, &header_buf);
        const header_section = header_buf[0..header_end];

        const first_crlf = std.mem.indexOf(u8, header_section, "\r\n") orelse
            return self.respond(stream, 400, "Bad Request");
        const request_line = header_section[0..first_crlf];

        var it = std.mem.splitScalar(u8, request_line, ' ');
        const method = it.next() orelse return self.respond(stream, 400, "Bad Request");
        const path = it.next() orelse return self.respond(stream, 400, "Bad Request");

        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/health")) {
            return self.handleHealth(a, stream);
        }

        if (!std.mem.eql(u8, method, "POST") or !std.mem.eql(u8, path, "/ingest")) {
            return self.respond(stream, 404, "Not Found");
        }

        // Rate-limit /ingest per source IP.
        var ip_buf: [64]u8 = undefined;
        const ip = remoteIp(conn.address, &ip_buf);
        if (!self.checkRateLimit(ip)) {
            std.log.warn("rate limit exceeded for {s}", .{ip});
            return self.respondWithHeader(stream, 429, "Too Many Requests", "Retry-After: 60");
        }

        return self.handleIngest(a, stream, header_section[first_crlf + 2 ..]);
    }

    fn handleHealth(self: *Server, a: std.mem.Allocator, stream: std.net.Stream) void {
        const now = std.time.timestamp();
        const entry_count = self.state.entryCount();
        const last_ingest = self.state.lastUpdatedS();
        const uptime = now - self.start_time_s;

        const body = std.fmt.allocPrint(a,
            "{{\"status\":\"ok\",\"entries\":{d},\"last_ingest_s\":{d},\"uptime_s\":{d}}}",
            .{ entry_count, last_ingest, uptime },
        ) catch return self.respond(stream, 500, "Internal Error");

        const resp = std.fmt.allocPrint(a,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ body.len, body },
        ) catch return self.respond(stream, 500, "Internal Error");

        stream.writeAll(resp) catch {};
    }

    fn handleIngest(
        self: *Server,
        a: std.mem.Allocator,
        stream: std.net.Stream,
        headers_body: []const u8,
    ) !void {
        const auth = findHeader(headers_body, "authorization") orelse
            return self.respond(stream, 401, "Unauthorized");
        const content_length_str = findHeader(headers_body, "content-length") orelse
            return self.respond(stream, 400, "Content-Length required");

        const expected = try std.fmt.allocPrint(a, "bearer {s}", .{self.shared_secret});
        if (self.shared_secret.len > 0 and !std.ascii.eqlIgnoreCase(auth, expected)) {
            return self.respond(stream, 403, "Forbidden");
        }

        const content_length = std.fmt.parseInt(usize, content_length_str, 10) catch
            return self.respond(stream, 400, "Invalid Content-Length");
        if (content_length > MAX_BODY_BYTES)
            return self.respond(stream, 413, "Payload Too Large");

        const body = try a.alloc(u8, content_length);
        try stream.reader().readNoEof(body);

        const Payload = struct { lines: [][]const u8 };
        const parsed = std.json.parseFromSlice(Payload, a, body, .{
            .ignore_unknown_fields = true,
        }) catch return self.respond(stream, 400, "Invalid JSON");
        defer parsed.deinit();

        const added = try self.state.addLines(parsed.value.lines);
        std.log.info("ingest: +{d} entries ({d} pushed)", .{ added, parsed.value.lines.len });

        const cutoff = std.time.timestamp() - (6 * 60 * 60 + 10 * 60);
        self.state.pruneOlderThan(cutoff);

        // Periodically evict stale entries from the rate-limit table.
        self.request_count += 1;
        if (self.request_count % 200 == 0) self.pruneIpTable();

        const resp_body = try std.fmt.allocPrint(a, "{{\"ok\":true,\"accepted\":{d}}}", .{added});
        const resp = try std.fmt.allocPrint(a,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ resp_body.len, resp_body },
        );
        stream.writeAll(resp) catch {};
    }

    // Returns true if the request is within the rate limit for this IP.
    fn checkRateLimit(self: *Server, ip: []const u8) bool {
        if (self.rate_limit_per_minute == 0) return true;
        self.ip_rate_mutex.lock();
        defer self.ip_rate_mutex.unlock();

        const now = std.time.timestamp();

        if (self.ip_rate.getPtr(ip)) |s| {
            if (now - s.window_start_s >= 60) {
                s.* = .{ .window_start_s = now, .count = 1 };
                return true;
            }
            if (s.count >= self.rate_limit_per_minute) return false;
            s.count += 1;
            return true;
        }

        // New IP — allocate a key copy and insert.
        const key = self.allocator.dupe(u8, ip) catch return true;
        self.ip_rate.put(key, .{ .window_start_s = now, .count = 1 }) catch {
            self.allocator.free(key);
        };
        return true;
    }

    // Removes entries whose 1-minute window has fully expired.
    fn pruneIpTable(self: *Server) void {
        self.ip_rate_mutex.lock();
        defer self.ip_rate_mutex.unlock();

        const cutoff = std.time.timestamp() - 60;
        var to_delete = std.BoundedArray([]const u8, 64).init(0) catch return;
        var it = self.ip_rate.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.window_start_s < cutoff)
                to_delete.append(entry.key_ptr.*) catch {};
        }
        for (to_delete.constSlice()) |k| {
            _ = self.ip_rate.remove(k);
            self.allocator.free(k);
        }
    }

    fn respond(self: *Server, stream: std.net.Stream, code: u16, reason: []const u8) void {
        _ = self;
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            .{ code, reason },
        ) catch return;
        stream.writeAll(msg) catch {};
    }

    fn respondWithHeader(
        self: *Server,
        stream: std.net.Stream,
        code: u16,
        reason: []const u8,
        extra_header: []const u8,
    ) void {
        _ = self;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "HTTP/1.1 {d} {s}\r\n{s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            .{ code, reason, extra_header },
        ) catch return;
        stream.writeAll(msg) catch {};
    }
};

// Extract just the IP portion from a std.net.Address (strips the port).
fn remoteIp(addr: std.net.Address, buf: []u8) []const u8 {
    const full = std.fmt.bufPrint(buf, "{}", .{addr}) catch return "";
    if (std.mem.lastIndexOfScalar(u8, full, ':')) |colon| return full[0..colon];
    return full;
}

fn readUntilDoubleNewline(stream: std.net.Stream, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total .. total + 1]);
        if (n == 0) break;
        total += n;
        if (total >= 4 and std.mem.eql(u8, buf[total - 4 .. total], "\r\n\r\n")) {
            return total - 4;
        }
    }
    return error.HeadersTooLarge;
}

fn findHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var line_it = std.mem.splitSequence(u8, headers, "\r\n");
    while (line_it.next()) |line| {
        const colon = std.mem.indexOf(u8, line, ":") orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(key, name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}
