//! Close, cancel and edge tests of the evented socket slots (plan 004 item 4, ADR 0003 section 3):
//! a close that meets parked waiters, from a fiber, from a thread that is not the carrier's, and
//! racing a real second thread; an accept off a fiber; bind and Unix sockets on the registry; a
//! recycled fd number; two waiters on one listener; a cancel in the middle of a connect; and the
//! registry-full overflow. Under `.threaded` the evented-only tests skip.

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");

const fibers_supported = Runtime.fibers_supported;
const evented = fixtures.backend != .threaded;

const Address = Io.net.IpAddress;
const Server = Io.net.Server;

fn listen_loopback(io: Io) Address.ListenError!Server {
    const any_port: Address = .{ .ip4 = .loopback(0) };
    return any_port.listen(io, .{ .reuse_address = true });
}

fn accept_close(io: Io, server: *Server) Server.AcceptError!void {
    const stream = try server.accept(io);
    stream.close(io);
}

fn accept_keep(io: Io, server: *Server) Server.AcceptError!Io.net.Stream {
    return server.accept(io);
}

fn connect_to(io: Io, address: Address) Address.ConnectError!Io.net.Stream {
    return address.connect(io, .{ .mode = .stream });
}

fn connect_close(io: Io, address: Address) Address.ConnectError!void {
    const stream = try address.connect(io, .{ .mode = .stream });
    stream.close(io);
}

fn close_server(io: Io, server: *Server) void {
    server.deinit(io);
}

fn expect_clean(rt: *Runtime, sockets: u32) !void {
    try std.testing.expectEqual(sockets, rt.sockets.count());
    try std.testing.expect(!rt.sched.armed_any());
}

/// A runtime with a listener whose accept is parked; the caller finishes both.
const Parked = struct {
    rt: Runtime,
    server: Server,
    accepting: Io.Future(Server.AcceptError!void),

    fn start(parked: *Parked) !void {
        parked.rt = try fixtures.init_runtime_sockets(std.testing.allocator, .forward, 8, 1, 4);
        errdefer parked.rt.deinit();

        const io = parked.rt.io();
        var listening = io.async(listen_loopback, .{io});
        parked.server = try listening.await(io);
        parked.accepting = io.async(accept_close, .{ io, &parked.server });
        try std.testing.expectEqual(@as(u32, 1), parked.rt.sched.parked_count);
    }
};

test "closing a listener from a fiber wakes a parked accept with SocketNotListening" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var parked: Parked = undefined;
    try parked.start();
    defer parked.rt.deinit();

    const io = parked.rt.io();
    var closing = io.async(close_server, .{ io, &parked.server });
    closing.await(io);
    try std.testing.expectError(error.SocketNotListening, parked.accepting.await(io));
    try expect_clean(&parked.rt, 0);
    // The woken accept did not touch the fd number again: a new listener works at once.
    var again = io.async(listen_loopback, .{io});
    var server = try again.await(io);
    defer server.deinit(io);

    try std.testing.expectEqual(@as(u32, 1), parked.rt.sockets.count());
}

test "closing a listener off the carrier leaves the fd to the woken accept" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var parked: Parked = undefined;
    try parked.start();
    defer parked.rt.deinit();

    const io = parked.rt.io();
    parked.server.deinit(io); // Not a fiber: the carrier is idle, a waiter is parked.
    // The slot lingers, closing, until the waiter has run on the carrier.
    try std.testing.expectEqual(@as(u32, 1), parked.rt.sockets.count());
    try std.testing.expectError(error.SocketNotListening, parked.accepting.await(io));
    try expect_clean(&parked.rt, 0);
}

fn close_after_start(io: Io, server: *Server, go: *std.atomic.Value(bool)) void {
    while (!go.load(.acquire)) std.atomic.spinLoopHint();
    server.deinit(io);
}

test "a close from another thread races a parked accept on the running carrier" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var parked: Parked = undefined;
    try parked.start();
    defer parked.rt.deinit();

    const io = parked.rt.io();
    var go: std.atomic.Value(bool) = .init(false);
    const closer = try std.Thread.spawn(.{}, close_after_start, .{ io, &parked.server, &go });
    go.store(true, .release);
    // The await runs the carrier, idle in the poller, while the thread closes.
    try std.testing.expectError(error.SocketNotListening, parked.accepting.await(io));
    closer.join();
    try expect_clean(&parked.rt, 0);
}

