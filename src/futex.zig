//! sirocco's futex `Io` slots: `futexWait`, `futexWaitUncancelable` and `futexWake` on fibers
//! (plan 002 item 8). std's `Mutex`, `Condition`, `Event`, `Semaphore` and `Queue` are built on
//! these three alone, so with them sirocco's fibers can block on each other.
//!
//! Model: a fiber that waits on an address parks and joins `Table`, one FIFO list of waiting
//! fibers in arrival order; `futexWake` walks the list and unparks the first `max_waiters` whose
//! address matches, so wake order per address is the order in which the fibers parked. The
//! comparison `ptr.* == expected` and the enqueue happen with no fiber switch between them, which
//! on a single carrier makes them atomic with respect to every other fiber's wake.
//!
//! Waiter bound: a fiber waits on at most one address, so the wait record is the `Sched.Wait` in
//! the `Sched.Fiber` itself (allocated by `Sched.init`; this file allocates nothing) and the
//! table holds at most `waiters_max` (= `fibers_max`) entries. `futexWait` has no failure but
//! `Canceled`, so if the table were ever full (a smaller `waiters_max`), the wait degrades to a
//! spurious return, which `Io.futexWait` allows ("spurious wakeups are possible"). That is the
//! only spurious return: a woken, timed-out or canceled fiber leaves the table before it runs.
//!
//! Timeouts: `.duration` and `.deadline` are read through the baseline `Io.Threaded`'s `now`
//! slot (the native table has none of its own) and armed as a `Clock.awake` deadline on the
//! scheduler's wheel (`Sched.wheel`, node = fiber index). `Sched.run` fires the wheel and calls
//! `Table.timeout` through `Sched.Expiry` for each futex waiter that is due; when every fiber is
//! parked it sleeps in the baseline futex until the earliest deadline. A wake that beats the
//! deadline leaves the node linked until the fiber runs again and clears it; if the node fires
//! first, `timeout` finds the waiter already out of the table and does nothing.
//!
//! Cancelation: `futexWait` is a cancelation point. A request that is pending (and not blocked by
//! `swapCancelProtection`) when the call starts is delivered before anything else, even if the
//! value differs. One that arrives while the fiber is parked removes it from the table and
//! unparks it, and the call returns `error.Canceled` (`concurrency.zig` calls `cancel_wait`).
//! `futexWaitUncancelable` never looks at the request and never registers for one.
//!
//! Outside a fiber (the carrier between `run` calls, or a worker thread) `futexWait` blocks in
//! the baseline, which owns the cancel state of those threads; `futexWake` then also forwards to
//! the baseline while such a waiter exists (`Table.forwarded`), so a thread blocked through
//! `rt.io()` is woken by a fiber and by another thread alike.
//!
//! Threads: `Io` is thread-safe, so any thread holding `rt.io()` may call `futexWake` (a
//! `Mutex.unlock` from a user thread). A small spinlock (`Table.acquire`) guards the list and the
//! counters; critical sections are bounded by `waiters_max`, take no clock reading and make no
//! syscall. A wake inside a fiber (the carrier) unparks directly. A wake from any other thread,
//! or from the carrier outside `run`, removes the waiters under the lock and then hands each to
//! `Sched.unpark_foreign`, which bumps the inbox word so an idle carrier wakes. The comparison
//! with `expected` is made under the same lock as the enqueue, so a value change followed by a
//! wake from another thread cannot slip between the two. `futexWait` itself is fiber code and
//! so runs on the carrier; its cancel state, like every task's, is carrier-only.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");
const concurrency = @import("concurrency.zig");
const sleep = @import("sleep.zig");

const Io = std.Io;
const Fiber = Sched.Fiber;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

const Limit = sleep.Limit;

/// Result of `Table.enqueue`: the fiber must park only on `.queued`.
pub const Enqueue = enum { queued, mismatch, full };

/// Spins `acquire` may burn before it gives up; far beyond any critical section here.
const spin_max: u32 = 1 << 24;

