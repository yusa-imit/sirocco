//! Evented socket tests (plan 004 item 4, ADR 0003 section 3): `netListenIp`, `netBindIp`,
//! `netAccept`, `netConnectIp`, `netListenUnix`, `netConnectUnix` and `netSocketCreatePair` are
//! native on the evented backends: a would-block parks the fiber on the poller instead of holding
//! an offload worker. Under `.threaded` the same tests run the offloaded path.
//!
//! Parity compares `rt.io()` in a fiber against `rt.baselineIo()`; a socket made by one `Io` is
//! never handed to the other (a registered socket is non-blocking and owned by `rt.io()`). The
//! data path (`netRead`/`netWrite`) is item 5, so these tests exchange no bytes on registered
//! sockets; the registry-full test, whose sockets are blocking, does.

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");

const fibers_supported = Runtime.fibers_supported;
const evented = fixtures.backend != .threaded;

const Address = Io.net.IpAddress;

fn open_listener(io: Io, options: Address.ListenOptions) Address.ListenError!Io.net.Server {
    const any_port: Address = .{ .ip4 = .loopback(0) };
    return any_port.listen(io, options);
}

fn accept_one(io: Io, server: *Io.net.Server) Io.net.Server.AcceptError!Io.net.Stream {
    return server.accept(io);
}

fn connect_to(io: Io, address: Address) Address.ConnectError!Io.net.Stream {
    return address.connect(io, .{ .mode = .stream });
}

/// Listen, connect and accept inside one fiber; the outcome is the error or the addresses'
/// shape, which both `Io`s must agree on.
fn loopback_pair(io: Io) !struct { bool, bool, bool } {
    var server = try open_listener(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var accepting = io.async(accept_one, .{ io, &server });
    var connecting = io.async(connect_to, .{ io, server.socket.address });
    const client = try connecting.await(io);
    defer client.close(io);

    const served = try accepting.await(io);
    defer served.close(io);
    const listen_port_set = server.socket.address.getPort() != 0;
    // `connect` reports the local end, which is the peer address `accept` sees.
    const client_is_peer = client.socket.address.eql(&served.socket.address);
    const peer_is_loopback = served.socket.address == .ip4 and
        std.mem.eql(u8, &served.socket.address.ip4.bytes, &.{ 127, 0, 0, 1 });
    return .{ listen_port_set, client_is_peer, peer_is_loopback };
}

test "listen, connect and accept in a fiber match the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, loopback_pair, .{});
    const result = try loopback_pair(rt.io());
    try std.testing.expectEqual(@as(@TypeOf(result), .{ true, true, true }), result);
}

fn connect_closed(io: Io, address: Address) Address.ConnectError!void {
    const stream = try address.connect(io, .{ .mode = .stream });
    stream.close(io);
}

fn closed_port(io: Io) !Address {
    var server = try open_listener(io, .{});
    const address = server.socket.address;
    server.deinit(io);
    return address;
}

test "connecting to a closed port is ConnectionRefused, as on the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    // The port comes from the baseline, so no sirocco socket crosses over.
    const address = try closed_port(rt.baselineIo());
    try harness.expectSameResultInFiber(&rt, connect_closed, .{address});
    var future = rt.io().async(connect_closed, .{ rt.io(), address });
    try std.testing.expectError(error.ConnectionRefused, future.await(rt.io()));
}

fn listen_twice(io: Io) Address.ListenError!void {
    var first = try open_listener(io, .{});
    defer first.deinit(io);

    var second = try first.socket.address.listen(io, .{});
    second.deinit(io);
}

test "a second listen on a taken address is AddressInUse, as on the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, listen_twice, .{});
    var future = rt.io().async(listen_twice, .{rt.io()});
    try std.testing.expectError(error.AddressInUse, future.await(rt.io()));
}

const pairs_max: u32 = 64;

fn serve_pairs(io: Io, server: *Io.net.Server, served_count: *u32) !void {
    for (0..pairs_max) |_| {
        const stream = try server.accept(io);
        stream.close(io);
        served_count.* += 1;
    }
}

fn connect_pairs(io: Io, address: Address) !void {
    for (0..pairs_max) |_| {
        const stream = try address.connect(io, .{ .mode = .stream });
        stream.close(io);
    }
}

