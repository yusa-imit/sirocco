//! sirocco's future-producing `Io` slots: `async`, `concurrent`, `await`, `cancel` (plan 002
//! item 5), installed by `Runtime` as one set because `await`/`cancel` receive the `*AnyFuture`
//! that `async` produced, so a half-native vtable would hand a sirocco future to Threaded.
//!
//! Model: one carrier thread, many fibers (`Sched`). `async` allocates a task record, copies the
//! context into it and spawns a fiber that runs `start` and then marks the task done; the fiber
//! does not run until the carrier does: from `await`/`cancel` called outside any fiber (which
//! drives `Sched.run_until` the awaited task is done, so later tasks stay pending) or whenever
//! another fiber parks. Scheduling is FIFO, so the interleaving of a single-threaded program is
//! deterministic. `await` inside a fiber records itself as the task's waiter and parks; the
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
//! forward to the embedded `Io.Threaded`, which owns the state of those threads). No
//! native slot parks cancelably yet (`await`/`cancel` cannot return `error.Canceled`), so a cancel
//! never unparks its target; item 8's `futexWait` will. A task that never calls `checkCancel`
//! runs to completion and its result is delivered.
//!
//! Allocation: `async` still allocates one task record per started task from the allocator that
//! `Runtime` gave `Io.Threaded` (as Threaded itself does), freed by `await`/`cancel`; the
//! no-allocation contract is a later item. Fibers and stacks come from `Sched.init`.
//!
//! Known limits until item 8 (futex table): `async` is lazy, and forwarded blocking slots
//! (`futexWait`, `sleep`) block the carrier thread, so a task that only the caller's own flow can
//! unblock (`io.async(producer)` then `queue.getOne`) deadlocks where Threaded would complete.
//! Under `.forward`, `concurrent` is `ConcurrencyUnavailable` where Threaded would succeed.
//!
//! Threads: every slot runs on the carrier thread, the one that calls the first `await` outside a
//! fiber. The `Io` contract calls these slots thread-safe; this implementation is not yet, and a
//! second thread using the same `Io` is a contract breach. Every future must be awaited or
//! cancelled exactly once before `Runtime.deinit`.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");

const Io = std.Io;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

/// Per-future record: lives from `async` until `await`/`cancel` frees it, followed in the same
/// allocation by the copied context and the result storage (each at its own alignment).
const Task = struct {
    sched: *Sched,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    /// The single fiber parked in `await`/`cancel`, if any.
    waiter: ?*Sched.Fiber,
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

/// Overwrites the seven slots of `vtable`. Precondition: `Sched.supported`, otherwise the slots
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
            };
            rt.sched.init(rt.threaded.allocator, options) catch |err| switch (err) {
                error.OutOfMemory, error.FibersUnsupported => {
                    rt.sched_state = .unavailable;
                    return;
                },
            };
            rt.sched_pin = @intFromPtr(&rt.sched);
            rt.sched_state = .ready;
        },
    }
}

fn runtime_of(userdata: ?*anyopaque) *Runtime {
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
    const task = task_create(rt, result.len, result_alignment, context, context_alignment, start);
    const task_ok = task orelse return run_inline(result, context, start);
    const fiber = rt.sched.spawn(task_entry, task_ok) catch |err| switch (err) {
        // `has_free_fiber` held on this thread a moment ago and nothing ran in between.
        error.FibersExhausted => unreachable,
    };
    assert(fiber.state == .ready);
    return @ptrCast(task_ok);
}

fn run_inline(
    result: []u8,
    context: []const u8,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Io.AnyFuture {
    assert(result.len == 0 or @intFromPtr(result.ptr) != 0);
    assert(context.len == 0 or @intFromPtr(context.ptr) != 0);
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
    assert(context.len == 0 or @intFromPtr(context.ptr) != 0);
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
    task.cancel = .requested;
    task_finish(rt, task, result, result_alignment);
}

/// The task running on the calling fiber, or null when the caller is not on a fiber: the carrier
/// outside `run`, or any other thread (a worker of the forwarded `Io.Threaded` running a group
/// task receives `rt.io()` too). Callers forward a null to the baseline, which holds the cancel
/// state of those threads.
fn current_task(rt: *Runtime) ?*Task {
    // `.unavailable`: the scheduler never existed, so every task ran inline on the caller.
    if (rt.sched_state != .ready) return null;
    if (!rt.sched.in_fiber()) return null;
    const arg = rt.sched.current_fiber().arg;
    assert(arg != null); // Every fiber is spawned by `slot_async` with its task as the argument.
    const task: *Task = @ptrCast(@alignCast(arg.?));
    assert(task.sched == &rt.sched);
    assert(!task.done);
    return task;
}

fn slot_check_cancel(userdata: ?*anyopaque) Io.Cancelable!void {
    const rt = runtime_of(userdata);
    const task = current_task(rt) orelse return rt.baselineIo().checkCancel();
    switch (task.protection) {
        .blocked => return,
        .unblocked => {},
    }
    switch (task.cancel) {
        .none, .acknowledged => {},
        .requested => {
            task.cancel = .acknowledged;
            return error.Canceled;
        },
    }
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
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
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
        .start = start,
        .waiter = null,
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

/// Fiber body of every task: run the user function, publish completion, wake the waiter.
fn task_entry(arg: ?*anyopaque) void {
    const task: *Task = @ptrCast(@alignCast(arg.?));
    assert(!task.done);
    assert(task.sched.in_fiber());
    task.start(task.context(), task.result());
    task.done = true;
    if (task.waiter) |waiter| {
        task.waiter = null;
        task.sched.unpark(waiter);
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
    const base: [*]u8 = @ptrCast(task);
    rt.threaded.allocator.rawFree(base[0..task.alloc_len], task.alloc_alignment, @returnAddress());
}
