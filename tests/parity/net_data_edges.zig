//! Edge tests of the data-path socket slots (plan 004 item 5): `netShutdown` parity, every error
//! variant the slots can provoke on loopback, calls off a fiber and on handles the registry does
//! not know, and the rule that the data path allocates nothing after `init`. Building blocks
//! (pairs, raw slot calls, error kinds) come from `net_data.zig`; the same parity rules apply.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");
const data = @import("net_data.zig");

const fibers_supported = Runtime.fibers_supported;
const evented = fixtures.backend != .threaded;

const Address = Io.net.IpAddress;
const Stream = Io.net.Stream;
const Handle = Io.net.Socket.Handle;
const Kind = data.Kind;
const Pair = data.Pair;
const init_rt = data.init_rt;
const connect_pair = data.connect_pair;
const pair_close = data.pair_close;
const raw_read = data.raw_read;
const raw_write = data.raw_write;
const raw_shutdown = data.raw_shutdown;
const read_some = data.read_some;
const kind_of_result = data.kind_of_result;

// ---------------------------------------------------------------- (5) shutdown parity

const ShutdownOutcome = struct {
    shutdown: Kind,
    self_read: ?usize,
    peer_read: ?usize,
    write: Kind,
};

fn shutdown_scenario(io: Io, how: Io.net.ShutdownHow) !ShutdownOutcome {
    const pair = try connect_pair(io);
    defer pair_close(io, pair);

    const client = pair.client.socket.handle;
    const served = pair.served.socket.handle;
    var out: ShutdownOutcome = .{
        .shutdown = kind_of_result(raw_shutdown(io, client, how)),
        .self_read = null,
        .peer_read = null,
        .write = .none,
    };
    if (how != .send) out.self_read = try read_some(io, client);
    out.write = kind_of_result(raw_write(io, client, "x"));
    out.peer_read = try read_some(io, served);
    return out;
}

test "shutdown of the send side gives the peer EOF and the writer an error, as the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, shutdown_scenario, .{Io.net.ShutdownHow.send});
    const out = try shutdown_scenario(rt.io(), .send);
    try std.testing.expectEqual(Kind.none, out.shutdown);
    try std.testing.expectEqual(@as(?usize, 0), out.peer_read);
    try std.testing.expectEqual(Kind.SocketUnconnected, out.write);
}

test "shutdown of the receive side makes the next read EOF, as the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, shutdown_scenario, .{Io.net.ShutdownHow.recv});
    const out = try shutdown_scenario(rt.io(), .recv);
    try std.testing.expectEqual(Kind.none, out.shutdown);
    try std.testing.expectEqual(@as(?usize, 0), out.self_read);
    try std.testing.expectEqual(Kind.none, out.write);
    try std.testing.expectEqual(@as(?usize, 1), out.peer_read);
}

test "shutdown of both sides gives EOF on both ends, as the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, shutdown_scenario, .{Io.net.ShutdownHow.both});
    const out = try shutdown_scenario(rt.io(), .both);
    try std.testing.expectEqual(Kind.none, out.shutdown);
    try std.testing.expectEqual(@as(?usize, 0), out.self_read);
    try std.testing.expectEqual(@as(?usize, 0), out.peer_read);
    try std.testing.expectEqual(Kind.SocketUnconnected, out.write);
}

fn shutdown_wakes_reader(io: Io, how: Io.net.ShutdownHow, rt: *Runtime) !usize {
    const pair = try connect_pair(io);
    defer pair_close(io, pair);

    var reading = io.async(read_some, .{ io, pair.served.socket.handle });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    try raw_shutdown(io, pair.client.socket.handle, how);
    return reading.await(io);
}

test "a shutdown from another fiber wakes a parked reader with EOF" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    var future = io.async(shutdown_wakes_reader, .{ io, Io.net.ShutdownHow.send, &rt });
    try std.testing.expectEqual(@as(usize, 0), try future.await(io));
    try std.testing.expect(!rt.sched.armed_any());
}

// ---------------------------------------------------------------- (6) declared error variants

const Linger = extern struct { onoff: c_int, linger: c_int };

fn abortive_close(io: Io, stream: Stream) void {
    const linger: Linger = .{ .onoff = 1, .linger = 0 };
    const bytes = std.mem.asBytes(&linger);
    const rc = posix.system.setsockopt(
        stream.socket.handle,
        posix.SOL.SOCKET,
        posix.SO.LINGER,
        bytes,
        @sizeOf(Linger),
    );
    std.debug.assert(posix.errno(rc) == .SUCCESS);
    stream.close(io);
}

const ResetOutcome = struct { read: Kind, write: Kind };

fn reset_scenario(io: Io) !ResetOutcome {
    const pair = try connect_pair(io);
    defer pair.client.close(io);

    abortive_close(io, pair.served);
    try io.sleep(.fromMilliseconds(40), .awake); // The RST reaches the client.
    return .{
        .read = kind_of_result(read_some(io, pair.client.socket.handle)),
        .write = kind_of_result(raw_write(io, pair.client.socket.handle, "x")),
    };
}

