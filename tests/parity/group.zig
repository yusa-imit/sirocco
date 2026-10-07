//! Group-slot tests (plan 002 item 7): `groupAsync`, `groupConcurrent`, `groupAwait`,
//! `groupCancel` and `crashHandler`, the last of P0's 12 slots.
//!
//! Wait-all facts are compared against `Io.Threaded` (both `Io`s run the same group and must end
//! with the same count). Facts that need a cancel to land at a known point are asserted on
//! `rt.io()` alone: sirocco starts a group task lazily on a fiber, so `cancel` lands before the
//! first instruction of every member, while `Io.Threaded` may already be running them. Every test
//! runs under `.forward` and `.fail`: the group slots are native, so `Io.failing`'s unreachable
//! stubs must stay unreached.

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");
const scene = @import("scene.zig");

const modes = [_]Runtime.Unimplemented{ .forward, .fail };

const fibers_supported = Runtime.fibers_supported;

fn bump(counter: *std.atomic.Value(u32)) void {
    _ = counter.fetchAdd(1, .monotonic);
}

fn group_wait_all(io: Io, tasks_count: u32) u32 {
    var counter: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    for (0..tasks_count) |_| group.async(io, bump, .{&counter});
    group.await(io) catch return std.math.maxInt(u32);
    return counter.load(.monotonic);
}

test "await returns after every member ran; counts match Io.Threaded" {
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        // Empty (the token is null, so the slot is never reached), one, and a handful.
        inline for (.{ 0, 1, 7 }) |tasks_count| {
            try harness.expectSameResult(&rt, group_wait_all, .{@as(u32, tasks_count)});
            const counted = group_wait_all(rt.io(), tasks_count);
            try std.testing.expectEqual(@as(u32, tasks_count), counted);
        }
    }
}

test "more members than fibers run the surplus inline and still all run" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime_in(std.testing.allocator, mode, 2);
        defer rt.deinit();

        try std.testing.expectEqual(@as(u32, 9), group_wait_all(rt.io(), 9));
    }
}

test "a group can be reused after await" {
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var counter: std.atomic.Value(u32) = .init(0);
        var group: Io.Group = .init;
        for (0..3) |_| group.async(io, bump, .{&counter});
        try group.await(io);
        try std.testing.expectEqual(@as(?*anyopaque, null), group.token.raw);
        for (0..4) |_| group.async(io, bump, .{&counter});
        try group.await(io);
        try std.testing.expectEqual(@as(u32, 7), counter.load(.monotonic));
        // Idempotent: a finished group awaits and cancels as a no-op.
        try group.await(io);
        group.cancel(io);
    }
}

fn observe_cancel(counter: *std.atomic.Value(u32), io: Io) void {
    io.checkCancel() catch |err| switch (err) {
        error.Canceled => _ = counter.fetchAdd(1, .monotonic),
    };
}

test "cancel reaches every member before it starts" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var observed: std.atomic.Value(u32) = .init(0);
        var group: Io.Group = .init;
        for (0..5) |_| group.async(io, observe_cancel, .{ &observed, io });
        group.cancel(io);
        try std.testing.expectEqual(@as(u32, 5), observed.load(.monotonic));
        try std.testing.expectEqual(@as(?*anyopaque, null), group.token.raw);
    }
}

test "await without a cancel lets every member finish unobserved" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var observed: std.atomic.Value(u32) = .init(0);
        var group: Io.Group = .init;
        for (0..5) |_| group.async(io, observe_cancel, .{ &observed, io });
        try group.await(io);
        try std.testing.expectEqual(@as(u32, 0), observed.load(.monotonic));
    }
}

fn error_returning(io: Io, counter: *std.atomic.Value(u32)) Io.Cancelable!void {
    _ = counter.fetchAdd(1, .monotonic);
    try io.checkCancel();
}

test "a member returning error.Canceled is swallowed at the group boundary" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var counter: std.atomic.Value(u32) = .init(0);
        var group: Io.Group = .init;
        group.async(io, error_returning, .{ io, &counter });
        group.cancel(io);
        try std.testing.expectEqual(@as(u32, 1), counter.load(.monotonic));
    }
}

fn await_group_in_task(io: Io, counter: *std.atomic.Value(u32)) Io.Cancelable!u32 {
    var group: Io.Group = .init;
    for (0..3) |_| group.async(io, bump, .{counter});
    try group.await(io);
    return counter.load(.monotonic);
}

