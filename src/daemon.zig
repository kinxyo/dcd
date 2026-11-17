//! `dcd daemon`: keeps the screens in the desired mode for whatever monitors
//! are connected, and `dcd reload`, which asks it to check now.
//!
//! The daemon holds one long-lived connection, used only as a trigger: any
//! `done` means "go look". Its contents can be stale (sprints 1 and 2), so
//! every check reads the screens over a fresh connection instead.

const std = @import("std");
const linux = std.os.linux;
const state = @import("state.zig");
const store = @import("store.zig");
const sys = @import("sys.zig");
const outputs = @import("outputs.zig");
const switching = @import("switching.zig");

/// Hyprland sends bursts of `done` during one switch. Check once things have
/// been quiet this long.
const debounce_ms = 500;
/// The loop guard: this many switches for one monitor set within this window
/// means something keeps undoing dcd.
const guard_switches = 3;
const guard_window_ms = 30_000;

// -- reload ----------------------------------------------------------------------

pub fn reload(init: std.process.Init, out: *std.Io.Writer) !u8 {
    const pid = try runningPid(init) orelse {
        try out.writeAll("dcd daemon is not running\n");
        return 1;
    };
    if (linux.errno(linux.kill(pid, linux.SIG.USR1)) != .SUCCESS) {
        try out.writeAll("dcd daemon is not running\n");
        return 1;
    }
    try out.print("asked the daemon (pid {d}) to check now\n", .{pid});
    return 0;
}

/// The running daemon's pid, or null if none holds the lock (whatever the
/// pid file says).
pub fn runningPid(init: std.process.Init) !?i32 {
    const gpa = init.gpa;
    const pid_path = try pidPath(gpa, init.environ_map);
    defer gpa.free(pid_path);

    const fd = sys.open(pid_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    defer sys.close(fd);
    if (sys.lockExclusive(fd)) |_| {
        return null; // free lock: no daemon
    } else |err| if (err != error.WouldBlock) return err;

    const text = try sys.readFile(gpa, pid_path, 64) orelse return null;
    defer gpa.free(text);
    return std.fmt.parseInt(i32, std.mem.trim(u8, text, " \n"), 10) catch null;
}

fn pidPath(a: std.mem.Allocator, environ: *const std.process.Environ.Map) ![:0]u8 {
    const runtime = environ.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
    return std.fmt.allocPrintSentinel(a, "{s}/dcd.pid", .{runtime}, 0);
}

// -- daemon ----------------------------------------------------------------------

const Daemon = struct {
    init: std.process.Init,
    log: Log,
    timer_fd: sys.Fd,
    force_fail: bool,
    guard: Guard = .{},

    /// Called at every `done` on the long-lived connection: (re)start the
    /// debounce timer.
    fn onDone(ctx: ?*anyopaque, _: ?*const outputs.Snapshot, _: *const outputs.Snapshot) anyerror!void {
        const d: *Daemon = @ptrCast(@alignCast(ctx.?));
        try d.armTimer();
    }

    fn armTimer(d: *Daemon) !void {
        const spec: linux.itimerspec = .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = debounce_ms * std.time.ns_per_ms },
        };
        if (linux.errno(linux.timerfd_settime(d.timer_fd, .{}, &spec, null)) != .SUCCESS) return error.TimerFd;
    }

    /// A check whose unexpected errors are logged instead of ending the
    /// daemon: the next trigger simply tries again.
    fn checkLogged(d: *Daemon, why: []const u8) void {
        d.check(why) catch |err| d.log.line("check ({s}) failed: {t}; will retry on the next change or dcd reload", .{ why, err });
    }

    /// Reads the screens fresh, looks up the desired mode, and applies it if
    /// the screens don't already match.
    fn check(d: *Daemon, why: []const u8) !void {
        const gpa = d.init.gpa;
        defer d.log.flush();
        const w = d.log.writer();

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const o = outputs.Outputs.open(d.init, null, null) catch |err| {
            try w.print("check ({s}): cannot read the screens: {t}\n", .{ why, err });
            return;
        };
        const heads = o.heads();
        if (heads.len == 0) {
            o.close();
            try w.print("check ({s}): no screens reported, skipping\n", .{why});
            return;
        }
        const key = try store.keyOf(a, heads);
        const default = store.defaultMode(heads);
        o.close();

        var saved = store.load(gpa, d.init.environ_map) catch |err| blk: {
            try w.print("cannot read saved modes: {t}; using defaults\n", .{err});
            break :blk store.Store.init(gpa);
        };
        defer saved.deinit();
        const chosen = saved.get(key);
        const target = chosen orelse default;

        if (d.guard.tripped(key)) {
            try w.print("check ({s}): {t} for {s}: skipped, loop guard is on (dcd reload to retry)\n", .{ why, target, key });
            return;
        }
        try w.print("check ({s}): {t} ({s}) for {s}\n", .{ why, target, if (chosen != null) "saved" else "default", key });

        const result = try switching.switchTo(d.init, w, target, .{ .force_fail = d.force_fail });
        switch (result) {
            .already, .refused => {},
            .switched => {},
            .fell_back_laptop => d.notify("Display switch failed", "Couldn't switch to the external monitor. The laptop panel is on."),
            .fell_back_all => d.notify("Display switch failed", "Couldn't apply the display mode. Every screen is on."),
            .nothing => d.notify("Display switch failed", "No display configuration could be applied. See ~/.local/state/dcd/daemon.log."),
        }
        if (result != .already and result != .refused) {
            if (try d.guard.record(gpa, key, outputs.now())) {
                try w.print("loop guard: {d} switches in {d}s for {s}; not switching this monitor set again until dcd reload\n", .{ guard_switches, guard_window_ms / 1000, key });
                d.notify("Display switching paused", "The screens kept changing back. dcd stopped switching; run `dcd reload` to retry.");
            }
        }
    }

    fn notify(d: *Daemon, title: []const u8, body: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(d.init.gpa);
        defer arena.deinit();
        sys.spawnDetached(arena.allocator(), &.{ "notify-send", "-a", "dcd", title, body }, d.init.environ_map) catch |err| {
            d.log.writer().print("could not send a notification: {t}\n", .{err}) catch {};
        };
    }
};

