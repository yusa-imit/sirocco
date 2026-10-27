//! Tests for `sched.zig`: spawn, round-robin, park/unpark, cross-thread wakes and the
//! allocation contract of `init`.
//!
//! Split out of `sched.zig` to keep that file under the 800-line cap; everything here goes through
//! its public surface. The two white-box tests (canary in `sched_fiber.zig`, `init_checked` in
//! `sched.zig`) stay beside the private helpers they cover.

const std = @import("std");
const Sched = @import("sched.zig");

const Io = std.Io;
const Fiber = Sched.Fiber;
const Options = Sched.Options;
const supported = Sched.supported;
const poller_supported = @import("backend/poller.zig").Native != void;
const sleep = @import("sleep.zig");

const ns_per_ms: u64 = 1_000_000;
// std's `Io` clock call runs on a fiber stack in the sleeper tests; Debug builds want room.
const stack_size_clock: u32 = 128 * 1024;

const TestLog = struct {
    sched: *Sched,
    ids: [64]u32,
    len: u32,
    fiber: ?*Fiber,
    flag: u32,

    fn record(log: *TestLog, id: u32) void {
        log.ids[log.len] = id;
        log.len += 1;
    }
};

const TestSlot = struct { log: *TestLog, id: u32 };

fn test_yielder(arg: ?*anyopaque) void {
    const slot: *TestSlot = @ptrCast(@alignCast(arg.?));
    slot.log.record(slot.id);
    slot.log.sched.yield();
    slot.log.record(slot.id + 100);
}

var test_stop: bool = false;

fn test_stopper(arg: ?*anyopaque) void {
    const slot: *TestSlot = @ptrCast(@alignCast(arg.?));
    slot.log.record(slot.id);
    if (slot.id == 1) test_stop = true;
}

fn test_options(fibers_max: u32, stack_size: u32) Options {
    return .{
        .fibers_max = fibers_max,
        .stack_size = stack_size,
        .now_ns = now_ns(std.testing.io),
        .idle = .futex,
    };
}

/// The same limits with the carrier idling in the kernel poller instead of the futex word.
fn test_options_poller(fibers_max: u32, stack_size: u32) Options {
    return .{
        .fibers_max = fibers_max,
        .stack_size = stack_size,
        .now_ns = now_ns(std.testing.io),
        .idle = .{ .poller = .{ .registrations_max = 8 } },
    };
}

fn now_ns(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).nanoseconds);
}

/// An `Io` that forwards to `std.testing.io` and counts the futex calls the scheduler makes, so
/// a test can prove which way the carrier slept. Counters are atomic: wakers run on threads.
const CountingIo = struct {
    var vtable: Io.VTable = undefined;
    var waits: u32 = 0;
    var wakes: u32 = 0;

    fn make() Io {
        const inner = std.testing.io;
        vtable = inner.vtable.*;
        vtable.futexWait = wait;
        vtable.futexWaitUncancelable = wait_uncancelable;
        vtable.futexWake = wake;
        @atomicStore(u32, &waits, 0, .monotonic);
        @atomicStore(u32, &wakes, 0, .monotonic);
        return .{ .userdata = inner.userdata, .vtable = &vtable };
    }

    fn wait(
        userdata: ?*anyopaque,
        ptr: *const u32,
        expected: u32,
        timeout: Io.Timeout,
    ) Io.Cancelable!void {
        _ = @atomicRmw(u32, &waits, .Add, 1, .monotonic);
        return std.testing.io.vtable.futexWait(userdata, ptr, expected, timeout);
    }

    fn wait_uncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
        _ = @atomicRmw(u32, &waits, .Add, 1, .monotonic);
        return std.testing.io.vtable.futexWaitUncancelable(userdata, ptr, expected);
    }

    fn wake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
        _ = @atomicRmw(u32, &wakes, .Add, 1, .monotonic);
        return std.testing.io.vtable.futexWake(userdata, ptr, max_waiters);
    }

    fn futex_calls() u32 {
        return @atomicLoad(u32, &waits, .monotonic) + @atomicLoad(u32, &wakes, .monotonic);
    }
};

