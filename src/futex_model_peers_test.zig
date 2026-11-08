//! Seeded model test of futex wake and cancel across four carriers (ADR 0004 section 4, plan 005
//! item 7). A plan drawn from the seed homes up to 24 waiters on peers 1..3, on three words, and
//! gives each a fate: woken by a release of its word, or canceled on its home. Wakes come from the
//! test thread (off every carrier) or from a fiber mailed to a random peer. The reference model
//! is the plan itself: a waiter ends with its fate's outcome, on its home, and each release
//! wakes exactly the released waiters of its word. A failure is reproduced by the seed it logs.
//! Waits on atomics are bounded spins.

const std = @import("std");
const stdx = @import("stdx.zig");
const futex = @import("futex.zig");
const mail = @import("mail.zig");
const Runtime = @import("runtime.zig");
const Sched = @import("sched.zig");

const Io = std.Io;
const Mail = mail.Mail;
const Table = futex.Table;
const assert = stdx.assert;

const spin_max: u32 = 20_000_000;
const waiters_max: u32 = 24;
const words_count: u32 = 3;
const peers_count: u32 = 3;
const wake_all: u32 = 1000;

const Fate = enum { release, cancel };

const Plan = struct {
    count: u32,
    word: [waiters_max]u8,
    /// Index into the peers: the carrier is `home + 1`.
    home: [waiters_max]u8,
    fate: [waiters_max]Fate,
    /// Whether the release of each word runs as a fiber on a peer instead of the test thread.
    waker_fiber: [words_count]bool,
    waker_home: [words_count]u8,
};

/// The program for `seed`: a pure function, so the failing seed reproduces the failure.
fn plan_make(seed: u64) Plan {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var plan: Plan = undefined;
    plan.count = 6 + random.uintLessThan(u32, waiters_max - 6 + 1);
    for (0..waiters_max) |index| {
        plan.word[index] = random.uintLessThan(u8, words_count);
        plan.home[index] = random.uintLessThan(u8, peers_count);
        plan.fate[index] = if (random.uintLessThan(u8, 4) == 0) .cancel else .release;
    }
    for (0..words_count) |word| {
        plan.waker_fiber[word] = random.boolean();
        plan.waker_home[word] = random.uintLessThan(u8, peers_count);
    }
    assert(plan.count >= 6);
    assert(plan.count <= waiters_max);
    return plan;
}

/// The reference: how many waiters of `word` a release must wake, by the plan alone.
fn model_released(plan: *const Plan, word: u32) u32 {
    var released: u32 = 0;
    for (0..plan.count) |index| {
        if (plan.word[index] == word and plan.fate[index] == .release) released += 1;
    }
    assert(released <= plan.count);
    return released;
}

fn model_outcome(fate: Fate) Sched.WaitOutcome {
    return switch (fate) {
        .release => .woken,
        .cancel => .canceled,
    };
}

const Waiter = struct {
    fixture: *Fixture,
    index: u32,
    fiber: std.atomic.Value(?*Sched.Fiber),
    outcome: Sched.WaitOutcome,
    resumed_on_home: bool,
};

const Waker = struct {
    fixture: *Fixture,
    word: u32,
    woken: std.atomic.Value(u32),
    done: std.atomic.Value(bool),
};

const Fixture = struct {
    rt: *Runtime,
    io: Io,
    table: Table,
    words: [words_count]u32,
    plan: Plan,
    waiters: [waiters_max]Waiter,
    starts: [waiters_max]Mail,
    cancels: [waiters_max]Mail,
    wakers: [words_count]Waker,
    wake_mails: [words_count]Mail,
    done: std.atomic.Value(u32),
};

fn options() Runtime.Options {
    return .{
        .backend = .threaded,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
        .carriers = 4,
        .fibers_max = waiters_max + 2,
        .batch_ops_max = 8,
        .fiber_stack_size = 64 * 1024,
        .offload_threads = 2,
        .sockets_max = 8,
    };
}

fn home_of(fixture: *Fixture, index: u32) *Sched {
    return &fixture.rt.peers[fixture.plan.home[index]].sched;
}

fn entry_wait(arg: ?*anyopaque) void {
    const waiter: *Waiter = @ptrCast(@alignCast(arg.?));
    const fixture = waiter.fixture;
    const home = home_of(fixture, waiter.index);
    const fiber = home.current_fiber();
    const addr = &fixture.words[fixture.plan.word[waiter.index]];
    const queued = fixture.table.enqueue(fiber, addr, 0);
    assert(queued == .queued);
    waiter.fiber.store(fiber, .release);
    home.park();
    waiter.resumed_on_home = Sched.here() == home;
    waiter.outcome = fiber.wait.outcome;
    fiber.wait = .none;
    _ = fixture.done.fetchAdd(1, .release);
}

fn entry_cancel(arg: ?*anyopaque) void {
    const waiter: *Waiter = @ptrCast(@alignCast(arg.?));
    const home = home_of(waiter.fixture, waiter.index);
    // The waiter parked before this mail ran: both are fibers of the same carrier.
    futex.cancel_wait(&waiter.fixture.table, home, waiter.fiber.load(.acquire).?);
}

fn release_word(waker: *Waker) void {
    const fixture = waker.fixture;
    const addr = &fixture.words[waker.word];
    const count = fixture.table.wake(fixture.io, @intFromPtr(addr), wake_all);
    waker.woken.store(count, .release);
    waker.done.store(true, .release);
}