fn pairs_scenario(io: Io, served_count: *u32) !void {
    var server = try open_listener(io, .{ .reuse_address = true });
    defer server.deinit(io);

    // The accept parks first. With one offload worker an offloaded accept would hold it, and
    // the connects behind it could never run.
    var serving = io.async(serve_pairs, .{ io, &server, served_count });
    var connecting = io.async(connect_pairs, .{ io, server.socket.address });
    try connecting.await(io);
    try serving.await(io);
}

test "64 accept/connect pairs finish with a single offload worker" {
    if (!fibers_supported) return error.SkipZigTest;
    if (!evented) return error.SkipZigTest; // `.threaded` offloads: one worker would deadlock.
    var rt = try fixtures.init_runtime_sockets(std.testing.allocator, .forward, 8, 1, 32);
    defer rt.deinit();

    const io = rt.io();
    var served_count: u32 = 0;
    var future = io.async(pairs_scenario, .{ io, &served_count });
    try future.await(io);
    try std.testing.expectEqual(pairs_max, served_count);
}

fn accept_parked(io: Io, server: *Io.net.Server) Io.net.Server.AcceptError!void {
    const stream = try server.accept(io);
    stream.close(io);
}

fn listen_in_fiber(io: Io) Address.ListenError!Io.net.Server {
    return open_listener(io, .{});
}

test "a canceled parked accept returns Canceled and leaves the poller clean" {
    if (!fibers_supported) return error.SkipZigTest;
    if (!evented) return error.SkipZigTest; // An offloaded accept cannot be interrupted.
    var rt = try fixtures.init_runtime_sockets(std.testing.allocator, .forward, 8, 1, 8);
    defer rt.deinit();

    const io = rt.io();
    var listening = io.async(listen_in_fiber, .{io});
    var server = try listening.await(io);
    defer server.deinit(io);

    var accepting = io.async(accept_parked, .{ io, &server });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    try std.testing.expectError(error.Canceled, accepting.cancel(io));
    try std.testing.expect(!rt.sched.armed_any());
    // The listener still works: a connect is accepted afterwards.
    var again = io.async(accept_one, .{ io, &server });
    var connecting = io.async(connect_to, .{ io, server.socket.address });
    const client = try connecting.await(io);
    defer client.close(io);
    const served = try again.await(io);
    defer served.close(io);
}

fn full_registry_scenario(io: Io, registered: *u32, rt: *Runtime) !void {
    var server = try open_listener(io, .{ .reuse_address = true });
    defer server.deinit(io);

    // The listener took the only slot; the client and the accepted socket are foreign, blocking
    // and offloaded, so they can move bytes through the forwarded data path.
    var accepting = io.async(accept_one, .{ io, &server });
    var connecting = io.async(connect_to, .{ io, server.socket.address });
    const client = try connecting.await(io);
    defer client.close(io);

    const served = try accepting.await(io);
    defer served.close(io);
    registered.* = rt.sockets.count();

    var write_buffer: [8]u8 = @splat(0);
    var writer = client.writer(io, &write_buffer);
    try writer.interface.writeAll("x");
    try writer.interface.flush();
    var read_buffer: [8]u8 = @splat(0);
    var reader = served.reader(io, &read_buffer);
    try std.testing.expectEqual(@as(u8, 'x'), try reader.interface.takeByte());
}

test "a full registry serves the overflow through the offload path" {
    if (!fibers_supported) return error.SkipZigTest;
    if (!evented) return error.SkipZigTest; // `.threaded` has no registry.
    var rt = try fixtures.init_runtime_sockets(std.testing.allocator, .forward, 8, 2, 1);
    defer rt.deinit();

    const io = rt.io();
    var registered: u32 = 99;
    var future = io.async(full_registry_scenario, .{ io, &registered, &rt });
    try future.await(io);
    try std.testing.expectEqual(@as(u32, 1), registered);
}

fn pair_scenario(io: Io) Io.net.Socket.CreatePairError!void {
    const pair = try Io.net.Socket.createPair(io, .{});
    pair[0].close(io);
    pair[1].close(io);
}

// `Socket.createPair` only offers IP families, and no kernel serves `socketpair(AF_INET, ...)`:
// the call is an error everywhere. The baseline reports it through std's noisy
// `unexpectedErrno` (a stack dump), so parity is not run; the native slot must fail cleanly
// and must not leak a registry entry.
test "socketpair on an IP family fails cleanly and leaks no registry entry" {
    if (!fibers_supported) return error.SkipZigTest;
    if (!evented) return error.SkipZigTest;
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    const io = rt.io();
    var future = io.async(pair_scenario, .{io});
    try std.testing.expectError(error.Unexpected, future.await(io));
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}