test "run_until stops once the flag is set and leaves the rest for a later run" {
    if (!supported) return error.SkipZigTest;
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, test_options(4, 64 * 1024));
    defer sched.deinit(std.testing.allocator);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    var slots: [4]TestSlot = undefined;
    for (&slots, 0..) |*slot, id| {
        slot.* = .{ .log = &log, .id = @intCast(id) };
        _ = try sched.spawn(test_stopper, slot);
    }
    test_stop = false;
    sched.run_until(std.testing.io, &test_stop);
    // Fibers 0 and 1 ran (1 raised the flag); 2 and 3 are still queued and alive.
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, log.ids[0..log.len]);
    try std.testing.expectEqual(@as(u32, 2), sched.live_count);
    try std.testing.expect(!sched.running);
    try std.testing.expect(!sched.in_fiber());

    sched.run(std.testing.io);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, log.ids[0..log.len]);
    try std.testing.expectEqual(@as(u32, 0), sched.live_count);
}

test "in_fiber is false on a thread that is not running the scheduler" {
    if (!supported) return error.SkipZigTest;
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, test_options(1, 64 * 1024));
    defer sched.deinit(std.testing.allocator);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    var slot: TestSlot = .{ .log = &log, .id = 7 };
    _ = try sched.spawn(test_foreign_probe, &slot);
    sched.run(std.testing.io);
    try std.testing.expectEqual(@as(u32, 1), log.flag);
}

fn test_foreign_probe(arg: ?*anyopaque) void {
    const slot: *TestSlot = @ptrCast(@alignCast(arg.?));
    const sched = slot.log.sched;
    // On the carrier, inside the fiber: true. A second thread asks while the fiber is running.
    if (!sched.in_fiber()) return;
    var seen_elsewhere: bool = true;
    const thread = std.Thread.spawn(.{}, probe_elsewhere, .{ sched, &seen_elsewhere }) catch return;
    thread.join();
    if (!seen_elsewhere) slot.log.flag = 1;
}

fn probe_elsewhere(sched: *const Sched, result: *bool) void {
    result.* = sched.in_fiber();
}

test "spawn fibers_max fibers, round-robin them, recycle the stacks" {
    if (!supported) return error.SkipZigTest;
    const fibers_max = 8;
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, test_options(fibers_max, 64 * 1024));
    defer sched.deinit(std.testing.allocator);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    var slots: [fibers_max]TestSlot = undefined;
    // Two rounds prove a finished fiber's stack is reusable and its canary re-armed.
    for (0..2) |_| {
        log.len = 0;
        for (&slots, 0..) |*slot, id| {
            slot.* = .{ .log = &log, .id = @intCast(id) };
            _ = try sched.spawn(test_yielder, slot);
        }
        try std.testing.expectError(error.FibersExhausted, sched.spawn(test_yielder, &slots[0]));
        sched.run(std.testing.io);

        try std.testing.expectEqual(@as(u32, 2 * fibers_max), log.len);
        for (0..fibers_max) |id| {
            try std.testing.expectEqual(@as(u32, @intCast(id)), log.ids[id]);
            try std.testing.expectEqual(@as(u32, @intCast(id)) + 100, log.ids[fibers_max + id]);
        }
        try std.testing.expectEqual(@as(u32, 0), sched.live_count);
    }
}

test "init allocates, spawn and run do not" {
    if (!supported) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var sched: Sched = undefined;
    try sched.init(gpa, test_options(4, 32 * 1024));
    defer sched.deinit(gpa);
    // Fiber table, stack arena and wheel nodes; nothing else.
    try std.testing.expectEqual(@as(usize, 3), failing.alloc_index);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    var slots: [4]TestSlot = undefined;
    for (&slots, 0..) |*slot, id| {
        slot.* = .{ .log = &log, .id = @intCast(id) };
        _ = try sched.spawn(test_yielder, slot);
    }
    sched.run(std.testing.io);
    try std.testing.expectEqual(@as(usize, 3), failing.alloc_index);
    try std.testing.expectEqual(@as(u32, 8), log.len);
}

