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

// -- tests -------------------------------------------------------------------

const testing = std.testing;

const panel: Head = .{
    .name = "eDP-1",
    .make = "BOE",
    .model = "0x0BC9",
    .enabled = true,
    .mode = .{ .width = 1920, .height = 1080, .refresh = 144000 },
    .scale = 1.25,
};
const hdmi: Head = .{
    .name = "HDMI-A-1",
    .make = "Dell Inc.",
    .model = "G2724D",
    .serial = "ABC123",
    .enabled = true,
    .mode = .{ .width = 1920, .height = 1080, .refresh = 180000 },
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
