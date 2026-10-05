//! Seeded model test for the futex slots (plan 002 item 8): one random wait/wake program replayed
//! on `rt.io()` (sirocco's fibers), on `rt.baselineIo()` (`Io.Threaded`'s threads) and on a
//! trivial reference model, which must all produce the same wake trace.
//!
//! The program is a pure function of its seed (`gen_ops`), so a failure is reproduced by the seed
//! the failing run logs. Each `spawn` starts a waiter on one of three words, `release` bumps the
//! word and wakes everyone on it and then joins that word's waiters, `mismatch` is a wait that must
//! return at once and `timeout` a 1 ms timed wait that must expire. The trace records which waiters
//! each release completed, in spawn order, plus a marker per other op. Waiters loop on their word
//! so the trace does not depend on spurious wakeups or on when a waiter first runs, which both
//! `Io` values may vary; what it does pin is that no release ever loses a waiter (a lost wakeup is
//! a hang) and that every wait/wake/timeout call returns. Exact FIFO and wake counts are asserted
//! in `futex.zig`, where the schedule is deterministic. The reference model has no futex in it:
//! a queue of waiter ids per address.
//!
//! The native replay runs as one task so its `await`s can park; the baseline replay runs on the
//! test thread with its waiters on real threads (`concurrent`).

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const scene = @import("scene.zig");

const run_modes = scene.run_modes;
const wake_all = std.math.maxInt(u32);
const Cancelable = Io.Cancelable;
const ms: i96 = 1_000_000;

fn timeout_duration(nanoseconds: i96) Io.Timeout {
    const raw: Io.Duration = .fromNanoseconds(nanoseconds);
    return .{ .duration = .{ .raw = raw, .clock = .awake } };
}

const addrs_n = 3;
const ops_n = 48;
const live_max = 6;
const trace_cap = ops_n * (live_max + 2);

const Kind = enum { spawn, release, mismatch, timeout };
const Op = struct { kind: Kind, addr: u8 };

/// Markers in the trace, above every waiter id.
const mark_spawn: u16 = 0xF000;
const mark_release_end: u16 = 0xF001;
const mark_mismatch: u16 = 0xF002;
const mark_timeout: u16 = 0xF003;

const Trace = struct {
    items: [trace_cap]u16 = @splat(0),
    len: u32 = 0,

    fn push(t: *Trace, item: u16) void {
        std.debug.assert(t.len < trace_cap);
        t.items[t.len] = item;
        t.len += 1;
    }

    fn slice(t: *const Trace) []const u16 {
        return t.items[0..t.len];
    }
};

/// The program for `seed`: never more than `live_max` waiters alive in total, so a fiber runtime
/// with `fibers_max > live_max + 1` always has a fiber for each.
fn gen_ops(seed: u64) [ops_n]Op {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var ops: [ops_n]Op = undefined;
    var live: [addrs_n]u32 = @splat(0);
    for (&ops) |*op| {
        const addr = random.uintLessThan(u8, addrs_n);
        var kind: Kind = switch (random.uintLessThan(u8, 8)) {
            0...3 => .spawn,
            4, 5 => .release,
            6 => .mismatch,
            else => .timeout,
        };
        const live_total = live[0] + live[1] + live[2];
        if (kind == .spawn and live_total == live_max) kind = .release;
        switch (kind) {
            .spawn => live[addr] += 1,
            .release => live[addr] = 0,
            .mismatch, .timeout => {},
        }
        op.* = .{ .kind = kind, .addr = addr };
    }
    return ops;
}

/// The trivial reference: waiters of an address are released together by a release of it, in
/// the order they were spawned, and nothing else completes a waiter.
fn model_trace(ops: *const [ops_n]Op, out: *Trace) void {
    var queued: [addrs_n][live_max]u16 = undefined;
    var queued_len: [addrs_n]u32 = @splat(0);
    var next_id: u16 = 0;
    // The replay ends by releasing every address once (it must join all of its futures).
    for (0..ops_n + addrs_n) |step| {
        const op: Op = if (step < ops_n) ops[step] else .{
            .kind = .release,
            .addr = @intCast(step - ops_n),
        };
        model_step(op, &queued, &queued_len, &next_id, out);
    }
}

fn model_step(
    op: Op,
    queued: *[addrs_n][live_max]u16,
    queued_len: *[addrs_n]u32,
    next_id: *u16,
    out: *Trace,
) void {
    switch (op.kind) {
        .spawn => {
            queued[op.addr][queued_len[op.addr]] = next_id.*;
            queued_len[op.addr] += 1;
            next_id.* += 1;
            out.push(mark_spawn);
        },
        .release => {
            for (queued[op.addr][0..queued_len[op.addr]]) |id| out.push(id);
            queued_len[op.addr] = 0;
            out.push(mark_release_end);
        },
        .mismatch => out.push(mark_mismatch),
        .timeout => out.push(mark_timeout),
    }
}

