//! Seeded model test of `await` and cancel of tasks homed on peer carriers (ADR 0004 section 3,
//! plan 005 item 7). A plan drawn from the seed makes up to 24 hand-made tasks homed on peers
//! 1..3. Each one either ends by itself after a few yields or parks in the futex until it is
//! canceled. Each is awaited by the test thread (before or after the finish), or by a fiber
//! mailed to a random peer, which registers in the join word before or after the task starts.
//! A parked task is canceled by the test thread or by a fiber on a random peer, which settles
//! its own mail. The reference model is the plan: a task ends with its fate, on its home, an
//! awaiter sees it done and resumes on its own carrier, and a cancel travels as mail exactly when
//! the canceler is not on the home. A failure is reproduced by the seed it logs. Waits on
//! atomics are bounded spins.

const std = @import("std");
const stdx = @import("stdx.zig");
const cancel_mail = @import("cancel_mail.zig");
const concurrency = @import("concurrency.zig");
const join = @import("join.zig");
const mail = @import("mail.zig");
const Runtime = @import("runtime.zig");
const Sched = @import("sched.zig");

const assert = stdx.assert;
const assert_always = stdx.assert_always;
const Task = concurrency.Task;

const spin_max: u32 = 20_000_000;
const tasks_max: u32 = 24;
const peers_count: u32 = 3;
const yields_max: u32 = 6;

const Fate = enum { finish, park_cancel };
const Awaiter = enum { driver, late, fiber };
const Canceler = enum { thread, fiber };

const Plan = struct {
    count: u32,
    fate: [tasks_max]Fate,
    /// Index into the peers: the carrier is `home + 1`.
    home: [tasks_max]u8,
    yields: [tasks_max]u8,
    awaiter: [tasks_max]Awaiter,
    awaiter_home: [tasks_max]u8,
    /// Whether the awaiter fiber is mailed before the task is started.
    awaiter_first: [tasks_max]bool,
    canceler: [tasks_max]Canceler,
    canceler_home: [tasks_max]u8,
};

/// The program for `seed`: a pure function, so the failing seed reproduces the failure.
fn plan_make(seed: u64) Plan {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var plan: Plan = undefined;
    plan.count = 6 + random.uintLessThan(u32, tasks_max - 6 + 1);
    for (0..tasks_max) |index| {
        plan.fate[index] = if (random.uintLessThan(u8, 3) == 0) .park_cancel else .finish;
        plan.home[index] = random.uintLessThan(u8, peers_count);
        plan.yields[index] = random.uintLessThan(u8, yields_max + 1);
        plan.awaiter[index] = random.enumValue(Awaiter);
        plan.awaiter_home[index] = random.uintLessThan(u8, peers_count);
        plan.awaiter_first[index] = random.boolean();
        plan.canceler[index] = random.enumValue(Canceler);
        plan.canceler_home[index] = random.uintLessThan(u8, peers_count);
    }
    assert(plan.count >= 6);
    assert(plan.count <= tasks_max);
    return plan;
}

/// The reference: whether the cancel of task `index` is mailed (the canceler is off the home).
fn model_mailed(plan: *const Plan, index: u32) bool {
    assert(plan.fate[index] == .park_cancel);
    return switch (plan.canceler[index]) {
        .thread => true,
        .fiber => plan.canceler_home[index] != plan.home[index],
    };
}

const Case = struct {
    fixture: *Fixture,
    index: u32,
    task: *Task,
    /// The futex word a parking task waits on (never changed, so only a cancel ends the wait).
    word: u32,
    parked: std.atomic.Value(bool),
    /// The next five are written by the task's fiber before it ends, read after the task is done.
    ran_on_home: bool,
    ended_by_itself: bool,
    outcome: Sched.WaitOutcome,
    acknowledged: bool,
    awaiter_resumed: std.atomic.Value(bool),
    awaiter_on_home: bool,
    canceler_done: std.atomic.Value(bool),
    start: mail.Mail,
    awaiter_mail: mail.Mail,
    canceler_mail: mail.Mail,
};

const Fixture = struct {
    rt: *Runtime,
    plan: Plan,
    cases: [tasks_max]Case,
    /// Tasks made so far, so a failure path frees exactly those.
    made: u32,
};

fn options() Runtime.Options {
    return .{
        .backend = .threaded,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
        .carriers = 4,
        .fibers_max = 4 * tasks_max + 4,
        .batch_ops_max = 8,
        .fiber_stack_size = 128 * 1024,
        .offload_threads = 2,
        .sockets_max = 8,
    };
}

fn peer_sched(fixture: *Fixture, peer: u8) *Sched {
    return &fixture.rt.peers[peer].sched;
}

/// Body of a hand-made task, running on its home peer.
fn task_body(context: *const anyopaque, result: *anyopaque) void {
    _ = result;
    const case = @as(*const *Case, @ptrCast(@alignCast(context))).*;
    const fixture = case.fixture;
    const home = case.task.sched;
    case.ran_on_home = Sched.here() == home;
    switch (fixture.plan.fate[case.index]) {
        .finish => {
            for (0..fixture.plan.yields[case.index]) |_| home.yield();
            case.ended_by_itself = true;
        },
        .park_cancel => {
            const fiber = home.current_fiber();
            const queued = fixture.rt.waits.enqueue(fiber, &case.word, 0);
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
        },
    }
}

