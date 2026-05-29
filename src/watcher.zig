// Filesystem watcher for ~/.claude/projects/**/*.jsonl.
//
// Three strategies tried in order at init time:
//   1. Linux inotify    — event-driven, ~0% idle CPU. Used on Pi Zero / Linux.
//   2. BSD/macOS kqueue — event-driven, ~0% idle CPU. Used on macOS dev machines.
//   3. stat() polling   — cross-platform fallback for other platforms.
//
// Either way, only NEW bytes are read from each file (per-file offsets stored
// across calls). The caller polls() to receive new lines, and may call
// waitForEvent() to block until the kernel hints that something changed.

const std = @import("std");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;
const is_bsd = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

const linux = std.os.linux;

// kqueue filter/flag constants (BSD <sys/event.h> — stable for decades).
const KQ_EVFILT_VNODE: i16 = -4;
const KQ_EV_ADD: u16 = 0x0001;
const KQ_EV_CLEAR: u16 = 0x0020;
const KQ_NOTE_WRITE: u32 = 0x00000002;
const KQ_NOTE_EXTEND: u32 = 0x00000004;

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

    inotify_fd: i32 = -1,  // Linux inotify; -1 = unavailable
    kqueue_fd: i32 = -1,   // BSD/macOS kqueue; -1 = unavailable
    kqueue_dir_fd: i32 = -1, // directory fd kept open for the kqueue vnode watch

    pub fn init(allocator: std.mem.Allocator, projects_path: []const u8) Watcher {
        var w = Watcher{
            .allocator = allocator,
            .projects_path = projects_path,
            .file_states = std.StringHashMap(FileState).init(allocator),
        };
        if (is_linux) {
            w.tryInitInotify();
        } else if (is_bsd) {
            w.tryInitKqueue();
        }
        return w;
    }

    pub fn deinit(self: *Watcher) void {
        if (self.inotify_fd >= 0) {
            std.posix.close(self.inotify_fd);
            self.inotify_fd = -1;
        }
        if (self.kqueue_dir_fd >= 0) {
            std.posix.close(self.kqueue_dir_fd);
            self.kqueue_dir_fd = -1;
        }
        if (self.kqueue_fd >= 0) {
            std.posix.close(self.kqueue_fd);
            self.kqueue_fd = -1;
        }
        var it = self.file_states.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.file_states.deinit();
    }

    // ── inotify (Linux) ───────────────────────────────────────────────────────

    fn tryInitInotify(self: *Watcher) void {
        if (!is_linux) return;

        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        const signed: isize = @bitCast(rc);
        if (signed < 0) return;
        self.inotify_fd = @intCast(signed);

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
        }
    }

    // ── kqueue (macOS / BSD) ──────────────────────────────────────────────────

    fn tryInitKqueue(self: *Watcher) void {
        if (!is_bsd) return;

        const kq = std.posix.kqueue() catch return;

        // Open the projects directory for vnode watching.
        // O_EVTONLY (0x8000) avoids preventing unmount on macOS; fall back to RDONLY.
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{self.projects_path}) catch {
            std.posix.close(kq);
            return;
        };

        const O_EVTONLY: u32 = if (builtin.os.tag == .macos) 0x8000 else 0;
        const open_flags: std.posix.O = if (O_EVTONLY != 0)
            @bitCast(O_EVTONLY)
        else
            .{ .ACCMODE = .RDONLY };

        const dir_fd = std.posix.open(path_z, open_flags, 0) catch {
            std.posix.close(kq);
            return;
        };

        // Register a vnode watch for write/extend events.
        var kev = std.posix.Kevent{
            .ident = @intCast(dir_fd),
            .filter = KQ_EVFILT_VNODE,
            .flags = KQ_EV_ADD | KQ_EV_CLEAR,
            .fflags = KQ_NOTE_WRITE | KQ_NOTE_EXTEND,
            .data = 0,
            .udata = 0,
        };
        _ = std.posix.kevent(kq, &.{kev}, &.{}, null) catch {
            std.posix.close(dir_fd);
            std.posix.close(kq);
            return;
        };

        self.kqueue_fd = kq;
        self.kqueue_dir_fd = dir_fd;
    }

    // ── Event waiting ─────────────────────────────────────────────────────────

    // Blocks until either a filesystem event arrives or `timeout_ms` elapses.
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
        } else if (self.kqueue_fd >= 0) {
            const ms: u64 = @intCast(@max(timeout_ms, 0));
            const ts = std.posix.timespec{
                .tv_sec = @intCast(ms / 1000),
                .tv_nsec = @intCast((ms % 1000) * 1_000_000),
            };
            var ev_out: [1]std.posix.Kevent = undefined;
            _ = std.posix.kevent(self.kqueue_fd, &.{}, &ev_out, &ts) catch {};
        } else {
            const ns: u64 = @as(u64, @intCast(@max(timeout_ms, 0))) * std.time.ns_per_ms;
            std.time.sleep(ns);
        }
    }

    // ── Incremental line scanning ─────────────────────────────────────────────

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