test "a task can run and await a group of its own" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var counter: std.atomic.Value(u32) = .init(0);
        var future = io.async(await_group_in_task, .{ io, &counter });
        try std.testing.expectEqual(@as(u32, 3), try future.await(io));
    }
}

test "a canceled awaiter cancels its members and gets error.Canceled" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var counter: std.atomic.Value(u32) = .init(0);
        var future = io.async(await_group_in_task, .{ io, &counter });
        // The task has not started: the request lands at its first cancelation point, which is
        // the `groupAwait`; its members are canceled but still run to their own check.
        try std.testing.expectError(error.Canceled, future.cancel(io));
        try std.testing.expectEqual(@as(u32, 3), counter.load(.monotonic));
    }
}

test "groupConcurrent reports ConcurrencyUnavailable and leaves the group empty" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var counter: std.atomic.Value(u32) = .init(0);
        var group: Io.Group = .init;
        try std.testing.expectError(
            error.ConcurrencyUnavailable,
            group.concurrent(io, bump, .{&counter}),
        );
        try std.testing.expectEqual(@as(?*anyopaque, null), group.token.raw);
        try std.testing.expectEqual(@as(u32, 0), counter.load(.monotonic));
    }
}

test "an allocation failure runs the member inline" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var rt = try fixtures.init_runtime_in(failing.allocator(), mode, 4);
        defer rt.deinit();

        const io = rt.io(); // The fiber table and stacks are allocated here.
        failing.fail_index = failing.alloc_index;
        var counter: std.atomic.Value(u32) = .init(0);
        var group: Io.Group = .init;
        group.async(io, bump, .{&counter});
        // Inline: already ran, and no resource is associated with the group.
        try std.testing.expectEqual(@as(u32, 1), counter.load(.monotonic));
        try std.testing.expectEqual(@as(?*anyopaque, null), group.token.raw);
        try group.await(io);
    }
}

const CrashProbe = struct { protection_before: Io.CancelProtection, canceled_after: bool };

fn crash_in_task(io: Io) CrashProbe {
    io.vtable.crashHandler(io.userdata);
    const before = io.swapCancelProtection(.unblocked);
    // Threaded marks the thread as already canceled, so lifting protection delivers nothing more.
    const canceled_after = if (io.checkCancel()) |_| false else |_| true;
    return .{ .protection_before = before, .canceled_after = canceled_after };
}

test "crashHandler protects the task and marks its cancelation as already delivered" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var future = io.async(crash_in_task, .{io});
        const result = future.await(io);
        try std.testing.expectEqual(Io.CancelProtection.blocked, result.protection_before);
        try std.testing.expect(!result.canceled_after);
    }
}

test "a group record allocation failure runs the member inline and frees its task" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var rt = try fixtures.init_runtime_in(failing.allocator(), mode, 4);
        defer rt.deinit();

        const io = rt.io();
        // The task record is the next allocation, the group record the one after it.
        failing.fail_index = failing.alloc_index + 1;
        var counter: std.atomic.Value(u32) = .init(0);
        var group: Io.Group = .init;
        group.async(io, bump, .{&counter});
        try std.testing.expectEqual(@as(u32, 1), counter.load(.monotonic));
        try std.testing.expectEqual(@as(?*anyopaque, null), group.token.raw);
        // The testing allocator reports the task record as a leak if it was not freed.
    }
}

fn spawn_into_group(io: Io, group: *Io.Group, observed: *std.atomic.Value(u32)) void {
    group.async(io, observe_cancel, .{ observed, io });
}

test "a member added while the group is being canceled is born canceled" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var observed: std.atomic.Value(u32) = .init(0);
        var group: Io.Group = .init;
        group.async(io, spawn_into_group, .{ io, &group, &observed });
        group.cancel(io);
        try std.testing.expectEqual(@as(u32, 1), observed.load(.monotonic));
    }
}

fn cancel_group_in_task(io: Io, observed: *std.atomic.Value(u32)) u32 {
    var group: Io.Group = .init;
    for (0..2) |_| group.async(io, observe_cancel, .{ observed, io });
    group.cancel(io);
    return observed.load(.monotonic);
}

test "a task can cancel a group of its own" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var observed: std.atomic.Value(u32) = .init(0);
        var future = io.async(cancel_group_in_task, .{ io, &observed });
        try std.testing.expectEqual(@as(u32, 2), future.await(io));
    }
}