/// The FIFO of fibers parked on an address, behind a spinlock. `forwarded` counts off-fiber
/// waiters blocked in the baseline and is atomic, outside the lock.
pub const Table = struct {
    /// 0 free, 1 held.
    lock: u32,
    head: ?*Fiber,
    tail: ?*Fiber,
    /// Fibers in the list.
    waiting: u32,
    waiters_max: u32,
    forwarded: u32,

    pub fn init(waiters_max: u32) Table {
        assert(waiters_max > 0);
        assert(waiters_max < std.math.maxInt(u32));
        return .{
            .lock = 0,
            .head = null,
            .tail = null,
            .waiting = 0,
            .waiters_max = waiters_max,
            .forwarded = 0,
        };
    }

    fn acquire(table: *Table) void {
        for (0..spin_max) |spin| {
            const seen = @cmpxchgWeak(u32, &table.lock, 0, 1, .acquire, .monotonic);
            if (seen == null) return;
            if (spin % 256 == 255) std.Thread.yield() catch {};
            std.atomic.spinLoopHint();
        }
        assert_always(false); // A critical section is a few dozen steps: the lock leaked.
    }

    fn release(table: *Table) void {
        assert(@atomicLoad(u32, &table.lock, .monotonic) == 1);
        @atomicStore(u32, &table.lock, 0, .release);
    }

    /// Fibers in the list, read under the lock.
    pub fn waiting_count(table: *Table) u32 {
        table.acquire();
        defer table.release();

        assert(table.waiting <= table.waiters_max);
        return table.waiting;
    }

    /// If `ptr.* == expected` still holds under the lock, appends `fiber` (idle, about to park)
    /// to the list. `.full` and `.mismatch` tell the caller to return without parking.
    pub fn enqueue(
        table: *Table,
        fiber: *Fiber,
        ptr: *const u32,
        expected: u32,
    ) Enqueue {
        assert(fiber.wait.outcome == .idle);
        assert(!fiber.wait.sleeping);
        table.acquire();
        defer table.release();

        assert(table.waiting <= table.waiters_max);
        if (@atomicLoad(u32, ptr, .seq_cst) != expected) return .mismatch;
        if (table.waiting >= table.waiters_max) return .full;
        fiber.wait = .{
            .addr = @intFromPtr(ptr),
            .prev = table.tail,
            .next = null,
            .sleeping = false,
            .outcome = .waiting,
        };
        if (table.tail) |tail| tail.wait.next = fiber else table.head = fiber;
        table.tail = fiber;
        table.waiting += 1;
        assert((table.head == null) == (table.tail == null));
        return .queued;
    }

    fn remove(table: *Table, fiber: *Fiber) void {
        assert(fiber.wait.outcome == .waiting);
        assert(table.waiting > 0);
        const wait = &fiber.wait;
        if (wait.prev) |prev| prev.wait.next = wait.next else table.head = wait.next;
        if (wait.next) |next| next.wait.prev = wait.prev else table.tail = wait.prev;
        wait.prev = null;
        wait.next = null;
        table.waiting -= 1;
        assert((table.head == null) == (table.waiting == 0));
    }

    /// Wakes up to `max_waiters` fibers waiting on `addr`, oldest first; returns how many. Inside
    /// a fiber they are unparked directly; anywhere else they are removed under the lock and then
    /// handed to `unpark_foreign` (through `io`, the baseline) once it is released.
    pub fn wake(
        table: *Table,
        sched: *Sched,
        io: Io,
        addr: usize,
        max_waiters: u32,
    ) u32 {
        assert(max_waiters > 0);
        const on_carrier = sched.in_fiber();
        var handoff_head: ?*Fiber = null;
        var handoff_tail: ?*Fiber = null;
        var woken: u32 = 0;
        table.acquire();
        assert(table.waiting <= table.waiters_max);
        var node = table.head;
        for (0..table.waiters_max) |_| {
            if (woken >= max_waiters) break;
            const fiber = node orelse break;
            node = fiber.wait.next;
            if (fiber.wait.addr != addr) continue;
            table.remove(fiber);
            fiber.wait.outcome = .woken;
            woken += 1;
            if (on_carrier) {
                sched.unpark(fiber);
                continue;
            }
            // The fiber may not have parked yet and `queue_next` is free while it is in the table.
            fiber.queue_next = null;
            if (handoff_tail) |tail| tail.queue_next = fiber else handoff_head = fiber;
            handoff_tail = fiber;
        }
        table.release();

        var next = handoff_head;
        for (0..woken) |_| {
            const fiber = next orelse break;
            next = fiber.queue_next;
            sched.unpark_foreign(io, fiber);
        }
        assert(next == null);
        assert(woken <= max_waiters);
        return woken;
    }

    /// The wheel node of `fiber` fired: if it still waits, takes it out of the table and makes it
    /// runnable with outcome `.timed_out`. A no-op when a wake or cancel ended the wait first.
    /// Precondition: carrier thread.
    pub fn timeout(table: *Table, sched: *Sched, fiber: *Fiber) void {
        table.acquire();
        defer table.release();

        assert(table.waiting <= table.waiters_max);
        // A wake or cancel that came first set another outcome and made the fiber ready (or it
        // still runs toward its park); its node stays linked until it runs again.
        if (fiber.wait.outcome != .waiting) return;
        assert(fiber.state == .parked);
        table.remove(fiber);
        fiber.wait.outcome = .timed_out;
        sched.unpark(fiber);
    }
};

