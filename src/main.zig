//! dcd: display configuration daemon.
//!
//! `dcd watch` prints the screens as the compositor reports them over
//! wlr-output-management, and every change from then on.
//! `dcd laptop` and `dcd external` switch to one screen, check the result,
//! and fall back to the laptop panel if the switch doesn't stick.

const std = @import("std");
const linux = std.os.linux;
const Connection = @import("wayland-client").Connection;
const protocols = @import("wayland-protocols");
const wl = protocols.wl;
const zwlr = protocols.zwlr;
const Fixed = @import("wayland-wire").Fixed;
const state = @import("state.zig");

/// The newest version of wlr-output-management dcd knows how to speak.
const max_manager_version = 4;

const usage =
    \\usage: dcd <command>
    \\
    \\commands:
    \\  laptop    built-in panel on, external monitor off
    \\  external  external monitor on, built-in panel off
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

    if (std.mem.eql(u8, cmd, "watch") and !force_fail) return watch(init, out);
    if (std.mem.eql(u8, cmd, "laptop")) return switchCommand(init, out, .laptop, force_fail);
    if (std.mem.eql(u8, cmd, "external")) return switchCommand(init, out, .external, force_fail);
    try out.writeAll(usage);
    return 2;
}

fn watch(init: std.process.Init, out: *std.Io.Writer) !u8 {
    const gpa = init.gpa;

    var conn: Connection = Connection.connect(gpa, init.io, init.environ_map) catch |err| {
        try out.print("dcd: cannot connect to the compositor: {t}\n", .{err});
        return 1;
    };
    defer conn.deinit();

    var live: Live = .{ .gpa = gpa, .out = out, .start = now() };
    defer live.deinit();

    const display: wl.Display = .{ .id = .display };
    const registry = try display.getRegistry(&conn.session);
    try conn.setListener(registry, &live, onRegistry);
    // Every global arrives in reply to get_registry, so after one roundtrip
    // the manager has been bound if the compositor has it.
    try conn.roundtrip();

    if (live.manager == null) {
        try out.writeAll("dcd: compositor does not support wlr-output-management\n");
        return 1;
    }

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
        .{ .fd = conn.fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = sfd, .events = linux.POLL.IN, .revents = 0 },
    };

    while (!live.finished) {
        try conn.flush();
        try out.flush();

        const rc = linux.poll(&fds, fds.len, -1);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Poll,
        }

        if (fds[1].revents != 0) break; // SIGINT or SIGTERM
        if (fds[0].revents & linux.POLL.IN != 0) {
            conn.read() catch |err| switch (err) {
                error.ConnectionClosed => {
                    try out.writeAll("dcd: compositor closed the connection\n");
                    return 1;
                },
                else => return err,
            };
            _ = try conn.dispatchPending();
        } else if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
            try out.writeAll("dcd: compositor closed the connection\n");
            return 1;
        }
    }

    if (live.finished) {
        try out.writeAll("dcd: compositor stopped output management\n");
        return 1;
    }
    try live.manager.?.stop(&conn.session);
    conn.flush() catch {};
    return 0;
}

// -- live state ----------------------------------------------------------------
//
// Objects the compositor creates (heads, modes) get a heap-allocated struct
// each, which is also the listener's context, so it must not move while the
// object is alive.

const Live = struct {
    gpa: std.mem.Allocator,
    /// Where `watch` prints. Null for a silent snapshot.
    out: ?*std.Io.Writer,
    start: u64,
    /// Set at the first `done`: the snapshot in `prev` is complete.
    ready: bool = false,
    manager: ?zwlr.OutputManagerV1 = null,
    version: u32 = 0,
    heads: std.ArrayList(*LiveHead) = .empty,
    /// The snapshot from the previous `done`, to diff the next one against.
    prev: ?Snapshot = null,
    finished: bool = false,

    fn deinit(live: *Live) void {
        for (live.heads.items) |h| h.destroy();
        live.heads.deinit(live.gpa);
        if (live.prev) |*p| p.arena.deinit();
    }

    fn removeHead(live: *Live, head: *LiveHead) void {
        for (live.heads.items, 0..) |h, i| {
            if (h == head) {
                _ = live.heads.orderedRemove(i);
                return;
            }
        }
    }
};

