//! Parity tests for the time slots (P2). `clockResolution` is delegated and passes trivially; it
//! exists so the day it turns native the regression is caught by a test that already runs. `now`
//! is not deterministic enough to compare payloads. `sleep` is native (plan 003 item 4): its
//! ordering, cancelation and no-stall facts run on fibers, via `scene.run_modes`.
//!
//! Clock: elapsed time is measured with `std.testing.io`, never with the runtime under test.

const std = @import("std");
const Io = std.Io;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");
const scene = @import("scene.zig");
const Runtime = @import("sirocco").Runtime;

const expectEqual = std.testing.expectEqual;
const ms: i96 = 1_000_000;

fn resolution(io: Io, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    return clock.resolution(io);
}

test "clockResolution agrees with the baseline for every clock" {
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    inline for (@typeInfo(Io.Clock).@"enum".fields) |field| {
        const clock: Io.Clock = @enumFromInt(field.value);
        try harness.expectSameResult(&rt, resolution, .{clock});
    }
}

fn clock_now() i96 {
    return Io.Clock.awake.now(std.testing.io).nanoseconds;
}

fn sleep_ms(io: Io, milliseconds: i96, clock: Io.Clock) Io.Cancelable!void {
    const raw: Io.Duration = .fromNanoseconds(milliseconds * ms);
    return io.sleep(raw, clock);
}

test "sleep is sirocco's own slot, and the baseline's agrees on a short real sleep" {
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    try std.testing.expect(rt.io().vtable.sleep != rt.baselineIo().vtable.sleep or
        !Runtime.fibers_supported);
    inline for (.{ Io.Clock.awake, Io.Clock.real, Io.Clock.boot }) |clock| {
        try harness.expectSameResult(&rt, sleep_ms, .{ 1, clock });
    }
}

const Trace = struct {
    order: [4]u8 = @splat(0),
    len: u32 = 0,
    elapsed_ns: i96 = 0,
    finished: u32 = 0,
};

fn ordered_sleeper(io: Io, t: *Trace, id: u8, milliseconds: i96) Io.Cancelable!void {
    try sleep_ms(io, milliseconds, .awake);
    t.order[t.len] = id;
    t.len += 1;
}

test "sleep: fibers wake in deadline order, not start order" {
    try scene.run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var t: Trace = .{};
            var a = io.async(ordered_sleeper, .{ io, &t, 'a', 30 });
            var b = io.async(ordered_sleeper, .{ io, &t, 'b', 10 });
            var c = io.async(ordered_sleeper, .{ io, &t, 'c', 20 });
            try a.await(io);
            try b.await(io);
            try c.await(io);
            try std.testing.expectEqualSlices(u8, "bca", t.order[0..t.len]);
        }
    }.scenario);
}

fn timed_sleeper(io: Io, t: *Trace) Io.Cancelable!void {
    try sleep_ms(io, 50, .awake);
    t.finished += 1;
}

test "sleep: 16 fibers sleeping 50 ms overlap instead of stalling the carrier" {
    try scene.run_modes(20, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var t: Trace = .{};
            var futures: [16]Io.Future(Io.Cancelable!void) = undefined;
            const start = clock_now();
            for (&futures) |*future| future.* = io.async(timed_sleeper, .{ io, &t });
            for (&futures) |*future| try future.await(io);
            const elapsed_ns = clock_now() - start;
            try expectEqual(@as(u32, 16), t.finished);
            // A stall serialises them: 16 * 50 ms = 800 ms.
            try std.testing.expect(elapsed_ns >= 50 * ms);
            try std.testing.expect(elapsed_ns < 400 * ms);
        }
    }.scenario);
}

fn long_sleeper(io: Io, t: *Trace) Io.Cancelable!void {
    t.len += 1;
    try sleep_ms(io, 5_000, .awake);
    t.finished += 1;
}

fn cancel_it(io: Io, target: *Io.Future(Io.Cancelable!void)) Io.Cancelable!void {
    return target.cancel(io);
}

