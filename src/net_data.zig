//! sirocco.net_data — the native data-path socket slots on the evented poller (plan 004 item 5,
//! ADR 0003 section 3): `netRead` (`readv`), `netWrite` (`sendmsg` over `header`, `data` and
//! `splat`), `netSend` (`sendmsg` per datagram, partial count) and `netShutdown`. `netClose`, which
//! disarms and unparks waiters before `close(2)`, lives in `src/net.zig` with the creation slots.
//!
//! Purpose: a read or write on a socket in the `sockets_max` registry is one non-blocking syscall.
//! A would-block arms the poller and parks the fiber (`net.wait_for`); the event, a cancel or a
//! close ends the park, and the call retries. A close under the call ends it with
//! `error.SocketUnconnected` without touching the fd again. Dispatch per ADR: registered handle on
//! a fiber: park on would-block; registered handle off a fiber: `poll(2)` on would-block; a foreign
//! handle (or any handle under `.threaded`, whose registry is empty) takes the v0.4.0 offload
//! thunk, and `netShutdown`, which never blocks, calls the baseline slot directly.
//!
//! Invariants: no allocation after init, no recursion, every retry loop bounded by
//! `net.wakeups_max`. A write returns the bytes the kernel took, which may be fewer than offered,
//! as `Io.net.Stream.Writer` expects. `header` and `data` reach the kernel as iovecs of the
//! caller's own buffers; only a one-byte `splat` pattern is materialized, into a stack fill of
//! `fill_len` bytes (as `Io.Threaded` does), so one call carries up to `sys.iovecs_max` x
//! `fill_len` repeated bytes. Cost per call: one syscall, at most `sys.iovecs_max` x 16 bytes of
//! iovec plus `fill_len` bytes of stack.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");
const concurrency = @import("concurrency.zig");
const net = @import("net.zig");
const sys = @import("backend/sys.zig");

const Io = std.Io;
const posix = std.posix;
const assert = stdx.assert;
const fd_t = sys.fd_t;
const Socket = Io.net.Socket;
const Stream = Io.net.Stream;

/// Bytes of the stack fill a one-byte `splat` pattern is expanded into.
const fill_len: u32 = 256;

const SendResult = struct { ?Socket.SendError, usize };

fn slot_read(
    userdata: ?*anyopaque,
    handle: Socket.Handle,
    data: [][]u8,
) Stream.Reader.Error!usize {
    const E = Stream.Reader.Error;
    const rt = concurrency.runtime_of(userdata);
    const r = net.route(rt, handle);
    if (r == .fallback) return net.thunk("netRead", userdata, .{ handle, data });
    try net.cancel_check(r);

    var iovecs: [sys.iovecs_max]posix.iovec = undefined; // Filled below, `count` entries read.
    const iov = iovecs_read(data, &iovecs);
    for (0..net.wakeups_max) |_| {
        if (sys.readv(handle, iov)) |count| {
            return count;
        } else |err| switch (err) {
            error.WouldBlock => {
                try net.wait_for(E, rt, r, handle, .read, error.SocketUnconnected);
            },
            error.Interrupted => continue,
            else => return net.narrow(E, err),
        }
    }
    return net.narrow(E, error.WouldBlock);
}

fn slot_write(
    userdata: ?*anyopaque,
    handle: Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) Stream.Writer.Error!usize {
    const E = Stream.Writer.Error;
    const rt = concurrency.runtime_of(userdata);
    const r = net.route(rt, handle);
    if (r == .fallback) {
        return net.thunk("netWrite", userdata, .{ handle, header, data, splat });
    }
    try net.cancel_check(r);

    var iovecs: [sys.iovecs_max]posix.iovec_const = undefined; // `count` entries are filled.
    var fill: [fill_len]u8 = undefined; // Written by `iovecs_write` before any iovec views it.
    const count = iovecs_write(&iovecs, &fill, header, data, splat);
    const msg = msghdr_of(iovecs[0..count]);
    for (0..net.wakeups_max) |_| {
        if (sys.sendmsg(handle, &msg, 0)) |sent| {
            return sent;
        } else |err| switch (err) {
            error.WouldBlock => {
                try net.wait_for(E, rt, r, handle, .write, error.SocketUnconnected);
            },
            error.Interrupted => continue,
            else => return net.narrow(E, err),
        }
    }
    return net.narrow(E, error.WouldBlock);
}

