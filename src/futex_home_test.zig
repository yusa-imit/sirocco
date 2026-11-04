//! Tests of futex wake routing across carriers (ADR 0004 section 4, plan 005 item 7): a fiber
//! parked in the shared `futex.Table` is woken on its home carrier whichever thread or carrier
//! calls `Table.wake`. Each test runs real peer threads and waits on atomics with a bounded spin.

const std = @import("std");
const stdx = @import("stdx.zig");
const futex = @import("futex.zig");
const mail = @import("mail.zig");
const Sched = @import("sched.zig");

const Io = std.Io;
const Mail = mail.Mail;
const Table = futex.Table;
const assert = stdx.assert;

const stack_size_test: u32 = 64 * 1024;
const spin_max: u32 = 20_000_000;

const Case = struct {
    table: Table,
    word: u32,
    io: Io,
    /// The carrier the waiter fiber is homed on.
    home: *Sched,
    /// Written by the waiter after it resumes, read by the test after `done` reached 1.
    outcome: Sched.WaitOutcome,
    resumed_on_home: bool,
    woken: std.atomic.Value(u32),
    done: std.atomic.Value(u32),
};

fn case_of(arg: ?*anyopaque) *Case {
    return @ptrCast(@alignCast(arg.?));
}

fn entry_wait(arg: ?*anyopaque) void {
    const case = case_of(arg);
    const fiber = case.home.current_fiber();
    assert(case.table.enqueue(fiber, &case.word, 0) == .queued);
    case.home.park();
    case.resumed_on_home = Sched.here() == case.home;
    case.outcome = fiber.wait.outcome;
    fiber.wait = .none;
    _ = case.done.fetchAdd(1, .release);
}

fn entry_wake(arg: ?*anyopaque) void {
    const case = case_of(arg);
    const count = case.table.wake(case.io, @intFromPtr(&case.word), 1);
    case.woken.store(count, .release);
}

fn serve_main(sched: *Sched, io: Io, stop: *const std.atomic.Value(bool)) void {
    mail.serve(sched, io, stop);
}

const Peer = struct {
    sched: Sched,
    stop: std.atomic.Value(bool),
    thread: std.Thread,

    fn start(peer: *Peer, io: Io) !void {
        try peer.sched.init(std.testing.allocator, .{
            .fibers_max = 2,
            .batch_ops_max = 0,
            .stack_size = stack_size_test,
            .now_ns = 0,
            .idle = .futex,
        });
        errdefer peer.sched.deinit(std.testing.allocator);

        peer.stop = .init(false);
        peer.thread = try std.Thread.spawn(.{}, serve_main, .{ &peer.sched, io, &peer.stop });
    }

    fn finish(peer: *Peer, io: Io) void {
        peer.stop.store(true, .release);
        peer.sched.notify(io);
        peer.thread.join();
        peer.sched.deinit(std.testing.allocator);
    }
};

fn case_make(io: Io, home: *Sched) Case {
    return .{
        .table = .init(4),
        .word = 0,
        .io = io,
        .home = home,
        .outcome = .idle,
        .resumed_on_home = false,
        .woken = .init(0),
        .done = .init(0),
    };
}

fn spin_until_queued(case: *Case) !void {
    for (0..spin_max) |_| {
        if (case.table.waiting_count() == 1) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.WaiterNeverQueued;
}

fn spin_until_done(case: *Case) !void {
    for (0..spin_max) |_| {
        if (case.done.load(.acquire) == 1) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.WaiterNeverWoke;
}

test "a wake from a thread off every carrier resumes the fiber on its home carrier" {
    if (!Sched.supported) return error.SkipZigTest;
    const io = std.testing.io;
    var home: Peer = undefined;
    try home.start(io);
    var case = case_make(io, &home.sched);
    var waiter: Mail = .init(entry_wait, &case);

    mail.post(&home.sched, io, &waiter);
    spin_until_queued(&case) catch |err| {
        home.finish(io);
        return err;
    };
    const count = case.table.wake(io, @intFromPtr(&case.word), 1);
    spin_until_done(&case) catch |err| {
        home.finish(io);
        return err;
    };
    home.finish(io);

    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(Sched.WaitOutcome.woken, case.outcome);
    try std.testing.expect(case.resumed_on_home);
    try std.testing.expectEqual(@as(u32, 0), case.table.waiting_count());
}

test "a wake from a fiber on another carrier resumes the fiber on its home carrier" {
    if (!Sched.supported) return error.SkipZigTest;
    const io = std.testing.io;
    var home: Peer = undefined;
    try home.start(io);
    var other: Peer = undefined;
    other.start(io) catch |err| {
        home.finish(io);
        return err;
    };
    var case = case_make(io, &home.sched);
    var waiter: Mail = .init(entry_wait, &case);
    var waker: Mail = .init(entry_wake, &case);

    mail.post(&home.sched, io, &waiter);
    spin_until_queued(&case) catch |err| {
        other.finish(io);
        home.finish(io);
        return err;
    };
    mail.post(&other.sched, io, &waker);
    spin_until_done(&case) catch |err| {
        other.finish(io);
        home.finish(io);
        return err;
    };
    other.finish(io);
    home.finish(io);

    try std.testing.expectEqual(@as(u32, 1), case.woken.load(.acquire));
    try std.testing.expectEqual(Sched.WaitOutcome.woken, case.outcome);
    try std.testing.expect(case.resumed_on_home);
    try std.testing.expectEqual(@as(u32, 0), case.table.waiting_count());
}
