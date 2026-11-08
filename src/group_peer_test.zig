//! Tests of the group record lock (ADR 0004 section 3, plan 005 item 7): members that finish on
//! peer carriers leave the list under the lock and the last one wakes the awaiter on its home.
//! No placement exists yet, so each test makes member records by hand, links them with
//! `rec_link`, homes them on peers 1..3 and starts them with a mail. The seed fixes how many
//! times each member yields before it ends. Waits on atomics are bounded spins.

const std = @import("std");
const stdx = @import("stdx.zig");
const concurrency = @import("concurrency.zig");
const group = @import("concurrency_group.zig");
const mail = @import("mail.zig");
const Runtime = @import("runtime.zig");
const Sched = @import("sched.zig");

const Io = std.Io;
const assert = stdx.assert;
const Task = concurrency.Task;

const spin_max: u32 = 20_000_000;
const members_max: u32 = 24;
const peers_count: u32 = 3;
const yields_max: u32 = 8;

const Shared = struct {
    /// The carrier the awaiter runs on.
    awaiter: *Sched,
    /// Raised once the awaiter is about to wait, so members end after it (or while it parks).
    go: std.atomic.Value(bool),
    finished: std.atomic.Value(u32),
    /// Members that ran on a carrier other than the awaiter's.
    off_awaiter: std.atomic.Value(u32),
};

const Member = struct {
    shared: *Shared,
    yields: u32,
};

const Fixture = struct {
    rt: *Runtime,
    /// Made as `group_rec_ensure` makes it: `groupAwait` frees it with the runtime's allocator.
    rec: *group.GroupRec,
    shared: Shared,
    members: [members_max]Member,
    tasks: [members_max]*Task,
    starts: [members_max]mail.Mail,
    count: u32,
};

fn options() Runtime.Options {
    return .{
        .backend = .threaded,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
        .carriers = 4,
        .fibers_max = 4,
        .batch_ops_max = 8,
        .fiber_stack_size = 128 * 1024,
        .offload_threads = 2,
        .sockets_max = 8,
    };
}

/// Body of a hand-made member, running on a peer carrier.
fn member_body(context: *const anyopaque) void {
    const member = @as(*const *Member, @ptrCast(@alignCast(context))).*;
    const here = Sched.here().?;
    if (here != member.shared.awaiter) _ = member.shared.off_awaiter.fetchAdd(1, .monotonic);
    for (0..spin_max) |_| {
        if (member.shared.go.load(.acquire)) break;
        here.yield();
    }
    for (0..member.yields) |_| here.yield();
    _ = member.shared.finished.fetchAdd(1, .release);
}

/// Fills `fixture` with `count` members linked to its record, homed round-robin on the peers.
fn fixture_init(fixture: *Fixture, rt: *Runtime, seed: u64, count: u32) !void {
    assert(count <= members_max);
    var prng = std.Random.DefaultPrng.init(seed);
    fixture.rt = rt;
    fixture.rec = try rt.threaded.allocator.create(group.GroupRec);
    fixture.rec.* = group.rec_init(&rt.sched);
    fixture.shared = .{
        .awaiter = &rt.sched,
        .go = .init(false),
        .finished = .init(0),
        .off_awaiter = .init(0),
    };
    fixture.count = 0;
    for (0..count) |index| {
        const member = &fixture.members[index];
        member.* = .{
            .shared = &fixture.shared,
            .yields = prng.random().uintLessThan(u32, yields_max),
        };
        const context = std.mem.asBytes(&member);
        const body: concurrency.Body = .{ .member = member_body };
        const task = concurrency.task_create(rt, 0, .@"1", context, .of(*Member), body) orelse {
            return error.OutOfMemory;
        };
        task.sched = &rt.peers[index % peers_count].sched;
        group.rec_link(fixture.rec, task);
        fixture.tasks[index] = task;
        fixture.count += 1;
    }
    try std.testing.expectEqual(count, fixture.rec.pending);
    try std.testing.expect(!fixture.rec.idle);
}

/// Mails every member its fiber; each runs on its home peer.
fn fixture_start(fixture: *Fixture) void {
    for (0..fixture.count) |index| {
        const task = fixture.tasks[index];
        fixture.starts[index] = mail.Mail.init(concurrency.task_entry, task);
        mail.post(task.sched, fixture.rt.baselineIo(), &fixture.starts[index]);
    }
}

fn spin_until_idle(rec: *const group.GroupRec) !void {
    for (0..spin_max) |_| {
        if (group.rec_is_idle(rec)) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.GroupNeverIdle;
}

/// With `rec_alive` false the record was freed by `groupAwait`, so only the counters are read.
fn check_ended(fixture: *Fixture, rec_alive: bool) !void {
    if (rec_alive) {
        try std.testing.expectEqual(@as(u32, 0), fixture.rec.pending);
        try std.testing.expect(fixture.rec.head == null);
        try std.testing.expect(fixture.rec.waiter == null);
    }
    try std.testing.expectEqual(fixture.count, fixture.shared.finished.load(.acquire));
    // Every member ran on a peer, none on the awaiter's carrier.
    try std.testing.expectEqual(fixture.count, fixture.shared.off_awaiter.load(.acquire));
}

test "members finishing on three peers empty the list under the lock" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, options());
    defer rt.deinit();

    _ = rt.io();
    const fixture = try std.testing.allocator.create(Fixture);
    defer std.testing.allocator.destroy(fixture);

    for ([_]u64{ 1, 2, 3, 4 }) |seed| {
        try fixture_init(fixture, &rt, seed, members_max);
        fixture.shared.go.store(true, .release);
        fixture_start(fixture);
        try spin_until_idle(fixture.rec);
        // A member frees its own record when it ends.
        try check_ended(fixture, true);
        rt.threaded.allocator.destroy(fixture.rec);
    }
}

/// Body of the awaiting future on carrier 0: opens the gate, then waits for the group.
fn awaiter_body(context: *const anyopaque, result: *anyopaque) void {
    _ = result;
    const fixture = @as(*const *Fixture, @ptrCast(@alignCast(context))).*;
    var handle: Io.Group = .init;
    handle.token.store(fixture.rec, .release);
    fixture.shared.go.store(true, .release);
    // Members end on peers meanwhile: this parks, or finds the group already idle.
    handle.await(fixture.rt.io()) catch unreachable; // A proof: never canceled here.
    assert(handle.token.raw == null);
}

test "the last member finishing on a peer wakes the awaiter on carrier 0" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    var rt: Runtime = try .init(std.testing.allocator, options());
    defer rt.deinit();

    _ = rt.io();
    const fixture = try std.testing.allocator.create(Fixture);
    defer std.testing.allocator.destroy(fixture);

    for ([_]u64{ 11, 12, 13, 14, 15, 16 }) |seed| {
        try fixture_init(fixture, &rt, seed, 6 + @as(u32, @intCast(seed % 3)) * 6);
        const context = std.mem.asBytes(&fixture);
        const body: concurrency.Body = .{ .future = awaiter_body };
        const alignment: std.mem.Alignment = .of(*Fixture);
        const awaiter = concurrency.task_create(&rt, 0, .@"1", context, alignment, body) orelse {
            return error.OutOfMemory;
        };
        _ = try rt.sched.spawn(concurrency.task_entry, awaiter);
        fixture_start(fixture);
        // Carrier 0 runs the awaiter; it ends once the last peer member woke it.
        rt.sched.run(rt.baselineIo());

        try std.testing.expect(concurrency.task_is_done(awaiter));
        try check_ended(fixture, false);
        concurrency.task_free(&rt, awaiter);
    }
}