/// Counts switches per monitor set. Trips when one set needs too many
/// switches in a short time, and stays tripped for that set until reset.
const Guard = struct {
    key: ?[]u8 = null,
    times: [guard_switches]u64 = @splat(0),
    count: usize = 0,
    is_tripped: bool = false,

    fn tripped(g: *const Guard, key: []const u8) bool {
        const k = g.key orelse return false;
        return g.is_tripped and std.mem.eql(u8, k, key);
    }

    /// Records a switch at `t` (ns). Returns true if this one tripped it.
    fn record(g: *Guard, gpa: std.mem.Allocator, key: []const u8, t: u64) !bool {
        if (g.key == null or !std.mem.eql(u8, g.key.?, key)) {
            g.reset(gpa);
            g.key = try gpa.dupe(u8, key);
        }
        g.times[g.count % guard_switches] = t;
        g.count += 1;
        if (g.count < guard_switches) return false;
        // The oldest of the last `guard_switches` switches.
        const oldest = g.times[g.count % guard_switches];
        if (t - oldest <= guard_window_ms * std.time.ns_per_ms) {
            g.is_tripped = true;
            return true;
        }
        return false;
    }

    fn reset(g: *Guard, gpa: std.mem.Allocator) void {
        if (g.key) |k| gpa.free(k);
        g.* = .{};
    }
};

/// The daemon's log: whole lines, each stamped with the time, appended to
/// the log file and echoed to stdout when that's a terminal. Callers write
/// into a buffer; `flush` stamps and writes complete lines.
const Log = struct {
    aw: std.Io.Writer.Allocating,
    file: ?sys.Fd,
    tty: bool,

    fn writer(l: *Log) *std.Io.Writer {
        return &l.aw.writer;
    }

    fn line(l: *Log, comptime fmt: []const u8, args: anytype) void {
        l.writer().print(fmt ++ "\n", args) catch {};
        l.flush();
    }

    fn flush(l: *Log) void {
        var stamp: [32]u8 = undefined;
        const ts = timestamp(&stamp);
        var lines = std.mem.splitScalar(u8, l.aw.written(), '\n');
        while (lines.next()) |text| {
            if (text.len == 0) continue;
            var buf: [4096]u8 = undefined;
            const out = std.fmt.bufPrint(&buf, "{s} {s}\n", .{ ts, text }) catch continue;
            if (l.file) |fd| sys.writeAll(fd, out) catch {};
            if (l.tty) sys.writeAll(1, out) catch {};
        }
        l.aw.clearRetainingCapacity();
    }
};

/// Wall-clock time as `2026-11-17 01:23:45Z` (UTC).
fn timestamp(buf: []u8) []const u8 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts.sec) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,                 md.month.numeric(),        md.day_index + 1,
        ds.getHoursIntoDay(),    ds.getMinutesIntoHour(),   ds.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

