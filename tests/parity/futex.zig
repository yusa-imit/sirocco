//! Futex-slot tests (plan 002 item 8): `futexWait`, `futexWaitUncancelable`, `futexWake` on
//! sirocco's fibers, against the contract in `Io.futexWait`'s doc comments and `Io.Threaded`.
//!
//! Three kinds of check. (1) Facts that both `Io`s must agree on (a wait that finds a different
//! value returns, a wait that times out returns, `Event.waitTimeout` reports `error.Timeout`) run
//! through `harness.expectSameResult`. (2) Scheduling facts that `Io.Threaded` does not promise
//! (FIFO wake order, a cancel unparking a parked fiber, no spurious wakeup) are asserted on
//! `rt.io()` alone. (3) The seeded model test (random wait/wake program on both `Io` values and on
//! a reference model, same wake trace) lives in `futex_model.zig`.
//!
//! Scenario shape: waiter fibers are spawned before the driver fiber, and scheduling is FIFO, so
//! when the driver first runs every waiter has already parked. `scene.yield` then lets the woken
//! fibers run. Fibers only record facts into a `Scene`; the test body asserts after the join.
//!
//! Waiter bound (decision, no std error exists for it): `futexWait` has no failure but
//! `Canceled`, so a full wait table must degrade to a spurious return, which the contract allows,
//! never to an error or a hang. Every waiter is a parked fiber and at most `fibers_max` fibers are
//! alive, so the public surface cannot overflow a `fibers_max` table: the test
//! "fibers_max parked waiters ..." saturates it exactly and requires no spurious return. Provoking
//! the degrade path itself is a unit test inside `src/futex.zig` on its table.
//!
//! Clock: timeouts are measured with `std.testing.io`, never with the runtime under test (`.fail`
//! mode has no working `now`). The runtime must read its own clock through the baseline.

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const harness = @import("harness.zig");
const scene = @import("scene.zig");

const yield = scene.yield;
const run_modes = scene.run_modes;
const observes_cancel = scene.observes_cancel;
const expectEqual = std.testing.expectEqual;
const wake_all = std.math.maxInt(u32);

const Cancelable = Io.Cancelable;
const ms: i96 = 1_000_000;

/// Facts recorded by fibers, asserted after the join.
const Scene = struct {
    words: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) },
    /// Waiters that reached their wait call.
    parked: u32 = 0,
    /// Waiters that returned from their wait call.
    finished: u32 = 0,
    /// Waiter ids in the order they resumed.
    trace: [8]u8 = @splat(0),
    trace_len: u32 = 0,
    /// Samples a driver took mid-scenario.
    seen: [6]u32 = @splat(0),
    elapsed_ns: i96 = 0,

    fn word(s: *Scene, index: usize) *u32 {
        return &s.words[index].raw;
    }

    fn push(s: *Scene, id: u8) void {
        std.debug.assert(s.trace_len < s.trace.len);
        s.trace[s.trace_len] = id;
        s.trace_len += 1;
    }
};

fn clock_now() i96 {
    return Io.Clock.awake.now(std.testing.io).nanoseconds;
}

fn timeout_duration(nanoseconds: i96) Io.Timeout {
    const raw: Io.Duration = .fromNanoseconds(nanoseconds);
    return .{ .duration = .{ .raw = raw, .clock = .awake } };
}

fn timeout_deadline(nanoseconds_from_now: i96) Io.Timeout {
    const at: Io.Timestamp = .fromNanoseconds(clock_now() + nanoseconds_from_now);
    return .{ .deadline = .{ .raw = at, .clock = .awake } };
}

// ---- positive contract: agreement with the baseline -------------------------------------------

fn wait_mismatch(io: Io) Cancelable!void {
    var word: u32 = 7;
    try io.futexWait(u32, &word, 5);
}

fn async_wait_mismatch(io: Io) Cancelable!void {
    var future = io.async(wait_mismatch, .{io});
    return future.await(io);
}

fn wake_nobody(io: Io) void {
    var word: u32 = 0;
    io.futexWake(u32, &word, 3);
    io.futexWake(u32, &word, wake_all);
}

