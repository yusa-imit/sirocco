//! sirocco.submit — the native `operate` slot on the evented poller (plan 004 item 7, ADR 0003
//! section 2b): `net_receive` (`recvmsg`) on a registered socket, and `file_read_streaming` /
//! `file_write_streaming` (`readv` / `writev`) on a file whose `flags.nonblocking` says its caller
//! made it non-blocking. `device_io_control`, blocking files and unregistered handles keep the
//! v0.4.0 offload thunk, which runs `Io.Threaded`'s `operate` on a worker.
//!
//! Purpose: one non-blocking syscall per call. A would-block arms the poller and parks the fiber
//! (`net.wait_for`); the event, a cancel or a close ends the park and the call retries, so a read
//! on a pipe waits for its writer without holding a worker. Result semantics are `Io.Threaded`'s:
//! `net_receive` fills `message_buffer[0]` and reports `{ null, 1 }`, or `{ error, 0 }` with
//! `Canceled` on the outer error channel; a file read that returns 0 bytes is `EndOfStream`; an
//! operation with no non-empty buffer (or nothing to write) returns 0 without a syscall. The one
//! deliberate difference is on a non-blocking file: `Io.Threaded` reports `WouldBlock`, sirocco
//! waits, so the std doc comment's `WouldBlock` never reaches a caller on a fiber.
//!
//! Dispatch: a registered socket takes `net.route` (fiber: park; off a fiber: `poll(2)` on the
//! calling thread). A non-blocking file on a fiber is entered in the registry for the length of
//! the call (`Registry.lease`, counted against `sockets_max`, shared by fibers waiting on the same
//! pipe) and released on every exit; off a fiber it waits in `poll(2)` like a socket does. With
//! the registry full the call runs on an offload worker that waits in `poll(2)` and retries, so
//! the caller still never sees `WouldBlock`. Under `.threaded` the registry is empty, every call
//! takes the thunk, and `Io.Threaded`'s `WouldBlock` is what the caller gets.
//!
//! Invariants: no allocation after init, no recursion, every retry loop bounded by
//! `net.wakeups_max`. A cancel pending before the first syscall is delivered before it; one that
//! arrives while parked unparks the fiber with `error.Canceled`; once the overflow worker has the
//! call it completes (ADR 0001). A close under a parked socket call ends it with
//! `SocketUnconnected`. Cost per call: one syscall (no arm when the data is ready), plus for a
//! file on a fiber two registry lock holds and a hash insert and remove; up to
//! `sys.iovecs_max` x 16 bytes of iovec and `net_data.fill_len` bytes of stack for a write.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");
const concurrency = @import("concurrency.zig");
const net = @import("net.zig");
const net_data = @import("net_data.zig");
const sys = @import("backend/sys.zig");

const Io = std.Io;
const posix = std.posix;
const assert = stdx.assert;
const assert_always = stdx.assert_always;
const Socket = Io.net.Socket;
const NetReceive = Io.Operation.NetReceive;
const FileRead = Io.Operation.FileReadStreaming;
const FileWrite = Io.Operation.FileWriteStreaming;

fn slot_operate(
    userdata: ?*anyopaque,
    operation: Io.Operation,
) Io.Cancelable!Io.Operation.Result {
    const rt = concurrency.runtime_of(userdata);
    const r = route_of(rt, operation);
    if (r == .fallback) return net.thunk("operate", userdata, .{operation});
    try net.cancel_check(r);

    return switch (operation) {
        .net_receive => |o| .{ .net_receive = try receive(rt, r, o) },
        .file_read_streaming, .file_write_streaming => try serve_file(rt, r, operation),
        .device_io_control => unreachable, // Proof: `route_of` sends it to the thunk.
    };
}

/// Where `operation` runs: `.fallback` is the offload thunk, `.fiber` and `.blocking` are served
/// here. Only an evented runtime that is ready has a registry to serve from.
fn route_of(rt: *Runtime, operation: Io.Operation) net.Route {
    if (rt.sched_state != .ready) return .fallback;
    if (!rt.sockets.enabled()) return .fallback;
    return switch (operation) {
        .net_receive => |o| net.route(rt, o.socket_handle),
        .file_read_streaming => |o| file_route(rt, o.file),
        .file_write_streaming => |o| file_route(rt, o.file),
        .device_io_control => .fallback,
    };
}

fn file_route(rt: *Runtime, file: Io.File) net.Route {
    assert(file.handle >= 0);
    assert(rt.sockets.enabled());
    if (!file.flags.nonblocking) return .fallback;
    const task = concurrency.current_task(rt) orelse return .blocking;
    return .{ .fiber = task };
}

