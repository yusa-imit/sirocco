//! Tests of `Options.carriers` (ADR 0004 section 1): the peers are built, started and torn down
//! by the runtime, while every task still runs on carrier 0 until placement lands (plan 005 items
//! 7 and 8). Built on `.threaded` and `.auto` so both idle paths cover the peer threads.

const std = @import("std");
const Runtime = @import("runtime.zig");

const assert = @import("stdx.zig").assert;

const fail_index_max: usize = 64;

fn options(backend: Runtime.Backend, carriers: u32) Runtime.Options {
    assert(carriers >= 1);
    assert(carriers <= Runtime.carriers_max);
    return .{
        .backend = backend,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
        .carriers = carriers,
        .fibers_max = 4,
        .batch_ops_max = 8,
        .fiber_stack_size = 128 * 1024,
        .offload_threads = 2,
        .sockets_max = 8,
    };
}

fn add(a: u32, b: u32) u32 {
    return a + b;
}

test "carriers_max is the width of the armed mask" {
    try std.testing.expectEqual(@as(u32, 64), Runtime.carriers_max);
    try std.testing.expect(Runtime.carriers_max >= 1);
}

test "carriers = 1 builds no peer and spawns no thread" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, options(.auto, 1));
    defer rt.deinit();

    try std.testing.expectEqual(@as(usize, 0), rt.peers.len);
    const rio = rt.io();
    var future = rio.async(add, .{ 1, 2 });
    try std.testing.expectEqual(@as(u32, 3), future.await(rio));
    try std.testing.expectEqual(@as(usize, 0), rt.peers.len);
    try std.testing.expectEqual(Runtime.SchedState.ready, rt.sched_state);
}

test "carriers = 3 runs async on carrier 0 and tears the peers down without a leak" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    const backends = [_]Runtime.Backend{ .threaded, .auto };
    for (backends) |backend| {
        var rt: Runtime = try .init(std.testing.allocator, options(backend, 3));
        defer rt.deinit();

        // `init` only allocates the block; the threads start at the first `io()`.
        try std.testing.expectEqual(@as(usize, 2), rt.peers.len);
        for (rt.peers) |*peer| try std.testing.expect(peer.thread == null);

        const rio = rt.io();
        try std.testing.expectEqual(Runtime.SchedState.ready, rt.sched_state);
        var future = rio.async(add, .{ 40, 2 });
        try std.testing.expectEqual(@as(u32, 42), future.await(rio));

        try std.testing.expectEqual(@as(usize, 2), rt.peers.len);
        for (rt.peers) |*peer| {
            try std.testing.expect(peer.thread != null);
            try std.testing.expectEqual(@as(u32, 0), peer.sched.live_count);
        }
        try std.testing.expectEqual(@as(u32, 0), rt.sched.live_count);
    }
}

test "allocation failure at any point of a two-carrier start never leaks" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var succeeded = false;
    for (0..fail_index_max) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var rt = Runtime.init(failing.allocator(), options(.threaded, 2)) catch |err| switch (err) {
            error.OutOfMemory => continue,
            error.BackendUnavailable => return error.TestUnexpectedResult,
        };
        defer rt.deinit();

        const rio = rt.io();
        try std.testing.expect(rt.sched_state != .pending);
        var future = rio.async(add, .{ 1, 1 });
        try std.testing.expectEqual(@as(u32, 2), future.await(rio));
        if (rt.sched_state == .ready) {
            try std.testing.expectEqual(@as(usize, 1), rt.peers.len);
            try std.testing.expect(rt.peers[0].thread != null);
        } else {
            try std.testing.expectEqual(Runtime.SchedState.unavailable, rt.sched_state);
            for (rt.peers) |*peer| try std.testing.expect(peer.thread == null);
        }
        if (!failing.has_induced_failure) {
            succeeded = true;
            break;
        }
    }
    try std.testing.expect(succeeded);
}

test "each peer carrier knows its index and owns fibers that point home" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, options(.auto, 4));
    defer rt.deinit();

    const rio = rt.io();
    var future = rio.async(add, .{ 2, 3 });
    try std.testing.expectEqual(@as(u32, 5), future.await(rio));
    if (rt.sched_state != .ready) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, 0), rt.sched.index);
    for (rt.peers, 0..) |*peer, offset| {
        try std.testing.expectEqual(@as(u32, @intCast(offset + 1)), peer.sched.index);
        for (peer.sched.fibers) |*fiber| try std.testing.expectEqual(&peer.sched, fiber.home);
    }
}