fn connect_from_thread(io: Io, address: Address) void {
    const stream = address.connect(io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

test "an accept off a fiber blocks in poll and registers the peer" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try fixtures.init_runtime_sockets(std.testing.allocator, .forward, 8, 1, 4);
    defer rt.deinit();

    const io = rt.io();
    var listening = io.async(listen_loopback, .{io});
    var server = try listening.await(io);
    defer server.deinit(io);

    // A pending connection: the first accept finds it without waiting.
    const early = try server.socket.address.connect(rt.baselineIo(), .{ .mode = .stream });
    defer early.close(rt.baselineIo());

    const first = try server.accept(io);
    defer first.close(io);

    try std.testing.expectEqual(@as(u32, 2), rt.sockets.count());
    // Nothing pending: the accept waits in poll(2) until a thread connects.
    const caller = try std.Thread.spawn(.{}, connect_from_thread, .{
        rt.baselineIo(), server.socket.address,
    });
    defer caller.join();

    const second = try server.accept(io);
    defer second.close(io);

    try std.testing.expectEqual(@as(u32, 3), rt.sockets.count());
}

fn bind_scenario(io: Io, rt: *Runtime) !void {
    const any_port: Address = .{ .ip4 = .loopback(0) };
    const socket = try any_port.bind(io, .{ .mode = .dgram });
    defer socket.close(io);

    try std.testing.expect(socket.address.getPort() != 0);
    if (evented) try std.testing.expectEqual(@as(u32, 1), rt.sockets.count());
}

test "a datagram bind in a fiber is entered in the registry and leaves it on close" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    const io = rt.io();
    var future = io.async(bind_scenario, .{ io, &rt });
    try future.await(io);
    if (evented) try expect_clean(&rt, 0);
}

fn unix_scenario(io: Io, path: []const u8, rt: *Runtime, peer: *Address) !void {
    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    var accepting = io.async(accept_keep, .{ io, &server });
    var connecting = io.async(unix_connect, .{ io, address });
    const client = try connecting.await(io);
    defer client.close(io);

    const served = try accepting.await(io);
    defer served.close(io);

    peer.* = served.socket.address;
    if (evented) try std.testing.expectEqual(@as(u32, 3), rt.sockets.count());
}

fn unix_connect(io: Io, address: Io.net.UnixAddress) Io.net.UnixAddress.ConnectError!Io.net.Stream {
    return address.connect(io);
}

test "a Unix listener accepts a Unix connect; the peer reads as loopback port 0" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/sirocco-net-{d}.sock", .{
        std.c.getpid(),
    });
    Io.Dir.deleteFileAbsolute(rt.baselineIo(), path) catch {};
    defer Io.Dir.deleteFileAbsolute(rt.baselineIo(), path) catch {};

    const io = rt.io();
    var peer: Address = .{ .ip4 = .{ .bytes = .{ 1, 2, 3, 4 }, .port = 9 } };
    var future = io.async(unix_scenario, .{ io, path, &rt, &peer });
    try future.await(io);
    // `Io.Threaded` reports a non-IP peer this way; the native slot matches it.
    try std.testing.expect(peer.eql(&.{ .ip4 = .loopback(0) }));
    if (evented) try expect_clean(&rt, 0);
}

fn listen_keep(io: Io) Address.ListenError!Server {
    return listen_loopback(io);
}

test "a recycled fd number replaces the stale registry entry" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try fixtures.init_runtime_sockets(std.testing.allocator, .forward, 8, 1, 4);
    defer rt.deinit();

    const io = rt.io();
    var first_future = io.async(listen_keep, .{io});
    const first = try first_future.await(io);
    try std.testing.expectEqual(@as(u32, 1), rt.sockets.count());
    // Closed behind the runtime's back (through the baseline), as a foreign owner could.
    first.socket.close(rt.baselineIo());

    var second_future = io.async(listen_keep, .{io});
    var second = try second_future.await(io);
    defer second.deinit(io);

    const same = second.socket.handle == first.socket.handle;
    try std.testing.expectEqual(@as(u32, if (same) 1 else 2), rt.sockets.count());
    try std.testing.expect(!rt.sched.armed_any());
}

