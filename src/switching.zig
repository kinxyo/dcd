//! One switch, end to end: read the screens fresh, plan, apply, verify,
//! retry once, and fall back to the laptop panel, then to every screen on.
//! Used by the `laptop` / `external` commands and by the daemon.

const std = @import("std");
const state = @import("state.zig");
const outputs = @import("outputs.zig");
const Outputs = outputs.Outputs;

/// How many times `cancelled` (the screens changed meanwhile) is retried.
const max_cancels = 3;
/// Verification re-reads the screens this often, this many times, because the
/// compositor may finish applying slightly after `succeeded`.
const verify_interval_ms = 250;
const verify_reads = 8;

pub const Result = enum {
    /// The screens already matched; nothing was applied.
    already,
    /// Applied and verified.
    switched,
    /// Not possible (e.g. no external connected); nothing changed.
    refused,
    fell_back_laptop,
    fell_back_all,
    /// Nothing could be applied.
    nothing,

    pub fn ok(r: Result) bool {
        return r == .already or r == .switched;
    }
};

pub const Options = struct {
    /// Skip the real apply of `target` and report it as failed, to exercise
    /// the fallback. Fallbacks themselves are applied for real.
    force_fail: bool = false,
};

/// Switches to `target`, falling back if it doesn't stick. Every step is
/// written to `log`, one line each.
pub fn switchTo(init: std.process.Init, log: *std.Io.Writer, target: state.Target, opts: Options) !Result {
    switch (try attempt(init, log, target, opts.force_fail)) {
        .already => return .already,
        .switched => return .switched,
        .refused => return .refused,
        .failed => {},
    }
    if (target != .laptop) {
        try log.writeAll("falling back to laptop\n");
        if ((try attempt(init, log, .laptop, false)).ok()) {
            try log.print("{t}: fell back to laptop\n", .{target});
            return .fell_back_laptop;
        }
    }
    try log.writeAll("falling back to every screen on\n");
    if ((try attempt(init, log, null, false)).ok()) {
        try log.print("{t}: fell back to every screen on\n", .{target});
        return .fell_back_all;
    }
    try log.print("{t}: could not apply any configuration\n", .{target});
    return .nothing;
}

const Outcome = enum {
    already,
    switched,
    refused,
    failed,

    fn ok(o: Outcome) bool {
        return o == .already or o == .switched;
    }
};

/// One switch, retried once if it fails. A null target means every screen on.
fn attempt(init: std.process.Init, log: *std.Io.Writer, target: ?state.Target, force_fail: bool) !Outcome {
    for (0..2) |i| {
        if (i > 0) try log.print("{s}: retrying\n", .{targetName(target)});
        const outcome = try tryOnce(init, log, target, force_fail);
        if (outcome != .failed) return outcome;
    }
    return .failed;
}

fn tryOnce(init: std.process.Init, log: *std.Io.Writer, target: ?state.Target, force_fail: bool) !Outcome {
    const name = targetName(target);
    var cancels: usize = 0;
    while (true) {
        // A fresh connection every time: a long-lived one can hold stale state.
        const o = Outputs.open(init, null, null) catch |err| {
            try log.print("{s}: cannot read the screens: {t}\n", .{ name, err });
            return .failed;
        };
        defer o.close();
        const heads = o.heads();

        var p: state.Plan = if (target) |t| switch (state.plan(heads, t)) {
            .plan => |p| p,
            .refused => |r| {
                try log.print("{s}: refused: {s}\n", .{ name, r.message() });
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
            try log.print("{s}: done (already in place)\n", .{name});
            return .already;
        }
        try printPlan(log, name, heads, &p);
        try log.flush();

        if (force_fail) {
            try log.print("{s}: failed (--force-fail, nothing applied)\n", .{name});
            return .failed;
        }

        const result = o.apply(&p) catch |err| {
            try log.print("{s}: failed: {t}\n", .{ name, err });
            return .failed;
        };
        switch (result) {
            .succeeded => {},
            .cancelled => {
                cancels += 1;
                try log.print("{s}: cancelled by the compositor (screens changed), re-reading\n", .{name});
                if (cancels >= max_cancels) return .failed;
                continue;
            },
            .failed => {
                try log.print("{s}: failed: the compositor rejected the configuration\n", .{name});
                return .failed;
            },
            .timeout => {
                try log.print("{s}: failed: no answer from the compositor in {d}s\n", .{ name, outputs.timeout_ms / 1000 });
                return .failed;
            },
        }

        if (try verifyFresh(init, &p)) {
            try log.print("{s}: done\n", .{name});
            return .switched;
        }
        try log.print("{s}: failed: the compositor said yes, but the screens don't match\n", .{name});
        return .failed;
    }
}

/// Re-reads the screens over new connections until they match `p`, or the
/// time runs out.
fn verifyFresh(init: std.process.Init, p: *const state.Plan) !bool {
    for (0..verify_reads) |i| {
        if (i > 0) outputs.sleepMs(verify_interval_ms);
        const o = Outputs.open(init, null, null) catch continue;
        defer o.close();
        if (state.verify(o.heads(), p)) return true;
    }
    return false;
}

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
