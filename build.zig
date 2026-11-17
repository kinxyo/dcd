const std = @import("std");
const wayland = @import("wayland");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_dep = b.dependency("wayland", .{ .target = target, .optimize = optimize });
    const protocols = wayland.addProtocols(b, wayland_dep, .{
        .target = target,
        .optimize = optimize,
        .extra = &.{b.path("protocol/wlr-output-management-unstable-v1.xml")},
    });

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wayland-protocols", .module = protocols },
            .{ .name = "wayland-client", .module = wayland_dep.module("client") },
            .{ .name = "wayland-wire", .module = wayland_dep.module("protocol") },
        },
    });
    const exe = b.addExecutable(.{ .name = "dcd", .root_module = root });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run dcd").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