test "sleep: a cancel while parked returns error.Canceled long before the deadline" {
    try scene.run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var t: Trace = .{};
            const start = clock_now();
            var sleeper = io.async(long_sleeper, .{ io, &t });
            var killer = io.async(cancel_it, .{ io, &sleeper });
            try std.testing.expectError(error.Canceled, killer.await(io));
            // It reached the sleep first, so the cancel found it parked.
            try expectEqual(@as(u32, 1), t.len);
            try expectEqual(@as(u32, 0), t.finished);
            try std.testing.expect(clock_now() - start < 1_000 * ms);
        }
    }.scenario);
}

fn gated_sleeper(io: Io, t: *Trace, gate: *std.atomic.Value(u32)) Io.Cancelable!void {
    while (gate.load(.acquire) == 0) io.futexWaitUncancelable(u32, &gate.raw, 0);
    try sleep_ms(io, 5_000, .awake);
    t.finished += 1;
}

test "sleep: a cancel pending at entry is observed without sleeping" {
    try scene.run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var t: Trace = .{};
            var gate: std.atomic.Value(u32) = .init(0);
            const start = clock_now();
            var task = io.async(gated_sleeper, .{ io, &t, &gate });
            gate.store(1, .release);
            io.futexWake(u32, &gate.raw, 1);
            try std.testing.expectError(error.Canceled, task.cancel(io));
            try expectEqual(@as(u32, 0), t.finished);
            try std.testing.expect(clock_now() - start < 1_000 * ms);
        }
    }.scenario);
}

fn protected_sleeper(io: Io, t: *Trace) bool {
    const old = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old);

    sleep_ms(io, 20, .awake) catch return false; // blocked: must not be canceled
    t.finished += 1;
    return true;
}

test "sleep: under blocked cancelation protection a cancel does not end the sleep" {
    try scene.run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var t: Trace = .{};
            var sleeper = io.async(protected_sleeper, .{ io, &t });
            // Not a cancelation point while blocked: the task finishes its sleep.
            try std.testing.expect(sleeper.cancel(io));
            try expectEqual(@as(u32, 1), t.finished);
        }
    }.scenario);
}

fn past_sleeper(io: Io, t: *Trace) Io.Cancelable!void {
    const past: Io.Timestamp = .fromNanoseconds(clock_now() - 1);
    try io.vtable.sleep(io.userdata, .{ .deadline = .{ .raw = past, .clock = .awake } });
    t.finished += 1;
}

test "sleep: a deadline in the past returns at once" {
    try scene.run_modes(4, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var t: Trace = .{};
            const start = clock_now();
            var task = io.async(past_sleeper, .{ io, &t });
            try task.await(io);
            try expectEqual(@as(u32, 1), t.finished);
            try std.testing.expect(clock_now() - start < 100 * ms);
        }
    }.scenario);
}

fn forever_sleeper(io: Io, t: *Trace) Io.Cancelable!void {
    t.len += 1;
    try io.vtable.sleep(io.userdata, .none);
    t.finished += 1;
}

test "sleep: a .none sleep lasts until it is canceled" {
    try scene.run_modes(4, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var t: Trace = .{};
            var sleeper = io.async(forever_sleeper, .{ io, &t });
            var killer = io.async(cancel_it, .{ io, &sleeper });
            try std.testing.expectError(error.Canceled, killer.await(io));
            try expectEqual(@as(u32, 1), t.len);
            try expectEqual(@as(u32, 0), t.finished);
        }
    }.scenario);
}

fn deadline_sleeper(io: Io, t: *Trace) Io.Cancelable!void {
    const at: Io.Timestamp = .fromNanoseconds(clock_now() + 30 * ms);
    try io.vtable.sleep(io.userdata, .{ .deadline = .{ .raw = at, .clock = .awake } });
    t.elapsed_ns = clock_now();
    t.finished += 1;
}

test "sleep: an absolute deadline sleeps until it, not less" {
    try scene.run_modes(4, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var t: Trace = .{};
            const start = clock_now();
            var task = io.async(deadline_sleeper, .{ io, &t });
            try task.await(io);
            try expectEqual(@as(u32, 1), t.finished);
            try std.testing.expect(t.elapsed_ns - start >= 30 * ms);
            try std.testing.expect(t.elapsed_ns - start < 400 * ms);
        }
    }.scenario);
}