// ---------------------------------------------------------------- net_receive

fn receive(rt: *Runtime, r: net.Route, o: NetReceive) Io.Cancelable!NetReceive.Result {
    const E = Socket.ReceiveError;
    assert(o.message_buffer.len > 0); // `Io.Threaded` fills the first message as well.
    assert(o.socket_handle >= 0);
    const message = &o.message_buffer[0];
    var address: sys.Addr = .{ .storage = std.mem.zeroes(posix.sockaddr.storage), .len = 0 };
    var iov = [1]posix.iovec{.{ .base = o.data_buffer.ptr, .len = o.data_buffer.len }};
    var msg = msghdr_for(&address, &iov, message.control);
    const bits = receive_bits(o.flags);
    for (0..net.wakeups_max) |_| {
        if (sys.recvmsg(o.socket_handle, &msg, bits)) |count| {
            const data = o.data_buffer[0..count];
            message.* = message_from(&msg, &address, data, message.control);
            return .{ null, 1 };
        } else |err| switch (err) {
            error.WouldBlock => {
                const closed = error.SocketUnconnected;
                net.wait_for(E, rt, r, o.socket_handle, .read, closed) catch |wait_err| {
                    switch (wait_err) {
                        error.Canceled => return error.Canceled,
                        else => return .{ wait_err, 0 }, // Any other member is the call's own.
                    }
                };
            },
            error.Interrupted => continue,
            else => return .{ net.narrow(E, err), 0 },
        }
    }
    return .{ net.narrow(E, error.WouldBlock), 0 };
}

fn msghdr_for(address: *sys.Addr, iov: *[1]posix.iovec, control: []u8) posix.msghdr {
    assert(control.len <= std.math.maxInt(u32));
    assert(@sizeOf(posix.sockaddr.storage) <= std.math.maxInt(u32));
    return .{
        .name = @ptrCast(&address.storage),
        .namelen = @sizeOf(posix.sockaddr.storage),
        .iov = iov,
        .iovlen = 1,
        // The kernel checks the pointer only for a non-zero length; `Io.Threaded` passes it as is.
        .control = control.ptr,
        .controllen = @intCast(control.len),
        .flags = 0,
    };
}

/// The `MSG` bits of `ReceiveFlags`; `DONTWAIT` is always set so a flipped `O_NONBLOCK` can never
/// freeze the carrier (`sys.recvmsg` adds `NOSIGNAL`).
fn receive_bits(flags: Io.net.ReceiveFlags) u32 {
    var bits: u32 = posix.MSG.DONTWAIT;
    if (flags.oob) bits |= posix.MSG.OOB;
    if (flags.peek) bits |= posix.MSG.PEEK;
    if (flags.trunc) bits |= posix.MSG.TRUNC;
    assert(bits & posix.MSG.DONTWAIT != 0);
    return bits;
}

/// The message `Io.Threaded` builds after a successful `recvmsg`: a peer with no IP address reads
/// as loopback port 0, and `control` shrinks to the length the kernel filled.
fn message_from(
    msg: *const posix.msghdr,
    address: *const sys.Addr,
    data: []u8,
    control_in: []u8,
) Io.net.IncomingMessage {
    assert(msg.iovlen == 1);
    const control = if (msg.control) |ptr|
        @as([*]u8, @ptrCast(ptr))[0..msg.controllen]
    else
        control_in;
    assert(control.len <= control_in.len);
    return .{
        .from = sys.addr_to_ip(address) orelse .{ .ip4 = .loopback(0) },
        .data = data,
        .control = control,
        .flags = flags_from(msg.flags),
    };
}

fn flags_from(bits: @FieldType(posix.msghdr, "flags")) Io.net.IncomingMessage.Flags {
    const errqueue = if (@hasDecl(posix.MSG, "ERRQUEUE")) bits & posix.MSG.ERRQUEUE else 0;
    return .{
        .eor = (bits & posix.MSG.EOR) != 0,
        .trunc = (bits & posix.MSG.TRUNC) != 0,
        .ctrunc = (bits & posix.MSG.CTRUNC) != 0,
        .oob = (bits & posix.MSG.OOB) != 0,
        .errqueue = errqueue != 0,
    };
}

// ---------------------------------------------------------------- file streams

