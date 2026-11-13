//! The group half of sirocco's concurrency `Io` slots: `groupAsync`, `groupConcurrent`,
//! `groupAwait` and `groupCancel` (plan 002 item 7), split out of `src/concurrency.zig`, which
//! installs them in one vtable set with `async`/`await`/`cancel` and owns the `Task` record, the
//! cancel state and the fiber body (`task_entry`) that every group member shares with a future.
//!
//! Model: `Io.Group.token` points at a `GroupRec` (live members as an intrusive list, a count, the
//! one parked awaiter) made by the first `groupAsync` that gets a fiber; each member is a `Task`
//! whose fiber frees its own record when it ends (`member_finish`). `groupAwait`/`groupCancel`
//! request cancelation where needed, park until the count reaches zero, free the record and null
//! the token.
//!
//! Invariants: `GroupRec.pending` equals the length of the `head` list and `idle` is exactly
//! `pending == 0`; a group is awaited or canceled once, by one fiber that is not one of its
//! members; a group awaiter parks at most `parks_max` times; the token is null from `group_finish`
//! on. Members are created on the awaiter's carrier, as in `src/concurrency.zig`; a cancel reaches
//! one homed elsewhere as a mail (`src/cancel_mail.zig`), which the member settles before it frees
//! its record; a member may end on another carrier: the list, `pending`, `idle` and `waiter`
//! change under `GroupRec.lock`, and the last member wakes the awaiter on its home
//! (`join.wake_fiber`).
//!
//! Allocation: the first member of a group allocates one `GroupRec` (and every member one task
//! record, `concurrency.task_create`) from the allocator `Runtime` gave `Io.Threaded`; the record
//! is freed by `group_finish`, a member's task record by its own fiber. Nothing else allocates.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");
const concurrency = @import("concurrency.zig");
const join = @import("join.zig");
const cancel_mail = @import("cancel_mail.zig");

const Io = std.Io;
const assert = stdx.assert;
const assert_always = stdx.assert_always;
const Task = concurrency.Task;

/// What `Io.Group.token` points at while the group has had members: allocated by the first
/// `groupAsync` that starts a fiber, freed by `groupAwait`/`groupCancel`, which also null the
/// token. `Io.Group.state` is not used.
pub const GroupRec = struct {
    /// Spinlock (`rec_acquire`) over `head`, the members' links, `pending`, `idle` and `waiter`:
    /// a member finishes on its own carrier while the awaiter is on another.
    lock: u32,
    /// The awaiter's carrier.
    sched: *Sched,
    /// Live (not yet finished) members, most recent first; `pending` of them.
    head: ?*Task,
    pending: u32,
    /// `pending == 0`; a field of its own because `Sched.run_until` watches a `*const bool`.
    idle: bool,
    /// The single fiber parked in `groupAwait`/`groupCancel`, if any.
    waiter: ?*Sched.Fiber,
    /// `groupAwait`/`groupCancel` has requested cancelation: members spawned later by a member
    /// are born requested.
    canceling: bool,
};

/// Bound on the spins for the record lock: its critical sections are a few dozen steps.
const spin_max: u32 = 1 << 24;

/// A record for a group whose awaiter runs on `sched`, with no members.
pub fn rec_init(sched: *Sched) GroupRec {
    return .{
        .lock = 0,
        .sched = sched,
        .head = null,
        .pending = 0,
        .idle = true,
        .waiter = null,
        .canceling = false,
    };
}

pub fn rec_acquire(rec: *GroupRec) void {
    for (0..spin_max) |spin| {
        const seen = @cmpxchgWeak(u32, &rec.lock, 0, 1, .acquire, .monotonic);
        if (seen == null) return;
        if (spin % 256 == 255) std.Thread.yield() catch {};
        std.atomic.spinLoopHint();
    }
    assert_always(false); // A critical section is a few dozen steps: the lock leaked.
}

pub fn rec_release(rec: *GroupRec) void {
    assert(@atomicLoad(u32, &rec.lock, .monotonic) == 1);
    @atomicStore(u32, &rec.lock, 0, .release);
}

/// Whether every member finished. An acquire load: what the last member wrote is then visible.
pub fn rec_is_idle(rec: *const GroupRec) bool {
    return @atomicLoad(bool, &rec.idle, .acquire);
}

/// Takes the parked awaiter, if any, out of the record: its wake belongs to the caller. Any
/// thread.
pub fn rec_take_waiter(rec: *GroupRec) ?*Sched.Fiber {
    rec_acquire(rec);
    defer rec_release(rec);

    const waiter = rec.waiter;
    rec.waiter = null;
    return waiter;
}

