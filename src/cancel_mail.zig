//! Cancel mail: how a cancel reaches a task homed on another carrier (ADR 0004 section 3, plan
//! 005 item 7).
//!
//! Purpose: the cancel state of a task (`Task.cancel`, `Task.waiting`, `Task.awaiting`) is owned
//! by the task's home carrier, so a canceler running anywhere else does not touch it. `request`
//! mails the cancel to the home (`src/mail.zig`); a fiber started there applies it with
//! `task_request_cancel`, exactly as a same-carrier cancel does, then finishes the slot's join
//! word. `settle` is the canceler's wait for that word: the mail lives inside the task record, so
//! the record must not be freed before the home has read it.
//!
//! Invariants: a task is canceled once, so a slot posts at most one mail. The handler skips the
//! request when the task is already done (it ran to completion first), which is decided on the
//! home, where finishing and canceling cannot interleave. The handler's last touch of the task is
//! the wake of the settler.
//!
//! Allocation: none; the mail and join word are part of the `Task`. Threads: `request` and
//! `settle` any thread (the canceler's), the handler on the task's home carrier.

const std = @import("std");
const stdx = @import("stdx.zig");
const concurrency = @import("concurrency.zig");
const join = @import("join.zig");
const mail = @import("mail.zig");
const Sched = @import("sched.zig");

const Io = std.Io;
const Task = concurrency.Task;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

/// Bound on the settler's futex sleeps; a wake after the signal is set ends the first one.
const wait_iterations_max: u32 = 1 << 20;

/// The canceler's side of one task's cancel mail; lives in the `Task`.
pub const Slot = struct {
    mail: mail.Mail,
    /// Running until the home has handled the mail; then done (`src/join.zig`).
    join: join.Word,
    /// Set to 1 for an off-fiber settler, which sleeps on it in the baseline futex: carrier 0 may
    /// have no fiber to drive, so `run_until` would return at once.
    signal: u32,
    /// Whether `request` mailed a cancel; written by the canceler only.
    posted: bool,

    pub fn init() Slot {
        return .{
            .mail = .init(handle, null),
            .join = join.init,
            .signal = 0,
            .posted = false,
        };
    }
};

/// Whether the calling thread is not the carrier that owns `task`. Carrier 0's own thread counts
/// as carrier 0 even outside `run`, where it drives the scheduler. Any thread.
pub fn is_remote(task: *const Task) bool {
    if (Sched.here()) |here| return here != task.sched;
    return task.sched != &task.rt.sched;
}

/// Requests cancelation of `task`: applied now on its own carrier, else mailed to it. Any thread.
/// Preconditions: not requested before, and the caller `settle`s before it frees the task.
pub fn request(task: *Task, io: Io) void {
    if (!is_remote(task)) return concurrency.task_request_cancel(task);
    assert(!task.cancel_slot.posted);
    task.cancel_slot.posted = true;
    task.cancel_slot.mail.arg = task;
    mail.post(task.sched, io, &task.cancel_slot.mail);
}

/// Waits until the home has handled a mailed cancel; returns at once when none was mailed.
/// Parks a calling fiber; any other thread sleeps in the futex. After it returns nothing
/// refers to the task's slot any more, so the task may be freed.
pub fn settle(task: *Task) void {
    const slot = &task.cancel_slot;
    if (!slot.posted) return;
    if (Sched.here()) |here| {
        if (here.in_fiber()) {
            if (join.await_fiber(&slot.join, here.current_fiber())) here.park();
            assert_always(join.is_done(&slot.join));
            return;
        }
    }
    if (join.await_driver(&slot.join)) {
        const io = task.rt.baselineIo();
        for (0..wait_iterations_max) |_| {
            if (@atomicLoad(u32, &slot.signal, .acquire) != 0) break;
            io.futexWaitUncancelable(u32, &slot.signal, 0);
        }
    }
    assert_always(join.is_done(&slot.join));
}

/// Fiber body started on the home carrier by the posted mail.
fn handle(arg: ?*anyopaque) void {
    assert(arg != null);
    const task: *Task = @ptrCast(@alignCast(arg.?));
    // Read first: the settler may free the task as soon as it is woken.
    const rt = task.rt;
    assert(task.sched.in_fiber());
    assert(task.cancel_slot.posted);
    if (!concurrency.task_is_done(task)) concurrency.task_request_cancel(task);
    const waiter = join.finish(&task.cancel_slot.join);
    const io = rt.baselineIo();
    switch (waiter) {
        .none => {},
        .driver => {
            // Read before the store: the settler may free the task once it sees the signal. The
            // futex is keyed by address, so waking after the free is harmless.
            const signal = &task.cancel_slot.signal;
            @atomicStore(u32, signal, 1, .release);
            io.futexWake(u32, signal, 1);
        },
        .fiber => |fiber| join.wake_fiber(fiber, io),
    }
}
