//! sirocco.batch_park — the parked wait of a batch of `net_receive`s on registered sockets (plan
//! 005 item 5, ADR 0004 section 6): an idle batch sits on the poller and the wheel and makes no
//! syscall until an event, a cancel, a close or its deadline wakes it.
//!
//! Purpose: `wait` sweeps once with `try_once` (a datagram that is already there completes with no
//! registration at all). When nothing completed, one round binds a `Sched.Waiter` to every
//! pending operation (the fiber's own node first, then spares from `Sched.waiter_acquire`), joins
//! each socket's read list through `Registry.batch_enter`, arms the batch deadline on the wheel and
//! parks. `wait.outcome` is a claim: the first of an event, a cancel, the wheel and a close from
//! another thread to move it off `.waiting` wins and wakes the fiber; each node says what became
//! of its own socket. The resumed fiber disarms the wheel, runs `Registry.leave` on every node,
//! retries only the `.ready` ones, completes `.closed` and `.closing` ones with
//! `SocketUnconnected` (after `closing_finish`), and returns the spares to the pool.
//!
//! Results, as `Io.Threaded`'s: `.canceled` is `Canceled` (the `.ready` operations are not read,
//! so no datagram is consumed by a call that reports no result); a wake with a completion
//! returns; `.timed_out` with nothing completed is `Timeout`; any other wake with nothing
//! completed (a datagram that another reader took, say) parks again, bounded by `rounds_max`.
//!
//! Sketch, for N pending operations: the entry sweep costs N `recvmsg`; an idle wait then costs N
//! arms and N disarms (kqueue/epoll syscalls) and nothing else, where the sliced wait cost N
//! `recvmsg` every 50 us to 2 ms. A wake costs one `recvmsg` per ready node. No allocation.
//!
//! Limits: a batch of more than `ops_max` operations, or more than the free spares plus the
//! fiber's own node, is not served here (`src/batch.zig` forwards it whole to the baseline). The
//! node of operation k is `held.nodes[k]`, in the order of the `submitted` list, which nothing
//! reorders while the fiber is parked.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");
const concurrency = @import("concurrency.zig");
const net = @import("net.zig");
const sleep = @import("sleep.zig");
const batch_sweep = @import("batch_sweep.zig");

const Io = std.Io;
const Waiter = Sched.Waiter;
const assert = stdx.assert;
const assert_always = stdx.assert_always;
const OptionalIndex = Io.Operation.OptionalIndex;
const NetReceive = Io.Operation.NetReceive;

/// Most operations one parked batch holds: the size of the node array on the fiber's stack.
pub const ops_max: u32 = 128;

/// Rounds (parks) per await; every round ends in a wake, so 2^32 of them is a hang, not a wait.
const rounds_max: u64 = 1 << 32;

/// Nap in nanoseconds of a round that finds the node pool short.
const pool_short_nap_ns: i96 = 100_000;

/// The nodes one round holds. `nodes[0..taken]` were taken (the first is the fiber's own, the rest
/// spares); `nodes[0..bound]` are joined to a socket's list, one per pending operation in order.
const Held = struct {
    nodes: [ops_max]*Waiter,
    taken: u32,
    bound: u32,
};