fn async_wake_nobody(io: Io) void {
    var future = io.async(wake_nobody, .{io});
    future.await(io);
}

fn event_times_out(io: Io) Io.Event.WaitTimeoutError!void {
    var event: Io.Event = .unset;
    try event.waitTimeout(io, timeout_duration(5 * ms));
}

fn async_event_times_out(io: Io) Io.Event.WaitTimeoutError!void {
    var future = io.async(event_times_out, .{io});
    return future.await(io);
}

fn event_already_set(io: Io) Io.Event.WaitTimeoutError!void {
    var event: Io.Event = .is_set;
    try event.waitTimeout(io, timeout_duration(5 * ms));
}

fn async_event_already_set(io: Io) Io.Event.WaitTimeoutError!void {
    var future = io.async(event_already_set, .{io});
    return future.await(io);
}

test "futex: a wait on a changed value returns, on both Io values, in and out of a fiber" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            try harness.expectSameResult(rt, wait_mismatch, .{});
            try harness.expectSameResult(rt, async_wait_mismatch, .{});
            try harness.expectSameResult(rt, wake_nobody, .{});
            try harness.expectSameResult(rt, async_wake_nobody, .{});
            try wait_mismatch(rt.io());
        }
    }.scenario);
}

test "futex: a timed-out wait reports error.Timeout through Event.waitTimeout, as the baseline" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            try harness.expectSameResult(rt, async_event_times_out, .{});
            try harness.expectSameResult(rt, async_event_already_set, .{});
            const io = rt.io();
            try std.testing.expectError(error.Timeout, async_event_times_out(io));
            try async_event_already_set(io);
        }
    }.scenario);
}

// ---- wake: exactly N, FIFO, only the addressed word -------------------------------------------

fn fan_waiter(io: Io, s: *Scene, id: u8) Cancelable!void {
    s.parked += 1;
    try io.futexWait(u32, s.word(0), 0);
    s.push(id);
}

/// Wakes 2, then 1, then everyone, letting the woken fibers run after each call.
fn fan_driver(io: Io, s: *Scene) void {
    s.seen[0] = s.parked;
    io.futexWake(u32, s.word(0), 2);
    yield(io);
    s.seen[1] = s.trace_len;
    io.futexWake(u32, s.word(0), 1);
    yield(io);
    s.seen[2] = s.trace_len;
    io.futexWake(u32, s.word(0), wake_all);
    yield(io);
    s.seen[3] = s.trace_len;
}

fn scenario_fifo_fan(rt: *Runtime) anyerror!void {
    const io = rt.io();
    var s: Scene = .{};
    var waiters: [4]Io.Future(Cancelable!void) = undefined;
    for (&waiters, 0..) |*waiter, id| {
        waiter.* = io.async(fan_waiter, .{ io, &s, @as(u8, @intCast(id)) });
    }
    var driver = io.async(fan_driver, .{ io, &s });
    driver.await(io);
    for (&waiters) |*waiter| try waiter.await(io);

    // Four parked; wake(2) -> two resumed; wake(1) -> one more; wake(max) -> the last one.
    try std.testing.expectEqualSlices(u32, &.{ 4, 2, 3, 4 }, s.seen[0..4]);
    // Longest-waiting first: the order they parked in is the order they wake in.
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, s.trace[0..4]);
}

test "futex: wake(n) releases exactly n waiters, oldest first" {
    try run_modes(16, scenario_fifo_fan);
}

fn fan_driver_wake_all(io: Io, s: *Scene) void {
    s.seen[0] = s.parked;
    // No yield: with `fibers_max` fibers alive `async` would run inline and nobody would switch.
    io.futexWake(u32, s.word(0), wake_all);
    s.seen[1] = s.trace_len;
}