/// A file operation on a fiber holds a registry lease while it waits; off a fiber it needs none.
fn serve_file(
    rt: *Runtime,
    r: net.Route,
    operation: Io.Operation,
) Io.Cancelable!Io.Operation.Result {
    assert(r != .fallback);
    const fd = file_of(operation).handle;
    assert(fd >= 0);
    if (r == .blocking) return file_run(rt, r, operation);

    const held = rt.sockets.lease(fd) catch |err| switch (err) {
        error.Full => return overflow(rt, operation),
    };
    defer if (held == .held) rt.sockets.lease_release(fd);

    return file_run(rt, r, operation);
}

fn file_of(operation: Io.Operation) Io.File {
    return switch (operation) {
        .file_read_streaming => |o| o.file,
        .file_write_streaming => |o| o.file,
        .net_receive, .device_io_control => unreachable, // Proof: `serve_file` has a file op.
    };
}

fn file_run(
    rt: *Runtime,
    r: net.Route,
    operation: Io.Operation,
) Io.Cancelable!Io.Operation.Result {
    assert(r != .fallback);
    return switch (operation) {
        .file_read_streaming => |o| .{ .file_read_streaming = try file_read(rt, r, o) },
        .file_write_streaming => |o| .{ .file_write_streaming = try file_write(rt, r, o) },
        .net_receive, .device_io_control => unreachable, // Proof: only `serve_file` calls this.
    };
}

fn file_read(rt: *Runtime, r: net.Route, o: FileRead) Io.Cancelable!FileRead.Result {
    const E = Io.Cancelable || FileRead.Error;
    const R = FileRead.Result;
    assert(o.file.handle >= 0);
    if (!any_nonempty(o.data)) return @as(R, 0); // As `Io.Threaded`: nothing to read, no syscall.

    var iovecs: [sys.iovecs_max]posix.iovec = undefined; // `iovecs_read` fills what it returns.
    const iov = net_data.iovecs_read(o.data, &iovecs);
    for (0..net.wakeups_max) |_| {
        if (sys.file_readv(o.file.handle, iov)) |count| {
            if (count == 0) return @as(R, error.EndOfStream);
            return @as(R, count);
        } else |err| switch (err) {
            error.WouldBlock => {
                const closed = error.SocketUnconnected;
                net.wait_for(E, rt, r, o.file.handle, .read, closed) catch |wait_err| {
                    switch (wait_err) {
                        error.Canceled => return error.Canceled,
                        else => return @as(R, net.narrow(FileRead.Error, wait_err)),
                    }
                };
            },
            error.Interrupted => continue,
            error.NotOpenForReading,
            error.NotOpenForWriting,
            error.InputOutput,
            error.IsDir,
            error.SystemResources,
            error.SocketUnconnected,
            error.ConnectionResetByPeer,
            error.DiskQuota,
            error.FileTooBig,
            error.NoSpaceLeft,
            error.PermissionDenied,
            error.BrokenPipe,
            error.DeviceBusy,
            error.Unexpected,
            => return @as(R, net.narrow(FileRead.Error, err)),
        }
    }
    return @as(R, net.narrow(FileRead.Error, error.WouldBlock));
}

fn file_write(rt: *Runtime, r: net.Route, o: FileWrite) Io.Cancelable!FileWrite.Result {
    const E = Io.Cancelable || FileWrite.Error;
    const R = FileWrite.Result;
    assert(o.file.handle >= 0);
    var iovecs: [sys.iovecs_max]posix.iovec_const = undefined; // `count` entries are filled.
    var fill: [net_data.fill_len]u8 = undefined; // Written by `iovecs_write` before it is viewed.
    const count = net_data.iovecs_write(&iovecs, &fill, o.header, o.data, o.splat);
    if (count == 0) return @as(R, 0); // As `Io.Threaded`: nothing to write, no syscall.

    const iov = iovecs[0..count];
    for (0..net.wakeups_max) |_| {
        if (sys.file_writev(o.file.handle, iov)) |sent| {
            return @as(R, sent);
        } else |err| switch (err) {
            error.WouldBlock => {
                const closed = error.BrokenPipe;
                net.wait_for(E, rt, r, o.file.handle, .write, closed) catch |wait_err| {
                    switch (wait_err) {
                        error.Canceled => return error.Canceled,
                        else => return @as(R, net.narrow(FileWrite.Error, wait_err)),
                    }
                };
            },
            error.Interrupted => continue,
            error.NotOpenForReading,
            error.NotOpenForWriting,
            error.InputOutput,
            error.IsDir,
            error.SystemResources,
            error.SocketUnconnected,
            error.ConnectionResetByPeer,
            error.DiskQuota,
            error.FileTooBig,
            error.NoSpaceLeft,
            error.PermissionDenied,
            error.BrokenPipe,
            error.DeviceBusy,
            error.Unexpected,
            => return @as(R, net.narrow(FileWrite.Error, err)),
        }
    }
    return @as(R, net.narrow(FileWrite.Error, error.WouldBlock));
}

