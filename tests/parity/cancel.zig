//! Cancel-state tests (plan 002 item 6): `checkCancel`, `recancel`, `swapCancelProtection`.
//!
//! Facts about "no cancel requested" and "outside any task" are compared against `Io.Threaded`
//! through `harness.expectSameResult`. Facts that need a cancel to arrive at a known point are
//! asserted on `rt.io()` alone: sirocco runs a task at once, so those tasks park on a gate first
//! and the test opens it only after `cancel` queued the request, while `Io.Threaded` may already
//! be running the task on a worker (or inline) and the cancel would race. Every test runs under
//! both `.forward` and `.fail`: the three slots are native, so `Io.failing`'s unreachable stubs
//! must stay unreached.

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");

const modes = [_]Runtime.Unimplemented{ .forward, .fail };

const fibers_supported = Runtime.fibers_supported;

fn check_cancel_plain(io: Io) Io.Cancelable!void {
    try io.checkCancel();
}

fn check_cancel_in_task(io: Io) Io.Cancelable!void {
    var future = io.async(check_cancel_plain, .{io});
    return future.await(io);
}

fn swap_outside_task(io: Io) [3]Io.CancelProtection {
    const first = io.swapCancelProtection(.blocked);
    const second = io.swapCancelProtection(.unblocked);
    const third = io.swapCancelProtection(.unblocked);
    return .{ first, second, third };
}

test "checkCancel without a request returns normally, in and out of a task" {
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        try harness.expectSameResult(&rt, check_cancel_plain, .{});
        try harness.expectSameResult(&rt, check_cancel_in_task, .{});
    }
}

test "swapCancelProtection returns the previous state; a task holds its own" {
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        try harness.expectSameResult(&rt, swap_outside_task, .{});
        // Outside a task there is no state to hold: every call reports `.unblocked`.
        const outside = swap_outside_task(rt.io());
        try std.testing.expectEqual(Io.CancelProtection.unblocked, outside[0]);
        try std.testing.expectEqual(Io.CancelProtection.unblocked, outside[1]);
        try std.testing.expectEqual(Io.CancelProtection.unblocked, outside[2]);
        if (!fibers_supported) continue;
        // Inside a task the state is held. (`Io.Threaded` is not compared: it runs a task inline
        // on the caller's thread when no worker is free, and that thread holds no state.)
        const io = rt.io();
        var future = io.async(swap_outside_task, .{io});
        const inside = future.await(io);
        try std.testing.expectEqual(Io.CancelProtection.unblocked, inside[0]);
        try std.testing.expectEqual(Io.CancelProtection.blocked, inside[1]);
        try std.testing.expectEqual(Io.CancelProtection.unblocked, inside[2]);
    }
}

/// Holds a task before its first cancelation point: `async` runs the task up to this wait, the
/// test opens the gate, and the task proceeds only when the scheduler next runs it.
fn gate_wait(io: Io, gate: *u32) void {
    while (@atomicLoad(u32, gate, .acquire) == 0) io.futexWaitUncancelable(u32, gate, 0);
}

fn gate_open(io: Io, gate: *u32) void {
    @atomicStore(u32, gate, 1, .release);
    io.futexWake(u32, gate, 16);
}

/// True when `checkCancel` reported the cancelation.
fn observes_cancel(io: Io) bool {
    io.checkCancel() catch |err| switch (err) {
        error.Canceled => return true,
    };
    return false;
}

fn gated_observes_cancel(io: Io, gate: *u32) bool {
    gate_wait(io, gate);
    return observes_cancel(io);
}

test "cancel before the task starts is observed at its first check" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var gate: u32 = 0;
        var future = io.async(gated_observes_cancel, .{ io, &gate });
        gate_open(io, &gate);
        try std.testing.expect(future.cancel(io));
    }
}

test "a task nobody cancelled does not observe a cancelation" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var future = io.async(observes_cancel, .{io});
        try std.testing.expect(!future.await(io));
    }
}

/// Counts cancelations: the request is delivered once, `recancel` re-arms it.
fn observes_cancel_twice(io: Io, gate: *u32) u32 {
    gate_wait(io, gate);
    var count: u32 = 0;
    if (observes_cancel(io)) count += 1;
    // Acknowledged: the request is spent until `recancel`.
    if (observes_cancel(io)) count += 10;
    io.recancel();
    if (observes_cancel(io)) count += 100;
    return count;
}

