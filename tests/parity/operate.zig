//! `operate` tests (plan 004 item 7, ADR 0003 section 2b): `net_receive` on a registered socket
//! and `file_read_streaming`/`file_write_streaming` on a file opened non-blocking are native on
//! the evented backends: a would-block arms the poller and parks the fiber instead of holding an
//! offload worker. Blocking files, `device_io_control` and handles the registry does not know keep
//! the v0.4.0 offload thunk.
//!
//! Parity scenarios build their own sockets and pipes from the `Io` they are given and return a
//! value with no pointers, so `harness.expectSameResultInFiber` compares `rt.io()` in a fiber with
//! `rt.baselineIo()`. A non-blocking file is where the two legitimately differ: `Io.Threaded`
//! reports `WouldBlock` (the std doc comment of `FileReadStreaming.UnendingError`) while sirocco
//! parks, so parking, cancel and registry facts are asserted on `rt.io()` alone and skip on
//! `.threaded`, whose registry is empty. The non-blocking file streams are in
//! `operate_files.zig`, which shares this file's building blocks.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");

const fibers_supported = Runtime.fibers_supported;
const evented = fixtures.backend != .threaded;

const Address = Io.net.IpAddress;
const Socket = Io.net.Socket;
const NetReceive = Io.Operation.NetReceive;

pub const loops_max: u32 = 1 << 20;

pub fn init_rt() !Runtime {
    return fixtures.init_runtime_sockets(std.testing.allocator, .forward, 16, 2, 16);
}

/// Error names the three operations declare, as a value the harness can compare.
pub const Kind = enum {
    none,
    other,
    Canceled,
    WouldBlock,
    EndOfStream,
    BrokenPipe,
    SocketUnconnected,
    ConnectionResetByPeer,
    NotOpenForReading,
    NotOpenForWriting,
    InputOutput,
    SystemResources,
    MessageOversize,
    Unexpected,
};

pub fn kind_of(err: anyerror) Kind {
    return std.meta.stringToEnum(Kind, @errorName(err)) orelse .other;
}

// ---------------------------------------------------------------- building blocks: UDP

pub const Udp = struct {
    receiver: Socket,
    sender: Socket,

    pub fn open(io: Io) !Udp {
        const any_port: Address = .{ .ip4 = .loopback(0) };
        const receiver = try any_port.bind(io, .{ .mode = .dgram });
        errdefer receiver.close(io);

        const sender = try any_port.bind(io, .{ .mode = .dgram });
        return .{ .receiver = receiver, .sender = sender };
    }

    pub fn close(udp: Udp, io: Io) void {
        udp.sender.close(io);
        udp.receiver.close(io);
    }
};

/// What one `net_receive` delivered, projected to values both `Io`s can reproduce.
const Received = struct {
    kind: Kind,
    count: usize,
    len: usize,
    data_ok: bool,
    from_ok: bool,
    trunc: bool,
    ctrunc: bool,
};

fn receive_raw(
    io: Io,
    handle: Socket.Handle,
    message: *Io.net.IncomingMessage,
    buffer: []u8,
    flags: Io.net.ReceiveFlags,
) Io.Cancelable!NetReceive.Result {
    const result = try io.operate(.{ .net_receive = .{
        .socket_handle = handle,
        .message_buffer = message[0..1],
        .data_buffer = buffer,
        .flags = flags,
    } });
    return result.net_receive;
}

fn receive_into(
    io: Io,
    udp: Udp,
    buffer: []u8,
    flags: Io.net.ReceiveFlags,
    expected: []const u8,
) Io.Cancelable!Received {
    var message: Io.net.IncomingMessage = .init;
    const failure, const count = try receive_raw(io, udp.receiver.handle, &message, buffer, flags);
    var out: Received = .{
        .kind = if (failure) |err| kind_of(err) else .none,
        .count = count,
        .len = 0,
        .data_ok = false,
        .from_ok = false,
        .trunc = false,
        .ctrunc = false,
    };
    if (failure != null) return out;

    out.len = message.data.len;
    out.data_ok = std.mem.eql(u8, message.data, expected[0..message.data.len]);
    out.from_ok = message.from.eql(&udp.sender.address);
    out.trunc = message.flags.trunc;
    out.ctrunc = message.flags.ctrunc;
    return out;
}

fn send_later(io: Io, udp: Udp, payload: []const u8) void {
    io.sleep(.fromMilliseconds(40), .awake) catch return;
    udp.sender.send(io, &udp.receiver.address, payload) catch return;
}

// ---------------------------------------------------------------- (1) UDP net_receive parity

fn receive_ready(io: Io, payload: []const u8) !Received {
    const udp = try Udp.open(io);
    defer udp.close(io);

    try udp.sender.send(io, &udp.receiver.address, payload);
    var buffer: [64]u8 = undefined;
    return receive_into(io, udp, &buffer, .{}, payload);
}