fn any_nonempty(data: []const []u8) bool {
    for (data) |buffer| {
        if (buffer.len > 0) return true;
    }
    return false;
}

/// One file call handed to a worker because the registry had no slot for its wait.
const Overflow = struct {
    rt: *Runtime,
    operation: Io.Operation,
    result: ?(Io.Cancelable!Io.Operation.Result),

    fn job(context: ?*anyopaque) void {
        const call: *Overflow = @ptrCast(@alignCast(context.?));
        assert(call.result == null);
        call.result = file_run(call.rt, .blocking, call.operation);
    }
};

/// Runs a file call on an offload worker that waits in `poll(2)` where a fiber would park, so a
/// full registry degrades to ADR 0002's offload path instead of leaking `WouldBlock`. The pending
/// cancel was delivered before this; the call itself cannot be interrupted once submitted, and it
/// holds its worker until the peer is ready, exactly as v0.4.0 did for every call. That bound is
/// the price of `sockets_max` being a hard limit: size it for the files expected to wait at once.
fn overflow(rt: *Runtime, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    assert(rt.sockets.enabled());
    assert(rt.sched.in_fiber());
    var call: Overflow = .{ .rt = rt, .operation = operation, .result = null };
    rt.offload.call(Overflow.job, &call);
    assert_always(call.result != null); // The fiber woke without the worker's result.
    return call.result.?;
}

/// Overwrites the `operate` slot of `vtable`. Precondition: `Sched.supported`, `vtable` holds the
/// baseline's functions with the offload thunks over them (the fallbacks call that thunk).
pub fn install(vtable: *Io.VTable) void {
    assert(Sched.supported);
    assert(vtable.operate != slot_operate);
    vtable.operate = slot_operate;
}

/// The slots this file replaces.
pub fn is_native(comptime name: []const u8) bool {
    return comptime std.mem.eql(u8, name, "operate");
}

test "receive_bits always adds DONTWAIT and maps exactly the three receive flags" {
    const none = receive_bits(.{});
    try std.testing.expectEqual(@as(u32, posix.MSG.DONTWAIT), none);
    const all = receive_bits(.{ .oob = true, .peek = true, .trunc = true });
    try std.testing.expectEqual(
        @as(u32, posix.MSG.DONTWAIT | posix.MSG.OOB | posix.MSG.PEEK | posix.MSG.TRUNC),
        all,
    );
    try std.testing.expectEqual(
        @as(u32, posix.MSG.DONTWAIT | posix.MSG.PEEK),
        receive_bits(.{ .peek = true }),
    );
}

test "flags_from reads the bits the kernel left in msg_flags" {
    const clear = flags_from(0);
    try std.testing.expect(!clear.eor and !clear.trunc and !clear.ctrunc and !clear.oob);
    try std.testing.expect(!clear.errqueue);
    const set = flags_from(posix.MSG.TRUNC | posix.MSG.CTRUNC);
    try std.testing.expect(set.trunc);
    try std.testing.expect(set.ctrunc);
    try std.testing.expect(!set.eor and !set.oob);
}

test "any_nonempty finds a byte anywhere and nothing in empty buffers" {
    var one: [1]u8 = undefined;
    var none: [0]u8 = undefined;
    try std.testing.expect(!any_nonempty(&.{}));
    try std.testing.expect(!any_nonempty(&[_][]u8{ &none, &none }));
    try std.testing.expect(any_nonempty(&[_][]u8{ &none, &one }));
}

test "message_from reports a nameless peer as loopback port 0 and keeps the control slice" {
    var address: sys.Addr = .{ .storage = std.mem.zeroes(posix.sockaddr.storage), .len = 0 };
    var data: [3]u8 = .{ 1, 2, 3 };
    var control: [16]u8 = @splat(0);
    var iov = [1]posix.iovec{.{ .base = &data, .len = data.len }};
    var msg = msghdr_for(&address, &iov, &control);
    msg.controllen = 4;
    const message = message_from(&msg, &address, &data, &control);
    try std.testing.expect(message.from.eql(&.{ .ip4 = .loopback(0) }));
    try std.testing.expectEqual(@as(usize, 3), message.data.len);
    try std.testing.expectEqual(@as(usize, 4), message.control.len);
    try std.testing.expect(!message.flags.trunc);
}