/// A cancelation request reached `fiber` while it was parked in `futexWait` (or `sleep`, which
/// `sleep.cancel` handles): take it out of the table and make it runnable. A no-op when it was
/// already woken or timed out this turn (it has not run yet; the request stays pending for its
/// next cancelation point).
pub fn cancel_wait(table: *Table, sched: *Sched, fiber: *Fiber) void {
    if (fiber.wait.sleeping) return sleep.cancel(sched, fiber);

    table.acquire();
    defer table.release();

    assert(table.waiting <= table.waiters_max);
    if (fiber.wait.outcome != .waiting) return;
    assert(fiber.state == .parked);
    table.remove(fiber);
    fiber.wait.outcome = .canceled;
    sched.unpark(fiber);
}

/// Overwrites the three futex slots of `vtable`. Precondition: `Sched.supported`.
pub fn install(vtable: *Io.VTable) void {
    assert(Sched.supported);
    assert(@sizeOf(Io.VTable) > 0);
    vtable.futexWait = slot_futex_wait;
    vtable.futexWaitUncancelable = slot_futex_wait_uncancelable;
    vtable.futexWake = slot_futex_wake;
}

/// The handler `Sched.run` calls for a due futex waiter: `table` is `Runtime.waits`.
pub fn expiry(table: *Table) Sched.Expiry {
    return .{ .ctx = table, .futex_timeout = timeout_hook };
}

fn timeout_hook(ctx: *anyopaque, sched: *Sched, fiber: *Fiber) void {
    const table: *Table = @ptrCast(@alignCast(ctx));
    table.timeout(sched, fiber);
}

fn word_is(ptr: *const u32, expected: u32) bool {
    return @atomicLoad(u32, ptr, .seq_cst) == expected;
}

fn slot_futex_wait(
    userdata: ?*anyopaque,
    ptr: *const u32,
    expected: u32,
    timeout: Io.Timeout,
) Io.Cancelable!void {
    const rt = concurrency.runtime_of(userdata);
    const task = concurrency.current_task(rt) orelse {
        return forward_wait(rt, ptr, expected, timeout);
    };
    assert(rt.sched.in_fiber());
    if (concurrency.task_acknowledge_cancel(task)) return error.Canceled;
    if (!word_is(ptr, expected)) return;
    const limit = sleep.limit_of(rt, timeout);
    if (limit == .expired) return;

    const fiber = rt.sched.current_fiber();
    // A full table degrades to a spurious return, as the module header explains.
    switch (rt.waits.enqueue(fiber, ptr, expected)) {
        .queued => {},
        .mismatch, .full => return,
    }
    // Armed after the enqueue: a wake from another thread in between is cleared below.
    sleep.arm(&rt.sched, fiber, limit);
    concurrency.task_cancel_wake(task, fiber);
    rt.sched.park();
    concurrency.task_cancel_wake(task, null);
    sleep.disarm(&rt.sched, fiber);
    const outcome = fiber.wait.outcome;
    fiber.wait = .none;
    switch (outcome) {
        .woken, .timed_out => {},
        .canceled => {
            // `cancel_wait` ran because the request is pending and the task unprotected.
            assert_always(concurrency.task_acknowledge_cancel(task));
            return error.Canceled;
        },
        .idle, .waiting => unreachable, // Only `wake`, `expire` and `cancel_wait` unpark it.
    }
}

