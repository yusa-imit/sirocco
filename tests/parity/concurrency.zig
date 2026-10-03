//! Parity and behaviour tests for the four future-producing slots (plan 002 item 5): `async`,
//! `concurrent`, `await`, `cancel`.
//!
//! Value-returning calls run through `harness.expectSameResult` against the embedded
//! `Io.Threaded`. Scheduling facts that `Io.Threaded` does not share (a started task runs lazily
//! on a fiber, in FIFO order, exhaustion runs a task inline, `concurrent` is unavailable) are
//! asserted on `rt.io()` alone, because the contract permits either behaviour. Every test runs
//! under both `.forward` and `.fail`: the four slots are native, so `Io.failing`'s unreachable
//! `await`/`cancel` must never be reached. The runtime's allocator is `std.testing.allocator`
//! (or a `FailingAllocator` over it), so a leaked task record fails the test.

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");

const modes = [_]Runtime.Unimplemented{ .forward, .fail };

// Fibers exist only where the switch assembly does; elsewhere the slots stay forwarded and the
// scheduling facts below do not apply.
const fibers_supported = Runtime.fibers_supported;

fn mul_add(a: u32, b: u32) u32 {
    return a * 3 + b;
}

fn async_await_mul_add(io: Io, a: u32, b: u32) u32 {
    var future = io.async(mul_add, .{ a, b });
    return future.await(io);
}

fn checked_half(value: u32) error{Odd}!u32 {
    if (value % 2 != 0) return error.Odd;
    return value / 2;
}

fn async_await_checked_half(io: Io, value: u32) error{Odd}!u32 {
    var future = io.async(checked_half, .{value});
    return future.await(io);
}

fn nothing() void {}

fn async_await_void(io: Io) void {
    var future = io.async(nothing, .{});
    future.await(io);
}

test "async + await matches the baseline for values, errors and void" {
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        try harness.expectSameResult(&rt, async_await_mul_add, .{ 7, 5 });
        try harness.expectSameResult(&rt, async_await_mul_add, .{ 0, 0 });
        try harness.expectSameResult(&rt, async_await_checked_half, .{10});
        try harness.expectSameResult(&rt, async_await_checked_half, .{7});
        try harness.expectSameResult(&rt, async_await_void, .{});
    }
}

const Wide = struct { lanes: [4]u64 align(64) };
const Mid = struct { lanes: [2]u64 align(32) };

fn fold_wide(wide: Wide, salt: u64) Mid {
    return .{ .lanes = .{ wide.lanes[0] + wide.lanes[1] + salt, wide.lanes[2] ^ wide.lanes[3] } };
}

fn async_await_fold(io: Io, wide: Wide, salt: u64) Mid {
    var future = io.async(fold_wide, .{ wide, salt });
    return future.await(io);
}

test "over-aligned context and result survive the task record" {
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const wide: Wide = .{ .lanes = .{ 1, 2, 0xf0f0, 0x0ff0 } };
        try harness.expectSameResult(&rt, async_await_fold, .{ wide, 100 });
    }
}

fn chain(io: Io, depth: u32, seed: u32) u32 {
    if (depth == 0) return seed;
    var next = io.async(chain, .{ io, depth - 1, seed *% 31 +% 7 });
    return next.await(io) +% depth;
}

fn fib(io: Io, n: u32) u32 {
    if (n < 2) return n;
    var left = io.async(fib, .{ io, n - 1 });
    const right = fib(io, n - 2);
    return left.await(io) + right;
}

test "a chain of three tasks agrees with the baseline" {
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        try harness.expectSameResult(&rt, chain, .{ 3, 1 });
        try harness.expectSameResult(&rt, chain, .{ 0, 9 });
    }
}

test "nested async and await from inside fibers: fib(10)" {
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        try std.testing.expectEqual(@as(u32, 55), fib(rt.io(), 10));
    }
}

test "fiber exhaustion falls back to inline execution and results stay right" {
    for (modes) |mode| {
        // 2 fibers for a fib(10) tree of 177 calls: nearly every `async` runs inline.
        var rt = try fixtures.init_runtime_in(std.testing.allocator, mode, 2);
        defer rt.deinit();

        try std.testing.expectEqual(@as(u32, 55), fib(rt.io(), 10));
        try std.testing.expectEqual(@as(u32, 21), fib(rt.io(), 8));
    }
}

const Trace = struct {
    ids: [16]u32,
    len: u32,

    fn init() Trace {
        return .{ .ids = @splat(0), .len = 0 };
    }

    fn push(trace: *Trace, id: u32) void {
        trace.ids[trace.len] = id;
        trace.len += 1;
    }

    fn slice(trace: *const Trace) []const u32 {
        return trace.ids[0..trace.len];
    }
};

