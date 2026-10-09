//! sirocco's `sleep` slot on fibers (plan 003 item 4), and the wheel helpers the futex timeouts
//! share. A sleeping fiber parks with a node on `Sched.wheel` (key: its fiber index), so the
//! carrier never blocks in `sleep`: other fibers run, and `Sched.run` wakes the sleeper when its
//! deadline passes or, when every fiber is parked, waits in the baseline futex until then.
//!
//! Clocks: `.real`, `.awake` and `.boot` are all measured on `Clock.awake`. A `.duration` is
//! relative, so it is exact; a `.deadline` is converted to a remaining duration once, at entry,
//! so a later step of the wall clock does not move it. The CPU-time clocks (`cpu_process`,
//! `cpu_thread`) cannot be measured by a wall wheel and, like a call from outside a fiber, are
//! forwarded to the baseline `Io.Threaded`, which blocks the calling thread (the carrier too).
//! `.none` sleeps until canceled.
//!
//! Cancelation: `sleep` is a cancelation point. A request pending when the call starts is
//! delivered first; one that arrives while the fiber is parked removes its node and unparks it
//! (`futex.cancel_wait` dispatches here), and the call returns `error.Canceled`. Under
//! `swapCancelProtection(.blocked)` the sleep runs to its deadline.
//!
//! Resolution: the wheel fires a deadline between zero and one tick (131 us) late, never early;
//! the baseline's own clock read at entry adds the usual syscall jitter.
//!
//! Allocation: none; the wait record is the `Sched.Wait` in the fiber and the node lives in the
//! wheel's array, both sized at `Sched.init`.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");
const concurrency = @import("concurrency.zig");

const Io = std.Io;
const Fiber = Sched.Fiber;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

/// When a wait gives up: never, at an absolute `Clock.awake` time, or already (nothing to wait
/// for).
pub const Limit = union(enum) { forever, at: i96, expired };

/// Overwrites the `sleep` slot of `vtable`. Precondition: `Sched.supported`.
pub fn install(vtable: *Io.VTable) void {
    assert(Sched.supported);
    assert(@sizeOf(Io.VTable) > 0);
    vtable.sleep = slot_sleep;
}

/// Links `fiber`'s wheel node for `limit`; `.forever` links nothing. Precondition: carrier
/// thread, `fiber` running and not linked, `limit` not `.expired`.
pub fn arm(sched: *Sched, fiber: *Fiber, limit: Limit) void {
    assert(limit != .expired);
    const index = fiber_index(sched, fiber);
    assert(!sched.wheel.is_linked(index));
    switch (limit) {
        .forever => {},
        .at => |deadline_ns| sched.wheel.insert(index, std.math.lossyCast(u64, deadline_ns)),
        .expired => unreachable, // Asserted away above.
    }
}

/// Unlinks `fiber`'s wheel node if it is still linked (a wake or cancel beat the deadline).
/// Precondition: carrier thread.
pub fn disarm(sched: *Sched, fiber: *Fiber) void {
    const index = fiber_index(sched, fiber);
    if (sched.wheel.is_linked(index)) sched.wheel.remove(index);
    assert(!sched.wheel.is_linked(index));
}

/// A cancelation request reached a fiber that is parked in `sleep`: unlink it and make it
/// runnable with outcome `.canceled`. Precondition: carrier thread, `fiber.wait.sleeping`.
pub fn cancel(sched: *Sched, fiber: *Fiber) void {
    assert(fiber.wait.sleeping);
    assert(fiber.wait.outcome == .waiting);
    assert(fiber.state == .parked);
    disarm(sched, fiber);
    fiber.wait.sleeping = false;
    fiber.wait.outcome = .canceled;
    sched.unpark(fiber);
}

/// Converts `timeout` to a `Clock.awake` limit, reading the clocks through the baseline `Io`.
pub fn limit_of(rt: *Runtime, timeout: Io.Timeout) Limit {
    const io = rt.baselineIo();
    const remaining = timeout.toDurationFromNow(io) orelse return .forever;
    const remaining_ns = remaining.raw.nanoseconds;
    if (remaining_ns <= 0) return .expired;
    const now_ns = Io.Clock.awake.now(io).nanoseconds;
    return .{ .at = now_ns +| remaining_ns };
}

