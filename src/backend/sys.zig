//! sirocco.backend.sys — the non-blocking POSIX socket calls of the evented backends (ADR 0003).
//!
//! Purpose: the one file besides the pollers that talks to the kernel about sockets. Every
//! descriptor it creates is `O_NONBLOCK | O_CLOEXEC`, every call returns a typed `Error`, and
//! `error.WouldBlock` (and `error.InProgress` for `connect`) means "arm the poller and retry",
//! never a failure. `src/net.zig` maps `Error` onto each slot's own error set.
//!
//! Invariants: no call here blocks except `poll_block`, which the caller uses only off a fiber.
//! No allocation, no clock. `accept` and `connect` never retry on `EINTR` themselves (the caller's
//! loop owns the bound and reports `error.Interrupted`); `socket`, `socketpair`, `bind` and
//! `listen` retry up to `attempts_max` times, then report it. Where the kernel has
//! `accept4`/`SOCK_NONBLOCK` we still set the flags with
//! `fcntl` after the call, so Darwin and Linux share one path; the window between create and
//! `fcntl` is harmless because the descriptor is not yet visible to any other thread.

const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("../stdx.zig");

const posix = std.posix;
const system = posix.system;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

pub const fd_t = posix.fd_t;

pub const Error = error{
    WouldBlock,
    InProgress,
    /// `EINTR` after `attempts_max` retries (or from `accept`/`connect`, which the caller owns).
    Interrupted,
    AddressInUse,
    AddressUnavailable,
    AddressFamilyUnsupported,
    ProtocolUnsupported,
    ConnectionRefused,
    ConnectionReset,
    ConnectionAborted,
    HostUnreachable,
    NetworkUnreachable,
    NetworkDown,
    Timeout,
    AccessDenied,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SocketNotListening,
    FileNotFound,
    SymLinkLoop,
    NotDir,
    ReadOnlyFileSystem,
    NameTooLong,
    Unexpected,
};

/// A socket address in kernel layout plus its length.
pub const Addr = struct {
    storage: posix.sockaddr.storage,
    len: posix.socklen_t,
};

pub const Interest = enum { read, write };

const attempts_max: u32 = 8;

/// Calls `function(args...)` again while it fails with `EINTR`, at most `attempts_max` times in
/// all; the last result is returned either way.
fn retried(comptime function: anytype, args: anytype) @TypeOf(@call(.auto, function, args)) {
    var rc = @call(.auto, function, args);
    for (1..attempts_max) |_| {
        if (posix.errno(rc) != .INTR) break;
        rc = @call(.auto, function, args);
    }
    return rc;
}

/// A new socket, `O_NONBLOCK | O_CLOEXEC`. `domain` and `kind` are `AF` and `SOCK` values.
pub fn socket_open(domain: u32, kind: u32, protocol: u32) Error!fd_t {
    assert(kind <= std.math.maxInt(u16));
    assert(domain != 0);
    const rc = retried(system.socket, .{ domain, kind, protocol });
    if (posix.errno(rc) != .SUCCESS) return fail(posix.errno(rc));
    const fd: fd_t = @intCast(rc);
    errdefer close(fd);

    try flags_set(fd);
    assert(fd >= 0);
    return fd;
}

pub fn socket_pair(domain: u32, kind: u32, protocol: u32) Error![2]fd_t {
    assert(kind <= std.math.maxInt(u16));
    assert(domain != 0);
    var fds: [2]fd_t = .{ -1, -1 };
    const rc = retried(system.socketpair, .{ domain, kind, protocol, &fds });
    if (posix.errno(rc) != .SUCCESS) return fail(posix.errno(rc));
    errdefer close(fds[0]);
    errdefer close(fds[1]);

    try flags_set(fds[0]);
    try flags_set(fds[1]);
    assert(fds[0] >= 0 and fds[1] >= 0);
    return fds;
}

/// `O_NONBLOCK | O_CLOEXEC` on `fd`.
fn flags_set(fd: fd_t) Error!void {
    assert(fd >= 0);
    const fd_flags = system.fcntl(fd, posix.F.GETFD, @as(usize, 0));
    if (posix.errno(fd_flags) != .SUCCESS) return fail(posix.errno(fd_flags));
    const cloexec = system.fcntl(fd, posix.F.SETFD, @as(usize, @intCast(fd_flags)) |
        posix.FD_CLOEXEC);
    if (posix.errno(cloexec) != .SUCCESS) return fail(posix.errno(cloexec));
    try blocking_set(fd, false);
}

