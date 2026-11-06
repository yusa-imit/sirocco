//! The join word of a future's task (ADR 0004 section 3, plan 005 item 7): who waits for it, and
//! whether it is done, in one atomic so a finisher and an awaiter on different carriers cannot
//! miss each other.
//!
//! Values: `0` running, `1` done, `2` an off-fiber driver is waiting, anything else a `*Fiber`
//! parked (or about to park) in `await`. The awaiter publishes itself with a compare-exchange from
//! `0`; the finisher writes the result first and then swaps in `1`, so a finisher that gets a
//! fiber or the driver marker back is the one that must wake it, and exactly one side wins.
//!
//! Invariants: a word goes `0 -> waiter -> 1` or `0 -> 1`, never back; it is awaited once (a
//! second awaiter would be lost, so `await_*` asserts the word was `0`); finished once.
//!
//! Allocation: none. Threads: any; the result written before `finish` is visible to an awaiter
//! that observes `1` (release on the swap, acquire on the observation).

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");

const Io = std.Io;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

pub const Word = std.atomic.Value(usize);

const running: usize = 0;
const done: usize = 1;
const driver: usize = 2;

// Fiber addresses must not collide with the three markers.
comptime {
    assert(@alignOf(Sched.Fiber) > driver);
}

pub const Waiter = union(enum) {
    /// Nobody was waiting; the next awaiter sees `done`.
    none,
    /// The off-fiber driver is in `run_until`; the finisher stops it and notifies carrier 0.
    driver,
    /// A fiber parked (or about to park) in `await`; wake it on its home carrier.
    fiber: *Sched.Fiber,
};

pub const init: Word = .init(running);

/// Whether the task has finished. An acquire load: the result is visible once this is true.
pub fn is_done(word: *const Word) bool {
    return word.load(.acquire) == done;
}

/// Registers `fiber` as the awaiter. Returns true when the caller must park (the finisher will
/// wake it), false when the task already finished and the caller must not park.
/// Precondition: nobody else awaits this word.
pub fn await_fiber(word: *Word, fiber: *Sched.Fiber) bool {
    const marker = @intFromPtr(fiber);
    assert(marker > driver);
    const seen = word.cmpxchgStrong(running, marker, .acq_rel, .acquire) orelse return true;
    assert_always(seen == done); // Awaited once: a second waiter would be lost.
    return false;
}

/// Registers the off-fiber driver as the awaiter; same contract as `await_fiber`. The caller then
/// drives the scheduler until the stop flag it passed to `run_until` is raised.
pub fn await_driver(word: *Word) bool {
    const seen = word.cmpxchgStrong(running, driver, .acq_rel, .acquire) orelse return true;
    assert_always(seen == done); // Awaited once: a second waiter would be lost.
    return false;
}

/// Publishes completion and says whom to wake. Call after the result is written.
/// Precondition: not finished before.
pub fn finish(word: *Word) Waiter {
    const seen = word.swap(done, .acq_rel);
    assert_always(seen != done); // Finished once.
    return switch (seen) {
        running => .none,
        driver => .driver,
        else => .{ .fiber = @ptrFromInt(seen) },
    };
}

/// Resumes `fiber`, the awaiter `finish` named, on its own carrier: directly when the caller is
/// a fiber of that carrier, else through its inbox. Any thread. The awaiter may free the word's
/// owner once resumed, so the owner is not read afterwards.
pub fn wake_fiber(fiber: *Sched.Fiber, io: Io) void {
    const home = fiber.home;
    if (home.in_fiber()) {
        home.unpark(fiber);
    } else {
        home.unpark_foreign(io, fiber);
    }
}

const testing = std.testing;

test "finish with no awaiter reports none and the word reads done" {
    var word = init;
    try testing.expect(!is_done(&word));
    try testing.expectEqual(Waiter.none, finish(&word));
    try testing.expect(is_done(&word));
}

test "an awaiter that comes after finish must not park" {
    var word = init;
    _ = finish(&word);
    var fiber: Sched.Fiber = undefined;
    try testing.expect(!await_fiber(&word, &fiber));
    try testing.expect(!await_driver(&word));
    try testing.expect(is_done(&word));
}

test "a fiber awaiter parks and finish hands that fiber back" {
    var word = init;
    var fiber: Sched.Fiber = undefined;
    try testing.expect(await_fiber(&word, &fiber));
    try testing.expect(!is_done(&word));
    const waiter = finish(&word);
    try testing.expectEqual(&fiber, waiter.fiber);
    try testing.expect(is_done(&word));
}

test "a driver awaiter is reported as the driver" {
    var word = init;
    try testing.expect(await_driver(&word));
    try testing.expect(!is_done(&word));
    try testing.expectEqual(Waiter.driver, finish(&word));
    try testing.expect(is_done(&word));
}

test "a thread race between await and finish loses no wake" {
    const Case = struct {
        word: Word,
        fiber: Sched.Fiber,
        woken: std.atomic.Value(u32),

        fn finisher(case: *@This()) void {
            switch (finish(&case.word)) {
                .fiber => |fiber| {
                    assert_always(fiber == &case.fiber);
                    _ = case.woken.fetchAdd(1, .acq_rel);
                },
                .none, .driver => {},
            }
        }
    };
    for (0..200) |_| {
        var case: Case = .{ .word = init, .fiber = undefined, .woken = .init(0) };
        const thread = try std.Thread.spawn(.{}, Case.finisher, .{&case});
        const must_park = await_fiber(&case.word, &case.fiber);
        thread.join();
        // Either the awaiter parked and was woken exactly once, or it saw done and was not.
        try testing.expectEqual(@as(u32, @intFromBool(must_park)), case.woken.load(.acquire));
        try testing.expect(is_done(&case.word));
    }
}