/// Fiber body mailed to an awaiter's carrier: registers in the join word and parks until woken.
fn entry_awaiter(arg: ?*anyopaque) void {
    const case: *Case = @ptrCast(@alignCast(arg.?));
    const here = Sched.here().?;
    const fiber = here.current_fiber();
    // Read first: once the task is done the test thread may free its record.
    const join_word = &case.task.join;
    const expected = peer_sched(case.fixture, case.fixture.plan.awaiter_home[case.index]);
    if (join.await_fiber(join_word, fiber)) here.park();
    case.awaiter_on_home = here == expected;
    case.awaiter_resumed.store(true, .release);
}

/// Fiber body mailed to a canceler's carrier: waits for the task to park, then cancels it.
fn entry_canceler(arg: ?*anyopaque) void {
    const case: *Case = @ptrCast(@alignCast(arg.?));
    const here = Sched.here().?;
    for (0..spin_max) |_| {
        if (case.parked.load(.acquire)) break;
        here.yield();
    }
    assert_always(case.parked.load(.acquire));
    cancel_mail.request(case.task, case.fixture.rt.baselineIo());
    cancel_mail.settle(case.task);
    case.canceler_done.store(true, .release);
}

fn case_init(fixture: *Fixture, index: u32) !void {
    const rt = fixture.rt;
    const case = &fixture.cases[index];
    case.* = .{
        .fixture = fixture,
        .index = index,
        .task = undefined,
        .word = 0,
        .parked = .init(false),
        .ran_on_home = false,
        .ended_by_itself = false,
        .outcome = .idle,
        .acknowledged = false,
        .awaiter_resumed = .init(false),
        .awaiter_on_home = false,
        .canceler_done = .init(false),
        .start = undefined,
        .awaiter_mail = .init(entry_awaiter, case),
        .canceler_mail = .init(entry_canceler, case),
    };
    const context = std.mem.asBytes(&case);
    const alignment: std.mem.Alignment = .of(*Case);
    const body: concurrency.Body = .{ .future = task_body };
    case.task = concurrency.task_create(rt, 0, .@"1", context, alignment, body) orelse {
        return error.OutOfMemory;
    };
    fixture.made += 1;
    case.task.sched = peer_sched(fixture, fixture.plan.home[index]);
    case.start = .init(concurrency.task_entry, case.task);
}

fn fixture_init(fixture: *Fixture, rt: *Runtime, seed: u64) !void {
    fixture.rt = rt;
    fixture.plan = plan_make(seed);
    fixture.made = 0;
    for (0..fixture.plan.count) |index| try case_init(fixture, @intCast(index));
}