fn scenario_saturated_fan(rt: *Runtime) anyerror!void {
    const io = rt.io();
    var s: Scene = .{};
    var waiters: [4]Io.Future(Cancelable!void) = undefined;
    for (&waiters, 0..) |*waiter, id| {
        waiter.* = io.async(fan_waiter, .{ io, &s, @as(u8, @intCast(id)) });
    }
    var driver = io.async(fan_driver_wake_all, .{ io, &s });
    try expectEqual(@as(u32, 5), rt.sched.live_count); // 4 waiters + the driver = fibers_max
    driver.await(io);
    for (&waiters) |*waiter| try waiter.await(io);

    try expectEqual(@as(u32, 4), s.seen[0]);
    // The driver did not switch, so nobody ran between the wake and the sample.
    try expectEqual(@as(u32, 0), s.seen[1]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, s.trace[0..4]);
}

test "futex: fibers_max parked waiters on one word all wake from one wake(max)" {
    try run_modes(5, scenario_saturated_fan);
}

fn pair_waiter(io: Io, s: *Scene, index: usize) Cancelable!void {
    s.parked += 1;
    try io.futexWait(u32, s.word(index), 0);
    s.push(@intCast(index));
}

fn pair_driver(io: Io, s: *Scene) void {
    // Adjacent words: the table keys on the exact address, not on a cache line or a hash bucket.
    io.futexWake(u32, s.word(1), wake_all);
    yield(io);
    s.seen[0] = s.trace_len;
    io.futexWake(u32, s.word(0), wake_all);
    yield(io);
    s.seen[1] = s.trace_len;
}

test "futex: a wake reaches only waiters of its own address" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var s: Scene = .{};
            var first = io.async(pair_waiter, .{ io, &s, @as(usize, 0) });
            var second = io.async(pair_waiter, .{ io, &s, @as(usize, 1) });
            var driver = io.async(pair_driver, .{ io, &s });
            driver.await(io);
            try first.await(io);
            try second.await(io);

            try expectEqual(@as(u32, 1), s.seen[0]);
            try expectEqual(@as(u32, 2), s.seen[1]);
            try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, s.trace[0..2]);
        }
    }.scenario);
}

// ---- wake with nobody parked; value change alone is not a wake --------------------------------

fn plain_waiter(io: Io, s: *Scene) Cancelable!void {
    s.parked += 1;
    try io.futexWait(u32, s.word(0), 0);
    s.finished += 1;
}

/// Runs first: its wake finds nobody, so it must not be remembered for the waiter that follows.
fn early_waker(io: Io, s: *Scene) void {
    io.futexWake(u32, s.word(0), 1);
    io.futexWake(u32, s.word(0), wake_all);
    yield(io);
    s.seen[0] = s.finished;
    io.futexWake(u32, s.word(0), 1);
    yield(io);
    s.seen[1] = s.finished;
}

test "futex: a wake with no waiters is a no-op and is not banked for a later waiter" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var s: Scene = .{};
            var waker = io.async(early_waker, .{ io, &s });
            var waiter = io.async(plain_waiter, .{ io, &s });
            waker.await(io);
            try waiter.await(io);

            try expectEqual(@as(u32, 0), s.seen[0]); // still parked after the stale wakes
            try expectEqual(@as(u32, 1), s.seen[1]); // released by the real one
            try expectEqual(@as(u32, 1), s.parked);
        }
    }.scenario);
}

/// Changes the word without waking: the waiter must stay parked (valid-becoming-invalid is the
/// waiter's problem to notice, after a wake).
fn silent_changer(io: Io, s: *Scene) void {
    s.words[0].store(1, .release);
    yield(io);
    s.seen[0] = s.finished;
    io.futexWake(u32, s.word(0), 1);
    yield(io);
    s.seen[1] = s.finished;
}

test "futex: changing the word without a wake does not unpark a waiter" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var s: Scene = .{};
            var waiter = io.async(plain_waiter, .{ io, &s });
            var changer = io.async(silent_changer, .{ io, &s });
            changer.await(io);
            try waiter.await(io);

            try expectEqual(@as(u32, 0), s.seen[0]);
            try expectEqual(@as(u32, 1), s.seen[1]);
        }
    }.scenario);
}

// ---- a wait that must not park, and one that must ---------------------------------------------

/// `expected` is whatever the scenario picked; the word holds 7.
fn probe_waiter(io: Io, s: *Scene, expected: u32) Cancelable!void {
    s.words[0].store(7, .release);
    try io.futexWait(u32, s.word(0), expected);
    s.finished += 1;
}

