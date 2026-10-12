//! Tests for `sched.zig`: spawn, round-robin, park/unpark, cross-thread wakes and the
//! allocation contract of `init`.
//!
//! Split out of `sched.zig` to keep that file under the 800-line cap; everything here goes through
//! its public surface. The two white-box tests (canary, `init_checked`) stay beside the private
//! helpers they cover.

const std = @import("std");
const Sched = @import("sched.zig");

const Io = std.Io;
const Fiber = Sched.Fiber;
const Options = Sched.Options;
const supported = Sched.supported;

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
    return .{ .fibers_max = fibers_max, .stack_size = stack_size, .now_ns = 0 };
}

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

test "unpark_foreign wakes a carrier blocked on an empty ready queue" {
    if (!supported) return error.SkipZigTest;
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, test_options(1, 32 * 1024));
    defer sched.deinit(std.testing.allocator);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    _ = try sched.spawn(test_foreign_parker, &log);
    const waker = try std.Thread.spawn(.{}, test_foreign_waker, .{ &log, std.testing.io });
    sched.run(std.testing.io);
    waker.join();

    try std.testing.expectEqualSlices(u32, &.{7}, log.ids[0..log.len]);
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