test "a cancelation is delivered once and recancel re-arms it" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var gate: u32 = 0;
        var future = io.async(observes_cancel_twice, .{ io, &gate });
        gate_open(io, &gate);
        try std.testing.expectEqual(@as(u32, 101), future.cancel(io));
    }
}

/// Blocked protection hides the request; unblocking reveals it again.
fn observes_through_protection(io: Io, gate: *u32) [3]bool {
    gate_wait(io, gate);
    const old = io.swapCancelProtection(.blocked);
    const hidden = observes_cancel(io);
    const restored = io.swapCancelProtection(old);
    std.debug.assert(restored == .blocked);
    const revealed = observes_cancel(io);
    return .{ hidden, revealed, old == .unblocked };
}

test "blocked protection hides a cancelation until it is lifted" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var gate: u32 = 0;
        var future = io.async(observes_through_protection, .{ io, &gate });
        gate_open(io, &gate);
        const seen = future.cancel(io);
        try std.testing.expect(!seen[0]);
        try std.testing.expect(seen[1]);
        try std.testing.expect(seen[2]);
    }
}

test "a cancelation reaches only its own task" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var gate: u32 = 0;
        var cancelled = io.async(gated_observes_cancel, .{ io, &gate });
        var sibling = io.async(gated_observes_cancel, .{ io, &gate });
        gate_open(io, &gate);
        try std.testing.expect(cancelled.cancel(io));
        try std.testing.expect(!sibling.await(io));
    }
}

fn leaves_protection_blocked(io: Io) bool {
    _ = io.swapCancelProtection(.blocked);
    return observes_cancel(io);
}

fn reports_fresh_state(io: Io) bool {
    const old = io.swapCancelProtection(.unblocked);
    return old == .unblocked and !observes_cancel(io);
}

test "a recycled fiber starts with no request and no protection" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        // One fiber: the second task necessarily runs on the first task's recycled fiber.
        var rt = try fixtures.init_runtime_in(std.testing.allocator, mode, 1);
        defer rt.deinit();

        const io = rt.io();
        var first = io.async(leaves_protection_blocked, .{io});
        try std.testing.expect(!first.cancel(io));
        var second = io.async(reports_fresh_state, .{io});
        try std.testing.expect(second.await(io));
    }
}

test "cancel after the task finished delivers the result and nothing else" {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime(mode);
        defer rt.deinit();

        const io = rt.io();
        var early = io.async(observes_cancel, .{io});
        var later = io.async(observes_cancel, .{io});
        // Awaiting the second drives the scheduler until it is done; the first ran before it.
        try std.testing.expect(!later.await(io));
        try std.testing.expect(!early.cancel(io));
    }
}

const GroupProbe = struct {
    started: std.atomic.Value(bool) = .init(false),
    /// Cancelations delivered to the group task (the request, then the re-armed one).
    delivered: std.atomic.Value(u32) = .init(0),
};

const spin_max: u32 = 20_000_000;

fn group_task(io: Io, probe: *GroupProbe) void {
    probe.started.store(true, .release);
    for (0..2) |_| {
        for (0..spin_max) |_| {
            io.checkCancel() catch |err| switch (err) {
                error.Canceled => {
                    _ = probe.delivered.fetchAdd(1, .acq_rel);
                    break;
                },
            };
            std.Thread.yield() catch {};
        } else return;
        io.recancel();
    }
}

test "group tasks on baseline worker threads still see cancel, recancel and protection" {
    // The group is spawned through the baseline `Io.Threaded`, so its task runs on a worker thread
    // and calls sirocco's native slots there, which must reach the worker's own cancel state.
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    const io = rt.io();
    const baseline = rt.baselineIo();
    var probe: GroupProbe = .{};
    var group: Io.Group = .init;
    try group.concurrent(baseline, group_task, .{ io, &probe });
    for (0..spin_max) |_| {
        if (probe.started.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(probe.started.load(.acquire));
    group.cancel(baseline);
    try std.testing.expectEqual(@as(u32, 2), probe.delivered.load(.acquire));
}