/// Sibling queued behind the probe: records whether the probe already returned, then rescues it so
/// a probe that wrongly parked ends the scenario with a failed expectation instead of a hang.
fn probe_watchdog(io: Io, s: *Scene) void {
    s.seen[0] = s.finished;
    io.futexWake(u32, s.word(0), wake_all);
}

fn probe_run(rt: *Runtime, expected: u32) !u32 {
    const io = rt.io();
    var s: Scene = .{};
    var probe = io.async(probe_waiter, .{ io, &s, expected });
    var watchdog = io.async(probe_watchdog, .{ io, &s });
    watchdog.await(io);
    try probe.await(io);
    try expectEqual(@as(u32, 1), s.finished);
    return s.seen[0];
}

test "futex: a wait whose expected value differs returns without parking" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            try expectEqual(@as(u32, 1), try probe_run(rt, 5));
            // Adjacent value on either side: the comparison is exact.
            try expectEqual(@as(u32, 1), try probe_run(rt, 6));
            try expectEqual(@as(u32, 1), try probe_run(rt, 8));
            try expectEqual(@as(u32, 1), try probe_run(rt, 0));
        }
    }.scenario);
}

test "futex: a wait whose expected value matches does park until woken" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            try expectEqual(@as(u32, 0), try probe_run(rt, 7));
        }
    }.scenario);
}

// ---- timeouts ---------------------------------------------------------------------------------

fn timed_waiter(io: Io, s: *Scene, timeout: Io.Timeout) Cancelable!void {
    s.parked += 1;
    const start = clock_now();
    try io.futexWaitTimeout(u32, s.word(0), 0, timeout);
    s.elapsed_ns = clock_now() - start;
    s.finished += 1;
}

fn timed_run(rt: *Runtime, timeout: Io.Timeout) !Scene {
    const io = rt.io();
    var s: Scene = .{};
    var waiter = io.async(timed_waiter, .{ io, &s, timeout });
    var watchdog = io.async(probe_watchdog, .{ io, &s });
    watchdog.await(io);
    try waiter.await(io);
    try expectEqual(@as(u32, 1), s.finished);
    return s;
}

fn timer_only_waiter(io: Io, s: *Scene, timeout: Io.Timeout) Cancelable!void {
    s.parked += 1;
    const start = clock_now();
    try io.futexWaitTimeout(u32, s.word(0), 0, timeout);
    s.elapsed_ns = clock_now() - start;
}

test "futex: an idle carrier sleeps until the deadline, then the waiter returns" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            // Alone on the scheduler: nothing can wake it but the clock, and no other fiber
            // exists to rescue it. Duration and deadline forms must both expire.
            var by_duration: Scene = .{};
            const duration = timeout_duration(15 * ms);
            var first = io.async(timer_only_waiter, .{ io, &by_duration, duration });
            try first.await(io);
            try std.testing.expect(by_duration.elapsed_ns >= 15 * ms);
            try std.testing.expect(by_duration.elapsed_ns < 5_000 * ms);

            var by_deadline: Scene = .{};
            const deadline = timeout_deadline(15 * ms);
            var second = io.async(timer_only_waiter, .{ io, &by_deadline, deadline });
            try second.await(io);
            try std.testing.expect(by_deadline.elapsed_ns >= 10 * ms);
            try std.testing.expect(by_deadline.elapsed_ns < 5_000 * ms);
        }
    }.scenario);
}

test "futex: a zero duration and a past deadline return without parking" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const zero = try timed_run(rt, timeout_duration(0));
            try expectEqual(@as(u32, 1), zero.seen[0]);
            const past = try timed_run(rt, timeout_deadline(-1_000 * ms));
            try expectEqual(@as(u32, 1), past.seen[0]);
        }
    }.scenario);
}

fn early_wake_driver(io: Io, s: *Scene) void {
    yield(io);
    io.futexWake(u32, s.word(0), 1);
}