/// Waits until an operation of `b` completes, the deadline passes or a cancel arrives.
/// Preconditions: on a fiber, `timeout` on the wall wheel, every submitted operation a
/// `net_receive` on a registered socket, at most `ops_max` of them and no more than the free
/// spares plus one (`served_task` checked it).
pub fn wait(
    rt: *Runtime,
    task: *concurrency.Task,
    b: *Io.Batch,
    timeout: Io.Timeout,
) Io.Batch.AwaitConcurrentError!void {
    assert(rt.sched.in_fiber());
    assert(sleep.on_wall_wheel(timeout));
    if (b.submitted.head == .none) return; // Nothing to wait for; a cancel stays pending.
    if (concurrency.task_acknowledge_cancel(task)) return error.Canceled;

    const limit = sleep.limit_of(rt, timeout);
    batch_sweep.sweep(rt, b);
    if (b.completed.head != .none or b.submitted.head == .none) return;

    for (0..rounds_max) |_| {
        // A cancel that arrived while the fiber was woken, not parked, found nothing to unpark.
        if (concurrency.task_acknowledge_cancel(task)) return error.Canceled;
        if (expired(rt, limit)) return error.Timeout;
        if (pending_count(b) > rt.sched.waiters_free() + 1) {
            // Another batch fiber holds the spares it took since this await began. Wait a slice
            // and sweep, as `batch.wait_sliced` does, until they are given back.
            const nap: Io.Duration = .fromNanoseconds(pool_short_nap_ns);
            rt.io().sleep(nap, .awake) catch return error.Canceled;
            batch_sweep.sweep(rt, b);
            if (b.completed.head != .none or b.submitted.head == .none) return;
            continue;
        }

        const outcome = park_round(rt, task, b, limit);
        switch (outcome) {
            .canceled => {
                // `cancel` ran because the request is pending and the task unprotected.
                assert_always(concurrency.task_acknowledge_cancel(task));
                return error.Canceled;
            },
            .woken, .timed_out => {},
            .idle, .waiting, .closed, .closing => unreachable, // Only claims end a round.
        }
        if (b.completed.head != .none or b.submitted.head == .none) return;
        if (outcome == .timed_out) return error.Timeout;
    }
    assert_always(false); // 2^32 wakes that completed nothing is a hang.
}

/// Submitted operations of `b`; each needs a node to park.
fn pending_count(b: *const Io.Batch) u32 {
    var count: u32 = 0;
    var index = b.submitted.head;
    for (0..b.storage.len) |_| {
        if (index == .none) break;
        count += 1;
        index = b.storage[index.toIndex()].submission.node.next;
    }
    assert_always(index == .none); // A longer list than the storage is corrupt.
    return count;
}

fn expired(rt: *Runtime, limit: sleep.Limit) bool {
    switch (limit) {
        .forever => return false,
        .expired => return true,
        .at => |deadline_ns| {
            const now_ns = Io.Clock.awake.now(rt.baselineIo()).nanoseconds;
            return deadline_ns <= now_ns;
        },
    }
}

/// One park: join, sleep, resume, leave, settle. Returns how the wait ended (`.woken`,
/// `.timed_out` or `.canceled`); the completions are on `b`. Everything taken is given back.
fn park_round(
    rt: *Runtime,
    task: *concurrency.Task,
    b: *Io.Batch,
    limit: sleep.Limit,
) Sched.WaitOutcome {
    const fiber = rt.sched.current_fiber();
    assert(fiber.wait.outcome == .idle);
    assert(limit != .expired);
    // The claim word is `.waiting` before the first node can be woken by anyone.
    fiber.wait = .{
        .addr = 0,
        .prev = null,
        .next = null,
        .sleeping = false,
        .outcome = .waiting,
        .socket = .batch,
    };
    var held: Held = .{ .nodes = undefined, .taken = 0, .bound = 0 };
    if (enter_all(rt, fiber, b, &held)) {
        if (limit == .at) {
            fiber.wait.sleeping = true;
            sleep.arm(&rt.sched, fiber, limit);
        }
        concurrency.task_cancel_wake(task, fiber);
        rt.sched.park();
        concurrency.task_cancel_wake(task, null);
    }
    // A socket event or a close from another thread won the claim, not the wheel: the node is
    // still linked, and the wheel never clears `sleeping` for a claim it lost.
    if (fiber.wait.sleeping) {
        sleep.disarm(&rt.sched, fiber);
        fiber.wait.sleeping = false;
    }
    const outcome = fiber.wait.outcome;
    assert(outcome != .idle);
    assert(outcome != .waiting);
    for (held.nodes[0..held.bound]) |node| _ = rt.sockets.leave(&rt.sched, node);
    settle(rt, b, &held, outcome != .canceled);
    for (held.nodes[1..held.taken]) |node| rt.sched.waiter_release(node);
    fiber.wait = .none;
    return outcome;
}