const LiveHead = struct {
    live: *Live,
    obj: zwlr.OutputHeadV1,
    name: []u8 = &.{},
    make: []u8 = &.{},
    model: []u8 = &.{},
    serial: []u8 = &.{},
    enabled: bool = false,
    current: ?*LiveMode = null,
    x: i32 = 0,
    y: i32 = 0,
    scale: f64 = 1.0,
    modes: std.ArrayList(*LiveMode) = .empty,

    fn destroy(h: *LiveHead) void {
        const gpa = h.live.gpa;
        for (h.modes.items) |m| gpa.destroy(m);
        h.modes.deinit(gpa);
        for ([_][]u8{ h.name, h.make, h.model, h.serial }) |s| gpa.free(s);
        gpa.destroy(h);
    }

    fn setString(h: *LiveHead, field: *[]u8, value: []const u8) !void {
        // EDID strings are often padded with spaces.
        const copy = try h.live.gpa.dupe(u8, std.mem.trim(u8, value, " \t\r\n"));
        h.live.gpa.free(field.*);
        field.* = copy;
    }

    fn findMode(h: *const LiveHead, mode: state.Mode) ?*LiveMode {
        for (h.modes.items) |m| {
            if (m.mode.eql(mode)) return m;
        }
        return null;
    }

    fn preferred(h: *const LiveHead) ?state.Mode {
        for (h.modes.items) |m| {
            if (m.preferred) return m.mode;
        }
        return null;
    }
};

const LiveMode = struct {
    head: *LiveHead,
    obj: zwlr.OutputModeV1,
    mode: state.Mode = .{},
    preferred: bool = false,
};

const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    heads: []state.Head,
    serial: u32,
};

fn onRegistry(live: *Live, conn: *Connection, registry: wl.Registry, event: wl.Registry.Event) !void {
    switch (event) {
        .global => |g| {
            if (live.manager != null) return;
            if (!std.mem.eql(u8, g.interface, zwlr.OutputManagerV1.interface.name)) return;
            live.version = @min(g.version, max_manager_version);
            const manager = try registry.bind(&conn.session, g.name, zwlr.OutputManagerV1, live.version);
            try conn.setListener(manager, live, onManager);
            live.manager = manager;
        },
        .global_remove => {},
    }
}

fn onManager(live: *Live, conn: *Connection, _: zwlr.OutputManagerV1, event: zwlr.OutputManagerV1.Event) !void {
    switch (event) {
        .head => |e| {
            const h = try live.gpa.create(LiveHead);
            h.* = .{ .live = live, .obj = e.head };
            errdefer live.gpa.destroy(h);
            try conn.setListener(e.head, h, onHead);
            try live.heads.append(live.gpa, h);
        },
        .done => |e| try snapshotAndPrint(live, e.serial),
        .finished => live.finished = true,
    }
}

fn onHead(h: *LiveHead, conn: *Connection, _: zwlr.OutputHeadV1, event: zwlr.OutputHeadV1.Event) !void {
    switch (event) {
        .name => |e| try h.setString(&h.name, e.name),
        .make => |e| try h.setString(&h.make, e.make),
        .model => |e| try h.setString(&h.model, e.model),
        .serial_number => |e| try h.setString(&h.serial, e.serial_number),
        .enabled => |e| {
            h.enabled = e.enabled != 0;
            if (!h.enabled) h.current = null;
        },
        .mode => |e| {
            const m = try h.live.gpa.create(LiveMode);
            m.* = .{ .head = h, .obj = e.mode };
            errdefer h.live.gpa.destroy(m);
            try conn.setListener(e.mode, m, onMode);
            try h.modes.append(h.live.gpa, m);
        },
        .current_mode => |e| {
            h.current = null;
            for (h.modes.items) |m| {
                if (m.obj.id == e.mode.id) h.current = m;
            }
        },
        .position => |e| {
            h.x = e.x;
            h.y = e.y;
        },
        .scale => |e| h.scale = e.scale.toDouble(),
        .finished => {
            // The monitor is gone. Its modes are dropped with it, and their
            // listeners cleared so nothing points at freed memory.
            for (h.modes.items) |m| {
                conn.clearListener(m.obj) catch {};
            }
            conn.clearListener(h.obj) catch {};
            if (h.live.version >= 3) try h.obj.release(&conn.session);
            h.live.removeHead(h);
            h.destroy();
        },
        .description, .physical_size, .transform, .adaptive_sync => {},
    }
}