fn traced_leaf(trace: *Trace, id: u32) u32 {
    trace.push(id);
    return id * 2;
}

fn traced_parent(io: Io, trace: *Trace) u32 {
    trace.push(1);
    var child = io.async(traced_leaf, .{ trace, 10 });
    trace.push(2); // The child is lazy: it runs only once this fiber parks in `await`.
    const value = child.await(io);
    trace.push(3);
    return value;
}

fn run_traced_parent(mode: Runtime.Unimplemented, trace: *Trace) !u32 {
    var rt = try fixtures.init_runtime(mode);
    defer rt.deinit();

    const io = rt.io();
    var future = io.async(traced_parent, .{ io, trace });
    // Nothing runs until the first `await` drives the scheduler.
    try std.testing.expectEqual(@as(u32, 0), trace.len);
    return future.await(io);
}

test "interleaving is deterministic: lazy start, park in await, FIFO resume" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var first = Trace.init();
        var second = Trace.init();
        try std.testing.expectEqual(@as(u32, 20), try run_traced_parent(mode, &first));
        try std.testing.expectEqual(@as(u32, 20), try run_traced_parent(mode, &second));
        try std.testing.expectEqualSlices(u32, &.{ 1, 2, 10, 3 }, first.slice());
        try std.testing.expectEqualSlices(u32, first.slice(), second.slice());
    }
}

test "spawned tasks run in spawn order when the first await drives the scheduler" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var trace = Trace.init();
        var futures: [4]Io.Future(u32) = undefined;
        for (&futures, 0..) |*future, id| {
            future.* = io.async(traced_leaf, .{ &trace, @as(u32, @intCast(id)) });
        }
        try std.testing.expectEqual(@as(u32, 0), trace.len);
        // Awaiting the last future still runs every earlier task first.
        try std.testing.expectEqual(@as(u32, 6), futures[3].await(io));
        try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, trace.slice());
        for (futures[0..3], 0..) |*future, id| {
            try std.testing.expectEqual(@as(u32, @intCast(id)) * 2, future.await(io));
        }
    }
}

test "exhaustion runs the overflow inline, at the call, and returns no future" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime_in(std.testing.allocator, mode, 2);
        defer rt.deinit();

        const io = rt.io();
        var trace = Trace.init();
        var futures: [5]Io.Future(u32) = undefined;
        for (&futures, 0..) |*future, id| {
            future.* = io.async(traced_leaf, .{ &trace, @as(u32, @intCast(id)) });
        }
        // Tasks 0 and 1 hold the two fibers; 2, 3 and 4 already ran inside `async`.
        try std.testing.expect(futures[0].any_future != null);
        try std.testing.expect(futures[1].any_future != null);
        for (futures[2..]) |future| try std.testing.expect(future.any_future == null);
        try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4 }, trace.slice());

        for (&futures, 0..) |*future, id| {
            try std.testing.expectEqual(@as(u32, @intCast(id)) * 2, future.await(io));
        }
        try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4, 0, 1 }, trace.slice());
    }
}

fn concurrent_attempt(io: Io) Io.ConcurrentError!u32 {
    var future = try io.concurrent(mul_add, .{ 1, 2 });
    return future.await(io);
}

test "concurrent is unavailable on a single carrier" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        // Permitted by `Io.ConcurrentError`: "to the Io implementation not supporting
        // concurrency". `Io.Threaded` succeeds, hence the `divergent` entry in slots.zig.
        try std.testing.expectError(error.ConcurrencyUnavailable, concurrent_attempt(rt.io()));
        try std.testing.expectEqual(@as(u32, 5), try concurrent_attempt(rt.baselineIo()));
    }
}

test "cancel completes the task and delivers its result" {
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var trace = Trace.init();
        var future = io.async(traced_leaf, .{ &trace, 21 });
        try std.testing.expectEqual(@as(u32, 42), future.cancel(io));
        // The request flag is not yet observable (item 6), so the task ran to completion.
        try std.testing.expectEqualSlices(u32, &.{21}, trace.slice());
    }
}

fn cancelling_parent(io: Io, trace: *Trace) u32 {
    var child = io.async(traced_leaf, .{ trace, 4 });
    trace.push(1);
    return child.cancel(io) + 1;
}

test "cancel from inside a fiber parks until the child finishes" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var trace = Trace.init();
        var future = io.async(cancelling_parent, .{ io, &trace });
        try std.testing.expectEqual(@as(u32, 9), future.await(io));
        try std.testing.expectEqualSlices(u32, &.{ 1, 4 }, trace.slice());
    }
}

