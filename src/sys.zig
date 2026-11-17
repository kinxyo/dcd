//! Thin wrappers over the Linux syscalls dcd needs for files, locks and
//! processes. Paths are null-terminated, as the kernel wants them.

const std = @import("std");
const linux = std.os.linux;

pub const Fd = i32;

pub const Error = error{ NotFound, WouldBlock, Unexpected };

fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .NOENT => error.NotFound,
        .AGAIN => error.WouldBlock,
        else => error.Unexpected,
    };
}

pub fn open(path: [:0]const u8, flags: linux.O, mode: linux.mode_t) Error!Fd {
    while (true) {
        const rc = linux.open(path.ptr, flags, mode);
        if (linux.errno(rc) == .INTR) continue;
        return @intCast(try check(rc));
    }
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn writeAll(fd: Fd, bytes: []const u8) Error!void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        if (linux.errno(rc) == .INTR) continue;
        rest = rest[try check(rc)..];
    }
}

/// The whole file, or null if it doesn't exist.
pub fn readFile(a: std.mem.Allocator, path: [:0]const u8, max: usize) !?[]u8 {
    const fd = open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    defer close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    var buf: [4096]u8 = undefined;
    while (list.items.len < max) {
        const rc = linux.read(fd, &buf, buf.len);
        if (linux.errno(rc) == .INTR) continue;
        const n = try check(rc);
        if (n == 0) break;
        try list.appendSlice(a, buf[0..n]);
    }
    return try list.toOwnedSlice(a);
}

/// Writes `bytes` to a temporary file beside `path`, syncs it, and renames it
/// over `path`, so a crash leaves either the old file or the new one.
pub fn writeFileAtomic(a: std.mem.Allocator, path: [:0]const u8, bytes: []const u8) !void {
    const tmp = try std.fmt.allocPrintSentinel(a, "{s}.tmp", .{path}, 0);
    defer a.free(tmp);
    const fd = try open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    {
        defer close(fd);
        try writeAll(fd, bytes);
        _ = try check(linux.fsync(fd));
    }
    _ = try check(linux.rename(tmp.ptr, path.ptr));
}

/// Creates `path` and its parents, like `mkdir -p`.
pub fn mkdirAll(a: std.mem.Allocator, path: []const u8) !void {
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        const part = try a.dupeSentinel(u8, path[0..i], 0);
        defer a.free(part);
        const rc = linux.mkdir(part.ptr, 0o755);
        switch (linux.errno(rc)) {
            .SUCCESS, .EXIST => {},
            else => return error.Unexpected,
        }
    }
}

/// Takes an exclusive lock without waiting. WouldBlock if another process
/// holds it. The kernel drops the lock when the fd closes or the process dies.
pub fn lockExclusive(fd: Fd) Error!void {
    _ = try check(linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB));
}

pub fn truncate(fd: Fd) Error!void {
    _ = try check(linux.ftruncate(fd, 0));
}

pub fn isTerminal(fd: Fd) bool {
    var t: linux.termios = undefined;
    return linux.errno(linux.ioctl(fd, linux.T.CGETS, @intFromPtr(&t))) == .SUCCESS;
}

/// Runs `argv[0]` (looked up in PATH) detached: dcd doesn't wait for it, and
/// it's never left as a zombie. Failure to start is silent; it's best effort.
pub fn spawnDetached(a: std.mem.Allocator, argv: []const []const u8, environ: *const std.process.Environ.Map) !void {
    // Everything is allocated before fork: the child only calls exec.
    const c_argv = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| c_argv[i] = (try a.dupeSentinel(u8, arg, 0)).ptr;

    var envp: std.ArrayList(?[*:0]const u8) = .empty;
    var it = environ.iterator();
    while (it.next()) |e| {
        try envp.append(a, (try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }, 0)).ptr);
    }
    try envp.append(a, null);

    var paths: std.ArrayList([:0]const u8) = .empty;
    var dirs = std.mem.tokenizeScalar(u8, environ.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin", ':');
    while (dirs.next()) |dir| {
        try paths.append(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, argv[0] }, 0));
    }

    // Fork twice: the middle process exits at once and is reaped here, so
    // the grandchild is adopted by init and reaped there.
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Unexpected;
    if (pid == 0) {
        const grandchild = linux.fork();
        if (grandchild == 0) {
            for (paths.items) |p| _ = linux.execve(p.ptr, c_argv.ptr, @ptrCast(envp.items.ptr));
            linux.exit(127);
        }
        linux.exit(0);
    }
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
}
