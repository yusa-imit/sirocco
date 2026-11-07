//! Tests of a socket closed from a fiber on a peer carrier (ADR 0004 sections 3 and 6, plan 005
//! item 7). The registry is shared but only carrier 0 arms the poller, so a close from a peer is
//! a close from "another thread": the waiters on carrier 0 are handed back with `.closing` and
//! the last one closes the fd. The closer is a fiber mailed to peer carrier 1. Waits on atomics
//! are bounded spins. Under `.threaded` there is no registry and the tests skip.

const std = @import("std");
const Io = std.Io;
const stdx = @import("stdx.zig");
const mail = @import("mail.zig");
const Runtime = @import("runtime.zig");
const Sched = @import("sched.zig");

const assert = stdx.assert;
const Address = Io.net.IpAddress;
const Server = Io.net.Server;

const spin_max: u32 = 20_000_000;

fn options() Runtime.Options {
    return .{
        .backend = .auto,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
        .carriers = 2,
        .fibers_max = 8,
        .batch_ops_max = 8,
        .fiber_stack_size = 128 * 1024,
        .offload_threads = 2,
        .sockets_max = 8,
    };
}

/// What the closer fiber on peer carrier 1 needs, and what it reports.
const Closer = struct {
    io: Io,
    server: *Server,
    ran_on_peer: bool,
    done: std.atomic.Value(bool),
};

fn close_entry(arg: ?*anyopaque) void {
    const closer: *Closer = @ptrCast(@alignCast(arg.?));
    const here = Sched.here().?;
    closer.ran_on_peer = here.index == 1;
    closer.server.deinit(closer.io);
    closer.done.store(true, .release);
}

fn listen_loopback(io: Io) Address.ListenError!Server {
    const any_port: Address = .{ .ip4 = .loopback(0) };
    return any_port.listen(io, .{ .reuse_address = true });
}

fn accept_close(io: Io, server: *Server) Server.AcceptError!void {
    const stream = try server.accept(io);
    stream.close(io);
}

fn close_server(io: Io, server: *Server) void {
    server.deinit(io);
}

fn spin_until(flag: *const std.atomic.Value(bool)) !void {
    for (0..spin_max) |_| {
        if (flag.load(.acquire)) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.NeverHappened;
}

test "a close from a fiber on a peer carrier wakes an accept parked on carrier 0" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, options());
    defer rt.deinit();

    const io = rt.io();
    if (!rt.sockets.enabled()) return error.SkipZigTest; // The registry is built by `io()`.
    var listening = io.async(listen_loopback, .{io});
    var server = try listening.await(io);
    var accepting = io.async(accept_close, .{ io, &server });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);

    var closer: Closer = .{
        .io = io,
        .server = &server,
        .ran_on_peer = false,
        .done = .init(false),
    };
    var close_mail = mail.Mail.init(close_entry, &closer);
    mail.post(&rt.peers[0].sched, rt.baselineIo(), &close_mail);
    // The await runs carrier 0 while the peer closes; the woken accept finishes the close.
    try std.testing.expectError(error.SocketNotListening, accepting.await(io));
    try spin_until(&closer.done);

    try std.testing.expect(closer.ran_on_peer);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
    try std.testing.expect(!rt.sched.armed_any());
}

test "a close from a fiber on a peer carrier with no waiter frees the slot at once" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, options());
    defer rt.deinit();

    const io = rt.io();
    if (!rt.sockets.enabled()) return error.SkipZigTest; // The registry is built by `io()`.
    var listening = io.async(listen_loopback, .{io});
    var server = try listening.await(io);
    try std.testing.expectEqual(@as(u32, 1), rt.sockets.count());

    var closer: Closer = .{
        .io = io,
        .server = &server,
        .ran_on_peer = false,
        .done = .init(false),
    };
    var close_mail = mail.Mail.init(close_entry, &closer);
    mail.post(&rt.peers[0].sched, rt.baselineIo(), &close_mail);
    try spin_until(&closer.done);

    try std.testing.expect(closer.ran_on_peer);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
    // The number is free again: a new listener works at once.
    var again = io.async(listen_loopback, .{io});
    var second = try again.await(io);
    var closing = io.async(close_server, .{ io, &second });
    closing.await(io);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}