test "futex: a wake before the timeout returns early" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var s: Scene = .{};
            var waiter = io.async(timed_waiter, .{ io, &s, timeout_duration(10_000 * ms) });
            var driver = io.async(early_wake_driver, .{ io, &s });
            driver.await(io);
            try waiter.await(io);
            try expectEqual(@as(u32, 1), s.finished);
            try std.testing.expect(s.elapsed_ns < 5_000 * ms);
        }
    }.scenario);
}

fn saturating_driver(io: Io, s: *Scene) void {
    // Both fibers of the runtime are alive (`plain_waiter` is the other), so `async` runs the task
    // inline on this fiber: this fiber is the second waiter on the word, and it parks with a
    // timeout while the first waiter must stay parked.
    var inline_wait = io.async(timed_waiter, .{ io, s, timeout_duration(10 * ms) });
    inline_wait.await(io) catch {};
    s.seen[0] = s.finished;
    io.futexWake(u32, s.word(0), wake_all);
}

test "futex: with fibers_max waiters parked a timeout fires without waking the others" {
    try run_modes(2, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var s: Scene = .{};
            var waiter = io.async(plain_waiter, .{ io, &s });
            var driver = io.async(saturating_driver, .{ io, &s });
            driver.await(io);
            try waiter.await(io);

            // `finished` was 1 after the driver's own timed wait; the plain waiter still parked.
            try expectEqual(@as(u32, 1), s.seen[0]);
            try std.testing.expect(s.elapsed_ns >= 10 * ms);
            try expectEqual(@as(u32, 2), s.finished);
        }
    }.scenario);
}

// ---- cancelation ------------------------------------------------------------------------------

fn cancelable_waiter(io: Io, s: *Scene) Cancelable!void {
    s.parked += 1;
    try io.futexWait(u32, s.word(0), 0);
    s.finished += 1;
}

fn canceler(io: Io, target: *Io.Future(Cancelable!void)) Cancelable!void {
    return target.cancel(io);
}

test "futex: a cancel that arrives while the waiter is parked unparks it with error.Canceled" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var s: Scene = .{};
            var waiter = io.async(cancelable_waiter, .{ io, &s });
            var killer = io.async(canceler, .{ io, &waiter });
            try std.testing.expectError(error.Canceled, killer.await(io));

            // It really parked first (so the cancel found it parked), and left without a wake.
            try expectEqual(@as(u32, 1), s.parked);
            try expectEqual(@as(u32, 0), s.finished);
            try expectEqual(@as(u32, 0), s.words[0].load(.acquire));
        }
    }.scenario);
}

fn mismatch_cancelable(io: Io, s: *Scene) Cancelable!void {
    s.words[0].store(7, .release);
    s.parked += 1;
    try io.futexWait(u32, s.word(0), 5);
    s.finished += 1;
}

test "futex: a cancel pending at entry is observed even when the wait would not block" {
    // `futexWait` is a cancelation point (`futexWaitUncancelable`: "does not introduce a
    // cancelation point"). The task is lazy, so `cancel` lands before its first instruction.
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var s: Scene = .{};
            var task = io.async(mismatch_cancelable, .{ io, &s });
            try std.testing.expectError(error.Canceled, task.cancel(io));
            try expectEqual(@as(u32, 0), s.finished);
        }
    }.scenario);
}

fn protected_waiter(io: Io, s: *Scene) bool {
    const old = io.swapCancelProtection(.blocked);
    s.words[0].store(7, .release);
    io.futexWait(u32, s.word(0), 5) catch return false; // blocked: must not be canceled
    s.finished += 1;
    _ = io.swapCancelProtection(old);
    return observes_cancel(io);
}

test "futex: blocked cancel protection makes the wait ignore a pending cancel" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var s: Scene = .{};
            var task = io.async(protected_waiter, .{ io, &s });
            // The request was kept, not dropped: it shows once protection is lifted.
            try std.testing.expect(task.cancel(io));
            try expectEqual(@as(u32, 1), s.finished);
        }
    }.scenario);
}

fn uncancelable_waiter(io: Io, s: *Scene) bool {
    s.parked += 1;
    io.futexWaitUncancelable(u32, s.word(0), 0);
    s.finished += 1;
    // The request was never consumed by the wait: it is still pending now.
    return observes_cancel(io);
}

