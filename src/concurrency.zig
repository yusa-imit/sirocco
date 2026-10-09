//! sirocco's concurrency `Io` slots: `async`, `concurrent`, `await`, `cancel` (plan 002 item 5),
//! the cancel state (item 6) and the group set `groupAsync`/`groupConcurrent`/`groupAwait`/
//! `groupCancel` plus `crashHandler` (item 7), installed by `Runtime` as one set because
//! `await`/`cancel` receive the `*AnyFuture` that `async` produced and a group's token is the
//! record `groupAsync` made, so a half-native vtable would hand a sirocco token to Threaded.
//!
//! Model: one carrier thread, many fibers (`Sched`). `async` allocates a task record, copies the
//! context into it and spawns a fiber that runs `start` and then marks the task done. The fiber
//! runs at once (`Sched.spawn_first`): a caller on a fiber yields to it, a caller outside any
//! fiber drives the carrier loop until the task first parks, yields or ends; `await`/`cancel`
//! outside a fiber drive `Sched.run_until` the awaited task is done. Scheduling is FIFO after
//! that, so the interleaving of a single-threaded program is deterministic (`groupAsync` members
//! still start lazily). `await` inside a fiber records itself as the task's waiter and parks; the
//! finishing task unparks it.
//!
//! Fallbacks, all permitted by `Io.VTable.async` ("if it returns `null` ... `result` has been
//! already populated"): with no free fiber (`fibers_max` alive), a failed task allocation, or a
//! scheduler that could not be allocated, `async` runs `start` inline in the caller and returns
//! `null`. `concurrent` always returns `error.ConcurrencyUnavailable` (`Io.ConcurrentError`: the
//! implementation does not support concurrency) while there is a single carrier.
//!
//! `cancel` is "set the request flag, then `await`". The flag lives in the task record and is
//! observed by `checkCancel` on the task's fiber (`recancel` and `swapCancelProtection` act on the
//! same record; outside a task, on the carrier or on a forwarded group worker thread, all three
//! forward to the embedded `Io.Threaded`, which owns the state of those threads). The only
//! cancelable park is `futexWait` (`src/futex.zig`): a cancel unparks a task parked there and the
//! wait returns `error.Canceled`. `await`/`cancel` cannot return `error.Canceled`. A task that
//! never reaches a cancelation point runs to completion and its result is delivered.
//!
//! Groups: `Io.Group.token` points at a `GroupRec` (live members as an intrusive list, a count,
//! the one parked awaiter) made by the first `groupAsync` that gets a fiber; each member is a
//! `Task` whose fiber frees its own record when it ends. Like `async`, a member runs inline when
//! no fiber, task record or group record is available (then the token stays null, which `Group`
//! documents as "no resources"), and `groupConcurrent` is `ConcurrencyUnavailable`.
//! `groupCancel` requests cancelation on every live member and waits; `groupAwait` does the same
//! when the awaiting task itself has a pending unprotected request, and then reports
//! `error.Canceled` after the group finished; a request that arrives while the awaiter is parked
//! unparks it, and it cancels the members and keeps waiting for them all before reporting (a
//! protected awaiter ignores the request). `crashHandler` marks the
//! calling task's cancelation acknowledged and protected, as Threaded does for its thread, so a
//! panic handler's cleanup is never interrupted. Preconditions, as std states them: a group is
//! awaited or canceled once by one fiber that is not one of its members, no member is added once
//! the last one has finished, and the group stays on one `Io` (a token made by `rt.baselineIo()`
//! is Threaded's, not a `GroupRec`).
//!
//! Allocation: `async` and `groupAsync` still allocate one task record per started task (and the
//! first member of a group one `GroupRec`) from the allocator that `Runtime` gave `Io.Threaded`
//! (as Threaded itself does), freed by `await`/`cancel` (members: by their own fiber, groups: by
//! `groupAwait`/`groupCancel`); the
//! no-allocation contract is a later item. Fibers and stacks come from `Sched.init`.
//!
//! Known limits: the forwarded blocking slots (I/O, and `sleep` on a CPU clock) block the
//! carrier thread, now inside the `async` call that started the task, not at `await`; a futex
//! wait or a wall-clock `sleep` does not (`src/futex.zig` and `src/sleep.zig` park the fiber), so
//! `io.async(producer)` followed by `queue.getOne` completes. Called from outside a fiber, a
//! futex wait or sleep still blocks the carrier. Under
//! `.forward`, `concurrent` is `ConcurrencyUnavailable` where Threaded would succeed.
//!
//! Threads: every slot runs on the carrier thread, the one that first calls `async` or `await`
//! outside a fiber. The `Io` contract calls these slots thread-safe; this implementation is not
//! yet, and a second thread using the same `Io` is a contract breach. Every future must be
//! awaited or cancelled exactly once before `Runtime.deinit`.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");
const futex = @import("futex.zig");

