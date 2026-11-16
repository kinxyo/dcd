//! What dcd knows about the screens at one moment, and what changed between
//! two moments. Pure data: no Wayland, so it can be tested without a compositor.

const std = @import("std");

pub const Mode = struct {
    width: i32 = 0,
    height: i32 = 0,
    /// Refresh rate in mHz, as the protocol sends it (180000 = 180 Hz).
    refresh: i32 = 0,

    pub fn eql(a: Mode, b: Mode) bool {
        return a.width == b.width and a.height == b.height and a.refresh == b.refresh;
    }

    pub fn format(m: Mode, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const hz: u32 = @intCast(@max(m.refresh, 0));
        try w.print("{d}x{d}@{d}.{d:0>2}", .{ m.width, m.height, hz / 1000, hz % 1000 / 10 });
    }
};

/// One screen as Hyprland reported it at a `done` event.
pub const Head = struct {
    name: []const u8,
    make: []const u8 = "",
    model: []const u8 = "",
    serial: []const u8 = "",
    enabled: bool = false,
    /// Null while disabled: a disabled head has no current mode.
    mode: ?Mode = null,
    x: i32 = 0,
    y: i32 = 0,
    scale: f64 = 1.0,
    /// Every mode the monitor offers.
    modes: []const Mode = &.{},

    /// The laptop's own panel, recognised by connector type.
    pub fn isBuiltin(h: Head) bool {
        return isBuiltinName(h.name);
    }

    /// Identifies the physical monitor, whichever connector it's plugged into.
    /// Missing fields print as "Unknown", like kanshi and wlr-randr do.
    pub fn identity(h: Head, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s} {s} {s}", .{
            orUnknown(h.make), orUnknown(h.model), orUnknown(h.serial),
        }) catch buf[0..0];
    }
};

