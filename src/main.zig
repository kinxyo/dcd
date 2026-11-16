//! dcd: display configuration daemon.
//!
//! Sprint 1 is `dcd watch`, which prints the screens as Hyprland reports
//! them over wlr-output-management and every change from then on. It never
//! changes anything.

const std = @import("std");
const linux = std.os.linux;
const Connection = @import("wayland-client").Connection;
const protocols = @import("wayland-protocols");
const wl = protocols.wl;
const zwlr = protocols.zwlr;
const state = @import("state.zig");

/// The newest version of wlr-output-management dcd knows how to speak.
const max_manager_version = 4;

const usage =
    \\usage: dcd <command>
    \\
    \\commands:
    \\  watch   print the screens and every change to them, live
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (args.len != 2 or !std.mem.eql(u8, args[1], "watch")) {
        try out.writeAll(usage);
        return 2;
    }
    return watch(init, out);
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
    out: *std.Io.Writer,
    start: u64,
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
        };
    }
    const next: Snapshot = .{ .arena = arena, .heads = heads, .serial = serial };

    const w = live.out;
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
