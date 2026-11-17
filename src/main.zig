//! dcd: display configuration daemon.

const std = @import("std");
const linux = std.os.linux;
const state = @import("state.zig");
const store = @import("store.zig");
const outputs = @import("outputs.zig");
const switching = @import("switching.zig");
const daemon = @import("daemon.zig");

const usage =
    \\usage: dcd <command>
    \\
    \\commands:
    \\  laptop    built-in panel on, external monitor off (remembered)
    \\  external  external monitor on, built-in panel off (remembered)
    \\  daemon    keep the screens in the remembered mode as monitors come and go
    \\  reload    ask the running daemon to check the screens now
    \\  status    the wanted mode, the screens, and whether the daemon runs
    \\  watch     print the screens and every change to them, live
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.writeAll(usage);
        return 2;
    }
    const cmd = args[1];
    // Hidden: skip the real apply and report failure, to exercise the fallback.
    const force_fail = args.len == 3 and std.mem.eql(u8, args[2], "--force-fail");
    if (args.len > 2 and !force_fail) {
        try out.writeAll(usage);
        return 2;
    }

    if (std.mem.eql(u8, cmd, "laptop")) return switchCommand(init, out, .laptop, force_fail);
    if (std.mem.eql(u8, cmd, "external")) return switchCommand(init, out, .external, force_fail);
    if (std.mem.eql(u8, cmd, "daemon")) {
        try out.flush();
        return daemon.run(init, out, force_fail);
    }
    if (!force_fail) {
        if (std.mem.eql(u8, cmd, "reload")) return daemon.reload(init, out);
        if (std.mem.eql(u8, cmd, "status")) return status(init, out);
        if (std.mem.eql(u8, cmd, "watch")) return watch(init, out);
    }
    try out.writeAll(usage);
    return 2;
}

// -- laptop / external ---------------------------------------------------------

/// Saves the choice for the connected monitors, then switches. Saving comes
/// first, so a running daemon reacting to the switch already sees the new
/// choice. Exit codes: 0 done, 1 fell back, 2 refused, 3 nothing applied.
fn switchCommand(init: std.process.Init, out: *std.Io.Writer, target: state.Target, force_fail: bool) !u8 {
    const gpa = init.gpa;
    {
        const o = outputs.Outputs.open(init, null, null) catch |err| {
            try out.print("{t}: cannot read the screens: {t}\n", .{ target, err });
            return 3;
        };
        defer o.close();
        const heads = o.heads();
        switch (state.plan(heads, target)) {
            .refused => |r| {
                try out.print("{t}: refused: {s}\n", .{ target, r.message() });
                return 2;
            },
            .plan => {},
        }
        saveChoice(gpa, init.environ_map, heads, target) catch |err| {
            try out.print("{t}: warning: could not save the choice: {t}\n", .{ target, err });
        };
    }

    return switch (try switching.switchTo(init, out, target, .{ .force_fail = force_fail })) {
        .already, .switched => 0,
        .fell_back_laptop, .fell_back_all => 1,
        .refused => 2,
        .nothing => 3,
    };
}

fn saveChoice(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, heads: []const state.Head, target: state.Target) !void {
    var s = try store.load(gpa, environ);
    defer s.deinit();
    const key = try store.keyOf(gpa, heads);
    defer gpa.free(key);
    try s.set(key, target);
    try store.save(&s, gpa, environ);
}

// -- status --------------------------------------------------------------------

/// Read-only. Exit code 0 when the screens match the wanted mode, else 1.
fn status(init: std.process.Init, out: *std.Io.Writer) !u8 {
    const gpa = init.gpa;
    const o = outputs.Outputs.open(init, null, null) catch |err| {
        try out.print("dcd: cannot read the screens: {t}\n", .{err});
        return 1;
    };
    defer o.close();
    const heads = o.heads();

    const key = try store.keyOf(gpa, heads);
    defer gpa.free(key);
    var saved = store.load(gpa, init.environ_map) catch store.Store.init(gpa);
    defer saved.deinit();
    const chosen = saved.get(key);
    const target = chosen orelse store.defaultMode(heads);

    const match = switch (state.plan(heads, target)) {
        .plan => |p| state.verify(heads, &p),
        .refused => false,
    };

    try out.print("mode:     {t} ({s})\n", .{ target, if (chosen != null) "saved" else "default" });
    try out.writeAll("screens: ");
    for (heads, 0..) |h, i| {
        try out.print("{s} {s}", .{ if (i == 0) "" else ",", h.name });
        if (h.mode) |m| try out.print(" on {f}", .{m}) else try out.writeAll(" off");
    }
    try out.print("\nmatch:    {s}\n", .{if (match) "yes" else "no"});
    if (try daemon.runningPid(init)) |pid| {
        try out.print("daemon:   running (pid {d})\n", .{pid});
    } else {
        try out.writeAll("daemon:   not running\n");
    }
    return if (match) 0 else 1;
}