/// Joins the read list of every pending operation's socket, in order. Stops at the first socket
/// that cannot be joined (closed, or the poller refused), completes that operation with the
/// error `submit.receive` would report and claims the fiber itself: false means the caller must
/// not park. When another thread's close already claimed the fiber the claim here is lost and the
/// caller parks (true), to be woken at once: that close's `unpark_foreign` is on the way and
/// needs the fiber to park, or it would hand a running fiber to the ready queue.
fn enter_all(rt: *Runtime, fiber: *Sched.Fiber, b: *Io.Batch, held: *Held) bool {
    assert(held.taken == 0);
    assert(held.bound == 0);
    var prev: OptionalIndex = .none;
    var index = b.submitted.head;
    for (0..b.storage.len) |_| {
        if (index == .none) break;
        const storage = &b.storage[index.toIndex()];
        const next = storage.submission.node.next;
        const o = storage.submission.operation.net_receive;
        const node = node_for(rt, fiber, held);
        const entered = rt.sockets.batch_enter(&rt.sched, o.socket_handle, .read, node);
        if (entered == .parked) {
            held.bound += 1;
            prev = index;
            index = next;
            continue;
        }
        const failure: NetReceive.Result = switch (entered) {
            .gone => .{ error.SocketUnconnected, 0 },
            .resources => .{ error.SystemResources, 0 },
            .parked => unreachable, // Handled above.
        };
        batch_sweep.unlink_submitted(b, prev, index, next);
        batch_sweep.complete(b, index, .{ .net_receive = failure });
        if (!Sched.claim(fiber, .woken)) return true; // A foreign close won; park for its wake.
        assert(fiber.wait.outcome != .waiting);
        return false;
    }
    assert_always(index == .none); // A longer list than the storage is corrupt.
    assert(held.bound > 0); // `wait` returned on an empty list.
    return true;
}

/// The node for the next operation: the one `enter_all` left idle after a failure, or a new one.
fn node_for(rt: *Runtime, fiber: *Sched.Fiber, held: *Held) *Waiter {
    assert(held.taken >= held.bound);
    assert(held.taken <= held.bound + 1);
    if (held.taken == held.bound) {
        const node = if (held.taken == 0) rt.sched.waiter_of(fiber) else spare: {
            // `wait` checked the pool before this round and nothing ran since; null is a bug.
            const lent = rt.sched.waiter_acquire().?;
            lent.fiber = fiber;
            break :spare lent;
        };
        // The fiber's own node keeps the outcome of its last single-socket wait.
        assert(node.prev == null);
        assert(node.next == null);
        node.outcome = .idle;
        held.nodes[held.taken] = node;
        held.taken += 1;
    }
    return held.nodes[held.bound];
}

/// After `leave`: reads each bound node's outcome against its operation (the k-th submitted one)
/// and completes what ended. `.ready` is retried only when `retry` (a canceled wait must not read
/// a datagram it reports to nobody); `.closed` and `.closing` fail with `SocketUnconnected`, the
/// latter after `closing_finish`, which closes the fd when this was its last waiter.
fn settle(rt: *Runtime, b: *Io.Batch, held: *const Held, retry: bool) void {
    var prev: OptionalIndex = .none;
    var index = b.submitted.head;
    var node_index: u32 = 0;
    for (0..b.storage.len) |_| {
        if (index == .none or node_index == held.bound) break;
        const storage = &b.storage[index.toIndex()];
        const next = storage.submission.node.next;
        const o = storage.submission.operation.net_receive;
        const node = held.nodes[node_index];
        node_index += 1;
        const closed: Io.Operation.Result = .{ .net_receive = .{ error.SocketUnconnected, 0 } };
        const result: ?Io.Operation.Result = switch (node.outcome) {
            .idle => null,
            .ready => if (retry) batch_sweep.try_once(rt, storage.submission.operation) else null,
            .closed => closed,
            .closing => finish: {
                if (rt.sockets.closing_finish(&rt.sched, o.socket_handle, .read)) {
                    net.close_baseline(rt, o.socket_handle);
                }
                break :finish closed;
            },
            .waiting => unreachable, // `leave` unlinked it.
        };
        if (result) |done| {
            batch_sweep.unlink_submitted(b, prev, index, next);
            batch_sweep.complete(b, index, done);
        } else prev = index;
        index = next;
    }
    assert(node_index == held.bound); // The k-th node always had its k-th operation.
}