const Io = std.Io;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

/// Per-task record: lives from `async` until `await`/`cancel` frees it (a group member: until its
/// own fiber ends), followed in the same allocation by the copied context and the result storage
/// (each at its own alignment; a member has no result).
pub const Task = struct {
    sched: *Sched,
    body: Body,
    /// The group this task is a member of; null for a future's task.
    group: ?*GroupRec,
    /// Links in `group`'s list of live members.
    prev: ?*Task,
    next: ?*Task,
    /// The single fiber parked in `await`/`cancel`, if any.
    waiter: ?*Sched.Fiber,
    /// The task's fiber while it is parked in a cancelable `futexWait`; a cancel unparks it.
    waiting: ?*Sched.Fiber,
    /// The group this task's fiber is parked on in a cancelable `groupAwait`; a cancel unparks it.
    awaiting: ?*GroupRec,
    context_offset: usize,
    result_offset: usize,
    result_len: usize,
    alloc_len: usize,
    alloc_alignment: std.mem.Alignment,
    done: bool,
    /// `cancel` sets `.requested`; the first unprotected `checkCancel` on the task's fiber
    /// acknowledges it; `recancel` re-arms it.
    cancel: CancelState,
    protection: Io.CancelProtection,

    fn context(task: *Task) *const anyopaque {
        return @ptrFromInt(@intFromPtr(task) + task.context_offset);
    }

    fn result(task: *Task) *anyopaque {
        return @ptrFromInt(@intFromPtr(task) + task.result_offset);
    }
};

const CancelState = enum { none, requested, acknowledged };

/// What a task's fiber runs: a future's function (result delivered to `await`) or a group
/// member's (nobody awaits it; the group counts it down).
const Body = union(enum) {
    future: *const fn (context: *const anyopaque, result: *anyopaque) void,
    member: *const fn (context: *const anyopaque) void,
};

