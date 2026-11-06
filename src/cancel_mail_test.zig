//! Tests of the cancel mail (ADR 0004 section 3, plan 005 item 7): a cancel requested off the
//! task's home carrier is mailed there and applied by a fiber on the home, and the canceler waits
//! for that mail before it frees the task. No placement exists yet, so each test makes a task
//! record by hand, homes it on peer carrier 1 and starts it with a mail. Waits on atomics are
//! bounded spins.

const std = @import("std");
const stdx = @import("stdx.zig");
const cancel_mail = @import("cancel_mail.zig");
const concurrency = @import("concurrency.zig");
const mail = @import("mail.zig");
const Runtime = @import("runtime.zig");
const Sched = @import("sched.zig");

const assert = stdx.assert;
const Task = concurrency.Task;

const spin_max: u32 = 20_000_000;

const Case = struct {
    rt: *Runtime,
    task: *Task,
    /// The futex word the task parks on (never changed, so only a cancel ends the wait).
    word: u32,
    /// Park in the futex before returning; false makes the task finish at once.
    park: bool,
    parked: std.atomic.Value(bool),
    /// Written by the task's fiber before it ends, read by the test after the task is done.
    outcome: Sched.WaitOutcome,
    acknowledged: bool,
    ran_on_home: bool,
};

fn options() Runtime.Options {
    return .{
        .backend = .threaded,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
        .carriers = 2,
        .fibers_max = 4,
        .batch_ops_max = 8,
        .fiber_stack_size = 128 * 1024,
        .offload_threads = 2,
        .sockets_max = 8,
    };
}

/// Body of the hand-made task, running on peer carrier 1.
fn task_body(context: *const anyopaque, result: *anyopaque) void {
    _ = result;
    const case = @as(*const *Case, @ptrCast(@alignCast(context))).*;
    const home = case.task.sched;
    case.ran_on_home = Sched.here() == home;
    if (!case.park) return;

    const fiber = home.current_fiber();
    const queued = case.rt.waits.enqueue(fiber, &case.word, 0);
    assert(queued == .queued);
    concurrency.task_cancel_wake(case.task, fiber);
    case.parked.store(true, .release);
    home.park();
    concurrency.task_cancel_wake(case.task, null);
    case.outcome = fiber.wait.outcome;
    fiber.wait = .none;
    if (case.outcome == .canceled) {
        case.acknowledged = concurrency.task_acknowledge_cancel(case.task);
    }
}

fn case_make(rt: *Runtime, park: bool) !*Case {
    const case = try std.testing.allocator.create(Case);
    case.* = .{
        .rt = rt,
        .task = undefined,
        .word = 0,
        .park = park,
        .parked = .init(false),
        .outcome = .idle,
        .acknowledged = false,
        .ran_on_home = false,
    };
    const context = std.mem.asBytes(&case);
    const alignment: std.mem.Alignment = .of(*Case);
    const body: concurrency.Body = .{ .future = task_body };
    case.task = concurrency.task_create(rt, 0, .@"1", context, alignment, body) orelse {
        return error.OutOfMemory;
    };
    return case;
}

fn case_free(rt: *Runtime, case: *Case) void {
    concurrency.task_free(rt, case.task);
    std.testing.allocator.destroy(case);
}

/// Homes the task on peer carrier 1 and mails it its fiber.
fn case_start(rt: *Runtime, case: *Case, start: *mail.Mail) void {
    const peer = &rt.peers[0].sched;
    case.task.sched = peer;
    start.* = mail.Mail.init(concurrency.task_entry, case.task);
    mail.post(peer, rt.baselineIo(), start);
}

fn spin_until(flag: *const std.atomic.Value(bool)) !void {
    for (0..spin_max) |_| {
        if (flag.load(.acquire)) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.NeverHappened;
}

fn spin_until_done(task: *const Task) !void {
    for (0..spin_max) |_| {
        if (concurrency.task_is_done(task)) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.TaskNeverFinished;
}

test "a cancel from the driver is mailed to the home and ends a parked task" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, options());
    defer rt.deinit();

    _ = rt.io();
    const case = try case_make(&rt, true);
    defer case_free(&rt, case);

    var start: mail.Mail = undefined;
    case_start(&rt, case, &start);
    try spin_until(&case.parked);

    // The driver is not carrier 1, so this must travel as mail.
    try std.testing.expect(cancel_mail.is_remote(case.task));
    cancel_mail.request(case.task, rt.baselineIo());
    try std.testing.expect(case.task.cancel_slot.posted);
    cancel_mail.settle(case.task);
    try spin_until_done(case.task);

    try std.testing.expect(case.ran_on_home);
    try std.testing.expectEqual(Sched.WaitOutcome.canceled, case.outcome);
    try std.testing.expect(case.acknowledged);
    try std.testing.expectEqual(@as(u32, 0), rt.waits.waiting_count());
}

test "a cancel mailed after the task finished is a no-op on the home" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, options());
    defer rt.deinit();

    _ = rt.io();
    const case = try case_make(&rt, false);
    defer case_free(&rt, case);

    var start: mail.Mail = undefined;
    case_start(&rt, case, &start);
    try spin_until_done(case.task);

    cancel_mail.request(case.task, rt.baselineIo());
    cancel_mail.settle(case.task);

    // The handler saw a finished task and left the request flag alone.
    try std.testing.expect(case.ran_on_home);
    try std.testing.expect(case.task.cancel_slot.posted);
    try std.testing.expectEqual(concurrency.CancelState.none, case.task.cancel);
    try std.testing.expectEqual(Sched.WaitOutcome.idle, case.outcome);
}

test "a cancel on the task's own carrier is applied at once and posts no mail" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, options());
    defer rt.deinit();

    _ = rt.io();
    const case = try case_make(&rt, false);
    defer case_free(&rt, case);

    // Homed on carrier 0, which the driver thread stands for outside `run`.
    try std.testing.expect(case.task.sched == &rt.sched);
    try std.testing.expect(!cancel_mail.is_remote(case.task));
    cancel_mail.request(case.task, rt.baselineIo());
    try std.testing.expect(!case.task.cancel_slot.posted);
    try std.testing.expectEqual(concurrency.CancelState.requested, case.task.cancel);
    cancel_mail.settle(case.task);
}