fn fixture_free(fixture: *Fixture) void {
    for (0..fixture.made) |index| concurrency.task_free(fixture.rt, fixture.cases[index].task);
    fixture.made = 0;
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

/// Posts the mails of case `index`: the task start and, in the seeded order, its awaiter and
/// canceler fibers.
fn case_post(fixture: *Fixture, index: u32) void {
    const plan = &fixture.plan;
    const io = fixture.rt.baselineIo();
    const case = &fixture.cases[index];
    const awaiter_fiber = plan.awaiter[index] == .fiber;
    if (awaiter_fiber and plan.awaiter_first[index]) {
        mail.post(peer_sched(fixture, plan.awaiter_home[index]), io, &case.awaiter_mail);
    }
    mail.post(case.task.sched, io, &case.start);
    if (awaiter_fiber and !plan.awaiter_first[index]) {
        mail.post(peer_sched(fixture, plan.awaiter_home[index]), io, &case.awaiter_mail);
    }
    if (plan.fate[index] == .park_cancel and plan.canceler[index] == .fiber) {
        mail.post(peer_sched(fixture, plan.canceler_home[index]), io, &case.canceler_mail);
    }
}

/// The test thread's part: cancel what it is to cancel, await what it is to await.
fn run_thread_duties(fixture: *Fixture) !void {
    const plan = &fixture.plan;
    const io = fixture.rt.baselineIo();
    for (0..plan.count) |index| {
        const case = &fixture.cases[index];
        if (plan.fate[index] == .park_cancel and plan.canceler[index] == .thread) {
            try spin_until(&case.parked);
            cancel_mail.request(case.task, io);
        }
    }
    for (0..plan.count) |index| {
        const case = &fixture.cases[index];
        switch (plan.awaiter[index]) {
            .fiber => {},
            .driver => {
                // Registers while the task may still run on its peer; the finisher names the
                // driver and notifies carrier 0, which has nothing to run.
                if (join.await_driver(&case.task.join)) try spin_until_done(case.task);
                try std.testing.expect(concurrency.task_is_done(case.task));
            },
            .late => {
                try spin_until_done(case.task);
                try std.testing.expect(!join.await_driver(&case.task.join));
                try std.testing.expect(concurrency.task_is_done(case.task));
            },
        }
    }
}

fn run_wait_fibers(fixture: *Fixture) !void {
    const plan = &fixture.plan;
    for (0..plan.count) |index| {
        const case = &fixture.cases[index];
        if (plan.awaiter[index] == .fiber) try spin_until(&case.awaiter_resumed);
        if (plan.fate[index] == .park_cancel and plan.canceler[index] == .fiber) {
            try spin_until(&case.canceler_done);
        }
    }
}

fn check_model(fixture: *Fixture) !void {
    const plan = &fixture.plan;
    for (0..plan.count) |index| {
        const case = &fixture.cases[index];
        try std.testing.expect(concurrency.task_is_done(case.task));
        try std.testing.expect(case.ran_on_home);
        switch (plan.fate[index]) {
            .finish => {
                try std.testing.expect(case.ended_by_itself);
                try std.testing.expectEqual(Sched.WaitOutcome.idle, case.outcome);
                try std.testing.expect(!case.task.cancel_slot.posted);
                try std.testing.expectEqual(concurrency.CancelState.none, case.task.cancel);
            },
            .park_cancel => {
                try std.testing.expect(!case.ended_by_itself);
                try std.testing.expectEqual(Sched.WaitOutcome.canceled, case.outcome);
                try std.testing.expect(case.acknowledged);
                try std.testing.expectEqual(
                    model_mailed(plan, @intCast(index)),
                    case.task.cancel_slot.posted,
                );
            },
        }
        if (plan.awaiter[index] == .fiber) try std.testing.expect(case.awaiter_on_home);
    }
    try std.testing.expectEqual(@as(u32, 0), fixture.rt.waits.waiting_count());
}

/// Failure path: a task left parked would keep its carrier from stopping, so cancel each one
/// that nobody canceled yet and give the fibers time to end.
fn abandon(fixture: *Fixture) void {
    for (0..fixture.made) |index| {
        const case = &fixture.cases[index];
        if (fixture.plan.fate[index] != .park_cancel) continue;
        if (concurrency.task_is_done(case.task)) continue;
        if (case.task.cancel_slot.posted or case.task.cancel != .none) continue;
        if (!case.parked.load(.acquire)) continue;
        cancel_mail.request(case.task, fixture.rt.baselineIo());
    }
    for (0..fixture.made) |index| {
        spin_until_done(fixture.cases[index].task) catch return; // Nothing more to do on a hang.
    }
}

fn run_seed(fixture: *Fixture, rt: *Runtime, seed: u64) !void {
    try fixture_init(fixture, rt, seed);
    errdefer abandon(fixture);
    for (0..fixture.plan.count) |index| case_post(fixture, @intCast(index));
    try run_thread_duties(fixture);
    try run_wait_fibers(fixture);
    // Every mailed cancel has been read by its home before a record is freed.
    for (0..fixture.plan.count) |index| cancel_mail.settle(fixture.cases[index].task);
    try check_model(fixture);
    fixture_free(fixture);
}

test "a seeded await and cancel program on four carriers matches the model" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, options());
    defer rt.deinit();

    _ = rt.io();
    const fixture = try std.testing.allocator.create(Fixture);
    defer std.testing.allocator.destroy(fixture);

    for (0..16) |seed_index| {
        const seed: u64 = 0xa7a1_4000 + seed_index;
        errdefer std.log.err("await peers model test failed, seed = {d}", .{seed});
        errdefer fixture_free(fixture);
        try run_seed(fixture, &rt, seed);
    }
}

test "the await model plan is reproducible from its seed and covers every branch" {
    const first = plan_make(7);
    const again = plan_make(7);
    try std.testing.expect(std.meta.eql(first, again));
    // A plan without one of these would leave a path of the join word or the mail untested.
    var finishes: u32 = 0;
    var parks: u32 = 0;
    var awaiters: [3]u32 = @splat(0);
    var fiber_first: u32 = 0;
    var fiber_after: u32 = 0;
    var mailed: u32 = 0;
    var local: u32 = 0;
    for (0..64) |seed| {
        const plan = plan_make(seed);
        for (0..plan.count) |index| {
            awaiters[@intFromEnum(plan.awaiter[index])] += 1;
            if (plan.awaiter[index] == .fiber) {
                if (plan.awaiter_first[index]) fiber_first += 1 else fiber_after += 1;
            }
            switch (plan.fate[index]) {
                .finish => finishes += 1,
                .park_cancel => {
                    parks += 1;
                    if (model_mailed(&plan, @intCast(index))) mailed += 1 else local += 1;
                },
            }
        }
    }
    try std.testing.expect(finishes > parks);
    try std.testing.expect(parks > 0);
    for (awaiters) |count| try std.testing.expect(count > 0);
    try std.testing.expect(fiber_first > 0);
    try std.testing.expect(fiber_after > 0);
    try std.testing.expect(mailed > 0);
    try std.testing.expect(local > 0);
    try std.testing.expect(!std.meta.eql(first, plan_make(8)));
}