/// What `Io.Group.token` points at while the group has had members: allocated by the first
/// `groupAsync` that starts a fiber, freed by `groupAwait`/`groupCancel`, which also null the
/// token. `Io.Group.state` is not used.
const GroupRec = struct {
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

/// Overwrites the twelve slots of `vtable`. Precondition: `Sched.supported`, otherwise the slots
/// must stay forwarded to the baseline.
pub fn install(vtable: *Io.VTable) void {
    assert(Sched.supported);
    assert(@sizeOf(Io.VTable) > 0);
    vtable.async = slot_async;
    vtable.concurrent = slot_concurrent;
    vtable.await = slot_await;
    vtable.cancel = slot_cancel;
    vtable.checkCancel = slot_check_cancel;
    vtable.recancel = slot_recancel;
    vtable.swapCancelProtection = slot_swap_cancel_protection;
    vtable.groupAsync = slot_group_async;
    vtable.groupConcurrent = slot_group_concurrent;
    vtable.groupAwait = slot_group_await;
    vtable.groupCancel = slot_group_cancel;
    vtable.crashHandler = slot_crash_handler;
}

/// Brings `rt.sched` into existence on the first `Runtime.io()`. The `Runtime` is pinned from
/// that call on, which is what makes the `*Sched` inside every fiber stable; the recorded address
/// is re-checked on every later call. Allocation failure is not an error: it leaves the runtime
/// `.unavailable`, where `async` runs inline and `concurrent` refuses, both in the contract.
pub fn sched_ensure(rt: *Runtime) void {
    switch (rt.sched_state) {
        .unsupported => assert(!Sched.supported),
        .unavailable => assert(rt.sched_pin == 0),
        .ready => assert(rt.sched_pin == @intFromPtr(&rt.sched)),
        .pending => {
            assert(Sched.supported);
            const options: Sched.Options = .{
                .fibers_max = rt.fibers_max,
                .stack_size = rt.fiber_stack_size,
                .now_ns = std.math.lossyCast(u64, Io.Clock.awake.now(rt.baselineIo()).nanoseconds),
            };
            rt.sched.init(rt.threaded.allocator, options) catch |err| switch (err) {
                error.OutOfMemory, error.FibersUnsupported => {
                    rt.sched_state = .unavailable;
                    return;
                },
            };
            rt.sched.expiry = futex.expiry(&rt.waits);
            rt.sched_pin = @intFromPtr(&rt.sched);
            rt.sched_state = .ready;
        },
    }
}

pub fn runtime_of(userdata: ?*anyopaque) *Runtime {
    assert(userdata != null);
    const threaded: *Io.Threaded = @ptrCast(@alignCast(userdata.?));
    const rt: *Runtime = @fieldParentPtr("threaded", threaded);
    assert(rt.sched_state == .ready or rt.sched_state == .unavailable);
    return rt;
}

fn slot_async(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Io.AnyFuture {
    const rt = runtime_of(userdata);
    if (rt.sched_state != .ready or !rt.sched.has_free_fiber()) {
        return run_inline(result, context, start);
    }
    assert(rt.sched_pin == @intFromPtr(&rt.sched));
    const body: Body = .{ .future = start };
    const task = task_create(rt, result.len, result_alignment, context, context_alignment, body);
    const task_ok = task orelse return run_inline(result, context, start);
    // Eager start: the body runs now, until it first parks or ends (`Io.async` permits it).
    rt.sched.spawn_first(rt.baselineIo(), task_entry, task_ok) catch |err| switch (err) {
        // `has_free_fiber` held on this thread a moment ago and nothing ran in between.
        error.FibersExhausted => unreachable,
    };
    return @ptrCast(task_ok);
}

fn run_inline(
    result: []u8,
    context: []const u8,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Io.AnyFuture {
    if (result.len != 0) assert(@intFromPtr(result.ptr) != 0);
    if (context.len != 0) assert(@intFromPtr(context.ptr) != 0);
    start(context.ptr, result.ptr);
    return null;
}

fn slot_concurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    const rt = runtime_of(userdata);
    if (context.len != 0) assert(@intFromPtr(context.ptr) != 0);
    assert(rt.sched_state != .pending);
    _ = .{ result_len, result_alignment, context_alignment, start };
    return error.ConcurrencyUnavailable;
}

fn slot_await(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    const rt = runtime_of(userdata);
    assert(rt.sched_state == .ready);
    task_finish(rt, @ptrCast(@alignCast(any_future)), result, result_alignment);
}

fn slot_cancel(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    const rt = runtime_of(userdata);
    assert(rt.sched_state == .ready);
    const task: *Task = @ptrCast(@alignCast(any_future));
    assert(task.cancel == .none); // `cancel` consumes the future: once.
    task_request_cancel(task);
    task_finish(rt, task, result, result_alignment);
}

/// The task running on the calling fiber, or null when the caller is not on a fiber: the carrier
/// outside `run`, or any other thread (a worker of the forwarded `Io.Threaded` running a group
/// task receives `rt.io()` too). Callers forward a null to the baseline, which holds the cancel
/// state of those threads.
pub fn current_task(rt: *Runtime) ?*Task {
    // `.unavailable`: the scheduler never existed, so every task ran inline on the caller.
    if (rt.sched_state != .ready) return null;
    if (!rt.sched.in_fiber()) return null;
    const arg = rt.sched.current_fiber().arg;
    // Every fiber is spawned by `slot_async`/`slot_group_async` with its task as the argument.
    assert(arg != null);
    const task: *Task = @ptrCast(@alignCast(arg.?));
    assert(task.sched == &rt.sched);
    assert(!task.done);
    return task;
}

fn slot_check_cancel(userdata: ?*anyopaque) Io.Cancelable!void {
    const rt = runtime_of(userdata);
    const task = current_task(rt) orelse return rt.baselineIo().checkCancel();
    if (task_acknowledge_cancel(task)) return error.Canceled;
}

/// True when `task` has an unprotected pending request, which this call acknowledges.
pub fn task_acknowledge_cancel(task: *Task) bool {
    switch (task.protection) {
        .blocked => return false,
        .unblocked => {},
    }
    switch (task.cancel) {
        .none, .acknowledged => return false,
        .requested => {
            task.cancel = .acknowledged;
            return true;
        },
    }
}

/// Sets the request flag and, when the task's fiber is parked in a cancelable `futexWait` or
/// `groupAwait`, unparks it so the wait can return `error.Canceled` (the awaiter then cancels the
/// members itself).
fn task_request_cancel(task: *Task) void {
    assert(task.cancel == .none);
    if (task.waiting != null) assert(!task.done); // A finished task is no longer parked.
    if (task.awaiting != null) assert(!task.done);
    task.cancel = .requested;
    if (task.awaiting) |rec| {
        // Protection cannot change while the task is parked, and `group_park` arms `awaiting`
        // only for an unprotected awaiter. The wake is one-shot: a finished group already woke it.
        assert(task.waiting == null);
        assert(task.protection == .unblocked);
        if (rec.waiter) |waiter| {
            rec.waiter = null;
            task.sched.unpark(waiter);
        }
        return;
    }
    const fiber = task.waiting orelse return;
    const rt: *Runtime = @fieldParentPtr("sched", task.sched);
    futex.cancel_wait(&rt.waits, task.sched, fiber);
}

/// `futex.zig` brackets a cancelable park with `fiber` and then null: while armed, a request
/// unparks the fiber. Protection cannot change while the task is parked, so a protected task is
/// simply never armed.
pub fn task_cancel_wake(task: *Task, fiber: ?*Sched.Fiber) void {
    assert(!task.done);
    if (fiber != null) assert(task.waiting == null);
    task.waiting = switch (task.protection) {
        .blocked => null,
        .unblocked => fiber,
    };
}

fn slot_recancel(userdata: ?*anyopaque) void {
    const rt = runtime_of(userdata);
    const task = current_task(rt) orelse return rt.baselineIo().recancel();
    // Called without a delivered cancelation: a caller bug, as in std.
    assert_always(task.cancel == .acknowledged);
    task.cancel = .requested;
}

fn slot_swap_cancel_protection(
    userdata: ?*anyopaque,
    new: Io.CancelProtection,
) Io.CancelProtection {
    const rt = runtime_of(userdata);
    const task = current_task(rt) orelse return rt.baselineIo().swapCancelProtection(new);
    const old = task.protection;
    task.protection = new;
    return old;
}

fn task_create(
    rt: *Runtime,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    body: Body,
) ?*Task {
    const alignment = result_alignment.max(context_alignment).max(.of(Task));
    const context_offset = context_alignment.forward(@sizeOf(Task));
    const result_offset = result_alignment.forward(context_offset + context.len);
    const alloc_len = result_offset + result_len;
    assert(result_offset >= context_offset + context.len);

    const base = rt.threaded.allocator.rawAlloc(alloc_len, alignment, @returnAddress()) orelse {
        return null;
    };
    const task: *Task = @ptrCast(@alignCast(base));
    task.* = .{
        .sched = &rt.sched,
        .body = body,
        .group = null,
        .prev = null,
        .next = null,
        .waiter = null,
        .waiting = null,
        .awaiting = null,
        .context_offset = context_offset,
        .result_offset = result_offset,
        .result_len = result_len,
        .alloc_len = alloc_len,
        .alloc_alignment = alignment,
        .done = false,
        .cancel = .none,
        .protection = .unblocked,
    };
    assert(context_alignment.check(@intFromPtr(task.context())));
    assert(result_alignment.check(@intFromPtr(task.result())));
    @memcpy(base[context_offset..][0..context.len], context);
    return task;
}

/// Fiber body of every task: run the user function, then publish completion (a future wakes its
/// waiter; a group member leaves its group and frees its own record).
fn task_entry(arg: ?*anyopaque) void {
    const task: *Task = @ptrCast(@alignCast(arg.?));
    assert(!task.done);
    assert(task.sched.in_fiber());
    switch (task.body) {
        .future => |start| {
            assert(task.group == null);
            start(task.context(), task.result());
            task.done = true;
            if (task.waiter) |waiter| {
                task.waiter = null;
                task.sched.unpark(waiter);
            }
        },
        .member => |start| {
            assert(task.group != null);
            start(task.context());
            member_finish(task);
        },
    }
}

/// Waits for `task` (parking inside a fiber, driving the scheduler outside one), moves the result
/// out and frees the record.
fn task_finish(
    rt: *Runtime,
    task: *Task,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    assert(task.sched == &rt.sched);
    assert(result.len == task.result_len);
    if (!task.done) {
        if (rt.sched.in_fiber()) {
            assert_always(task.waiter == null); // Awaited once: a second waiter would be lost.
            task.waiter = rt.sched.current_fiber();
            rt.sched.park();
        } else {
            // Outside any fiber the carrier loop is not running (all fibers run inside `run`).
            assert(!rt.sched.running);
            rt.sched.run_until(rt.baselineIo(), &task.done);
        }
    }
    assert_always(task.done);
    assert(task.waiter == null);
    assert(result_alignment.check(@intFromPtr(task.result())));
    @memcpy(result, @as([*]const u8, @ptrCast(task.result()))[0..task.result_len]);
    task_free(rt, task);
}

fn task_free(rt: *Runtime, task: *Task) void {
    assert(task.sched == &rt.sched);
    assert(task.waiter == null);
    const base: [*]u8 = @ptrCast(task);
    rt.threaded.allocator.rawFree(base[0..task.alloc_len], task.alloc_alignment, @returnAddress());
}

fn slot_group_async(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    const rt = runtime_of(userdata);
    if (rt.sched_state != .ready or !rt.sched.has_free_fiber()) return start(context.ptr);
    assert(rt.sched_pin == @intFromPtr(&rt.sched));
    const body: Body = .{ .member = start };
    const task = task_create(rt, 0, .@"1", context, context_alignment, body) orelse {
        return start(context.ptr);
    };
    const rec = group_rec_ensure(rt, group) orelse {
        task_free(rt, task);
        return start(context.ptr);
    };
    assert(rec.sched == &rt.sched);
    task.group = rec;
    task.next = rec.head;
    if (rec.head) |head| head.prev = task;
    rec.head = task;
    rec.pending += 1;
    rec.idle = false;
    if (rec.canceling) task.cancel = .requested;
    const fiber = rt.sched.spawn(task_entry, task) catch |err| switch (err) {
        // `has_free_fiber` held on this thread a moment ago and nothing ran in between.
        error.FibersExhausted => unreachable,
    };
    assert(fiber.state == .ready);
    assert(group.token.raw == @as(?*anyopaque, rec));
}

/// The group's record, created on the first member that gets a fiber; null on out-of-memory.
fn group_rec_ensure(rt: *Runtime, group: *Io.Group) ?*GroupRec {
    if (group.token.load(.acquire)) |token| return @ptrCast(@alignCast(token));
    const rec = rt.threaded.allocator.create(GroupRec) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
    rec.* = .{
        .sched = &rt.sched,
        .head = null,
        .pending = 0,
        .idle = true,
        .waiter = null,
        .canceling = false,
    };
    group.token.store(rec, .release);
    assert(rec.idle);
    assert(rec.pending == 0);
    return rec;
}

fn slot_group_concurrent(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) void,
) Io.ConcurrentError!void {
    const rt = runtime_of(userdata);
    if (context.len != 0) assert(@intFromPtr(context.ptr) != 0);
    assert(rt.sched_state != .pending);
    _ = .{ group, context_alignment, start };
    return error.ConcurrencyUnavailable;
}

fn slot_group_await(
    userdata: ?*anyopaque,
    group: *Io.Group,
    token: *anyopaque,
) Io.Cancelable!void {
    const rt = runtime_of(userdata);
    const rec: *GroupRec = @ptrCast(@alignCast(token));
    assert(group.token.raw == token);
    assert(rec.sched == &rt.sched);
    // A canceled awaiter cancels its members ("propagate to all members") and reports it once the
    // group has finished, so no member outlives the call.
    const canceled = if (current_task(rt)) |task| task_acknowledge_cancel(task) else false;
    if (canceled) group_request_cancel(rec);
    const canceled_parked = group_finish(rt, group, rec, .cancelable);
    if (canceled or canceled_parked) return error.Canceled;
}

fn slot_group_cancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
    const rt = runtime_of(userdata);
    const rec: *GroupRec = @ptrCast(@alignCast(token));
    assert(group.token.raw == token);
    assert(rec.sched == &rt.sched);
    group_request_cancel(rec);
    _ = group_finish(rt, group, rec, .uncancelable);
}