fn slot_send(
    userdata: ?*anyopaque,
    handle: Socket.Handle,
    messages: []Io.net.OutgoingMessage,
    flags: Io.net.SendFlags,
) SendResult {
    const rt = concurrency.runtime_of(userdata);
    const r = net.route(rt, handle);
    if (r == .fallback) return net.thunk("netSend", userdata, .{ handle, messages, flags });
    net.cancel_check(r) catch |err| return .{ err, 0 };

    const posix_flags = send_flags(flags);
    for (messages, 0..) |*message, index| {
        send_one(Socket.SendError, rt, r, handle, message, posix_flags) catch |err| {
            return .{ err, index };
        };
    }
    return .{ null, messages.len };
}

/// One datagram (or stream write) through `sendmsg`; on success `message.data_len` is the number of
/// bytes the kernel took, as `Io.Threaded` reports it.
fn send_one(
    comptime E: type,
    rt: *Runtime,
    r: net.Route,
    handle: fd_t,
    message: *Io.net.OutgoingMessage,
    flags: u32,
) E!void {
    assert(handle >= 0);
    assert(r != .fallback);
    var addr = sys.addr_from_ip(message.address.*);
    var iov = [1]posix.iovec_const{.{ .base = message.data_ptr, .len = message.data_len }};
    var msg = msghdr_of(&iov);
    msg.name = @ptrCast(&addr.storage);
    msg.namelen = addr.len;
    // The kernel checks the pointer even when the length is zero.
    msg.control = if (message.control.len == 0) null else @constCast(message.control.ptr);
    msg.controllen = @intCast(message.control.len);
    for (0..net.wakeups_max) |_| {
        if (sys.sendmsg(handle, &msg, flags)) |sent| {
            message.data_len = sent;
            return;
        } else |err| switch (err) {
            error.WouldBlock => {
                try net.wait_for(E, rt, r, handle, .write, error.SocketUnconnected);
            },
            error.Interrupted => continue,
            else => return net.narrow(E, err),
        }
    }
    return net.narrow(E, error.WouldBlock);
}

fn slot_shutdown(
    userdata: ?*anyopaque,
    handle: Socket.Handle,
    how: Io.net.ShutdownHow,
) Io.net.ShutdownError!void {
    const E = Io.net.ShutdownError;
    const rt = concurrency.runtime_of(userdata);
    const r = net.route(rt, handle);
    if (r == .fallback) {
        const baseline = rt.baselineIo();
        return baseline.vtable.netShutdown(baseline.userdata, handle, how);
    }
    try net.cancel_check(r);

    const sys_how: sys.ShutdownHow = switch (how) {
        .recv => .recv,
        .send => .send,
        .both => .both,
    };
    sys.shutdown(handle, sys_how) catch |err| return net.narrow(E, err);
}

/// The non-empty buffers of `data` (at most `out.len`) as iovecs: the kernel reads the iovec base
/// before its length, so an empty buffer must not be passed. Precondition, as `Io.Threaded`'s:
/// `data` holds at least one non-empty buffer.
fn iovecs_read(data: []const []u8, out: *[sys.iovecs_max]posix.iovec) []const posix.iovec {
    assert(data.len > 0);
    var count: u32 = 0;
    for (data) |buffer| {
        if (count == out.len) break;
        if (buffer.len == 0) continue;
        out[count] = .{ .base = buffer.ptr, .len = buffer.len };
        count += 1;
    }
    assert(count > 0); // No non-empty buffer: a caller bug, `readv` would return 0 as EOF.
    assert(count <= out.len);
    return out[0..count];
}

/// Lays `header`, every element of `data` but the last, then `splat` copies of the last element
/// (the pattern) into `out`, skipping empty buffers and stopping when `out` is full. A partial
/// layout is correct: a write may take fewer bytes than offered. Returns the entry count.
fn iovecs_write(
    out: *[sys.iovecs_max]posix.iovec_const,
    fill: *[fill_len]u8,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) u32 {
    assert(data.len > 0); // The last element is the splat pattern.
    var count: u32 = iovec_add(out, 0, header);
    for (data[0 .. data.len - 1]) |bytes| count = iovec_add(out, count, bytes);
    const pattern = data[data.len - 1];
    if (count < out.len) count = iovecs_pattern(out, count, fill, pattern, splat);
    assert(count <= out.len);
    return count;
}

fn iovecs_pattern(
    out: *[sys.iovecs_max]posix.iovec_const,
    first: u32,
    fill: *[fill_len]u8,
    pattern: []const u8,
    splat: usize,
) u32 {
    assert(first < out.len);
    var count = first;
    switch (splat) {
        0 => {},
        1 => count = iovec_add(out, count, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                @memset(fill, pattern[0]);
                var remaining = splat;
                for (0..out.len) |_| {
                    if (remaining == 0 or count == out.len) break;
                    const take = @min(remaining, fill.len);
                    count = iovec_add(out, count, fill[0..take]);
                    remaining -= take;
                }
            },
            else => for (0..@min(splat, out.len - count)) |_| {
                count = iovec_add(out, count, pattern);
            },
        },
    }
    assert(count >= first);
    return count;
}