fn entry_release(arg: ?*anyopaque) void {
    release_word(@ptrCast(@alignCast(arg.?)));
}

fn fixture_init(fixture: *Fixture, rt: *Runtime, seed: u64) void {
    fixture.rt = rt;
    fixture.io = rt.baselineIo();
    fixture.table = .init(waiters_max);
    fixture.words = @splat(0);
    fixture.plan = plan_make(seed);
    fixture.done = .init(0);
    for (0..fixture.plan.count) |index| {
        const at: u32 = @intCast(index);
        fixture.waiters[index] = .{
            .fixture = fixture,
            .index = at,
            .fiber = .init(null),
            .outcome = .idle,
            .resumed_on_home = false,
        };
        fixture.starts[index] = .init(entry_wait, &fixture.waiters[index]);
        fixture.cancels[index] = .init(entry_cancel, &fixture.waiters[index]);
    }
    for (0..words_count) |word| {
        fixture.wakers[word] = .{
            .fixture = fixture,
            .word = @intCast(word),
            .woken = .init(0),
            .done = .init(false),
        };
        fixture.wake_mails[word] = .init(entry_release, &fixture.wakers[word]);
    }
}

fn spin_until_waiting(fixture: *Fixture, count: u32) !void {
    for (0..spin_max) |_| {
        if (fixture.table.waiting_count() == count) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.WaitersNeverQueued;
}

fn spin_until_done(fixture: *Fixture, count: u32) !void {
    for (0..spin_max) |_| {
        if (fixture.done.load(.acquire) == count) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.WaitersNeverResumed;
}

/// Failure path: a waiter left parked would keep its carrier from stopping, so wake every word.
fn abandon(fixture: *Fixture) void {
    for (&fixture.words) |*word| {
        _ = fixture.table.wake(fixture.io, @intFromPtr(word), wake_all);
    }
    spin_until_done(fixture, fixture.plan.count) catch {}; // Nothing more to do on a hang.
}

fn run_cancels(fixture: *Fixture) !void {
    var canceled: u32 = 0;
    for (0..fixture.plan.count) |index| {
        if (fixture.plan.fate[index] != .cancel) continue;
        mail.post(home_of(fixture, @intCast(index)), fixture.io, &fixture.cancels[index]);
        canceled += 1;
        try spin_until_done(fixture, canceled);
    }
}

fn run_releases(fixture: *Fixture) !void {
    for (0..words_count) |word| {
        const waker = &fixture.wakers[word];
        if (fixture.plan.waker_fiber[word]) {
            const home = &fixture.rt.peers[fixture.plan.waker_home[word]].sched;
            mail.post(home, fixture.io, &fixture.wake_mails[word]);
            for (0..spin_max) |_| {
                if (waker.done.load(.acquire)) break;
                std.Thread.yield() catch {}; // A scheduling hint only.
            }
        } else {
            release_word(waker);
        }
        try std.testing.expect(waker.done.load(.acquire));
    }
}

fn check_model(fixture: *Fixture) !void {
    for (0..words_count) |word| {
        const expected = model_released(&fixture.plan, @intCast(word));
        try std.testing.expectEqual(expected, fixture.wakers[word].woken.load(.acquire));
    }
    for (0..fixture.plan.count) |index| {
        const waiter = &fixture.waiters[index];
        try std.testing.expectEqual(model_outcome(fixture.plan.fate[index]), waiter.outcome);
        try std.testing.expect(waiter.resumed_on_home);
    }
    try std.testing.expectEqual(@as(u32, 0), fixture.table.waiting_count());
}

fn run_seed(fixture: *Fixture, rt: *Runtime, seed: u64) !void {
    fixture_init(fixture, rt, seed);
    for (0..fixture.plan.count) |index| {
        mail.post(home_of(fixture, @intCast(index)), fixture.io, &fixture.starts[index]);
    }
    errdefer abandon(fixture);
    try spin_until_waiting(fixture, fixture.plan.count);
    try run_cancels(fixture);
    try run_releases(fixture);
    try spin_until_done(fixture, fixture.plan.count);
    try check_model(fixture);
}

test "a seeded wake and cancel program on four carriers matches the model" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, options());
    defer rt.deinit();

    _ = rt.io();
    const fixture = try std.testing.allocator.create(Fixture);
    defer std.testing.allocator.destroy(fixture);

    for (0..16) |seed_index| {
        const seed: u64 = 0x5eed_4000 + seed_index;
        errdefer std.log.err("futex peers model test failed, seed = {d}", .{seed});
        try run_seed(fixture, &rt, seed);
    }
}

test "the model plan is reproducible from its seed and varies across seeds" {
    const first = plan_make(7);
    const again = plan_make(7);
    try std.testing.expect(std.meta.eql(first, again));
    // A plan that never cancels, never releases or never leaves carrier 1 would test nothing.
    var cancels: u32 = 0;
    var releases: u32 = 0;
    var homes_seen: [peers_count]bool = @splat(false);
    for (0..64) |seed| {
        const plan = plan_make(seed);
        for (0..plan.count) |index| {
            switch (plan.fate[index]) {
                .cancel => cancels += 1,
                .release => releases += 1,
            }
            homes_seen[plan.home[index]] = true;
        }
    }
    try std.testing.expect(cancels > 0);
    try std.testing.expect(releases > cancels);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, &homes_seen);
    try std.testing.expect(!std.meta.eql(first, plan_make(8)));
}