/// Adds `task` (a member, `task.group` unset) to the live list. Any thread.
pub fn rec_link(rec: *GroupRec, task: *Task) void {
    assert(task.group == null);
    rec_acquire(rec);
    defer rec_release(rec);

    task.group = rec;
    task.next = rec.head;
    task.prev = null;
    if (rec.head) |head| head.prev = task;
    rec.head = task;
    rec.pending += 1;
    @atomicStore(bool, &rec.idle, false, .release);
    assert(rec.pending > 0);
    assert(!rec.idle);
}

/// A group awaiter parks at most twice: once until a cancel or the last member, and once more for
/// the last member after a cancel (a second request cannot arrive: the first is delivered).
const parks_max = 2;

/// Whether the park in `group_finish` is a cancelation point.
const GroupWait = enum { cancelable, uncancelable };

/// `Io.VTable.groupAsync`: a member on a fiber, or inline when none is available.
pub fn slot_group_async(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    const rt = concurrency.runtime_of(userdata);
    if (group_member_start(rt, group, context, context_alignment, start)) return;
    start(context.ptr);
}

/// Starts `start` as a member on a fiber (lazily: it first runs when the carrier next
/// schedules). False, with the group untouched, when the scheduler, a fiber, the task record or
/// the group record is missing.
fn group_member_start(
    rt: *Runtime,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) bool {
    if (rt.sched_state != .ready or !rt.sched.has_free_fiber()) return false;
    assert(rt.sched_pin == @intFromPtr(&rt.sched));
    const body: concurrency.Body = .{ .member = start };
    const task = concurrency.task_create(rt, 0, .@"1", context, context_alignment, body) orelse {
        return false;
    };
    const rec = group_rec_ensure(rt, group) orelse {
        concurrency.task_free(rt, task);
        return false;
    };
    assert(rec.sched == &rt.sched);
    rec_link(rec, task);
    if (rec.canceling) task.cancel = .requested;
    const fiber = rt.sched.spawn(concurrency.task_entry, task) catch |err| switch (err) {
        // `has_free_fiber` held on this thread a moment ago and nothing ran in between.
        error.FibersExhausted => unreachable,
    };
    assert(fiber.state == .ready);
    assert(group.token.raw == @as(?*anyopaque, rec));
    return true;
}

/// The group's record, created on the first member that gets a fiber; null on out-of-memory.
fn group_rec_ensure(rt: *Runtime, group: *Io.Group) ?*GroupRec {
    if (group.token.load(.acquire)) |token| return @ptrCast(@alignCast(token));
    const rec = rt.threaded.allocator.create(GroupRec) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
    rec.* = rec_init(&rt.sched);
    group.token.store(rec, .release);
    assert(rec.idle);
    assert(rec.pending == 0);
    return rec;
}

/// `Io.VTable.groupConcurrent`: as `groupAsync`, but refuses instead of running inline.
pub fn slot_group_concurrent(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) Io.ConcurrentError!void {
    const rt = concurrency.runtime_of(userdata);
    if (context.len != 0) assert(@intFromPtr(context.ptr) != 0);
    assert(rt.sched_state != .pending);
    // As `concurrent`: a member that would run inline is not concurrent, so refuse.
    if (group_member_start(rt, group, context, context_alignment, start)) return;
    return error.ConcurrencyUnavailable;
}

/// `Io.VTable.groupAwait`: waits for every member; reports `error.Canceled` when the awaiting
/// task was canceled, after the group finished.
pub fn slot_group_await(
    userdata: ?*anyopaque,
    group: *Io.Group,
    token: *anyopaque,
) Io.Cancelable!void {
    const rt = concurrency.runtime_of(userdata);
    const rec: *GroupRec = @ptrCast(@alignCast(token));
    assert(group.token.raw == token);
    assert(rec.sched == &rt.sched);
    // A canceled awaiter cancels its members ("propagate to all members") and reports it once the
    // group has finished, so no member outlives the call.
    const task_awaiting = concurrency.current_task(rt);
    const canceled = if (task_awaiting) |task| concurrency.task_acknowledge_cancel(task) else false;
    if (canceled) group_request_cancel(rec);
    const canceled_parked = group_finish(rt, group, rec, .cancelable);
    if (canceled or canceled_parked) return error.Canceled;
}

/// `Io.VTable.groupCancel`: requests cancelation on every live member and waits for them.
pub fn slot_group_cancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
    const rt = concurrency.runtime_of(userdata);
    const rec: *GroupRec = @ptrCast(@alignCast(token));
    assert(group.token.raw == token);
    assert(rec.sched == &rt.sched);
    group_request_cancel(rec);
    _ = group_finish(rt, group, rec, .uncancelable);
}

