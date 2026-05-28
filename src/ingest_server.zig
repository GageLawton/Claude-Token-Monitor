// Minimal HTTP/1.1 server for the Pi.
// Accepts POST /ingest from ctm-agent and GET /health from anyone on the LAN.
// No TLS — assumes a trusted LAN. A shared secret prevents rogue pushes.

const std = @import("std");
const IngestState = @import("ingest_state.zig").IngestState;

const MAX_HEADERS_BYTES = 8 * 1024;
const MAX_BODY_BYTES = 512 * 1024;

pub const Server = struct {
    allocator: std.mem.Allocator,
    state: *IngestState,
    shared_secret: []const u8,
    start_time_s: i64 = 0,

    pub fn run(self: *Server, bind_host: []const u8, bind_port: u16) !void {
        self.start_time_s = std.time.timestamp();
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
        if (self.shared_secret.len > 0 and
            !std.ascii.eqlIgnoreCase(auth, expected))
        {
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

        // Prune old entries. Use PRUNE_CUTOFF_SECONDS from daemon.zig (6h10m),
        // keeping a little slack for delayed pushes from the spool.
        const cutoff = std.time.timestamp() - (6 * 60 * 60 + 10 * 60);
        self.state.pruneOlderThan(cutoff);

        const resp_body = try std.fmt.allocPrint(a, "{{\"ok\":true,\"accepted\":{d}}}", .{added});
        const resp = try std.fmt.allocPrint(a,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ resp_body.len, resp_body },
        );
        stream.writeAll(resp) catch {};
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
};

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