pub fn run(init: std.process.Init, out: *std.Io.Writer, force_fail: bool) !u8 {
    const gpa = init.gpa;

    // -- single instance
    const pid_path = pidPath(gpa, init.environ_map) catch {
        try out.writeAll("dcd: XDG_RUNTIME_DIR is not set\n");
        return 1;
    };
    defer gpa.free(pid_path);
    const pid_fd = try sys.open(pid_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o644);
    defer sys.close(pid_fd);
    sys.lockExclusive(pid_fd) catch |err| switch (err) {
        error.WouldBlock => {
            try out.writeAll("dcd daemon is already running\n");
            return 1;
        },
        else => return err,
    };
    try sys.truncate(pid_fd);
    var pid_buf: [16]u8 = undefined;
    try sys.writeAll(pid_fd, try std.fmt.bufPrint(&pid_buf, "{d}\n", .{linux.getpid()}));

    // -- log
    const log_dir = try store.dir(gpa, init.environ_map);
    defer gpa.free(log_dir);
    try sys.mkdirAll(gpa, log_dir);
    const log_path = try std.fmt.allocPrintSentinel(gpa, "{s}/daemon.log", .{log_dir}, 0);
    defer gpa.free(log_path);
    const log_fd: ?sys.Fd = sys.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644) catch null;
    defer if (log_fd) |fd| sys.close(fd);

    // -- signals and timer, polled with the Wayland socket
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, linux.SIG.INT);
    linux.sigaddset(&mask, linux.SIG.TERM);
    linux.sigaddset(&mask, linux.SIG.USR1);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const sfd_rc = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC);
    if (linux.errno(sfd_rc) != .SUCCESS) return error.SignalFd;
    const sfd: sys.Fd = @intCast(sfd_rc);
    defer sys.close(sfd);

    const tfd_rc = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true });
    if (linux.errno(tfd_rc) != .SUCCESS) return error.TimerFd;
    const tfd: sys.Fd = @intCast(tfd_rc);
    defer sys.close(tfd);

    var d: Daemon = .{
        .init = init,
        .log = .{ .aw = .init(gpa), .file = log_fd, .tty = sys.isTerminal(1) },
        .timer_fd = tfd,
        .force_fail = force_fail,
    };
    defer d.log.aw.deinit();
    defer d.guard.reset(gpa);

    d.log.line("dcd daemon started (pid {d}){s}", .{ linux.getpid(), if (force_fail) ", --force-fail" else "" });

    // -- the trigger connection
    const trigger = outputs.Outputs.open(init, null, null) catch |err| {
        d.log.line("cannot connect to the compositor: {t}", .{err});
        return 1;
    };
    defer trigger.close();
    // Hooked up after the first snapshot: startup gets its own check below.
    trigger.live.on_done = Daemon.onDone;
    trigger.live.on_done_ctx = &d;

    d.checkLogged("startup");

    var fds = [_]linux.pollfd{
        .{ .fd = trigger.conn.fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = sfd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = tfd, .events = linux.POLL.IN, .revents = 0 },
    };
    while (true) {
        try trigger.conn.flush();
        const rc = linux.poll(&fds, fds.len, -1);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Poll,
        }

        if (fds[1].revents != 0) {
            var info: linux.signalfd_siginfo = undefined;
            _ = linux.read(sfd, @ptrCast(&info), @sizeOf(linux.signalfd_siginfo));
            if (info.signo == @intFromEnum(linux.SIG.USR1)) {
                d.guard.reset(gpa);
                d.checkLogged("reload");
            } else {
                d.log.line("stopping (signal {d}); screens left as they are", .{info.signo});
                return 0;
            }
        }
        if (fds[2].revents != 0) {
            var expirations: u64 = 0;
            _ = linux.read(tfd, @ptrCast(&expirations), @sizeOf(u64));
            d.checkLogged("screens changed");
        }
        if (fds[0].revents & linux.POLL.IN != 0) {
            trigger.dispatchReadable() catch |err| {
                d.log.line("lost the compositor connection: {t}; exiting", .{err});
                return 1;
            };
            if (trigger.live.finished) {
                d.log.line("the compositor stopped output management; exiting", .{});
                return 1;
            }
        } else if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
            d.log.line("the compositor closed the connection; exiting", .{});
            return 1;
        }
    }
}

// -- tests ---------------------------------------------------------------------

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "guard trips on the third switch within the window" {
    var g: Guard = .{};
    defer g.reset(testing.allocator);
    try testing.expect(!try g.record(testing.allocator, "A", 0));
    try testing.expect(!try g.record(testing.allocator, "A", 10_000 * ms));
    try testing.expect(try g.record(testing.allocator, "A", 20_000 * ms));
    try testing.expect(g.tripped("A"));
    try testing.expect(!g.tripped("B"));
}

test "guard doesn't trip when switches are spread out" {
    var g: Guard = .{};
    defer g.reset(testing.allocator);
    _ = try g.record(testing.allocator, "A", 0);
    _ = try g.record(testing.allocator, "A", 20_000 * ms);
    try testing.expect(!try g.record(testing.allocator, "A", 40_000 * ms));
    try testing.expect(!try g.record(testing.allocator, "A", 60_000 * ms));
    try testing.expect(!g.tripped("A"));
}

test "guard starts over for a different monitor set" {
    var g: Guard = .{};
    defer g.reset(testing.allocator);
    _ = try g.record(testing.allocator, "A", 0);
    _ = try g.record(testing.allocator, "A", 1_000 * ms);
    try testing.expect(!try g.record(testing.allocator, "B", 2_000 * ms));
    try testing.expect(!g.tripped("A"));
}
