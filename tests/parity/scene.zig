//! Shared scaffolding for the fiber-level parity tests (plan 002 item 8): the runtime loop every
//! scenario runs in, the precondition that the futex slots are sirocco's own, and the one
//! scheduling primitive the scenarios need, `yield`.
//!
//! Scenarios run their assertions on the test's own thread, after the join: a fiber stack is a
//! fixed 128 KiB and a failing `std.testing.expect` formats a diff on it. Fibers only record facts
//! (counters, an order trace, samples) into a caller-owned struct. Everything runs on the single
//! carrier thread, so those structs need no atomics except the futex words themselves.
//!
//! Hang safety: while the futex slots are still the baseline's, a fiber that parks blocks the
//! carrier thread for good. `require_native` therefore runs before every scenario, so a missing
//! implementation fails the test instead of hanging the suite.

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");

pub const fibers_supported = Runtime.fibers_supported;

/// Both ways a runtime may be built: forwarding and failing. The futex slots are native, so the
/// `.fail` pass proves no scenario passes by falling through to `Io.Threaded`.
pub const modes = [_]Runtime.Unimplemented{ .forward, .fail };

/// The three futex slots of `rt.io()` are sirocco's, not the embedded `Io.Threaded`'s.
pub fn require_native(rt: *Runtime) !void {
    const vtable = rt.io().vtable;
    const baseline = rt.baselineIo().vtable;
    inline for (.{ "futexWait", "futexWaitUncancelable", "futexWake" }) |name| {
        try std.testing.expect(@field(vtable, name) != @field(baseline, name));
    }
}

/// Builds a runtime with `fibers_max` fibers in each mode and runs `scenario` on it. Skips where
/// the target has no fiber switch.
pub fn run_modes(fibers_max: u32, comptime scenario: fn (*Runtime) anyerror!void) !void {
    if (!fibers_supported) return error.SkipZigTest;
    for (modes) |mode| {
        var rt = try fixtures.init_runtime_in(std.testing.allocator, mode, fibers_max);
        defer rt.deinit();

        try require_native(&rt);
        try scenario(&rt);
    }
}

fn nothing() void {}

/// Lets every fiber that is ready right now run before the caller continues: the `async` below
/// queues its task behind them and `await` parks the caller until it finished. Needs one free
/// fiber; with none, the task runs inline and nobody else gets a turn (a saturated scenario must
/// not use it).
pub fn yield(io: Io) void {
    var future = io.async(nothing, .{});
    future.await(io);
}

/// True when `checkCancel` reported a cancelation (which it then marks as delivered).
pub fn observes_cancel(io: Io) bool {
    io.checkCancel() catch |err| switch (err) {
        error.Canceled => return true,
    };
    return false;
}

test "yield lets an already-ready fiber run first" {
    const Order = struct {
        var seen: u32 = 0;
        fn first() void {
            seen = seen * 10 + 1;
        }
        fn second(io: Io) void {
            yield(io);
            seen = seen * 10 + 2;
        }
    };
    try run_modes(4, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            Order.seen = 0;
            var late = io.async(Order.second, .{io});
            var early = io.async(Order.first, .{});
            late.await(io);
            early.await(io);
            // `second` yields to `first`, which was queued behind it.
            try std.testing.expectEqual(@as(u32, 12), Order.seen);
        }
    }.scenario);
}
