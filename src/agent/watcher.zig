// Watches ~/.claude/projects/**/*.jsonl for new content.
// Uses stat()-based polling so it works on Linux and macOS without inotify/kqueue.
// Only the bytes added since the last check are returned — no re-reading.

const std = @import("std");

pub const NewData = struct {
    lines: std.ArrayList([]u8), // each line is owned; caller must free
    allocator: std.mem.Allocator,

    pub fn deinit(self: *NewData) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit();
    }
};

// Tracks read position per file.
const FileState = struct {
    offset: u64,
    mtime_ns: i128,
};

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    projects_path: []const u8,
    // Keyed by absolute file path.
    file_states: std.StringHashMap(FileState),

    pub fn init(allocator: std.mem.Allocator, projects_path: []const u8) Watcher {
        return .{
            .allocator = allocator,
            .projects_path = projects_path,
            .file_states = std.StringHashMap(FileState).init(allocator),
        };
    }

    pub fn deinit(self: *Watcher) void {
        var it = self.file_states.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.file_states.deinit();
    }

    // Scans the project directory tree for JSONL files.
    // Returns only the new lines written since the last call.
    pub fn poll(self: *Watcher) !NewData {
        var new_data = NewData{
            .lines = std.ArrayList([]u8).init(self.allocator),
            .allocator = self.allocator,
        };
        errdefer new_data.deinit();

        var projects_dir = std.fs.openDirAbsolute(self.projects_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound or err == error.NotDir) return new_data;
            return err;
        };
        defer projects_dir.close();

        var proj_iter = projects_dir.iterate();
        while (try proj_iter.next()) |proj_entry| {
            if (proj_entry.kind != .directory) continue;

            var proj_dir = projects_dir.openDir(proj_entry.name, .{ .iterate = true }) catch continue;
            defer proj_dir.close();

            var file_iter = proj_dir.iterate();
            while (try file_iter.next()) |file_entry| {
                if (file_entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, file_entry.name, ".jsonl")) continue;

                const abs_path = try std.fs.path.join(
                    self.allocator,
                    &.{ self.projects_path, proj_entry.name, file_entry.name },
                );
                defer self.allocator.free(abs_path);

                self.readNewBytes(abs_path, &new_data) catch |err| {
                    std.log.warn("watcher: skipping {s}: {}", .{ file_entry.name, err });
                };
            }
        }

        return new_data;
    }

    fn readNewBytes(self: *Watcher, abs_path: []const u8, out: *NewData) !void {
        const file = try std.fs.openFileAbsolute(abs_path, .{});
        defer file.close();

        const meta = try file.stat();
        const current_size = meta.size;

        const gop = try self.file_states.getOrPut(abs_path);
        if (!gop.found_existing) {
            // New file: store path as owned key, start reading from byte 0.
            gop.key_ptr.* = try self.allocator.dupe(u8, abs_path);
            gop.value_ptr.* = .{ .offset = 0, .mtime_ns = meta.mtime };
        }

        const state = gop.value_ptr;

        // File truncated (rotated): reset.
        if (current_size < state.offset) {
            state.offset = 0;
        }

        if (current_size == state.offset) return; // nothing new

        try file.seekTo(state.offset);

        var buf_reader = std.io.bufferedReader(file.reader());
        var line_buf = std.ArrayList(u8).init(self.allocator);
        defer line_buf.deinit();

        while (true) {
            line_buf.clearRetainingCapacity();
            buf_reader.reader().streamUntilDelimiter(line_buf.writer(), '\n', null) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            const trimmed = std.mem.trim(u8, line_buf.items, " \t\r");
            if (trimmed.len == 0) continue;
            const owned = try self.allocator.dupe(u8, trimmed);
            try out.lines.append(owned);
        }

        state.offset = try file.getPos();
        state.mtime_ns = meta.mtime;
    }
};