/// Fires every wheel node whose deadline has passed (`Sched.run` calls this before every dispatch)
/// and returns the earliest one still pending (`Clock.awake` nanoseconds), or null. Reads no
/// clock while no fiber has a deadline. Precondition: carrier thread, outside any fiber.
pub fn fire(sched: *Sched, io: Io) ?i96 {
    if (sched.wheel.count() == 0) return null;
    const now_ns = Io.Clock.awake.now(io).nanoseconds;
    _ = sched.wheel.expire(std.math.lossyCast(u64, now_ns));
    for (0..sched.fibers.len) |_| {
        const index = sched.wheel.pop_due() orelse break;
        const fiber = &sched.fibers[index];
        if (!fiber.wait.sleeping) {
            // A wake that beat the deadline leaves the node linked and the fiber possibly ready,
            // so the handler re-checks under the table lock before it touches the fiber.
            const expiry = sched.expiry.?;
            expiry.futex_timeout(expiry.ctx, sched, fiber);
            continue;
        }
        // Only the wheel and `cancel` end a sleep, and `cancel` unlinks the node.
        assert(fiber.state == .parked);
        assert(fiber.wait.outcome == .waiting);
        fiber.wait.sleeping = false;
        fiber.wait.outcome = .timed_out;
        sched.unpark(fiber);
    }
    const next_ns = sched.wheel.next_deadline() orelse return null;
    return @intCast(next_ns);
}

fn fiber_index(sched: *const Sched, fiber: *const Fiber) u32 {
    const offset = @intFromPtr(fiber) - @intFromPtr(sched.fibers.ptr);
    const index: u32 = @intCast(@divExact(offset, @sizeOf(Fiber)));
    assert(index < sched.fibers.len);
    assert(&sched.fibers[index] == fiber);
    return index;
}

fn on_wall_wheel(timeout: Io.Timeout) bool {
    const clock = switch (timeout) {
        .none => return true,
        .duration => |duration| duration.clock,
        .deadline => |deadline| deadline.clock,
    };
    return switch (clock) {
        .real, .awake, .boot => true,
        .cpu_process, .cpu_thread => false,
    };
}

fn slot_sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const rt = concurrency.runtime_of(userdata);
    const task = concurrency.current_task(rt) orelse return forward_sleep(rt, timeout);
    assert(rt.sched.in_fiber());
    if (concurrency.task_acknowledge_cancel(task)) return error.Canceled;
    if (!on_wall_wheel(timeout)) return forward_sleep(rt, timeout);

    const limit = limit_of(rt, timeout);
    if (limit == .expired) return;

    const fiber = rt.sched.current_fiber();
    assert(fiber.wait.outcome == .idle);
    fiber.wait = .{
        .addr = 0,
        .prev = null,
        .next = null,
        .sleeping = true,
        .outcome = .waiting,
    };
    arm(&rt.sched, fiber, limit);
    concurrency.task_cancel_wake(task, fiber);
    rt.sched.park();
    concurrency.task_cancel_wake(task, null);
    const outcome = fiber.wait.outcome;
    // The scheduler unlinked the node when it fired, `cancel` when it canceled.
    assert(!fiber.wait.sleeping);
    assert(!rt.sched.wheel.is_linked(fiber_index(&rt.sched, fiber)));
    fiber.wait = .none;
    switch (outcome) {
        .timed_out => {},
        .canceled => {
            // `cancel` ran because the request is pending and the task unprotected.
            assert_always(concurrency.task_acknowledge_cancel(task));
            return error.Canceled;
        },
        .idle, .waiting, .woken => unreachable, // Only the wheel and `cancel` unpark it.
    }
}

fn forward_sleep(rt: *Runtime, timeout: Io.Timeout) Io.Cancelable!void {
    const baseline = rt.baselineIo();
    return baseline.vtable.sleep(baseline.userdata, timeout);
}