pub fn isBuiltinName(name: []const u8) bool {
    for ([_][]const u8{ "eDP-", "LVDS-", "DSI-" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

fn orUnknown(s: []const u8) []const u8 {
    return if (s.len == 0) "Unknown" else s;
}

pub const Change = union(enum) {
    connected: Head,
    removed: []const u8,
    enabled: struct { name: []const u8, from: bool, to: bool },
    mode: struct { name: []const u8, from: ?Mode, to: ?Mode },
    position: struct { name: []const u8, x: i32, y: i32 },
    scale: struct { name: []const u8, from: f64, to: f64 },
};

/// Everything that differs between two snapshots, heads matched by name.
/// The changes borrow strings from `old` and `new`.
pub fn diff(gpa: std.mem.Allocator, old: []const Head, new: []const Head) ![]Change {
    var out: std.ArrayList(Change) = .empty;
    errdefer out.deinit(gpa);

    for (old) |o| {
        if (find(new, o.name) == null) try out.append(gpa, .{ .removed = o.name });
    }
    for (new) |n| {
        const o = find(old, n.name) orelse {
            try out.append(gpa, .{ .connected = n });
            continue;
        };
        if (o.enabled != n.enabled)
            try out.append(gpa, .{ .enabled = .{ .name = n.name, .from = o.enabled, .to = n.enabled } });
        if (!optModeEql(o.mode, n.mode))
            try out.append(gpa, .{ .mode = .{ .name = n.name, .from = o.mode, .to = n.mode } });
        if (n.enabled and (o.x != n.x or o.y != n.y))
            try out.append(gpa, .{ .position = .{ .name = n.name, .x = n.x, .y = n.y } });
        if (n.enabled and o.scale != n.scale)
            try out.append(gpa, .{ .scale = .{ .name = n.name, .from = o.scale, .to = n.scale } });
    }
    return out.toOwnedSlice(gpa);
}

fn find(heads: []const Head, name: []const u8) ?Head {
    for (heads) |h| {
        if (std.mem.eql(u8, h.name, name)) return h;
    }
    return null;
}

fn optModeEql(a: ?Mode, b: ?Mode) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.eql(b.?);
}

// -- planning ------------------------------------------------------------------

pub const Target = enum { laptop, external };

/// One screen to turn on, and how. Every head not listed is turned off.
pub const Enable = struct {
    name: []const u8,
    mode: Mode,
    scale: f64 = 1.0,
};

pub const max_heads = 16;

pub const Plan = struct {
    buf: [max_heads]Enable = undefined,
    len: usize = 0,

    pub fn enables(p: *const Plan) []const Enable {
        return p.buf[0..p.len];
    }

    fn add(p: *Plan, e: Enable) void {
        if (p.len < max_heads) {
            p.buf[p.len] = e;
            p.len += 1;
        }
    }
};

pub const Refusal = enum {
    no_external,
    no_builtin,
    /// The monitor reports no modes, so there's nothing to set.
    no_modes,

    pub fn message(r: Refusal) []const u8 {
        return switch (r) {
            .no_external => "no external monitor connected",
            .no_builtin => "no built-in panel found",
            .no_modes => "the monitor reports no modes",
        };
    }
};

pub const PlanResult = union(enum) {
    plan: Plan,
    refused: Refusal,
};

/// Which screen to light for `target`, and with what mode. Exactly one screen
/// is enabled, so a plan can never leave zero screens on.
pub fn plan(heads: []const Head, target: Target) PlanResult {
    for (heads) |h| {
        const wanted = switch (target) {
            .laptop => h.isBuiltin(),
            .external => !h.isBuiltin(),
        };
        if (!wanted) continue;
        const mode = pickMode(h.modes) orelse return .{ .refused = .no_modes };
        var p: Plan = .{};
        p.add(.{ .name = h.name, .mode = mode });
        return .{ .plan = p };
    }
    return .{ .refused = switch (target) {
        .laptop => .no_builtin,
        .external => .no_external,
    } };
}

/// The last resort: every screen on.
pub fn planAll(heads: []const Head) Plan {
    var p: Plan = .{};
    for (heads) |h| {
        if (pickMode(h.modes)) |mode| p.add(.{ .name = h.name, .mode = mode });
    }
    return p;
}

/// The largest resolution, at the highest refresh rate it supports.
pub fn pickMode(modes: []const Mode) ?Mode {
    var best: ?Mode = null;
    for (modes) |m| {
        const b = best orelse {
            best = m;
            continue;
        };
        const area = @as(i64, m.width) * m.height;
        const best_area = @as(i64, b.width) * b.height;
        if (area > best_area or (area == best_area and m.refresh > b.refresh)) best = m;
    }
    return best;
}

/// Whether the screens are exactly as `p` asks: each listed head on in its
/// mode and scale, every other head off.
pub fn verify(heads: []const Head, p: *const Plan) bool {
    for (heads) |h| {
        const want: ?Enable = for (p.enables()) |e| {
            if (std.mem.eql(u8, e.name, h.name)) break e;
        } else null;
        if (want) |e| {
            if (!h.enabled) return false;
            const m = h.mode orelse return false;
            if (!m.eql(e.mode)) return false;
            if (@abs(h.scale - e.scale) > 0.01) return false;
        } else if (h.enabled) return false;
    }
    // Every planned head must still exist.
    for (p.enables()) |e| {
        if (find(heads, e.name) == null) return false;
    }
    return true;
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

const panel_modes = [_]Mode{
    .{ .width = 1920, .height = 1080, .refresh = 60000 },
    .{ .width = 1920, .height = 1080, .refresh = 144000 },
    .{ .width = 1280, .height = 720, .refresh = 165000 },
};
const hdmi_modes = [_]Mode{
    .{ .width = 1920, .height = 1080, .refresh = 179990 },
    .{ .width = 1920, .height = 1080, .refresh = 60000 },
    .{ .width = 2560, .height = 0, .refresh = 0 }, // nonsense mode, zero area
};

const panel: Head = .{
    .name = "eDP-1",
    .make = "BOE",
    .model = "0x0BC9",
    .enabled = true,
    .mode = .{ .width = 1920, .height = 1080, .refresh = 144000 },
    .scale = 1.25,
    .modes = &panel_modes,
};
const hdmi: Head = .{
    .name = "HDMI-A-1",
    .make = "Dell Inc.",
    .model = "G2724D",
    .serial = "ABC123",
    .enabled = true,
    .mode = .{ .width = 1920, .height = 1080, .refresh = 180000 },
    .modes = &hdmi_modes,
};

test "no change" {
    const changes = try diff(testing.allocator, &.{ panel, hdmi }, &.{ panel, hdmi });
    defer testing.allocator.free(changes);
    try testing.expectEqual(0, changes.len);
}

test "external connected" {
    const changes = try diff(testing.allocator, &.{panel}, &.{ panel, hdmi });
    defer testing.allocator.free(changes);
    try testing.expectEqual(1, changes.len);
    try testing.expectEqualStrings("HDMI-A-1", changes[0].connected.name);
}

test "external removed" {
    const changes = try diff(testing.allocator, &.{ panel, hdmi }, &.{panel});
    defer testing.allocator.free(changes);
    try testing.expectEqual(1, changes.len);
    try testing.expectEqualStrings("HDMI-A-1", changes[0].removed);
}

test "disabled reports enabled and mode change, not position or scale" {
    var off = hdmi;
    off.enabled = false;
    off.mode = null;
    off.x = 99;
    const changes = try diff(testing.allocator, &.{hdmi}, &.{off});
    defer testing.allocator.free(changes);
    try testing.expectEqual(2, changes.len);
    try testing.expect(changes[0].enabled.from and !changes[0].enabled.to);
    try testing.expect(changes[1].mode.to == null);
}

test "mode change" {
    var slower = hdmi;
    slower.mode.?.refresh = 60000;
    const changes = try diff(testing.allocator, &.{hdmi}, &.{slower});
    defer testing.allocator.free(changes);
    try testing.expectEqual(1, changes.len);
    try testing.expectEqual(60000, changes[0].mode.to.?.refresh);
}

test "builtin detection" {
    try testing.expect(isBuiltinName("eDP-1"));
    try testing.expect(isBuiltinName("LVDS-1"));
    try testing.expect(isBuiltinName("DSI-1"));
    try testing.expect(!isBuiltinName("HDMI-A-1"));
    try testing.expect(!isBuiltinName("DP-1"));
}

test "identity fills unknown fields" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("BOE 0x0BC9 Unknown", panel.identity(&buf));
    try testing.expectEqualStrings("Dell Inc. G2724D ABC123", hdmi.identity(&buf));
    const bare: Head = .{ .name = "DP-1" };
    try testing.expectEqualStrings("Unknown Unknown Unknown", bare.identity(&buf));
}

test "mode formats as WxH@Hz" {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{Mode{ .width = 1920, .height = 1080, .refresh = 59951 }});
    try testing.expectEqualStrings("1920x1080@59.95", s);
}

test "pickMode: largest resolution, then highest refresh" {
    try testing.expect(pickMode(&panel_modes).?.eql(.{ .width = 1920, .height = 1080, .refresh = 144000 }));
    try testing.expect(pickMode(&hdmi_modes).?.eql(.{ .width = 1920, .height = 1080, .refresh = 179990 }));
    try testing.expect(pickMode(&.{}) == null);
}

test "plan external enables only the external" {
    const r = plan(&.{ panel, hdmi }, .external);
    const e = r.plan.enables();
    try testing.expectEqual(1, e.len);
    try testing.expectEqualStrings("HDMI-A-1", e[0].name);
    try testing.expectEqual(179990, e[0].mode.refresh);
    try testing.expectEqual(1.0, e[0].scale);
}

test "plan laptop enables only the panel at 144" {
    const r = plan(&.{ hdmi, panel }, .laptop);
    const e = r.plan.enables();
    try testing.expectEqual(1, e.len);
    try testing.expectEqualStrings("eDP-1", e[0].name);
    try testing.expectEqual(144000, e[0].mode.refresh);
}

test "plan refuses when the target is missing" {
    try testing.expectEqual(Refusal.no_external, plan(&.{panel}, .external).refused);
    try testing.expectEqual(Refusal.no_builtin, plan(&.{hdmi}, .laptop).refused);
    try testing.expectEqual(Refusal.no_external, plan(&.{}, .external).refused);
}

test "plan refuses a monitor with no modes" {
    const bare: Head = .{ .name = "HDMI-A-1" };
    try testing.expectEqual(Refusal.no_modes, plan(&.{ panel, bare }, .external).refused);
}

test "planAll enables everything" {
    const p = planAll(&.{ panel, hdmi });
    try testing.expectEqual(2, p.enables().len);
}

test "verify: exact match" {
    var on = hdmi;
    on.mode = hdmi_modes[0];
    var off = panel;
    off.enabled = false;
    off.mode = null;
    const p = plan(&.{ off, on }, .external).plan;
    try testing.expect(verify(&.{ off, on }, &p));
}

test "verify: other head still on" {
    var on = hdmi;
    on.mode = hdmi_modes[0];
    const p = plan(&.{ panel, on }, .external).plan;
    try testing.expect(!verify(&.{ panel, on }, &p));
}

test "verify: right head, wrong mode or scale" {
    var off = panel;
    off.enabled = false;
    off.mode = null;
    const p = plan(&.{ off, hdmi }, .external).plan;
    var slow = hdmi;
    slow.mode = hdmi_modes[1];
    try testing.expect(!verify(&.{ off, slow }, &p));
    var scaled = hdmi;
    scaled.mode = hdmi_modes[0];
    scaled.scale = 1.25;
    try testing.expect(!verify(&.{ off, scaled }, &p));
}

test "verify: planned head unplugged" {
    var off = panel;
    off.enabled = false;
    off.mode = null;
    const p = plan(&.{ off, hdmi }, .external).plan;
    try testing.expect(!verify(&.{off}, &p));
}