/// Switches `fd` between blocking and non-blocking. The flag belongs to the open file
/// description, so only a descriptor nobody else holds may be switched.
pub fn blocking_set(fd: fd_t, blocking: bool) Error!void {
    assert(fd >= 0);
    const status = system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(status) != .SUCCESS) return fail(posix.errno(status));
    var flags: posix.O = @bitCast(@as(u32, @intCast(status)));
    flags.NONBLOCK = !blocking;
    const rc = system.fcntl(fd, posix.F.SETFL, @as(usize, @as(u32, @bitCast(flags))));
    if (posix.errno(rc) != .SUCCESS) return fail(posix.errno(rc));
}

pub fn is_nonblocking(fd: fd_t) bool {
    assert(fd >= 0);
    const status = system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    assert_always(posix.errno(status) == .SUCCESS);
    const flags: posix.O = @bitCast(@as(u32, @intCast(status)));
    return flags.NONBLOCK;
}

/// `SO_REUSEADDR`, and `SO_REUSEPORT` where the target has it: what `Io.Threaded` sets for
/// `ListenOptions.reuse_address`.
pub fn reuse_address_set(fd: fd_t) Error!void {
    assert(fd >= 0);
    try option_on(fd, posix.SO.REUSEADDR);
    if (@hasDecl(posix.SO, "REUSEPORT")) try option_on(fd, posix.SO.REUSEPORT);
}

fn option_on(fd: fd_t, name: u32) Error!void {
    assert(fd >= 0);
    const one: c_int = 1;
    const bytes = std.mem.asBytes(&one);
    const rc = system.setsockopt(fd, posix.SOL.SOCKET, name, bytes, @sizeOf(c_int));
    if (posix.errno(rc) != .SUCCESS) return fail(posix.errno(rc));
}

pub fn bind(fd: fd_t, addr: *const Addr) Error!void {
    assert(fd >= 0);
    assert(addr.len > 0);
    const ptr: *const posix.sockaddr = @ptrCast(&addr.storage);
    const rc = retried(system.bind, .{ fd, ptr, addr.len });
    if (posix.errno(rc) != .SUCCESS) return fail(posix.errno(rc));
}

pub fn listen(fd: fd_t, backlog: u31) Error!void {
    assert(fd >= 0);
    const rc = retried(system.listen, .{ fd, backlog });
    if (posix.errno(rc) != .SUCCESS) return fail(posix.errno(rc));
}

/// Takes one pending connection; the new descriptor is `O_NONBLOCK | O_CLOEXEC`. Returns the
/// peer address in `peer`. `error.WouldBlock` when none is queued.
pub fn accept(fd: fd_t, peer: *Addr) Error!fd_t {
    assert(fd >= 0);
    peer.len = @sizeOf(posix.sockaddr.storage);
    const ptr: *posix.sockaddr = @ptrCast(&peer.storage);
    const rc = system.accept(fd, ptr, &peer.len);
    if (posix.errno(rc) != .SUCCESS) return fail(posix.errno(rc));
    const accepted: fd_t = @intCast(rc);
    errdefer close(accepted);

    try flags_set(accepted);
    assert(peer.len <= @sizeOf(posix.sockaddr.storage));
    return accepted;
}

/// Starts a connection. `error.InProgress` means the handshake runs on: arm write interest and
/// call `socket_error` when it fires.
pub fn connect(fd: fd_t, addr: *const Addr) Error!void {
    assert(fd >= 0);
    assert(addr.len > 0);
    const ptr: *const posix.sockaddr = @ptrCast(&addr.storage);
    const rc = system.connect(fd, ptr, addr.len);
    if (posix.errno(rc) != .SUCCESS) return fail(posix.errno(rc));
}

/// The pending error of `fd` (`SO_ERROR`), cleared by the read; `{}` when there is none.
pub fn socket_error(fd: fd_t) Error!void {
    assert(fd >= 0);
    var value: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    const bytes = std.mem.asBytes(&value);
    const rc = system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, bytes, &len);
    if (posix.errno(rc) != .SUCCESS) return fail(posix.errno(rc));
    assert(len == @sizeOf(c_int));
    if (value == 0) return;
    const code: u16 = @intCast(value);
    return fail(@enumFromInt(code));
}

pub fn socket_name(fd: fd_t, out: *Addr) Error!void {
    assert(fd >= 0);
    out.len = @sizeOf(posix.sockaddr.storage);
    const ptr: *posix.sockaddr = @ptrCast(&out.storage);
    const rc = system.getsockname(fd, ptr, &out.len);
    if (posix.errno(rc) != .SUCCESS) return fail(posix.errno(rc));
    assert(out.len <= @sizeOf(posix.sockaddr.storage));
}