fn forward_wait(
    rt: *Runtime,
    ptr: *const u32,
    expected: u32,
    timeout: Io.Timeout,
) Io.Cancelable!void {
    const baseline = rt.baselineIo();
    assert(@atomicLoad(u32, &rt.waits.forwarded, .monotonic) < std.math.maxInt(u32));
    if (rt.sched.in_fiber()) assert(rt.sched_state != .ready);
    _ = @atomicRmw(u32, &rt.waits.forwarded, .Add, 1, .seq_cst);
    defer _ = @atomicRmw(u32, &rt.waits.forwarded, .Sub, 1, .seq_cst);

    return baseline.vtable.futexWait(baseline.userdata, ptr, expected, timeout);
}

fn slot_futex_wait_uncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    const rt = concurrency.runtime_of(userdata);
    if (rt.sched_state != .ready or !rt.sched.in_fiber()) {
        return forward_wait_uncancelable(rt, ptr, expected);
    }
    if (!word_is(ptr, expected)) return;
    const fiber = rt.sched.current_fiber();
    switch (rt.waits.enqueue(fiber, ptr, expected)) {
        .queued => {},
        .mismatch, .full => return,
    }
    rt.sched.park();
    // No deadline and no cancel registration: only a wake can have unparked it.
    assert_always(fiber.wait.outcome == .woken);
    fiber.wait = .none;
}

fn forward_wait_uncancelable(rt: *Runtime, ptr: *const u32, expected: u32) void {
    const baseline = rt.baselineIo();
    assert(@atomicLoad(u32, &rt.waits.forwarded, .monotonic) < std.math.maxInt(u32));
    if (rt.sched.in_fiber()) assert(rt.sched_state != .ready);
    _ = @atomicRmw(u32, &rt.waits.forwarded, .Add, 1, .seq_cst);
    defer _ = @atomicRmw(u32, &rt.waits.forwarded, .Sub, 1, .seq_cst);

    return baseline.vtable.futexWaitUncancelable(baseline.userdata, ptr, expected);
}

fn slot_futex_wake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    const rt = concurrency.runtime_of(userdata);
    assert(rt.waits.waiters_max > 0);
    if (max_waiters == 0) return;
    const baseline = rt.baselineIo();
    const ready = rt.sched_state == .ready;
    const woken: u32 = if (ready)
        rt.waits.wake(&rt.sched, baseline, @intFromPtr(ptr), max_waiters)
    else
        0;
    assert(woken <= max_waiters);
    const left = max_waiters - woken;
    if (left == 0) return;
    // A read-modify-write is the seq_cst fence that pairs with the waiter's increment: either it
    // sees the waiter, or the waiter's own futex check sees the value this caller just stored.
    const forwarded = @atomicRmw(u32, &rt.waits.forwarded, .Add, 0, .seq_cst);
    if (ready and forwarded == 0) return;
    // No scheduler, or a thread is blocked in the baseline on this runtime: wake it there too.
    baseline.vtable.futexWake(baseline.userdata, ptr, left);
}

const test_options: Runtime.Options = .{
    .backend = .threaded,
    .unimplemented = .forward,
    .environ = .empty,
    .argv0 = .empty,
    .fibers_max = 4,
    .fiber_stack_size = 128 * 1024,
    .offload_threads = 2,
};