fn cancel_bool(io: Io, target: *Io.Future(bool)) bool {
    return target.cancel(io);
}

fn late_waker(io: Io, s: *Scene) void {
    s.seen[0] = s.finished;
    s.words[0].store(1, .release);
    io.futexWake(u32, s.word(0), 1);
}

test "futex: an uncancelable wait ignores a cancel until woken and does not consume it" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var s: Scene = .{};
            var waiter = io.async(uncancelable_waiter, .{ io, &s });
            var killer = io.async(cancel_bool, .{ io, &waiter });
            var waker = io.async(late_waker, .{ io, &s });
            // Order of events: waiter parks, killer requests the cancel and waits for it, the
            // waker runs next. If the cancel unparked the waiter, `seen[0]` would be 1.
            try std.testing.expect(killer.await(io));
            waker.await(io);

            try expectEqual(@as(u32, 1), s.parked);
            try expectEqual(@as(u32, 0), s.seen[0]);
            try expectEqual(@as(u32, 1), s.finished);
        }
    }.scenario);
}

// ---- entries are reclaimed: woken, canceled and timed-out waiters leave the table -------------

fn wake_now(io: Io, s: *Scene) void {
    io.futexWake(u32, s.word(0), wake_all);
}

fn cycle_woken(io: Io, s: *Scene) !void {
    const before = s.finished;
    var waiter = io.async(plain_waiter, .{ io, s });
    var waker = io.async(wake_now, .{ io, s });
    waker.await(io);
    try waiter.await(io);
    try expectEqual(before + 1, s.finished);
}

fn cycle_canceled(io: Io, s: *Scene) !void {
    const before = s.finished;
    var waiter = io.async(cancelable_waiter, .{ io, s });
    var killer = io.async(canceler, .{ io, &waiter });
    // A waiter that returned normally (a spurious return from a full table) is not Canceled.
    try std.testing.expectError(error.Canceled, killer.await(io));
    try expectEqual(before, s.finished);
}

fn cycle_timed(io: Io, s: *Scene) !void {
    const before = s.finished;
    var waiter = io.async(timed_waiter, .{ io, s, timeout_duration(1 * ms) });
    try waiter.await(io);
    try expectEqual(before + 1, s.finished);
    try std.testing.expect(s.elapsed_ns >= 1 * ms);
}

fn final_driver(io: Io, s: *Scene) void {
    yield(io);
    s.seen[0] = s.finished;
    io.futexWake(u32, s.word(0), 1);
    yield(io);
    s.seen[1] = s.finished;
}

test "futex: woken, canceled and timed-out waiters free their table entry (3x fibers_max cycles)" {
    // If any path leaked its entry, the table (fibers_max = 3) would be full by cycle 4 and the
    // final waiter would degrade to a spurious return instead of parking.
    try run_modes(3, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var s: Scene = .{};
            for (0..9) |cycle| switch (cycle % 3) {
                0 => try cycle_woken(io, &s),
                1 => try cycle_canceled(io, &s),
                else => try cycle_timed(io, &s),
            };
            const base = s.finished;
            var waiter = io.async(plain_waiter, .{ io, &s });
            var driver = io.async(final_driver, .{ io, &s });
            driver.await(io);
            try waiter.await(io);

            try expectEqual(base, s.seen[0]); // parked for real
            try expectEqual(base + 1, s.seen[1]); // and released by its wake
        }
    }.scenario);
}

// ---- off-fiber waker --------------------------------------------------------------------------

test "futex: a wake from outside any fiber releases a fiber parked on the table" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var s: Scene = .{};
            var waiter = io.async(plain_waiter, .{ io, &s });
            // Awaiting a task that is queued behind the waiter runs the waiter to its park.
            var bystander = io.async(wake_nothing, .{});
            bystander.await(io);
            try expectEqual(@as(u32, 1), s.parked);
            try expectEqual(@as(u32, 0), s.finished);

            io.futexWake(u32, s.word(0), 1); // the test thread is the carrier, not a fiber
            try waiter.await(io);
            try expectEqual(@as(u32, 1), s.finished);
        }
    }.scenario);
}

fn wake_nothing() void {}