fn onMode(m: *LiveMode, conn: *Connection, _: zwlr.OutputModeV1, event: zwlr.OutputModeV1.Event) !void {
    switch (event) {
        .size => |e| {
            m.mode.width = e.width;
            m.mode.height = e.height;
        },
        .refresh => |e| m.mode.refresh = e.refresh,
        .preferred => m.preferred = true,
        .finished => {
            const h = m.head;
            if (h.current == m) h.current = null;
            for (h.modes.items, 0..) |item, i| {
                if (item == m) {
                    _ = h.modes.orderedRemove(i);
                    break;
                }
            }
            conn.clearListener(m.obj) catch {};
            if (h.live.version >= 3) try m.obj.release(&conn.session);
            h.live.gpa.destroy(m);
        },
    }
}

// -- switching -----------------------------------------------------------------

/// How long any wait on the compositor may take before dcd gives up on it.
const timeout_ms = 5000;
/// How many times `cancelled` (the screens changed meanwhile) is retried.
const max_cancels = 3;
/// Verification re-reads the screens this often, this many times, because the
/// compositor may finish applying slightly after `succeeded`.
const verify_interval_ms = 250;
const verify_reads = 8;

const Outcome = enum { done, refused, failed };

/// Exit codes: 0 done, 1 fell back, 2 refused, 3 nothing could be applied.
fn switchCommand(init: std.process.Init, out: *std.Io.Writer, target: state.Target, force_fail: bool) !u8 {
    switch (try attempt(init, out, target, force_fail)) {
        .done => return 0,
        .refused => return 2,
        .failed => {},
    }
    if (target != .laptop) {
        try out.writeAll("falling back to laptop\n");
        if (try attempt(init, out, .laptop, false) == .done) {
            try out.print("{t}: fell back to laptop\n", .{target});
            return 1;
        }
    }
    try out.writeAll("falling back to every screen on\n");
    if (try attempt(init, out, null, false) == .done) {
        try out.print("{t}: fell back to every screen on\n", .{target});
        return 1;
    }
    try out.print("{t}: could not apply any configuration\n", .{target});
    return 3;
}

/// One switch, retried once if it fails. A null target means every screen on.
fn attempt(init: std.process.Init, out: *std.Io.Writer, target: ?state.Target, force_fail: bool) !Outcome {
    for (0..2) |i| {
        if (i > 0) try out.print("{s}: retrying\n", .{targetName(target)});
        const outcome = try tryOnce(init, out, target, force_fail);
        if (outcome != .failed) return outcome;
    }
    return .failed;
}

fn tryOnce(init: std.process.Init, out: *std.Io.Writer, target: ?state.Target, force_fail: bool) !Outcome {
    const name = targetName(target);
    var cancels: usize = 0;
    while (true) {
        // A fresh connection every time: a long-lived one can hold stale state.
        const o = Outputs.open(init) catch |err| {
            try out.print("{s}: cannot read the screens: {t}\n", .{ name, err });
            return .failed;
        };
        defer o.close();
        const heads = o.heads();

        var p: state.Plan = if (target) |t| switch (state.plan(heads, t)) {
            .plan => |p| p,
            .refused => |r| {
                try out.print("{s}: refused: {s}\n", .{ name, r.message() });
                return .refused;
            },
        } else state.planAll(heads);
        // The plan's names point into this connection's snapshot, which is
        // replaced (and freed) when the compositor reports the change. Keep
        // copies for verification.
        var names: std.heap.ArenaAllocator = .init(init.gpa);
        defer names.deinit();
        for (p.buf[0..p.len]) |*e| e.name = try names.allocator().dupe(u8, e.name);

        if (state.verify(heads, &p)) {
            try out.print("{s}: done (already in place)\n", .{name});
            return .done;
        }
        try printPlan(out, name, heads, &p);
        try out.flush();

        if (force_fail) {
            try out.print("{s}: failed (--force-fail, nothing applied)\n", .{name});
            return .failed;
        }

        const result = applyPlan(o, &p) catch |err| {
            try out.print("{s}: failed: {t}\n", .{ name, err });
            return .failed;
        };
        switch (result) {
            .succeeded => {},
            .cancelled => {
                cancels += 1;
                try out.print("{s}: cancelled by the compositor (screens changed), re-reading\n", .{name});
                if (cancels >= max_cancels) return .failed;
                continue;
            },
            .failed => {
                try out.print("{s}: failed: the compositor rejected the configuration\n", .{name});
                return .failed;
            },
            .timeout => {
                try out.print("{s}: failed: no answer from the compositor in {d}s\n", .{ name, timeout_ms / 1000 });
                return .failed;
            },
        }

        if (try verifyFresh(init, &p)) {
            try out.print("{s}: done\n", .{name});
            return .done;
        }
        try out.print("{s}: failed: the compositor said yes, but the screens don't match\n", .{name});
        return .failed;
    }
}