/// Appends `bytes` as the next iovec unless it is empty or `out` is full; returns the new count.
fn iovec_add(out: *[sys.iovecs_max]posix.iovec_const, count: u32, bytes: []const u8) u32 {
    assert(count <= out.len);
    if (bytes.len == 0) return count;
    if (count == out.len) return count;
    out[count] = .{ .base = bytes.ptr, .len = bytes.len };
    return count + 1;
}

fn msghdr_of(iov: []const posix.iovec_const) posix.msghdr_const {
    assert(iov.len <= sys.iovecs_max);
    return .{
        .name = null,
        .namelen = 0,
        .iov = iov.ptr,
        .iovlen = @intCast(iov.len),
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
}

/// The `MSG` bits of `Io.net.SendFlags` this target has (`sys.sendmsg` adds `NOSIGNAL`).
fn send_flags(flags: Io.net.SendFlags) u32 {
    var bits: u32 = 0;
    if (@hasDecl(posix.MSG, "CONFIRM") and flags.confirm) bits |= posix.MSG.CONFIRM;
    if (@hasDecl(posix.MSG, "DONTROUTE") and flags.dont_route) bits |= posix.MSG.DONTROUTE;
    if (@hasDecl(posix.MSG, "EOR") and flags.eor) bits |= posix.MSG.EOR;
    if (@hasDecl(posix.MSG, "OOB") and flags.oob) bits |= posix.MSG.OOB;
    if (@hasDecl(posix.MSG, "FASTOPEN") and flags.fastopen) bits |= posix.MSG.FASTOPEN;
    return bits;
}

/// Overwrites the four slots of `vtable`. Precondition: `Sched.supported`, `vtable` holds the
/// baseline's functions with the offload thunks over them (the fallbacks call those thunks).
pub fn install(vtable: *Io.VTable) void {
    assert(Sched.supported);
    assert(vtable.netRead != slot_read);
    vtable.netRead = slot_read;
    vtable.netWrite = slot_write;
    vtable.netSend = slot_send;
    vtable.netShutdown = slot_shutdown;
}

/// The slots this file replaces.
pub fn is_native(comptime name: []const u8) bool {
    const names = [_][]const u8{ "netRead", "netWrite", "netSend", "netShutdown" };
    inline for (names) |native| {
        if (comptime std.mem.eql(u8, name, native)) return true;
    }
    return false;
}

test "iovecs_write views header and data, expands a one-byte splat and skips empty buffers" {
    var out: [sys.iovecs_max]posix.iovec_const = undefined;
    var fill: [fill_len]u8 = undefined;
    const data = [_][]const u8{ "", "mid", "q" };
    const count = iovecs_write(&out, &fill, "head", &data, 300);
    try std.testing.expectEqual(@as(u32, 4), count);
    try std.testing.expectEqual(@as(usize, 4), out[0].len);
    try std.testing.expectEqual(@as(usize, 3), out[1].len);
    try std.testing.expectEqual(@as(usize, fill_len), out[2].len);
    try std.testing.expectEqual(@as(usize, 300 - fill_len), out[3].len);
    try std.testing.expect(out[0].base == "head".ptr);
    try std.testing.expect(std.mem.allEqual(u8, fill[0..], 'q'));
}

test "iovecs_write repeats a multi-byte pattern by reference and stops when full" {
    var out: [sys.iovecs_max]posix.iovec_const = undefined;
    var fill: [fill_len]u8 = undefined;
    const data = [_][]const u8{"abc"};
    try std.testing.expectEqual(@as(u32, 3), iovecs_write(&out, &fill, "", &data, 3));
    try std.testing.expect(out[2].base == data[0].ptr);
    const full = iovecs_write(&out, &fill, "", &data, 1 << 20);
    try std.testing.expectEqual(@as(u32, sys.iovecs_max), full);
    try std.testing.expectEqual(@as(u32, 0), iovecs_write(&out, &fill, "", &data, 0));
}

test "iovecs_read skips empty buffers and caps at iovecs_max" {
    var a: [4]u8 = undefined;
    var empty: [0]u8 = undefined;
    var out: [sys.iovecs_max]posix.iovec = undefined;
    const data = [_][]u8{ &empty, &a, &a };
    const iov = iovecs_read(&data, &out);
    try std.testing.expectEqual(@as(usize, 2), iov.len);
    try std.testing.expectEqual(@as(usize, 4), iov[0].len);
}