test "crashHandler outside any task does nothing, as on Io.Threaded" {
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        io.vtable.crashHandler(io.userdata);
        const baseline = rt.baselineIo();
        baseline.vtable.crashHandler(baseline.userdata);
        try io.checkCancel();
    }
}

// ---- a cancel that arrives while the awaiter is parked ----------------------------------------

const Park = struct {
    word: u32 = 0,
    members_parked: u32 = 0,
    members_canceled: u32 = 0,
    awaiter_parked: u32 = 0,
};

fn parked_member(io: Io, park: *Park) void {
    park.members_parked += 1;
    io.futexWait(u32, &park.word, 0) catch |err| switch (err) {
        error.Canceled => park.members_canceled += 1,
    };
}

fn parked_awaiter(io: Io, park: *Park, protection: Io.CancelProtection) Io.Cancelable!void {
    var group: Io.Group = .init;
    for (0..3) |_| group.async(io, parked_member, .{ io, park });
    _ = io.swapCancelProtection(protection);
    park.awaiter_parked += 1;
    try group.await(io);
    // Only reachable when the awaiter was protected: the members were woken by hand.
    park.awaiter_parked += 10;
}

fn cancel_awaiter(
    io: Io,
    target: *Io.Future(Io.Cancelable!void),
    park: *Park,
    wake: bool,
) Io.Cancelable!void {
    for (0..4) |_| scene.yield(io); // Members and the awaiter reach their parks first.
    std.debug.assert(park.members_parked == 3);
    if (!wake) return target.cancel(io);
    // `.blocked` keeps the awaiter waiting: the members finish only once the waker runs, which
    // is after `cancel` has requested and parked.
    var waker = io.async(wake_members, .{ io, park });
    const result = target.cancel(io);
    waker.await(io);
    return result;
}

fn wake_members(io: Io, park: *Park) void {
    scene.yield(io);
    @atomicStore(u32, &park.word, 1, .release);
    io.futexWake(u32, &park.word, 3);
}

test "a cancel that arrives while groupAwait is parked cancels every member" {
    try scene.run_modes(12, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var park: Park = .{};
            var awaiter = io.async(parked_awaiter, .{ io, &park, Io.CancelProtection.unblocked });
            var killer = io.async(cancel_awaiter, .{ io, &awaiter, &park, false });
            try std.testing.expectError(error.Canceled, killer.await(io));

            try std.testing.expectEqual(@as(u32, 3), park.members_parked);
            try std.testing.expectEqual(@as(u32, 3), park.members_canceled);
            try std.testing.expectEqual(@as(u32, 1), park.awaiter_parked);
        }
    }.scenario);
}

test "blocked protection keeps groupAwait waiting through a cancel" {
    try scene.run_modes(12, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var park: Park = .{};
            var awaiter = io.async(parked_awaiter, .{ io, &park, Io.CancelProtection.blocked });
            var killer = io.async(cancel_awaiter, .{ io, &awaiter, &park, true });
            try killer.await(io);

            try std.testing.expectEqual(@as(u32, 3), park.members_parked);
            try std.testing.expectEqual(@as(u32, 0), park.members_canceled);
            try std.testing.expectEqual(@as(u32, 11), park.awaiter_parked);
        }
    }.scenario);
}

fn racing_awaiter(io: Io, park: *Park) Io.Cancelable!bool {
    var group: Io.Group = .init;
    for (0..3) |_| group.async(io, parked_member, .{ io, park });
    park.awaiter_parked += 1;
    try group.await(io);
    // The request raced the last member: the group finished, the request stays pending.
    return if (io.checkCancel()) |_| false else |_| true;
}

fn wake_then_cancel(
    io: Io,
    target: *Io.Future(Io.Cancelable!bool),
    park: *Park,
) Io.Cancelable!bool {
    for (0..4) |_| scene.yield(io);
    @atomicStore(u32, &park.word, 1, .release);
    io.futexWake(u32, &park.word, 3);
    return target.cancel(io);
}

test "a cancel racing the last member leaves the request pending after groupAwait" {
    try scene.run_modes(12, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var park: Park = .{};
            var awaiter = io.async(racing_awaiter, .{ io, &park });
            var killer = io.async(wake_then_cancel, .{ io, &awaiter, &park });
            try std.testing.expectEqual(true, try killer.await(io));

            try std.testing.expectEqual(@as(u32, 3), park.members_parked);
            try std.testing.expectEqual(@as(u32, 0), park.members_canceled);
        }
    }.scenario);
}