test "init reports allocation failure at every block and frees the earlier ones" {
    if (!supported) return error.SkipZigTest;
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var sched: Sched = undefined;
        try std.testing.expectError(
            error.OutOfMemory,
            sched.init(failing.allocator(), test_options(2, 16 * 1024)),
        );
    }
}

fn test_parker(arg: ?*anyopaque) void {
    const log: *TestLog = @ptrCast(@alignCast(arg.?));
    log.fiber = log.sched.current_fiber();
    log.record(1);
    log.sched.park();
    log.record(3);
}

fn test_waker(arg: ?*anyopaque) void {
    const log: *TestLog = @ptrCast(@alignCast(arg.?));
    log.record(2);
    log.sched.unpark(log.fiber.?);
    log.record(2);
}

test "park suspends a fiber until another fiber unparks it" {
    if (!supported) return error.SkipZigTest;
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, test_options(2, 32 * 1024));
    defer sched.deinit(std.testing.allocator);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    _ = try sched.spawn(test_parker, &log);
    _ = try sched.spawn(test_waker, &log);
    sched.run(std.testing.io);

    // The waker keeps running after `unpark`; the parker resumes only on the next turn.
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 2, 3 }, log.ids[0..log.len]);
}

fn test_foreign_parker(arg: ?*anyopaque) void {
    const log: *TestLog = @ptrCast(@alignCast(arg.?));
    log.fiber = log.sched.current_fiber();
    @atomicStore(u32, &log.flag, 1, .release);
    log.sched.park();
    log.record(7);
}

fn test_foreign_waker(log: *TestLog, io: Io) void {
    // `flag` is set just before the fiber parks; `unpark_foreign` tolerates that window.
    for (0..std.math.maxInt(u32)) |_| {
        if (@atomicLoad(u32, &log.flag, .acquire) == 1) break;
        std.Thread.yield() catch {}; // Only a scheduling hint; spinning again is the fallback.
    }
    log.sched.unpark_foreign(io, log.fiber.?);
}

/// Runs one parked fiber that a second thread unparks; returns `inbox_version` afterwards.
fn run_foreign_wake(options: Options, io: Io) !u32 {
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, options);
    defer sched.deinit(std.testing.allocator);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    _ = try sched.spawn(test_foreign_parker, &log);
    const waker = try std.Thread.spawn(.{}, test_foreign_waker, .{ &log, io });
    sched.run(io);
    waker.join();

    try std.testing.expectEqualSlices(u32, &.{7}, log.ids[0..log.len]);
    return sched.inbox_version;
}

test "unpark_foreign wakes a carrier blocked on an empty ready queue" {
    if (!supported) return error.SkipZigTest;
    const version = try run_foreign_wake(test_options(1, 32 * 1024), std.testing.io);
    try std.testing.expectEqual(@as(u32, 1), version);
}

test "poller idle: unpark_foreign wakes a carrier asleep in the poller, not the futex" {
    if (!supported or !poller_supported) return error.SkipZigTest;
    const io = CountingIo.make();
    const version = try run_foreign_wake(test_options_poller(1, 32 * 1024), io);
    // The evented path needs no `inbox_version` (ADR 0003): the poller's latched wake does it.
    try std.testing.expectEqual(@as(u32, 0), version);
    try std.testing.expectEqual(@as(u32, 0), CountingIo.futex_calls());
}

const SleepProbe = struct { sched: *Sched, io: Io, sleep_ns: u64, elapsed_ns: u64 };

fn test_sleeper(arg: ?*anyopaque) void {
    const probe: *SleepProbe = @ptrCast(@alignCast(arg.?));
    const fiber = probe.sched.current_fiber();
    fiber.wait = .{ .addr = 0, .prev = null, .next = null, .sleeping = true, .outcome = .waiting };
    const started_ns = now_ns(probe.io);
    sleep.arm(probe.sched, fiber, .{ .at = @intCast(started_ns + probe.sleep_ns) });
    probe.sched.park();
    probe.elapsed_ns = now_ns(probe.io) - started_ns;
    fiber.wait = .none;
}