fn group_request_cancel(rec: *GroupRec) void {
    // A member on the awaiter's carrier is canceled in place; one homed elsewhere gets a cancel
    // mail, which its home applies (`src/cancel_mail.zig`). The lock keeps a member from leaving
    // the list under the walk, and a mailed member settles before it frees its record
    // (`member_finish`), so the mail never outlives the record.
    rec_acquire(rec);
    defer rec_release(rec);

    assert((rec.head == null) == (rec.pending == 0));
    rec.canceling = true;
    var node = rec.head;
    for (0..rec.pending) |_| {
        const member = node.?;
        if (cancel_mail.is_remote(member)) {
            if (!member.cancel_slot.posted) cancel_mail.request(member, member.rt.baselineIo());
        } else {
            assert(member.sched == rec.sched);
            if (member.cancel == .none) concurrency.task_request_cancel(member);
        }
        node = member.next;
    }
    assert(node == null);
}

/// Waits until every member finished (parking inside a fiber, driving the scheduler outside one),
/// then releases the record and nulls the token, as `Io.Group.await` asserts. Returns true when a
/// cancel that arrived during a `.cancelable` park was acknowledged; the members were canceled and
/// all of them finished before it returns.
fn group_finish(rt: *Runtime, group: *Io.Group, rec: *GroupRec, wait: GroupWait) bool {
    // A member waiting for its own group could never be woken: the count never reaches zero.
    if (concurrency.current_task(rt)) |task| assert_always(task.group != rec);
    var canceled = false;
    if (!rec_is_idle(rec)) {
        if (rt.sched.in_fiber()) {
            canceled = group_park(rt, rec, wait);
        } else {
            assert(!rt.sched.running);
            rt.sched.run_until(rt.baselineIo(), &rec.idle);
        }
    }
    assert_always(rec_is_idle(rec));
    assert(rec.pending == 0);
    assert(rec.head == null);
    assert(rec.waiter == null);
    if (wait == .uncancelable) assert(!canceled);
    group.token.store(null, .release);
    rt.threaded.allocator.destroy(rec);
    return canceled;
}

/// Parks the calling fiber until the group is idle. A cancel wakes a `.cancelable` park once; the
/// woken fiber then cancels the members itself (in its own context, so nested groups need no
/// recursion) and parks again for the last member. A request that races the last member's finish
/// finds the group idle and stays pending for the awaiter's next cancelation point.
fn group_park(rt: *Runtime, rec: *GroupRec, wait: GroupWait) bool {
    const task = concurrency.current_task(rt).?;
    assert_always(rec.waiter == null); // Awaited once: a second waiter would be lost.
    assert(task.awaiting == null);
    defer task.awaiting = null;

    switch (wait) {
        .uncancelable => {},
        .cancelable => switch (task.protection) {
            .blocked => {},
            .unblocked => task.awaiting = rec,
        },
    }
    var canceled = false;
    for (0..parks_max) |_| {
        // The idle check and the registration share the lock, so the last member either sees the
        // waiter and wakes it, or finished first and the awaiter does not park.
        rec_acquire(rec);
        if (rec.idle) {
            rec_release(rec);
            break;
        }
        rec.waiter = rt.sched.current_fiber();
        rec_release(rec);
        rt.sched.park();
        if (rec_is_idle(rec)) break;
        // Woken by a cancel (a finished group wakes only with `idle` set).
        assert(task.awaiting != null);
        assert(!canceled);
        canceled = concurrency.task_acknowledge_cancel(task);
        assert_always(canceled);
        group_request_cancel(rec);
        task.awaiting = null; // A second request cannot arrive: the flag is already delivered.
    }
    assert(rec_is_idle(rec));
    return canceled;
}

/// End of a group member's fiber: leave the list, free the record, wake the awaiting fiber when
/// this was the last member. Precondition: `task` is a member (`task.group` set) and its fiber is
/// the caller.
pub fn member_finish(task: *Task) void {
    const rec = task.group.?;
    const rt = task.rt;
    var waiter: ?*Sched.Fiber = null;
    var mailed = false;
    {
        rec_acquire(rec);
        defer rec_release(rec);

        assert(rec.pending > 0);
        assert(!rec.idle);
        if (task.prev) |prev| prev.next = task.next else rec.head = task.next;
        if (task.next) |next| next.prev = task.prev;
        rec.pending -= 1;
        // Read under the lock: a canceler posts only while the task is linked.
        mailed = task.cancel_slot.posted;
        if (rec.pending == 0) {
            assert(rec.head == null);
            waiter = rec.waiter;
            rec.waiter = null;
            @atomicStore(bool, &rec.idle, true, .release);
        }
    }
    // Unlinked, so nobody reaches the record any more. Past the unlock `rec` belongs to the
    // awaiter, which may free it once idle, so only `waiter` is used from here. A mailed cancel
    // holds a pointer into the task until its home has read it.
    if (mailed) cancel_mail.settle(task);
    concurrency.task_free(rt, task);
    if (waiter) |fiber| join.wake_fiber(fiber, rt.baselineIo());
}