fn two_waiters(cancel_first: enum { head, tail }) !void {
    var rt = try fixtures.init_runtime_sockets(std.testing.allocator, .forward, 8, 1, 4);
    defer rt.deinit();

    const io = rt.io();
    var listening = io.async(listen_loopback, .{io});
    var server = try listening.await(io);
    defer server.deinit(io);

    var tail = io.async(accept_close, .{ io, &server }); // Joins first: the list's tail.
    var head = io.async(accept_close, .{ io, &server });
    try std.testing.expectEqual(@as(u32, 2), rt.sched.parked_count);

    const leaving, const staying = switch (cancel_first) {
        .head => .{ &head, &tail },
        .tail => .{ &tail, &head },
    };
    try std.testing.expectError(error.Canceled, leaving.cancel(io));
    // One waiter is left, so the pair stays armed and a connect reaches it.
    try std.testing.expect(rt.sched.armed_any());
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    var connecting = io.async(connect_close, .{ io, server.socket.address });
    try connecting.await(io);
    try staying.await(io);
    try std.testing.expect(!rt.sched.armed_any());
}

test "canceling the head of two parked accepts keeps the other armed" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    try two_waiters(.head);
}

test "canceling the tail of two parked accepts keeps the other armed" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    try two_waiters(.tail);
}

fn listen_backlog_one(io: Io) Address.ListenError!Server {
    const any_port: Address = .{ .ip4 = .loopback(0) };
    return any_port.listen(io, .{ .reuse_address = true, .kernel_backlog = 1 });
}

test "canceling connects still in progress closes their sockets and disarms" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try fixtures.init_runtime_sockets(std.testing.allocator, .forward, 32, 1, 32);
    defer rt.deinit();

    const io = rt.io();
    var listening = io.async(listen_backlog_one, .{io});
    var server = try listening.await(io);
    defer server.deinit(io);

    // Nobody accepts: once the kernel's queue is full the handshake of a connect stays pending.
    var futures: [16]Io.Future(Address.ConnectError!void) = undefined;
    for (&futures) |*future| future.* = io.async(connect_close, .{ io, server.socket.address });
    if (rt.sched.parked_count == 0) return error.SkipZigTest; // The kernel queued every one.

    for (&futures) |*future| future.cancel(io) catch |err| switch (err) {
        error.Canceled, error.ConnectionRefused, error.Timeout => {},
        else => return err,
    };
    try expect_clean(&rt, 1);
}

fn is_blocking(fd: std.posix.fd_t) bool {
    const status = std.c.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
    std.debug.assert(status >= 0);
    const flags: std.posix.O = @bitCast(@as(u32, @intCast(status)));
    return !flags.NONBLOCK;
}

fn overflow_scenario(io: Io, rt: *Runtime) !void {
    var server = try listen_loopback(io);
    defer server.deinit(io);

    var accepting = io.async(accept_keep, .{ io, &server });
    var connecting = io.async(connect_to, .{ io, server.socket.address });
    const client = try connecting.await(io);
    defer client.close(io);

    const served = try accepting.await(io);
    defer served.close(io);

    // Only the listener holds the one slot; the others are blocking, offload-served sockets.
    try std.testing.expectEqual(@as(u32, 1), rt.sockets.count());
    try std.testing.expect(is_blocking(served.socket.handle));
    try std.testing.expect(is_blocking(client.socket.handle));
    try std.testing.expect(!is_blocking(server.socket.handle));
}

test "accept and connect overflow of a full registry yield blocking sockets" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try fixtures.init_runtime_sockets(std.testing.allocator, .forward, 8, 2, 1);
    defer rt.deinit();

    const io = rt.io();
    var future = io.async(overflow_scenario, .{ io, &rt });
    try future.await(io);
    try expect_clean(&rt, 0);
}