// -- watch -----------------------------------------------------------------------

const Watch = struct {
    out: *std.Io.Writer,
    start: u64,

    fn onDone(ctx: ?*anyopaque, prev: ?*const outputs.Snapshot, next: *const outputs.Snapshot) anyerror!void {
        const wt: *Watch = @ptrCast(@alignCast(ctx.?));
        const w = wt.out;
        try w.print("[{d:>8}ms] serial {d}", .{ (outputs.now() - wt.start) / std.time.ns_per_ms, next.serial });
        if (prev) |p| {
            const changes = try state.diff(std.heap.page_allocator, p.heads, next.heads);
            defer std.heap.page_allocator.free(changes);
            if (changes.len == 0) try w.writeAll("  (no change)");
            for (changes, 0..) |c, i| {
                try w.writeAll(if (i == 0) "  " else "\n                       ");
                try printChange(w, c);
            }
            try w.writeByte('\n');
        } else {
            try w.writeByte('\n');
            for (next.heads) |h| try printHead(w, h);
        }
    }
};

fn watch(init: std.process.Init, out: *std.Io.Writer) !u8 {
    var wt: Watch = .{ .out = out, .start = outputs.now() };
    const o = outputs.Outputs.open(init, Watch.onDone, &wt) catch |err| {
        try out.print("dcd: cannot read the screens: {t}\n", .{err});
        return 1;
    };
    defer o.close();

    // SIGINT and SIGTERM arrive on a file descriptor, polled with the
    // Wayland socket, instead of interrupting whatever is running.
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, linux.SIG.INT);
    linux.sigaddset(&mask, linux.SIG.TERM);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const sfd_rc = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC);
    if (linux.errno(sfd_rc) != .SUCCESS) return error.SignalFd;
    const sfd: i32 = @intCast(sfd_rc);
    defer _ = linux.close(sfd);

    var fds = [_]linux.pollfd{
        .{ .fd = o.conn.fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = sfd, .events = linux.POLL.IN, .revents = 0 },
    };
    while (!o.live.finished) {
        try o.conn.flush();
        try out.flush();
        const rc = linux.poll(&fds, fds.len, -1);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Poll,
        }
        if (fds[1].revents != 0) return 0; // SIGINT or SIGTERM
        if (fds[0].revents & linux.POLL.IN != 0) {
            o.dispatchReadable() catch |err| switch (err) {
                error.ConnectionClosed => {
                    try out.writeAll("dcd: compositor closed the connection\n");
                    return 1;
                },
                else => return err,
            };
        } else if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
            try out.writeAll("dcd: compositor closed the connection\n");
            return 1;
        }
    }
    try out.writeAll("dcd: compositor stopped output management\n");
    return 1;
}

fn printHead(w: *std.Io.Writer, h: state.Head) !void {
    var id_buf: [512]u8 = undefined;
    try w.print("  {s:<10} {s:<8} {s:<8} ", .{
        h.name,
        if (h.isBuiltin()) "builtin" else "external",
        if (h.enabled) "enabled" else "disabled",
    });
    if (h.mode) |m| try w.print("{f} scale {d:.2}", .{ m, h.scale }) else try w.writeAll("-");
    if (state.pickMode(h.modes)) |best| try w.print("  best {f}", .{best});
    try w.print("  \"{s}\"\n", .{h.identity(&id_buf)});
}

fn printChange(w: *std.Io.Writer, c: state.Change) !void {
    switch (c) {
        .connected => |h| try w.print("+ {s} connected ({s})", .{ h.name, onOff(h.enabled) }),
        .removed => |name| try w.print("- {s} removed", .{name}),
        .enabled => |e| try w.print("~ {s} {s} → {s}", .{ e.name, onOff(e.from), onOff(e.to) }),
        .mode => |e| {
            try w.print("~ {s} mode ", .{e.name});
            try printOptMode(w, e.from);
            try w.writeAll(" → ");
            try printOptMode(w, e.to);
        },
        .position => |e| try w.print("~ {s} position {d},{d}", .{ e.name, e.x, e.y }),
        .scale => |e| try w.print("~ {s} scale {d:.2} → {d:.2}", .{ e.name, e.from, e.to }),
    }
}

fn printOptMode(w: *std.Io.Writer, m: ?state.Mode) !void {
    if (m) |mode| try w.print("{f}", .{mode}) else try w.writeAll("-");
}

fn onOff(b: bool) []const u8 {
    return if (b) "enabled" else "disabled";
}

test {
    _ = state;
    _ = store;
    _ = daemon;
}
