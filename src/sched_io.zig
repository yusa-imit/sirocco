//! sirocco.sched_io — the scheduler's side of the evented poller (ADR 0003 sections 1 and 3).
//!
//! Purpose: `Sched` owns one `backend.poller.Native` under `.poller` idling. This file holds what
//! touches it: the carrier's idle `wait` (until the wheel's next deadline), the fairness poll
//! that keeps a busy run queue from starving sockets, arm/disarm for `src/net.zig`, and the
//! dispatch of each delivered `Event` to the handler (`Sched.events`) that names the fibers to
//! unpark. Split from `sched.zig` to keep that file under the 800-line cap.
//!
//! Invariants: carrier-only except where `Sched.unpark_foreign` says otherwise. An event can only
//! exist for a pair somebody armed, and arming requires a handler, so an event with no handler is
//! a breach. Nothing here allocates or reads a clock except the idle wait's single `now`.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const evented = @import("backend/poller.zig");

const Io = std.Io;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

/// Registers a one-shot read or write interest. Precondition: carrier thread, `.poller` idling,
/// a handler installed, and `(fd, interest)` not already armed.
pub fn arm(
    sched: *Sched,
    fd: evented.fd_t,
    interest: evented.Interest,
    token: u64,
) evented.ArmError!void {
    assert(sched.events != null);
    switch (sched.idle) {
        .futex => unreachable, // Proof: only a runtime with a registry arms, and it has a poller.
        .poller => |*native| {
            if (comptime evented.Native == void) unreachable;
            try native.arm(fd, interest, token);
            assert(native.is_armed(fd, interest));
        },
    }
}

/// Removes a registration; idempotent. Same preconditions as `arm`.
pub fn disarm(sched: *Sched, fd: evented.fd_t, interest: evented.Interest) void {
    assert(fd >= 0);
    switch (sched.idle) {
        .futex => unreachable, // Proof: see `arm`.
        .poller => |*native| {
            if (comptime evented.Native == void) unreachable;
            native.disarm(fd, interest);
            assert(!native.is_armed(fd, interest));
        },
    }
}

/// True while any pair is armed (zero under `.futex`).
pub fn armed_any(sched: *const Sched) bool {
    switch (sched.idle) {
        .futex => return false,
        .poller => |*native| {
            if (comptime evented.Native == void) unreachable;
            assert(native.table.count <= native.table.count_max);
            return native.table.count > 0;
        },
    }
}

/// Blocks in the poller until a wake, an event or `deadline_ns` (`Clock.awake`), then dispatches
/// what arrived. Returning early is fine: `run_loop` re-checks everything.
pub fn idle_wait(sched: *Sched, io: Io, deadline_ns: ?i96) void {
    const timeout_ns: ?u64 = if (deadline_ns) |at|
        timeout_until(at, Io.Clock.awake.now(io).nanoseconds)
    else
        null;
    wait_dispatch(sched, timeout_ns);
}

/// Fairness (ADR 0003 section 1): called once per `fibers_max` dispatches, polls without
/// blocking so ready fibers cannot starve sockets. A syscall only when something is armed.
pub fn poll_fair(sched: *Sched) void {
    sched.since_poll = 0;
    if (!armed_any(sched)) return;
    wait_dispatch(sched, 0);
}

fn wait_dispatch(sched: *Sched, timeout_ns: ?u64) void {
    switch (sched.idle) {
        .futex => unreachable, // Proof: callers switch on `.poller` first or check `armed_any`.
        .poller => |*native| {
            if (comptime evented.Native == void) unreachable;
            var events: [evented.events_max]evented.Event = undefined; // Written before read.
            const count = native.wait(timeout_ns, &events);
            assert(count <= events.len);
            for (events[0..count]) |event| {
                // Arming requires a handler, so an event without one is corrupt state.
                const handler = sched.events orelse return assert_always(false);
                handler.ready(handler.ctx, sched, event);
            }
        },
    }
}

/// The relative `Poller.wait` timeout for an absolute `deadline_ns`: the time left, 0 once it has
/// passed. Both are `Clock.awake` nanoseconds.
pub fn timeout_until(deadline_ns: i96, now_ns: i96) u64 {
    assert(now_ns >= 0);
    const remaining_ns = deadline_ns -| now_ns;
    if (remaining_ns <= 0) return 0;
    const timeout_ns = std.math.lossyCast(u64, remaining_ns);
    assert(timeout_ns > 0);
    return timeout_ns;
}

test "timeout_until is the time left, never negative, saturating" {
    try std.testing.expectEqual(@as(u64, 500), timeout_until(1_500, 1_000));
    try std.testing.expectEqual(@as(u64, 0), timeout_until(1_000, 1_000));
    try std.testing.expectEqual(@as(u64, 0), timeout_until(900, 1_000));
    const far: i96 = std.math.maxInt(i96);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), timeout_until(far, 1));
}
