// Filesystem watcher for ~/.claude/projects/**/*.jsonl.
//
// Two strategies are tried at init time:
//   1. Linux inotify — event-driven, ~0% idle CPU. Used on Pi Zero / Linux.
//   2. stat() polling — cross-platform fallback for macOS or kernels without inotify.
//
// Either way, only NEW bytes are read from each file (per-file offsets stored
// across calls). The caller polls() to receive new lines, and may call
// waitForEvent() to block until the kernel hints that something changed.

const std = @import("std");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;
const linux = std.os.linux;

pub const NewData = struct {
    lines: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *NewData) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit();
    }
};

const FileState = struct {
    offset: u64,
    mtime_ns: i128,
};

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    projects_path: []const u8,
    file_states: std.StringHashMap(FileState),

    inotify_fd: i32 = -1, // -1 means inotify unavailable

    pub fn init(allocator: std.mem.Allocator, projects_path: []const u8) Watcher {
        var w = Watcher{
            .allocator = allocator,
            .projects_path = projects_path,
            .file_states = std.StringHashMap(FileState).init(allocator),
        };
        if (is_linux) {
            w.tryInitInotify();
        }
        return w;
    }

    pub fn deinit(self: *Watcher) void {
        if (self.inotify_fd >= 0) {
            std.posix.close(self.inotify_fd);
            self.inotify_fd = -1;
        }
        var it = self.file_states.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.file_states.deinit();
    }

    fn tryInitInotify(self: *Watcher) void {
        if (!is_linux) return;

        // inotify_init1 returns usize; negative-cast indicates error.
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        const signed: isize = @bitCast(rc);
        if (signed < 0) return;
        self.inotify_fd = @intCast(signed);

        // Add a watch on the projects root. We re-scan the tree on every event
        // so per-subdir watches aren't required — root events suffice as a
        // "something changed" hint. A periodic timeout in waitForEvent catches
        // the case where IN_MODIFY on a file in a subdir wouldn't bubble up.
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{self.projects_path}) catch {
            std.posix.close(self.inotify_fd);
            self.inotify_fd = -1;
            return;
        };
        const mask = linux.IN.MODIFY | linux.IN.CREATE | linux.IN.MOVED_TO;
        const wd_rc = linux.inotify_add_watch(self.inotify_fd, path_z.ptr, mask);
        const wd_signed: isize = @bitCast(wd_rc);
        if (wd_signed < 0) {
            std.posix.close(self.inotify_fd);
            self.inotify_fd = -1;
            return;
        }
    }

    // Blocks until either a filesystem event arrives or `timeout_ms` elapses.
    // On non-Linux (no inotify), this just sleeps for `timeout_ms`.
    pub fn waitForEvent(self: *Watcher, timeout_ms: i32) void {
        if (self.inotify_fd >= 0) {
            var pfd = [_]std.posix.pollfd{.{
                .fd = self.inotify_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            _ = std.posix.poll(&pfd, timeout_ms) catch return;
            // Drain whatever's queued — we'll rescan in poll() anyway.
            var drain_buf: [4096]u8 = undefined;
            while (true) {
                const n = std.posix.read(self.inotify_fd, &drain_buf) catch break;
                if (n == 0) break;
                if (n < drain_buf.len) break;
            }
        } else {
            const ns: u64 = @as(u64, @intCast(@max(timeout_ms, 0))) * std.time.ns_per_ms;
            std.time.sleep(ns);
        }
    }

    // Scans for new lines added to any JSONL file since the last call.
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
            gop.key_ptr.* = try self.allocator.dupe(u8, abs_path);
            gop.value_ptr.* = .{ .offset = 0, .mtime_ns = meta.mtime };
        }

        const state = gop.value_ptr;

        // Truncation / rotation: re-read from the start.
        if (current_size < state.offset) state.offset = 0;
        if (current_size == state.offset) return;

        try file.seekTo(state.offset);

        var buf_reader = std.io.bufferedReader(file.reader());
        var line_buf = std.ArrayList(u8).init(self.allocator);
        defer line_buf.deinit();

        // Track committed bytes manually so a partial final line (no trailing
        // newline yet) is not counted — re-read it once the write completes.
        var committed_offset = state.offset;
        while (true) {
            line_buf.clearRetainingCapacity();
            buf_reader.reader().streamUntilDelimiter(line_buf.writer(), '\n', null) catch |err| {
                if (err == error.EndOfStream) break; // partial line — don't advance
                return err;
            };
            committed_offset += @as(u64, @intCast(line_buf.items.len)) + 1; // +1 for '\n'
            const trimmed = std.mem.trim(u8, line_buf.items, " \t\r");
            if (trimmed.len == 0) continue;
            const owned = try self.allocator.dupe(u8, trimmed);
            try out.lines.append(owned);
        }

        state.offset = committed_offset;
        state.mtime_ns = meta.mtime;
    }
};