test "a UDP net_receive delivers the data and the sender's address, as the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const args = .{@as([]const u8, "hello, datagram")};
    try harness.expectSameResultInFiber(&rt, receive_ready, args);
    const got = try harness.call_in_fiber(rt.io(), receive_ready, args);
    try std.testing.expectEqual(Kind.none, got.kind);
    try std.testing.expectEqual(@as(usize, 1), got.count);
    try std.testing.expectEqual(@as(usize, 15), got.len);
    try std.testing.expect(got.data_ok);
    try std.testing.expect(got.from_ok);
    try std.testing.expect(!got.trunc);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

fn receive_late(io: Io, payload: []const u8) !Received {
    const udp = try Udp.open(io);
    defer udp.close(io);

    var buffer: [64]u8 = undefined;
    const slice: []u8 = &buffer;
    var reading = io.async(receive_into, .{ io, udp, slice, Io.net.ReceiveFlags{}, payload });
    var sending = io.async(send_later, .{ io, udp, payload });
    const outcome = try reading.await(io);
    sending.await(io);
    return outcome;
}

test "a net_receive that would block waits for the datagram that arrives later" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const args = .{@as([]const u8, "late arrival")};
    try harness.expectSameResultInFiber(&rt, receive_late, args);
    const got = try harness.call_in_fiber(rt.io(), receive_late, args);
    try std.testing.expectEqual(Kind.none, got.kind);
    try std.testing.expectEqual(@as(usize, 12), got.len);
    try std.testing.expect(got.data_ok);
    try std.testing.expect(got.from_ok);
    if (evented) try std.testing.expect(!rt.sched.armed_any());
}

fn receive_peek(io: Io, payload: []const u8) !struct { Received, Received } {
    const udp = try Udp.open(io);
    defer udp.close(io);

    try udp.sender.send(io, &udp.receiver.address, payload);
    var buffer: [64]u8 = undefined;
    const peeked = try receive_into(io, udp, &buffer, .{ .peek = true }, payload);
    const taken = try receive_into(io, udp, &buffer, .{}, payload);
    return .{ peeked, taken };
}

test "a peeking net_receive leaves the datagram for the next one, as the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const args = .{@as([]const u8, "peek me")};
    try harness.expectSameResultInFiber(&rt, receive_peek, args);
    const peeked, const taken = try harness.call_in_fiber(rt.io(), receive_peek, args);
    try std.testing.expectEqual(@as(usize, 7), peeked.len);
    try std.testing.expectEqual(@as(usize, 7), taken.len);
    try std.testing.expect(peeked.data_ok);
    try std.testing.expect(taken.data_ok);
}

fn receive_small_buffer(io: Io, buffer_len: usize) !Received {
    const udp = try Udp.open(io);
    defer udp.close(io);

    const payload = "0123456789";
    try udp.sender.send(io, &udp.receiver.address, payload);
    var buffer: [16]u8 = undefined;
    return receive_into(io, udp, buffer[0..buffer_len], .{}, payload);
}

test "a datagram longer than the buffer is truncated and flagged, as the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, receive_small_buffer, .{@as(usize, 4)});
    const got = try harness.call_in_fiber(rt.io(), receive_small_buffer, .{@as(usize, 4)});
    try std.testing.expectEqual(Kind.none, got.kind);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expect(got.trunc);
    try std.testing.expect(got.data_ok);
    // The boundary the other way: a buffer of exactly the datagram's size is not truncated.
    const exact = try harness.call_in_fiber(rt.io(), receive_small_buffer, .{@as(usize, 10)});
    try std.testing.expectEqual(@as(usize, 10), exact.len);
    try std.testing.expect(!exact.trunc);
    try harness.expectSameResultInFiber(&rt, receive_small_buffer, .{@as(usize, 10)});
}

test "a net_receive into a one-byte buffer takes one byte of the datagram, as the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, receive_small_buffer, .{@as(usize, 1)});
    const got = try harness.call_in_fiber(rt.io(), receive_small_buffer, .{@as(usize, 1)});
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(got.trunc);
}

// ---------------------------------------------------------------- (2) foreign handle

fn receive_foreign(io: Io, udp: Udp) !Received {
    try udp.sender.send(io, &udp.receiver.address, "foreign");
    var buffer: [64]u8 = undefined;
    return receive_into(io, udp, &buffer, .{}, "foreign");
}

test "a socket the registry does not know is served by the offload route" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const base = rt.baselineIo();
    const udp = try Udp.open(base);
    defer udp.close(base);

    const io = rt.io();
    var future = io.async(receive_foreign, .{ io, udp });
    const got = try future.await(io);
    try std.testing.expectEqual(Kind.none, got.kind);
    try std.testing.expectEqual(@as(usize, 7), got.len);
    try std.testing.expect(got.from_ok);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

