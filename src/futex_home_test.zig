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
    /// The waiter fiber, published by the waiter before it parks.
    fiber: std.atomic.Value(?*Sched.Fiber),
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
    const queued = case.table.enqueue(fiber, &case.word, 0);
    assert(queued == .queued);
    case.fiber.store(fiber, .release);
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
        .fiber = .init(null),
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

/// Failure path: a waiter left parked would keep its carrier from stopping, so wake it first.
fn abandon(case: *Case, peers: []const *Peer) void {
    _ = case.table.wake(case.io, @intFromPtr(&case.word), 8);
    for (peers) |peer| peer.finish(case.io);
}

fn entry_cancel(arg: ?*anyopaque) void {
    const case = case_of(arg);
    futex.cancel_wait(&case.table, case.home, case.fiber.load(.acquire).?);
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
        abandon(&case, &.{&home});
        return err;
    };
    const count = case.table.wake(io, @intFromPtr(&case.word), 1);
    spin_until_done(&case) catch |err| {
        abandon(&case, &.{&home});
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
        abandon(&case, &.{ &other, &home });
        return err;
    };
    mail.post(&other.sched, io, &waker);
    spin_until_done(&case) catch |err| {
        abandon(&case, &.{ &other, &home });
        return err;
    };
    other.finish(io);
    home.finish(io);

    try std.testing.expectEqual(@as(u32, 1), case.woken.load(.acquire));
    try std.testing.expectEqual(Sched.WaitOutcome.woken, case.outcome);
    try std.testing.expect(case.resumed_on_home);
    try std.testing.expectEqual(@as(u32, 0), case.table.waiting_count());
}

test "a cancel on the home carrier ends the wait with the canceled outcome" {
    if (!Sched.supported) return error.SkipZigTest;
    const io = std.testing.io;
    var home: Peer = undefined;
    try home.start(io);
    var case = case_make(io, &home.sched);
    var waiter: Mail = .init(entry_wait, &case);
    var canceler: Mail = .init(entry_cancel, &case);

    mail.post(&home.sched, io, &waiter);
    spin_until_queued(&case) catch |err| {
        abandon(&case, &.{&home});
        return err;
    };
    mail.post(&home.sched, io, &canceler);
    spin_until_done(&case) catch |err| {
        abandon(&case, &.{&home});
        return err;
    };
    home.finish(io);

    try std.testing.expectEqual(Sched.WaitOutcome.canceled, case.outcome);
    try std.testing.expect(case.resumed_on_home);
    try std.testing.expectEqual(@as(u32, 0), case.table.waiting_count());
    try std.testing.expectEqual(@as(u32, 0), case.table.wake(io, @intFromPtr(&case.word), 1));
}

const Pair = struct {
    table: Table,
    word: u32,
    slots: [2]Slot,
    done: std.atomic.Value(u32),
};

const Slot = struct {
    pair: *Pair,
    home: *Sched,
    outcome: Sched.WaitOutcome,
    resumed_on_home: bool,
};

fn slot_make(pair: *Pair, home: *Sched) Slot {
    return .{ .pair = pair, .home = home, .outcome = .idle, .resumed_on_home = false };
}

fn entry_pair_wait(arg: ?*anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(arg.?));
    const fiber = slot.home.current_fiber();
    const queued = slot.pair.table.enqueue(fiber, &slot.pair.word, 0);
    assert(queued == .queued);
    slot.home.park();
    slot.resumed_on_home = Sched.here() == slot.home;
    slot.outcome = fiber.wait.outcome;
    fiber.wait = .none;
    _ = slot.pair.done.fetchAdd(1, .release);
}

fn spin_until_pair(pair: *Pair, count: u32, done: bool) !void {
    for (0..spin_max) |_| {
        const seen = if (done) pair.done.load(.acquire) else pair.table.waiting_count();
        if (seen == count) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.WaiterNeverSettled;
}

test "one wake of two waiters homed on different carriers resumes each on its own" {
    if (!Sched.supported) return error.SkipZigTest;
    const io = std.testing.io;
    var first: Peer = undefined;
    try first.start(io);
    var second: Peer = undefined;
    second.start(io) catch |err| {
        first.finish(io);
        return err;
    };
    var pair: Pair = .{
        .table = .init(4),
        .word = 0,
        .slots = undefined,
        .done = .init(0),
    };
    pair.slots[0] = slot_make(&pair, &first.sched);
    pair.slots[1] = slot_make(&pair, &second.sched);
    var mail_first: Mail = .init(entry_pair_wait, &pair.slots[0]);
    var mail_second: Mail = .init(entry_pair_wait, &pair.slots[1]);

    mail.post(&first.sched, io, &mail_first);
    mail.post(&second.sched, io, &mail_second);
    errdefer {
        _ = pair.table.wake(io, @intFromPtr(&pair.word), 8);
        second.finish(io);
        first.finish(io);
    }
    try spin_until_pair(&pair, 2, false);
    const count = pair.table.wake(io, @intFromPtr(&pair.word), 2);
    try spin_until_pair(&pair, 2, true);
    second.finish(io);
    first.finish(io);

    try std.testing.expectEqual(@as(u32, 2), count);
    for (pair.slots) |slot| {
        try std.testing.expectEqual(Sched.WaitOutcome.woken, slot.outcome);
        try std.testing.expect(slot.resumed_on_home);
    }
    try std.testing.expectEqual(@as(u32, 0), pair.table.waiting_count());
}