/// Waiters finish only when their word moved past `snapshot` and a wake arrived (or spuriously):
/// the loop makes the outcome independent of when the waiter first runs and of spurious wakeups,
/// which both `Io` values are allowed to produce.
fn model_waiter(io: Io, word: *u32, snapshot: u32) Cancelable!void {
    while (@atomicLoad(u32, word, .acquire) == snapshot) try io.futexWait(u32, word, snapshot);
}

const Replay = struct {
    words: [addrs_n]u32 = @splat(0),
    futures: [ops_n]Io.Future(Cancelable!void) = undefined,
    ids: [addrs_n][live_max]u16 = undefined,
    ids_len: [addrs_n]u32 = @splat(0),
    next_id: u16 = 0,
    trace: Trace = .{},
};

/// `concurrent` where the `Io` has threads, `async` (a fiber) where it does not.
fn spawn_waiter(io: Io, word: *u32, snapshot: u32) Io.Future(Cancelable!void) {
    return io.concurrent(model_waiter, .{ io, word, snapshot }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => io.async(model_waiter, .{ io, word, snapshot }),
    };
}

fn replay_step(io: Io, replay: *Replay, op: Op) Cancelable!void {
    const word = &replay.words[op.addr];
    switch (op.kind) {
        .spawn => {
            const id = replay.next_id;
            replay.next_id += 1;
            replay.futures[id] = spawn_waiter(io, word, @atomicLoad(u32, word, .acquire));
            replay.ids[op.addr][replay.ids_len[op.addr]] = id;
            replay.ids_len[op.addr] += 1;
            replay.trace.push(mark_spawn);
        },
        .release => {
            _ = @atomicRmw(u32, word, .Add, 1, .release);
            io.futexWake(u32, word, wake_all);
            for (replay.ids[op.addr][0..replay.ids_len[op.addr]]) |id| {
                try replay.futures[id].await(io);
                replay.trace.push(id);
            }
            replay.ids_len[op.addr] = 0;
            replay.trace.push(mark_release_end);
        },
        .mismatch => {
            try io.futexWait(u32, word, @atomicLoad(u32, word, .acquire) +% 1);
            replay.trace.push(mark_mismatch);
        },
        .timeout => {
            const current = @atomicLoad(u32, word, .acquire);
            try io.futexWaitTimeout(u32, word, current, timeout_duration(1 * ms));
            replay.trace.push(mark_timeout);
        },
    }
}

fn replay_all(io: Io, replay: *Replay, ops: *const [ops_n]Op) Cancelable!void {
    for (ops) |op| try replay_step(io, replay, op);
    // Join leftovers: every future is awaited exactly once.
    for (0..addrs_n) |addr| {
        try replay_step(io, replay, .{ .kind = .release, .addr = @intCast(addr) });
    }
}

fn replay_on(io: Io, ops: *const [ops_n]Op, on_fiber: bool) !Trace {
    const replay = try std.testing.allocator.create(Replay);
    defer std.testing.allocator.destroy(replay);
    replay.* = .{};
    if (on_fiber) {
        // A parked `await` needs a fiber to park: the whole program is one task.
        var program = io.async(replay_all, .{ io, replay, ops });
        try program.await(io);
    } else {
        try replay_all(io, replay, ops);
    }
    return replay.trace;
}

test "futex: a seeded random wait/wake program gives the same wake trace on both Io and the model" {
    try run_modes(2 * live_max, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            for (0..8) |seed_index| {
                const seed: u64 = 0x5eed_0000 + seed_index;
                errdefer std.log.err("futex model test failed, seed = {d}", .{seed});
                const ops = gen_ops(seed);
                var expected: Trace = .{};
                model_trace(&ops, &expected);

                const native = try replay_on(rt.io(), &ops, true);
                try std.testing.expectEqualSlices(u16, expected.slice(), native.slice());
                const baseline = try replay_on(rt.baselineIo(), &ops, false);
                try std.testing.expectEqualSlices(u16, expected.slice(), baseline.slice());
            }
        }
    }.scenario);
}

test "futex: the model program is reproducible from its seed and varies across seeds" {
    const first = gen_ops(42);
    const again = gen_ops(42);
    try std.testing.expect(std.meta.eql(first, again));
    var kinds_seen: [4]bool = @splat(false);
    for (&first) |op| kinds_seen[@intFromEnum(op.kind)] = true;
    // A program that never spawns, releases, mismatches and times out would test nothing.
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, true }, &kinds_seen);
    try std.testing.expect(!std.meta.eql(first, gen_ops(43)));
}
