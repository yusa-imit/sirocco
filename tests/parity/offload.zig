//! Offload tests (plan 003 item 8, ADR 0002): the forwarded blocking slots run on the offload
//! pool while their fiber parks, so one blocked call no longer freezes the carrier.
//!
//! The loopback pair is the proof: fiber A `netAccept`s and fiber B `netConnectIp`s on one
//! `rt.io()`. On v0.3.0 A blocked the only carrier inside the kernel and B never ran. Everything
//! here uses `.forward`: under `.fail` the blocking slots are `Io.failing`'s and must stay so.
//! Sizing rule (ADR 0002): a call holds its worker until it returns, so an accept that waits on a
//! connect needs two workers; with one, the connect must be submitted first.

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const cancel = @import("cancel.zig");
const fixtures = @import("fixtures.zig");

const fibers_supported = Runtime.fibers_supported;

const Listener = struct {
    server: Io.net.Server,
    address: Io.net.IpAddress,

    fn open(io: Io) !Listener {
        const any_port: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try any_port.listen(io, .{ .reuse_address = true });
        return .{ .server = server, .address = server.socket.address };
    }
};

fn accept_one(io: Io, server: *Io.net.Server) Io.net.Server.AcceptError!Io.net.Stream {
    return server.accept(io);
}

fn connect_to(io: Io, address: Io.net.IpAddress) Io.net.IpAddress.ConnectError!Io.net.Stream {
    return address.connect(io, .{ .mode = .stream });
}

fn exchange_byte(io: Io, client: Io.net.Stream, served: Io.net.Stream) !void {
    var write_buffer: [8]u8 = @splat(0);
    var writer = client.writer(io, &write_buffer);
    try writer.interface.writeAll("x");
    try writer.interface.flush();

    var read_buffer: [8]u8 = @splat(0);
    var reader = served.reader(io, &read_buffer);
    const byte = try reader.interface.takeByte();
    try std.testing.expectEqual(@as(u8, 'x'), byte);
}

test "an accept and a connect on one runtime overlap instead of deadlocking" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try fixtures.init_runtime_pool(std.testing.allocator, .forward, 4, 2);
    defer rt.deinit();

    const io = rt.io();
    var listener = try Listener.open(io);
    defer listener.server.deinit(io);

    // The accept is submitted first and holds a worker until the connect arrives.
    var accepting = io.async(accept_one, .{ io, &listener.server });
    var connecting = io.async(connect_to, .{ io, listener.address });
    const client = try connecting.await(io);
    defer client.close(io);

    const served = try accepting.await(io);
    defer served.close(io);
    try exchange_byte(io, client, served);
}

test "one worker suffices when the connect is submitted before the accept" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try fixtures.init_runtime_pool(std.testing.allocator, .forward, 4, 1);
    defer rt.deinit();

    const io = rt.io();
    var listener = try Listener.open(io);
    defer listener.server.deinit(io);

    // The kernel completes the connect against the listen backlog, so the lone worker is free
    // again by the time the accept needs it. The reverse order is the sizing-rule deadlock.
    var connecting = io.async(connect_to, .{ io, listener.address });
    const client = try connecting.await(io);
    defer client.close(io);

    var accepting = io.async(accept_one, .{ io, &listener.server });
    const served = try accepting.await(io);
    defer served.close(io);
    try exchange_byte(io, client, served);
}

fn access_after_gate(io: Io, gate: *u32) Io.Dir.AccessError!void {
    cancel.gate_wait(io, gate);
    return Io.Dir.cwd().access(io, ".", .{});
}

test "a pending cancel is delivered before a blocking call is submitted" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    const io = rt.io();
    var gate: u32 = 0;
    var future = io.async(access_after_gate, .{ io, &gate });
    cancel.gate_open(io, &gate);
    try std.testing.expectError(error.Canceled, future.cancel(io));
}

fn access_protected(io: Io, gate: *u32) Io.Dir.AccessError!void {
    cancel.gate_wait(io, gate);
    _ = io.swapCancelProtection(.blocked);
    return Io.Dir.cwd().access(io, ".", .{});
}

test "blocked cancel protection lets the blocking call through despite a request" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    const io = rt.io();
    var gate: u32 = 0;
    var future = io.async(access_protected, .{ io, &gate });
    cancel.gate_open(io, &gate);
    try future.cancel(io);
}

test "an unrequested cancel lets the blocking call through" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    const io = rt.io();
    var gate: u32 = 0;
    var future = io.async(access_after_gate, .{ io, &gate });
    cancel.gate_open(io, &gate);
    try future.await(io);
}
