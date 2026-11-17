//! The Wayland side: a connection with wlr-output-management bound, the
//! compositor's heads and modes kept up to date, a snapshot at every `done`,
//! and applying a plan as one output configuration.

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
/// How long any wait on the compositor may take before dcd gives up on it.
pub const timeout_ms = 5000;

/// Hyprland's placeholder head, present while no real screen is on. Not a
/// monitor: never planned for, never part of a monitor set.
pub fn isPlaceholder(name: []const u8) bool {
    return std.mem.eql(u8, name, "FALLBACK");
}

// -- live state ----------------------------------------------------------------
//
// Objects the compositor creates (heads, modes) get a heap-allocated struct
// each, which is also the listener's context, so it must not move while the
// object is alive.

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    heads: []state.Head,
    serial: u32,
};

/// Called at every `done` with the previous snapshot (null the first time)
/// and the new one. Both are valid only during the call.
pub const OnDone = *const fn (ctx: ?*anyopaque, prev: ?*const Snapshot, next: *const Snapshot) anyerror!void;

pub const Live = struct {
    gpa: std.mem.Allocator,
    on_done: ?OnDone = null,
    on_done_ctx: ?*anyopaque = null,
    /// Set at the first `done`: `latest` is complete.
    ready: bool = false,
    manager: ?zwlr.OutputManagerV1 = null,
    version: u32 = 0,
    heads: std.ArrayList(*LiveHead) = .empty,
    latest: ?Snapshot = null,
    finished: bool = false,

    pub fn deinit(live: *Live) void {
        for (live.heads.items) |h| h.destroy();
        live.heads.deinit(live.gpa);
        if (live.latest) |*p| p.arena.deinit();
    }

    fn removeHead(live: *Live, head: *LiveHead) void {
        for (live.heads.items, 0..) |h, i| {
            if (h == head) {
                _ = live.heads.orderedRemove(i);
                return;
            }
        }
    }

    pub fn findHead(live: *const Live, name: []const u8) ?*LiveHead {
        for (live.heads.items) |h| {
            if (std.mem.eql(u8, h.name, name)) return h;
        }
        return null;
    }
};

pub const LiveHead = struct {
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

    pub fn preferred(h: *const LiveHead) ?state.Mode {
        for (h.modes.items) |m| {
            if (m.preferred) return m.mode;
        }
        return null;
    }
};

pub const LiveMode = struct {
    head: *LiveHead,
    obj: zwlr.OutputModeV1,
    mode: state.Mode = .{},
    preferred: bool = false,
};

pub fn onRegistry(live: *Live, conn: *Connection, registry: wl.Registry, event: wl.Registry.Event) !void {
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
        .done => |e| try takeSnapshot(live, e.serial),
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

/// Copies the live heads into a snapshot, leaving out the placeholder head.
fn takeSnapshot(live: *Live, serial: u32) !void {
    var arena: std.heap.ArenaAllocator = .init(live.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var heads: std.ArrayList(state.Head) = .empty;
    for (live.heads.items) |lh| {
        if (isPlaceholder(lh.name)) continue;
        const modes = try a.alloc(state.Mode, lh.modes.items.len);
        for (lh.modes.items, modes) |lm, *m| m.* = lm.mode;
        try heads.append(a, .{
            .name = try a.dupe(u8, lh.name),
            .make = try a.dupe(u8, lh.make),
            .model = try a.dupe(u8, lh.model),
            .serial = try a.dupe(u8, lh.serial),
            .enabled = lh.enabled,
            .mode = if (lh.enabled) if (lh.current) |m| m.mode else null else null,
            .x = lh.x,
            .y = lh.y,
            .scale = lh.scale,
            .modes = modes,
        });
    }
    const next: Snapshot = .{ .arena = arena, .heads = heads.items, .serial = serial };

    if (live.on_done) |f| {
        try f(live.on_done_ctx, if (live.latest) |*p| p else null, &next);
    }
    if (live.latest) |*p| p.arena.deinit();
    live.latest = next;
    live.ready = true;
}

// -- connection ----------------------------------------------------------------

/// A connection with the output manager bound and the first full snapshot
/// read. Heap-allocated: `live` is a listener context and must not move.
pub const Outputs = struct {
    gpa: std.mem.Allocator,
    conn: Connection,
    live: Live,

    pub const OpenError = error{ OutputManagementUnsupported, Timeout } || anyerror;

    /// Connects and reads the screens. `on_done`, if given, is called for
    /// the first snapshot and every later one.
    pub fn open(init: std.process.Init, on_done: ?OnDone, ctx: ?*anyopaque) OpenError!*Outputs {
        const gpa = init.gpa;
        const o = try gpa.create(Outputs);
        errdefer gpa.destroy(o);
        o.gpa = gpa;
        o.conn = try Connection.connect(gpa, init.io, init.environ_map);
        errdefer o.conn.deinit();
        o.live = .{ .gpa = gpa, .on_done = on_done, .on_done_ctx = ctx };
        errdefer o.live.deinit();

        const display: wl.Display = .{ .id = .display };
        const registry = try display.getRegistry(&o.conn.session);
        try o.conn.setListener(registry, &o.live, onRegistry);
        // Every global arrives in reply to get_registry, so after one
        // roundtrip the manager has been bound if the compositor has it.
        try o.conn.roundtrip();
        if (o.live.manager == null) return error.OutputManagementUnsupported;
        if (!try o.waitUntil(&o.live.ready)) return error.Timeout;
        return o;
    }

    pub fn close(o: *Outputs) void {
        const gpa = o.gpa;
        o.live.deinit();
        o.conn.deinit();
        gpa.destroy(o);
    }

    /// The screens at the latest `done`, without the placeholder head.
    pub fn heads(o: *const Outputs) []const state.Head {
        return o.live.latest.?.heads;
    }

    /// Reads and dispatches whatever the compositor has sent. For a caller
    /// that polls `conn.fd` itself.
    pub fn dispatchReadable(o: *Outputs) !void {
        try o.conn.read();
        _ = try o.conn.dispatchPending();
    }

    /// Dispatches events until `flag` is set, for at most `timeout_ms`.
    /// Returns whether it was set.
    pub fn waitUntil(o: *Outputs, flag: *const bool) !bool {
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
                try o.dispatchReadable();
            } else if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
                return error.ConnectionClosed;
            }
        }
        return true;
    }

    pub const ApplyResult = enum { succeeded, failed, cancelled, timeout };

    const ConfigWait = struct {
        result: ?ApplyResult = null,
        answered: bool = false,
    };

    /// Sends `p` as one configuration: listed heads on, side by side from
    /// x = 0, every other head off (the protocol requires every head to be
    /// listed, the placeholder included). Waits for the compositor's answer.
    pub fn apply(o: *Outputs, p: *const state.Plan) !ApplyResult {
        const session = &o.conn.session;
        const latest = o.live.latest orelse return error.NoSnapshot;
        const config = try o.live.manager.?.createConfiguration(session, latest.serial);

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
};

// -- time ----------------------------------------------------------------------

pub fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    while (linux.errno(linux.nanosleep(&ts, &ts)) == .INTR) {}
}