/// Re-reads the screens over new connections until they match `p`, or the
/// time runs out.
fn verifyFresh(init: std.process.Init, p: *const state.Plan) !bool {
    for (0..verify_reads) |i| {
        if (i > 0) sleepMs(verify_interval_ms);
        const o = Outputs.open(init) catch continue;
        defer o.close();
        if (state.verify(o.heads(), p)) return true;
    }
    return false;
}

const ApplyResult = enum { succeeded, failed, cancelled, timeout };

const ConfigWait = struct {
    result: ?ApplyResult = null,
    answered: bool = false,
};

/// Sends `p` as one configuration: listed heads on, at x side by side from
/// 0, every other head off. Waits for the compositor's answer.
fn applyPlan(o: *Outputs, p: *const state.Plan) !ApplyResult {
    const session = &o.conn.session;
    const prev = o.live.prev orelse return error.NoSnapshot;
    const config = try o.live.manager.?.createConfiguration(session, prev.serial);

    var wait: ConfigWait = .{};
    try o.conn.setListener(config, &wait, onConfig);

    var x: i32 = 0;
    for (o.live.heads.items) |lh| {
        const e: ?state.Enable = for (p.enables()) |e| {
            if (std.mem.eql(u8, e.name, lh.name)) break e;
        } else null;
        if (e) |enable| {
            const mode = lh.findMode(enable.mode) orelse return error.ModeGone;
            const ch = try config.enableHead(session, lh.obj);
            try ch.setMode(session, mode.obj);
            try ch.setPosition(session, x, 0);
            try ch.setScale(session, Fixed.fromDouble(enable.scale));
            x += enable.mode.width;
        } else {
            try config.disableHead(session, lh.obj);
        }
    }
    try config.apply(session);

    const answered = try o.waitUntil(&wait.answered);
    try config.destroy(session);
    try o.conn.flush();
    if (!answered) return .timeout;
    return wait.result.?;
}

fn onConfig(wait: *ConfigWait, _: *Connection, _: zwlr.OutputConfigurationV1, event: zwlr.OutputConfigurationV1.Event) void {
    wait.result = switch (event) {
        .succeeded => .succeeded,
        .failed => .failed,
        .cancelled => .cancelled,
    };
    wait.answered = true;
}

/// A connection with the output manager bound and the first full snapshot
/// read. Heap-allocated: `live` is a listener context and must not move.
const Outputs = struct {
    gpa: std.mem.Allocator,
    conn: Connection,
    live: Live,

    fn open(init: std.process.Init) !*Outputs {
        const gpa = init.gpa;
        const o = try gpa.create(Outputs);
        errdefer gpa.destroy(o);
        o.gpa = gpa;
        o.conn = try Connection.connect(gpa, init.io, init.environ_map);
        errdefer o.conn.deinit();
        o.live = .{ .gpa = gpa, .out = null, .start = now() };
        errdefer o.live.deinit();

        const display: wl.Display = .{ .id = .display };
        const registry = try display.getRegistry(&o.conn.session);
        try o.conn.setListener(registry, &o.live, onRegistry);
        try o.conn.roundtrip();
        if (o.live.manager == null) return error.OutputManagementUnsupported;
        if (!try o.waitUntil(&o.live.ready)) return error.Timeout;
        return o;
    }

    fn close(o: *Outputs) void {
        const gpa = o.gpa;
        o.live.deinit();
        o.conn.deinit();
        gpa.destroy(o);
    }

    fn heads(o: *const Outputs) []const state.Head {
        return o.live.prev.?.heads;
    }

    /// Dispatches events until `flag` is set, for at most `timeout_ms`.
    /// Returns whether it was set.
    fn waitUntil(o: *Outputs, flag: *const bool) !bool {
        const deadline = now() + timeout_ms * std.time.ns_per_ms;
        while (!flag.*) {
            if (o.live.finished) return error.OutputManagerFinished;
            try o.conn.flush();
            if (try o.conn.dispatchPending() > 0) continue;

            const t = now();
            if (t >= deadline) return false;
            const wait_ms: i32 = @intCast((deadline - t) / std.time.ns_per_ms + 1);
            var fds = [_]linux.pollfd{.{ .fd = o.conn.fd, .events = linux.POLL.IN, .revents = 0 }};
            const rc = linux.poll(&fds, fds.len, wait_ms);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.Poll,
            }
            if (fds[0].revents & linux.POLL.IN != 0) {
                try o.conn.read();
                _ = try o.conn.dispatchPending();
            } else if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
                return error.ConnectionClosed;
            }
        }
        return true;
    }
};