test "enqueue refuses past waiters_max and leaves the table intact" {
    var table: Table = .init(2);
    var word: u32 = 0;
    var fibers: [3]Fiber = undefined;
    for (&fibers) |*fiber| {
        fiber.* = .{
            .context = std.mem.zeroes(Io.fiber.Context),
            .queue_next = null,
            .state = .running,
            .stack = &.{},
            .arg = null,
            .wait = .none,
        };
    }
    try std.testing.expectEqual(Enqueue.queued, table.enqueue(&fibers[0], &word, 0));
    try std.testing.expectEqual(Enqueue.queued, table.enqueue(&fibers[1], &word, 0));
    try std.testing.expectEqual(Enqueue.full, table.enqueue(&fibers[2], &word, 0));
    try std.testing.expectEqual(Enqueue.mismatch, table.enqueue(&fibers[2], &word, 1));
    try std.testing.expectEqual(@as(u32, 2), table.waiting_count());
    try std.testing.expectEqual(Sched.WaitOutcome.idle, fibers[2].wait.outcome);
    try std.testing.expectEqual(@as(?*Fiber, &fibers[0]), table.head);
    try std.testing.expectEqual(@as(?*Fiber, &fibers[1]), table.tail);

    // Removing the head frees a slot and keeps the arrival order of the rest.
    table.remove(&fibers[0]);
    try std.testing.expectEqual(Enqueue.queued, table.enqueue(&fibers[2], &word, 0));
    try std.testing.expectEqual(@as(?*Fiber, &fibers[1]), table.head);
    try std.testing.expectEqual(@as(?*Fiber, &fibers[2]), table.tail);
}

fn timed_wait_probe(
    io: Io,
    word: *const u32,
    timeout_ns: i96,
    elapsed_ns: *i96,
) Io.Cancelable!void {
    const start = Io.Clock.awake.now(std.testing.io);
    const timeout: Io.Timeout = .{ .duration = .{
        .raw = .fromNanoseconds(timeout_ns),
        .clock = .awake,
    } };
    try io.futexWaitTimeout(u32, word, 0, timeout);
    elapsed_ns.* = Io.Clock.awake.now(std.testing.io).nanoseconds - start.nanoseconds;
}

test "a full table degrades a wait to a spurious return, not to an error or a hang" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, test_options);
    defer rt.deinit();

    const io = rt.io();
    // Nobody wakes this word and the timeout is 5 s: returning at once is the degrade path.
    rt.waits.waiters_max = 0;
    defer rt.waits.waiters_max = test_options.fibers_max;

    var word: u32 = 0;
    var elapsed_ns: i96 = std.math.maxInt(i96);
    var future = io.async(timed_wait_probe, .{ io, &word, 5_000_000_000, &elapsed_ns });
    try future.await(io);
    try std.testing.expectEqual(@as(u32, 0), rt.waits.waiting_count());
    try std.testing.expect(elapsed_ns < 1_000_000_000);
}

const Waker = struct {
    io: Io,
    rt: *Runtime,
    word: *std.atomic.Value(u32),

    /// Waits (bounded) until the fiber is in the table, then changes the word and wakes it.
    fn run(waker: Waker) void {
        for (0..5_000) |_| {
            if (waker.rt.waits.waiting_count() == 1) break;
            waker.io.sleep(.fromMilliseconds(1), .awake) catch {};
        } else return;
        waker.word.store(1, .release);
        waker.io.futexWake(u32, &waker.word.raw, 1);
    }
};

test "a wake from a plain thread resumes a fiber parked in the table, even from an idle carrier" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, test_options);
    defer rt.deinit();

    const io = rt.io();
    var word: std.atomic.Value(u32) = .init(0);
    var elapsed_ns: i96 = std.math.maxInt(i96);
    // The 10 s timeout only bounds a lost wakeup; the thread's wake must end the wait first.
    var future = io.async(timed_wait_probe, .{ io, &word.raw, 10_000_000_000, &elapsed_ns });
    const waker: Waker = .{ .io = io, .rt = &rt, .word = &word };
    const thread = try std.Thread.spawn(.{}, Waker.run, .{waker});
    try future.await(io);
    thread.join();
    try std.testing.expect(elapsed_ns < 5_000_000_000);
    try std.testing.expectEqual(@as(u32, 0), rt.waits.waiting_count());
}