/// Parks one fiber on a wheel deadline with nothing else alive; returns how long it slept.
fn run_sleeper(options: Options, io: Io, sleep_ns: u64) !u64 {
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, options);
    defer sched.deinit(std.testing.allocator);

    var probe: SleepProbe = .{ .sched = &sched, .io = io, .sleep_ns = sleep_ns, .elapsed_ns = 0 };
    _ = try sched.spawn(test_sleeper, &probe);
    sched.run(io);
    try std.testing.expectEqual(@as(u32, 0), sched.live_count);
    return probe.elapsed_ns;
}

test "futex idle: a timed park waits in the futex until the wheel deadline" {
    if (!supported) return error.SkipZigTest;
    const sleep_ns: u64 = 20 * ns_per_ms;
    const options = test_options(1, stack_size_clock);
    const elapsed_ns = try run_sleeper(options, CountingIo.make(), sleep_ns);
    try std.testing.expect(elapsed_ns >= sleep_ns);
    // Proves the counter sees the idle path, so the poller twin below is not vacuous.
    try std.testing.expect(CountingIo.futex_calls() > 0);
}

test "poller idle: a timed park wakes from the poller at the wheel deadline" {
    if (!supported or !poller_supported) return error.SkipZigTest;
    const sleep_ns: u64 = 20 * ns_per_ms;
    const options = test_options_poller(1, stack_size_clock);
    const elapsed_ns = try run_sleeper(options, CountingIo.make(), sleep_ns);
    try std.testing.expect(elapsed_ns >= sleep_ns);
    try std.testing.expect(elapsed_ns < 10 * sleep_ns);
    try std.testing.expectEqual(@as(u32, 0), CountingIo.futex_calls());
}

test "poller idle: init adds the poller table and nothing allocates afterwards" {
    if (!supported or !poller_supported) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var sched: Sched = undefined;
    try sched.init(gpa, test_options_poller(2, stack_size_clock));
    defer sched.deinit(gpa);
    // Fiber table, stack arena, wheel nodes and the poller table.
    try std.testing.expectEqual(@as(usize, 4), failing.alloc_index);

    var probe: SleepProbe = .{
        .sched = &sched,
        .io = std.testing.io,
        .sleep_ns = ns_per_ms,
        .elapsed_ns = 0,
    };
    _ = try sched.spawn(test_sleeper, &probe);
    sched.run(std.testing.io);
    try std.testing.expect(probe.elapsed_ns >= ns_per_ms);
    try std.testing.expectEqual(@as(usize, 4), failing.alloc_index);
}

test "poller idle: init reports allocation failure at every block and frees the others" {
    if (!supported or !poller_supported) return error.SkipZigTest;
    for (0..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var sched: Sched = undefined;
        try std.testing.expectError(
            error.OutOfMemory,
            sched.init(failing.allocator(), test_options_poller(2, 16 * 1024)),
        );
    }
}

test "poller idle: a target without a poller refuses the option" {
    if (!supported or poller_supported) return error.SkipZigTest;
    var sched: Sched = undefined;
    try std.testing.expectError(
        error.PollerUnsupported,
        sched.init(std.testing.allocator, test_options_poller(1, 16 * 1024)),
    );
}

fn test_in_fiber_probe(arg: ?*anyopaque) void {
    const log: *TestLog = @ptrCast(@alignCast(arg.?));
    log.record(if (log.sched.in_fiber()) 1 else 0);
    log.record(if (log.sched.has_free_fiber()) 1 else 0);
}

test "in_fiber and has_free_fiber track the carrier and the fiber budget" {
    if (!supported) return error.SkipZigTest;
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, test_options(1, 32 * 1024));
    defer sched.deinit(std.testing.allocator);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    try std.testing.expect(!sched.in_fiber());
    try std.testing.expect(sched.has_free_fiber());
    _ = try sched.spawn(test_in_fiber_probe, &log);
    try std.testing.expect(!sched.has_free_fiber());
    try std.testing.expect(!sched.in_fiber()); // Spawned is not running.
    sched.run(std.testing.io);

    // Inside the fiber: in a fiber, and its own slot is taken.
    try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, log.ids[0..log.len]);
    try std.testing.expect(!sched.in_fiber());
    try std.testing.expect(sched.has_free_fiber());
}