fn group_request_cancel(rec: *GroupRec) void {
    assert((rec.head == null) == (rec.pending == 0));
    rec.canceling = true;
    var node = rec.head;
    for (0..rec.pending) |_| {
        const member = node.?;
        if (member.cancel == .none) task_request_cancel(member);
        node = member.next;
    }
    assert(node == null);
}

/// A group awaiter parks at most twice: once until a cancel or the last member, and once more for
/// the last member after a cancel (a second request cannot arrive: the first is delivered).
const parks_max = 2;

/// Whether the park in `group_finish` is a cancelation point.
const GroupWait = enum { cancelable, uncancelable };

/// Waits until every member finished (parking inside a fiber, driving the scheduler outside one),
/// then releases the record and nulls the token, as `Io.Group.await` asserts. Returns true when a
/// cancel that arrived during a `.cancelable` park was acknowledged; the members were canceled and
/// all of them finished before it returns.
fn group_finish(rt: *Runtime, group: *Io.Group, rec: *GroupRec, wait: GroupWait) bool {
    // A member waiting for its own group could never be woken: the count never reaches zero.
    if (current_task(rt)) |task| assert_always(task.group != rec);
    var canceled = false;
    if (!rec.idle) {
        if (rt.sched.in_fiber()) {
            canceled = group_park(rt, rec, wait);
        } else {
            assert(!rt.sched.running);
            rt.sched.run_until(rt.baselineIo(), &rec.idle);
        }
    }
    assert_always(rec.idle);
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
    const task = current_task(rt).?;
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
        rec.waiter = rt.sched.current_fiber();
        rt.sched.park();
        if (rec.idle) break;
        // Woken by a cancel (a finished group wakes only with `idle` set).
        assert(task.awaiting != null);
        assert(!canceled);
        canceled = task_acknowledge_cancel(task);
        assert_always(canceled);
        group_request_cancel(rec);
        task.awaiting = null; // A second request cannot arrive: the flag is already delivered.
    }
    assert(rec.idle);
    return canceled;
}