test "a read after the peer reset is ConnectionResetByPeer, as the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, reset_scenario, .{});
    const out = try reset_scenario(rt.io());
    try std.testing.expectEqual(Kind.ConnectionResetByPeer, out.read);
    try std.testing.expect(out.write != .none);
}

const UnconnectedOutcome = struct { read: Kind, write: Kind, shutdown: Kind };

fn unconnected_scenario(io: Io) !UnconnectedOutcome {
    const any_port: Address = .{ .ip4 = .loopback(0) };
    const socket = try any_port.bind(io, .{ .mode = .stream });
    defer socket.close(io);

    return .{
        .read = kind_of_result(read_some(io, socket.handle)),
        .write = kind_of_result(raw_write(io, socket.handle, "x")),
        .shutdown = kind_of_result(raw_shutdown(io, socket.handle, .both)),
    };
}

test "read, write and shutdown on an unconnected stream are SocketUnconnected, as the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, unconnected_scenario, .{});
    const out = try unconnected_scenario(rt.io());
    try std.testing.expectEqual(Kind.SocketUnconnected, out.read);
    try std.testing.expectEqual(Kind.SocketUnconnected, out.write);
    try std.testing.expectEqual(Kind.SocketUnconnected, out.shutdown);
}

// ---------------------------------------------------------------- (7) off a fiber, unregistered

fn write_from_thread(io: Io, handle: Handle) void {
    io.sleep(.fromMilliseconds(40), .awake) catch return;
    _ = raw_write(io, handle, "late") catch return;
}

test "a registered socket works off a fiber, and a read there waits in poll" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    var making = io.async(connect_pair, .{io});
    const pair = try making.await(io);
    defer pair_close(io, pair);

    // Off a fiber: the data is there at once.
    try std.testing.expectEqual(@as(usize, 2), try raw_write(io, pair.client.socket.handle, "hi"));
    try std.testing.expectEqual(@as(usize, 2), try read_some(io, pair.served.socket.handle));
    // Nothing buffered: the read waits until a thread writes.
    const writer = try std.Thread.spawn(.{}, write_from_thread, .{
        rt.baselineIo(), pair.client.socket.handle,
    });
    defer writer.join();

    try std.testing.expectEqual(@as(usize, 4), try read_some(io, pair.served.socket.handle));
    try raw_shutdown(io, pair.client.socket.handle, .send);
    try std.testing.expectEqual(@as(usize, 0), try read_some(io, pair.served.socket.handle));
}

fn foreign_scenario(io: Io, pair: Pair) !usize {
    const wrote = try raw_write(io, pair.client.socket.handle, "world");
    try std.testing.expectEqual(@as(usize, 5), wrote);
    const got = try read_some(io, pair.served.socket.handle);
    try raw_shutdown(io, pair.client.socket.handle, .send);
    try std.testing.expectEqual(@as(usize, 0), try read_some(io, pair.served.socket.handle));
    return got;
}

test "a handle the registry does not know is served through the baseline route" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const base = rt.baselineIo();
    const pair = try connect_pair(base);
    defer pair_close(base, pair);

    const io = rt.io();
    var future = io.async(foreign_scenario, .{ io, pair });
    try std.testing.expectEqual(@as(usize, 5), try future.await(io));
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

// ---------------------------------------------------------------- (8) allocation

const AllocProbe = struct { before: usize, after: usize };

fn data_loop(io: Io, pair: Pair, failing: *const std.testing.FailingAllocator) !AllocProbe {
    const before = failing.alloc_index;
    var first: [64]u8 = undefined;
    var second: [64]u8 = undefined;
    var bufs = [_][]u8{ &first, &second };
    const parts = [_][]const u8{ "abc", "xy" };
    for (0..64) |_| {
        const header = "hdr";
        const client = pair.client.socket.handle;
        const wrote = try io.vtable.netWrite(io.userdata, client, header, &parts, 3);
        try std.testing.expect(wrote > 0);
        _ = try raw_read(io, pair.served.socket.handle, &bufs);
    }
    try raw_shutdown(io, pair.client.socket.handle, .send);
    return .{ .before = before, .after = failing.alloc_index };
}

test "the data path allocates nothing after init, parked or not" {
    if (!fibers_supported) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var rt = try fixtures.init_runtime_in(failing.allocator(), .forward, 8);
    defer rt.deinit();

    const io = rt.io();
    var making = io.async(connect_pair, .{io});
    const pair = try making.await(io);
    defer pair_close(io, pair);

    var looping = io.async(data_loop, .{ io, pair, &failing });
    const probe = try looping.await(io);
    try std.testing.expectEqual(probe.before, probe.after);

    var reading = io.async(read_some, .{ io, pair.client.socket.handle });
    const started = failing.alloc_index; // Includes the task record of `reading`.
    _ = try raw_write(io, pair.served.socket.handle, "wake");
    try std.testing.expectEqual(@as(usize, 4), try reading.await(io));
    try std.testing.expectEqual(started, failing.alloc_index);
}