fn targetName(target: ?state.Target) []const u8 {
    return if (target) |t| @tagName(t) else "all";
}

fn printPlan(w: *std.Io.Writer, name: []const u8, heads: []const state.Head, p: *const state.Plan) !void {
    try w.print("{s}: applying", .{name});
    for (p.enables(), 0..) |e, i| {
        try w.print("{s} {s} on {f} scale {d:.2}", .{ if (i == 0) "" else ",", e.name, e.mode, e.scale });
    }
    for (heads) |h| {
        const listed = for (p.enables()) |e| {
            if (std.mem.eql(u8, e.name, h.name)) break true;
        } else false;
        if (!listed) try w.print(", {s} off", .{h.name});
    }
    try w.writeByte('\n');
}

fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    while (linux.errno(linux.nanosleep(&ts, &ts)) == .INTR) {}
}

// -- printing ------------------------------------------------------------------

fn snapshotAndPrint(live: *Live, serial: u32) !void {
    var arena: std.heap.ArenaAllocator = .init(live.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const heads = try a.alloc(state.Head, live.heads.items.len);
    for (live.heads.items, heads) |lh, *h| {
        h.* = .{
            .name = try a.dupe(u8, lh.name),
            .make = try a.dupe(u8, lh.make),
            .model = try a.dupe(u8, lh.model),
            .serial = try a.dupe(u8, lh.serial),
            .enabled = lh.enabled,
            .mode = if (lh.enabled) if (lh.current) |m| m.mode else null else null,
            .x = lh.x,
            .y = lh.y,
            .scale = lh.scale,
            .modes = modes: {
                const ms = try a.alloc(state.Mode, lh.modes.items.len);
                for (lh.modes.items, ms) |lm, *m| m.* = lm.mode;
                break :modes ms;
            },
        };
    }
    const next: Snapshot = .{ .arena = arena, .heads = heads, .serial = serial };

    const w = live.out orelse {
        if (live.prev) |*prev| prev.arena.deinit();
        live.prev = next;
        live.ready = true;
        return;
    };
    try w.print("[{d:>8}ms] serial {d}", .{ elapsedMs(live), serial });

    if (live.prev) |*prev| {
        const changes = try state.diff(live.gpa, prev.heads, next.heads);
        defer live.gpa.free(changes);
        if (changes.len == 0) try w.writeAll("  (no change)");
        for (changes, 0..) |c, i| {
            try w.writeAll(if (i == 0) "  " else "\n                       ");
            try printChange(w, c);
        }
        try w.writeByte('\n');
        prev.arena.deinit();
    } else {
        try w.writeByte('\n');
        for (next.heads, live.heads.items) |h, lh| try printHead(w, h, lh.preferred());
    }
    live.prev = next;
    live.ready = true;
}

fn printHead(w: *std.Io.Writer, h: state.Head, preferred: ?state.Mode) !void {
    var id_buf: [512]u8 = undefined;
    try w.print("  {s:<10} {s:<8} {s:<8} ", .{
        h.name,
        if (h.isBuiltin()) "builtin" else "external",
        if (h.enabled) "enabled" else "disabled",
    });
    if (h.mode) |m| try w.print("{f} scale {d:.2}", .{ m, h.scale }) else try w.writeAll("-");
    if (preferred) |p| try w.print("  preferred {f}", .{p});
    try w.print("  \"{s}\"\n", .{h.identity(&id_buf)});
}

fn printChange(w: *std.Io.Writer, c: state.Change) !void {
    switch (c) {
        .connected => |h| try w.print("+ {s} connected ({s})", .{ h.name, if (h.enabled) "enabled" else "disabled" }),
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

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedMs(live: *const Live) u64 {
    return (now() - live.start) / std.time.ns_per_ms;
}