pub fn close(fd: fd_t) void {
    assert(fd >= 0);
    const rc = system.close(fd);
    // EINTR leaves the descriptor closed on every kernel we target; EBADF is a caller bug.
    assert_always(posix.errno(rc) != .BADF);
}

/// Blocks the calling thread until `fd` is ready for `interest`, a hangup, or a signal. The
/// caller retries its syscall either way. Off a fiber only: it would freeze a carrier.
pub fn poll_block(fd: fd_t, interest: Interest) void {
    assert(fd >= 0);
    const events: i16 = switch (interest) {
        .read => posix.POLL.IN,
        .write => posix.POLL.OUT,
    };
    var entry: posix.pollfd = .{ .fd = fd, .events = events, .revents = 0 };
    for (0..attempts_max) |_| {
        const rc = system.poll(@ptrCast(&entry), 1, -1);
        if (posix.errno(rc) != .INTR) return;
    }
}

/// An IPv4/IPv6 address in kernel layout.
pub fn addr_from_ip(ip: std.Io.net.IpAddress) Addr {
    var addr: Addr = .{ .storage = std.mem.zeroes(posix.sockaddr.storage), .len = 0 };
    switch (ip) {
        .ip4 => |ip4| {
            const in: *posix.sockaddr.in = @ptrCast(&addr.storage);
            in.* = .{ .port = std.mem.nativeToBig(u16, ip4.port), .addr = @bitCast(ip4.bytes) };
            addr.len = @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |ip6| {
            const in6: *posix.sockaddr.in6 = @ptrCast(&addr.storage);
            in6.* = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = std.mem.nativeToBig(u32, ip6.flow),
                .addr = ip6.bytes,
                .scope_id = 0,
            };
            addr.len = @sizeOf(posix.sockaddr.in6);
        },
    }
    assert(addr.len > 0);
    return addr;
}

/// The IP address in `addr`; null for any other family (a Unix peer, for one), which the caller
/// reports the way `Io.Threaded` does: the unspecified loopback address.
pub fn addr_to_ip(addr: *const Addr) ?std.Io.net.IpAddress {
    const family: *const posix.sockaddr = @ptrCast(&addr.storage);
    switch (family.family) {
        posix.AF.INET => {
            const in: *const posix.sockaddr.in = @ptrCast(&addr.storage);
            const port = std.mem.bigToNative(u16, in.port);
            return .{ .ip4 = .{ .bytes = @bitCast(in.addr), .port = port } };
        },
        posix.AF.INET6 => {
            const in6: *const posix.sockaddr.in6 = @ptrCast(&addr.storage);
            const port = std.mem.bigToNative(u16, in6.port);
            return .{ .ip6 = .{
                .port = port,
                .bytes = in6.addr,
                .flow = std.mem.bigToNative(u32, in6.flowinfo),
            } };
        },
        else => return null,
    }
}

/// A filesystem Unix address; null for a path that is empty, abstract or too long.
pub fn addr_from_unix(path: []const u8) ?Addr {
    var addr: Addr = .{ .storage = std.mem.zeroes(posix.sockaddr.storage), .len = 0 };
    const un: *posix.sockaddr.un = @ptrCast(&addr.storage);
    if (path.len == 0 or path[0] == 0) return null;
    if (path.len >= un.path.len) return null;
    un.family = posix.AF.UNIX;
    @memcpy(un.path[0..path.len], path);
    addr.len = @intCast(@sizeOf(posix.sockaddr.un));
    assert(addr.len > 0);
    return addr;
}