// ---------------------------------------------------------------- (3) receive cancel and close

pub const ReceiveOutcome = struct {
    len: usize,
    canceled: bool,
    failed: bool,
    canceled_after: bool,
};

fn receive_once(io: Io, udp: Udp, protection: Io.CancelProtection) ReceiveOutcome {
    var out: ReceiveOutcome = .{
        .len = 0,
        .canceled = false,
        .failed = false,
        .canceled_after = false,
    };
    const previous = io.swapCancelProtection(protection);
    var buffer: [16]u8 = undefined;
    if (receive_into(io, udp, &buffer, .{}, "x" ** 16)) |got| {
        out.len = got.len;
        out.failed = got.kind != .none;
    } else |err| switch (err) {
        error.Canceled => out.canceled = true,
    }
    _ = io.swapCancelProtection(previous);
    io.checkCancel() catch {
        out.canceled_after = true;
    };
    return out;
}

fn receive_cancel(io: Io, protection: Io.CancelProtection) !ReceiveOutcome {
    const udp = try Udp.open(io);
    defer udp.close(io);

    var reading = io.async(receive_once, .{ io, udp, protection });
    var sending = io.async(send_later, .{ io, udp, @as([]const u8, "x") });
    const outcome = reading.cancel(io);
    sending.await(io);
    return outcome;
}

test "a net_receive canceled in flight returns Canceled, as the baseline" {
    if (!fibers_supported or !evented) return error.SkipZigTest; // Offloaded: no interrupt.
    var rt = try init_rt();
    defer rt.deinit();

    const unblocked = .{Io.CancelProtection.unblocked};
    try harness.expectSameResultInFiber(&rt, receive_cancel, unblocked);
    const outcome = try harness.call_in_fiber(rt.io(), receive_cancel, unblocked);
    try std.testing.expect(outcome.canceled);
    try std.testing.expectEqual(@as(usize, 0), outcome.len);
    try std.testing.expect(!rt.sched.armed_any());
}

test "a net_receive under blocked cancel protection completes, then the request is seen" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const blocked = .{Io.CancelProtection.blocked};
    try harness.expectSameResultInFiber(&rt, receive_cancel, blocked);
    const outcome = try harness.call_in_fiber(rt.io(), receive_cancel, blocked);
    try std.testing.expectEqual(@as(usize, 1), outcome.len);
    try std.testing.expect(!outcome.canceled);
    try std.testing.expect(outcome.canceled_after);
}

test "a parked net_receive arms the poller once, leaves it clean after a cancel, socket intact" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    var making = io.async(Udp.open, .{io});
    const udp = try making.await(io);
    defer udp.close(io);

    var reading = io.async(receive_once, .{ io, udp, Io.CancelProtection.unblocked });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    try std.testing.expect(rt.sched.armed_any());
    try std.testing.expect(reading.cancel(io).canceled);
    try std.testing.expectEqual(@as(u32, 0), rt.sched.parked_count);
    try std.testing.expect(!rt.sched.armed_any());
    try std.testing.expectEqual(@as(u32, 2), rt.sockets.count());
    // Still usable after the canceled receive.
    try udp.sender.send(io, &udp.receiver.address, "again");
    var buffer: [16]u8 = undefined;
    const message = try udp.receiver.receive(io, &buffer);
    try std.testing.expectEqualStrings("again", message.data);
}

fn close_socket(io: Io, socket: Socket) void {
    socket.close(io);
}

test "closing the socket a fiber is receiving on gives the receiver an error" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    var making = io.async(Udp.open, .{io});
    const udp = try making.await(io);
    defer udp.sender.close(io);

    var buffer: [16]u8 = undefined;
    const slice: []u8 = &buffer;
    var reading = io.async(receive_into, .{ io, udp, slice, Io.net.ReceiveFlags{}, "" });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    var closing = io.async(close_socket, .{ io, udp.receiver });
    closing.await(io);
    const got = try reading.await(io);
    try std.testing.expectEqual(Kind.SocketUnconnected, got.kind);
    try std.testing.expectEqual(@as(usize, 0), got.count);
    try std.testing.expect(!rt.sched.armed_any());
}

fn send_from_thread(io: Io, udp: Udp) void {
    send_later(io, udp, "thread");
}

test "a net_receive off a fiber on a registered socket waits in poll" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    var making = io.async(Udp.open, .{io});
    const udp = try making.await(io);
    defer udp.close(io);

    const sender = try std.Thread.spawn(.{}, send_from_thread, .{ rt.baselineIo(), udp });
    defer sender.join();

    var buffer: [16]u8 = undefined;
    const message = try udp.receiver.receive(io, &buffer);
    try std.testing.expectEqualStrings("thread", message.data);
}