test "no allocation beyond the runtime's, and nothing leaks, after await or cancel" {
    if (!fibers_supported) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var rt = try fixtures.init_runtime_in(failing.allocator(), .forward, 8);
    defer rt.deinit();

    const io = rt.io();
    // `io()` initialises the scheduler: fiber table and stack arena.
    try std.testing.expectEqual(@as(usize, 2), failing.alloc_index);
    const live_after_init = failing.allocated_bytes - failing.freed_bytes;
    var trace = Trace.init();
    var awaited = io.async(traced_leaf, .{ &trace, 1 });
    var cancelled = io.async(traced_leaf, .{ &trace, 2 });
    // One task record each (async still allocates per call, as Threaded does).
    try std.testing.expectEqual(@as(usize, 4), failing.alloc_index);
    _ = awaited.await(io);
    _ = cancelled.cancel(io);
    try std.testing.expectEqual(live_after_init, failing.allocated_bytes - failing.freed_bytes);
}

test "a failed task allocation runs the task inline" {
    if (!fibers_supported) return error.SkipZigTest;
    // Scheduler init takes allocations 0 and 1; the first task record is allocation 2.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var rt = try fixtures.init_runtime_in(failing.allocator(), .forward, 4);
    defer rt.deinit();

    const io = rt.io();
    var trace = Trace.init();
    var future = io.async(traced_leaf, .{ &trace, 5 });
    try std.testing.expect(future.any_future == null);
    try std.testing.expectEqualSlices(u32, &.{5}, trace.slice());
    try std.testing.expectEqual(@as(u32, 10), future.await(io));
}

test "a failed scheduler allocation degrades to inline async and refuses concurrent" {
    if (!fibers_supported) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var rt = try fixtures.init_runtime_in(failing.allocator(), .forward, 4);
    defer rt.deinit();

    const io = rt.io();
    try std.testing.expectEqual(Runtime.SchedState.unavailable, rt.sched_state);
    var trace = Trace.init();
    var future = io.async(traced_leaf, .{ &trace, 6 });
    try std.testing.expect(future.any_future == null);
    try std.testing.expectEqual(@as(u32, 12), future.await(io));
    try std.testing.expectError(error.ConcurrencyUnavailable, concurrent_attempt(io));
}

fn model_step(seed: u64) u64 {
    return seed *% 6364136223846793005 +% 1442695040888963407;
}

fn model_task(io: Io, seed: u64, depth: u32) u64 {
    var acc = seed;
    for (0..(seed % 17) + 1) |_| acc = model_step(acc);
    if (depth > 0) {
        var child = io.async(model_task, .{ io, acc, depth - 1 });
        acc ^= child.await(io);
    }
    return acc;
}

fn model_reference(seed: u64, depth: u32) u64 {
    var acc = seed;
    for (0..(seed % 17) + 1) |_| acc = model_step(acc);
    if (depth > 0) acc ^= model_reference(acc, depth - 1);
    return acc;
}

test "seeded model: random task trees awaited in random order match a trivial reference" {
    const tasks_max = 48;
    const rounds_max = 4;
    for (modes) |mode| {
        // Fewer fibers than tasks, so every round mixes lazy and inline tasks.
        var rt = try fixtures.init_runtime_in(std.testing.allocator, mode, 16);
        defer rt.deinit();

        const io = rt.io();
        var prng: std.Random.DefaultPrng = .init(0x5112_0cc0_0000_0005);
        const random = prng.random();
        for (0..rounds_max) |_| {
            var seeds: [tasks_max]u64 = undefined;
            var depths: [tasks_max]u32 = undefined;
            var futures: [tasks_max]Io.Future(u64) = undefined;
            var order: [tasks_max]u32 = undefined;
            for (0..tasks_max) |index| {
                seeds[index] = random.int(u64);
                depths[index] = random.uintLessThan(u32, 4);
                order[index] = @intCast(index);
                futures[index] = io.async(model_task, .{ io, seeds[index], depths[index] });
            }
            random.shuffle(u32, &order);
            for (order) |index| {
                const expected = model_reference(seeds[index], depths[index]);
                try std.testing.expectEqual(expected, futures[index].await(io));
            }
        }
    }
}

test "slots are native exactly where fibers exist" {
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    const vtable = rt.io().vtable;
    const baseline = rt.baselineIo().vtable;
    try std.testing.expectEqual(fibers_supported, vtable.async != baseline.async);
    try std.testing.expectEqual(fibers_supported, vtable.concurrent != baseline.concurrent);
    try std.testing.expectEqual(fibers_supported, vtable.await != baseline.await);
    try std.testing.expectEqual(fibers_supported, vtable.cancel != baseline.cancel);
}