fn fail(errno: posix.E) Error {
    return switch (errno) {
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .INPROGRESS, .ALREADY => error.InProgress,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .PROTONOSUPPORT, .PROTOTYPE, .PROTO => error.ProtocolUnsupported,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionReset,
        .CONNABORTED => error.ConnectionAborted,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .NETDOWN => error.NetworkDown,
        .TIMEDOUT => error.Timeout,
        .ACCES, .PERM => error.AccessDenied,
        .NOMEM, .NOBUFS => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .INVAL => error.SocketNotListening,
        .NOENT => error.FileNotFound,
        .LOOP => error.SymLinkLoop,
        .NOTDIR => error.NotDir,
        .ROFS => error.ReadOnlyFileSystem,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}

const testing = std.testing;

test "fail maps EINTR to Interrupted, not Unexpected" {
    try testing.expectEqual(@as(Error, error.Interrupted), fail(.INTR));
    try testing.expectEqual(@as(Error, error.Unexpected), fail(.IO));
    try testing.expectEqual(@as(Error, error.WouldBlock), fail(.AGAIN));
}

var interrupts_left: u32 = 0;

/// A stand-in syscall that fails with `EINTR` `interrupts_left` times, then succeeds.
fn flaky_call() c_int {
    if (interrupts_left == 0) return 0;
    interrupts_left -= 1;
    std.c._errno().* = @intFromEnum(posix.E.INTR);
    return -1;
}

test "retried repeats EINTR up to attempts_max and then gives the last result" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest; // Sets errno through std.c.
    interrupts_left = attempts_max - 1;
    try testing.expectEqual(@as(c_int, 0), retried(flaky_call, .{}));
    try testing.expectEqual(@as(u32, 0), interrupts_left);

    interrupts_left = attempts_max + 3;
    const rc = retried(flaky_call, .{});
    try testing.expectEqual(@as(c_int, -1), rc);
    try testing.expectEqual(posix.E.INTR, posix.errno(rc));
    try testing.expectEqual(@as(u32, 3), interrupts_left);
}

test "socket_pair is non-blocking, close-on-exec and connected" {
    const fds = try socket_pair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer close(fds[0]);
    defer close(fds[1]);

    try testing.expect(is_nonblocking(fds[0]));
    try testing.expect(is_nonblocking(fds[1]));
    const fd_flags = system.fcntl(fds[0], posix.F.GETFD, @as(usize, 0));
    try testing.expect(@as(usize, @intCast(fd_flags)) & posix.FD_CLOEXEC != 0);
    // Nothing is queued: a read would block.
    var byte: [1]u8 = undefined;
    const rc = system.read(fds[0], &byte, 1);
    try testing.expectEqual(posix.E.AGAIN, posix.errno(rc));
}

test "accept on an empty listener is WouldBlock; connect reports InProgress or success" {
    const listener = try socket_open(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer close(listener);

    var any = addr_from_ip(.{ .ip4 = .loopback(0) });
    try reuse_address_set(listener);
    try bind(listener, &any);
    try listen(listener, 8);
    var peer: Addr = undefined;
    try testing.expectError(error.WouldBlock, accept(listener, &peer));

    var bound: Addr = undefined;
    try socket_name(listener, &bound);
    const client = try socket_open(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer close(client);

    connect(client, &bound) catch |err| switch (err) {
        error.InProgress => {},
        else => return err,
    };
    poll_block(client, .write);
    try socket_error(client);
    poll_block(listener, .read);
    const accepted = try accept(listener, &peer);
    defer close(accepted);

    try testing.expect(is_nonblocking(accepted));
    try testing.expect(addr_to_ip(&peer) != null);
}

test "connect to a closed port surfaces ConnectionRefused through SO_ERROR or directly" {
    const probe = try socket_open(posix.AF.INET, posix.SOCK.STREAM, 0);
    var bound_addr = addr_from_ip(.{ .ip4 = .loopback(0) });
    try bind(probe, &bound_addr);
    try listen(probe, 1);
    var target: Addr = undefined;
    try socket_name(probe, &target);
    close(probe);

    const client = try socket_open(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer close(client);

    const first = connect(client, &target);
    if (first) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.ConnectionRefused => return,
        error.InProgress => {},
        else => return err,
    }
    poll_block(client, .write);
    try testing.expectError(error.ConnectionRefused, socket_error(client));
}

test "bind twice is AddressInUse" {
    const first = try socket_open(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer close(first);

    var addr = addr_from_ip(.{ .ip4 = .loopback(0) });
    try bind(first, &addr);
    try listen(first, 1);
    var taken: Addr = undefined;
    try socket_name(first, &taken);
    const second = try socket_open(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer close(second);

    try testing.expectError(error.AddressInUse, bind(second, &taken));
}

test "address conversion round-trips and rejects unusable unix paths" {
    const ip4: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 1, 2, 3 }, .port = 8080 } };
    const back = addr_to_ip(&addr_from_ip(ip4)).?;
    try testing.expect(back.eql(&ip4));
    const ip6: std.Io.net.IpAddress = .{ .ip6 = .loopback(9) };
    try testing.expect(addr_to_ip(&addr_from_ip(ip6)).?.eql(&ip6));

    try testing.expect(addr_from_unix("/tmp/x.sock") != null);
    try testing.expect(addr_from_unix("") == null);
    try testing.expect(addr_from_unix("\x00abstract") == null);
    const long = [_]u8{'a'} ** 200;
    try testing.expect(addr_from_unix(&long) == null);
}
