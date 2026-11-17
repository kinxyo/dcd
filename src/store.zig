//! The desired mode for each set of connected monitors, kept in
//! `$XDG_STATE_HOME/dcd/modes`. Commands write it; the daemon follows it.
//!
//! One line per monitor set: the mode, a tab, then the key.
//!
//!     laptop<TAB>China Star ... 0x00005600|Samsung ... H8CY500487

const std = @import("std");
const state = @import("state.zig");
const sys = @import("sys.zig");

pub const Entry = struct {
    mode: state.Target,
    key: []const u8,
};

pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(s: *Store) void {
        s.arena.deinit();
    }

    /// Reads the file format. Lines that don't parse are skipped, so a
    /// damaged file loses those entries, not everything.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Store {
        var s: Store = .init(gpa);
        errdefer s.deinit();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const mode = std.meta.stringToEnum(state.Target, line[0..tab]) orelse continue;
            const key = line[tab + 1 ..];
            if (key.len == 0) continue;
            try s.set(key, mode);
        }
        return s;
    }

    pub fn get(s: *const Store, key: []const u8) ?state.Target {
        for (s.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.mode;
        }
        return null;
    }

    pub fn set(s: *Store, key: []const u8, mode: state.Target) !void {
        for (s.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.mode = mode;
                return;
            }
        }
        const a = s.arena.allocator();
        try s.entries.append(a, .{ .mode = mode, .key = try a.dupe(u8, key) });
    }

    pub fn write(s: *const Store, w: *std.Io.Writer) !void {
        for (s.entries.items) |e| try w.print("{t}\t{s}\n", .{ e.mode, e.key });
    }
};

/// Identifies a set of connected monitors: their identities, sorted, joined
/// with `|`. Tabs and newlines become spaces so the key fits on one line.
pub fn keyOf(a: std.mem.Allocator, heads: []const state.Head) ![]u8 {
    const ids = try a.alloc([]u8, heads.len);
    defer a.free(ids);
    var buf: [512]u8 = undefined;
    for (heads, ids) |h, *id| {
        id.* = try a.dupe(u8, h.identity(&buf));
        for (id.*) |*c| {
            if (c.* == '\t' or c.* == '\n' or c.* == '|') c.* = ' ';
        }
    }
    defer for (ids) |id| a.free(id);
    std.mem.sort([]u8, ids, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return std.mem.join(a, "|", ids);
}

/// What to use when nothing has been chosen for a monitor set: the external
/// if there is one, else the laptop panel.
pub fn defaultMode(heads: []const state.Head) state.Target {
    for (heads) |h| {
        if (!h.isBuiltin()) return .external;
    }
    return .laptop;
}

// -- file ----------------------------------------------------------------------

pub fn dir(a: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("XDG_STATE_HOME")) |d| {
        if (d.len > 0) return std.fmt.allocPrint(a, "{s}/dcd", .{d});
    }
    const home = environ.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(a, "{s}/.local/state/dcd", .{home});
}

fn path(a: std.mem.Allocator, environ: *const std.process.Environ.Map) ![:0]u8 {
    const d = try dir(a, environ);
    defer a.free(d);
    return std.fmt.allocPrintSentinel(a, "{s}/modes", .{d}, 0);
}

/// The saved choices; empty if the file doesn't exist yet.
pub fn load(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) !Store {
    const p = try path(gpa, environ);
    defer gpa.free(p);
    const text = try sys.readFile(gpa, p, 1 << 20) orelse return .init(gpa);
    defer gpa.free(text);
    return Store.parse(gpa, text);
}

pub fn save(s: *const Store, gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) !void {
    const d = try dir(gpa, environ);
    defer gpa.free(d);
    try sys.mkdirAll(gpa, d);
    const p = try path(gpa, environ);
    defer gpa.free(p);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try s.write(&aw.writer);
    try sys.writeFileAtomic(gpa, p, aw.written());
}

// -- tests ---------------------------------------------------------------------

const testing = std.testing;

const panel: state.Head = .{ .name = "eDP-1", .make = "China Star", .model = "0x150F", .serial = "0x00005600" };
const samsung: state.Head = .{ .name = "HDMI-A-1", .make = "Samsung", .model = "LS24DG30X", .serial = "H8CY500487" };

test "key is sorted, so port order doesn't matter" {
    const k1 = try keyOf(testing.allocator, &.{ panel, samsung });
    defer testing.allocator.free(k1);
    const k2 = try keyOf(testing.allocator, &.{ samsung, panel });
    defer testing.allocator.free(k2);
    try testing.expectEqualStrings("China Star 0x150F 0x00005600|Samsung LS24DG30X H8CY500487", k1);
    try testing.expectEqualStrings(k1, k2);
}

test "key follows the monitor, not the port" {
    var moved = samsung;
    moved.name = "DP-2";
    const k1 = try keyOf(testing.allocator, &.{ panel, samsung });
    defer testing.allocator.free(k1);
    const k2 = try keyOf(testing.allocator, &.{ panel, moved });
    defer testing.allocator.free(k2);
    try testing.expectEqualStrings(k1, k2);
}

test "key keeps the file format safe" {
    var odd = samsung;
    odd.model = "LS24\tDG|30X";
    const k = try keyOf(testing.allocator, &.{odd});
    defer testing.allocator.free(k);
    try testing.expectEqualStrings("Samsung LS24 DG 30X H8CY500487", k);
}

test "default mode" {
    try testing.expectEqual(state.Target.external, defaultMode(&.{ panel, samsung }));
    try testing.expectEqual(state.Target.laptop, defaultMode(&.{panel}));
    try testing.expectEqual(state.Target.laptop, defaultMode(&.{}));
}

test "round trip" {
    var s: Store = .init(testing.allocator);
    defer s.deinit();
    try s.set("A|B", .laptop);
    try s.set("A", .external);
    try s.set("A|B", .external); // overwrite, not a second line

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try s.write(&aw.writer);
    try testing.expectEqualStrings("external\tA|B\nexternal\tA\n", aw.written());

    var back = try Store.parse(testing.allocator, aw.written());
    defer back.deinit();
    try testing.expectEqual(state.Target.external, back.get("A|B").?);
    try testing.expectEqual(state.Target.external, back.get("A").?);
    try testing.expect(back.get("C") == null);
}

test "parse skips damaged lines" {
    var s = try Store.parse(testing.allocator, "laptop\tA\ngarbage\nmirror\tB\nexternal\t\n\nexternal\tC");
    defer s.deinit();
    try testing.expectEqual(2, s.entries.items.len);
    try testing.expectEqual(state.Target.laptop, s.get("A").?);
    try testing.expectEqual(state.Target.external, s.get("C").?);
}