/// End of a group member's fiber: leave the list, free the record, wake the awaiting fiber when
/// this was the last member.
fn member_finish(task: *Task) void {
    const rec = task.group.?;
    const rt: *Runtime = @fieldParentPtr("sched", task.sched);
    assert(rec.pending > 0);
    assert(!rec.idle);
    if (task.prev) |prev| prev.next = task.next else rec.head = task.next;
    if (task.next) |next| next.prev = task.prev;
    task_free(rt, task);
    rec.pending -= 1;
    if (rec.pending > 0) return;
    rec.idle = true;
    if (rec.waiter) |waiter| {
        rec.waiter = null;
        rec.sched.unpark(waiter);
    }
}

/// Marks the calling task canceled and protected, so a panic handler's cleanup cannot block; on
/// any other thread the baseline owns the state.
fn slot_crash_handler(userdata: ?*anyopaque) void {
    const rt = runtime_of(userdata);
    const task = current_task(rt) orelse {
        const baseline = rt.baselineIo();
        return baseline.vtable.crashHandler(baseline.userdata);
    };
    // `.acknowledged` is Threaded's `.canceled`: already delivered, so lifting protection later
    // does not interrupt the cleanup that follows.
    assert(!task.done);
    task.cancel = .acknowledged;
    task.protection = .blocked;
    assert(task.cancel == .acknowledged);
}
