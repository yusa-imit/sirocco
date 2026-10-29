//! sirocco.profile — bench-only counters for the carrier's time (plan 005 item 1, ADR 0003 4c).
//!
//! Purpose: say how a carrier spends its time in `kevent` (arm and wait), socket syscalls and
//! fiber switches, on a box where Instruments, `dtrace` and `sample(1)` are unusable. The
//! counters exist only when the program's root file declares `pub const sirocco_profile = true`
//! (`bench/echo_profile.zig` does; the library, the tests and every other bench do not), so a
//! normal build compiles `begin`, `end` and `count` to nothing.
//!
//! Invariants: counters only grow; each sample is two `clock_gettime` calls (about 40 ns), so a
//! profiled run is slower than a plain one and the shares are a reading, not a gate figure.
//! Nothing allocates. Any thread may record; the totals are relaxed atomics.

const std = @import("std");
const stdx = @import("stdx.zig");

const assert = stdx.assert;

const ns_per_s: u64 = 1_000_000_000;

/// What a sample is attributed to.
pub const Counter = enum(u8) {
    kevent_wait,
    kevent_arm,
    socket_read,
    socket_write,
    fiber_switch,
};

pub const counter_count: u32 = @typeInfo(Counter).@"enum".fields.len;

pub const enabled: bool = blk: {
    const root = @import("root");
    break :blk @hasDecl(root, "sirocco_profile") and root.sirocco_profile;
};

/// Totals at one moment; `delta` of two snapshots is one measured window.
pub const Snapshot = struct {
    elapsed_ns: [counter_count]u64,
    calls: [counter_count]u64,

    pub fn delta(later: Snapshot, earlier: Snapshot) Snapshot {
        var result: Snapshot = later;
        for (0..counter_count) |index| {
            assert(later.elapsed_ns[index] >= earlier.elapsed_ns[index]);
            assert(later.calls[index] >= earlier.calls[index]);
            result.elapsed_ns[index] = later.elapsed_ns[index] - earlier.elapsed_ns[index];
            result.calls[index] = later.calls[index] - earlier.calls[index];
        }
        return result;
    }
};

pub const Stamp = if (enabled) u64 else void;

var elapsed_ns_total: [counter_count]std.atomic.Value(u64) = @splat(.init(0));
var calls_total: [counter_count]std.atomic.Value(u64) = @splat(.init(0));

/// Opens a sample; pass the result to `end`.
pub fn begin() Stamp {
    if (!enabled) return {};
    return clock_ns();
}

/// Closes a sample opened by `begin` and attributes its time to `counter`.
pub fn end(counter: Counter, stamp: Stamp) void {
    if (!enabled) return;
    const stop = clock_ns();
    assert(stop >= stamp);
    const index = @intFromEnum(counter);
    _ = elapsed_ns_total[index].fetchAdd(stop - stamp, .monotonic);
    _ = calls_total[index].fetchAdd(1, .monotonic);
}

/// Counts one event of `counter` without timing it.
pub fn count(counter: Counter) void {
    if (!enabled) return;
    _ = calls_total[@intFromEnum(counter)].fetchAdd(1, .monotonic);
}

pub fn snapshot() Snapshot {
    var result: Snapshot = .{ .elapsed_ns = @splat(0), .calls = @splat(0) };
    for (0..counter_count) |index| {
        result.elapsed_ns[index] = elapsed_ns_total[index].load(.monotonic);
        result.calls[index] = calls_total[index].load(.monotonic);
    }
    return result;
}

fn clock_ns() u64 {
    var stamp: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.MONOTONIC, &stamp);
    assert(rc == 0);
    assert(stamp.sec >= 0);
    return @as(u64, @intCast(stamp.sec)) * ns_per_s + @as(u64, @intCast(stamp.nsec));
}

test "a disabled build records nothing and a snapshot delta subtracts" {
    const before = snapshot();
    const stamp = begin();
    end(.kevent_wait, stamp);
    count(.fiber_switch);
    const change = snapshot().delta(before);
    // The test binary's root does not declare `sirocco_profile`.
    try std.testing.expect(!enabled);
    try std.testing.expectEqual(@as(u64, 0), change.calls[@intFromEnum(Counter.kevent_wait)]);
    try std.testing.expectEqual(@as(u64, 0), change.calls[@intFromEnum(Counter.fiber_switch)]);
}

test "delta is the difference of two snapshots" {
    var earlier: Snapshot = .{ .elapsed_ns = @splat(10), .calls = @splat(2) };
    var later = earlier;
    later.elapsed_ns[1] = 25;
    later.calls[1] = 5;
    earlier.calls[0] = 1;
    later.calls[0] = 1;
    const change = later.delta(earlier);
    try std.testing.expectEqual(@as(u64, 15), change.elapsed_ns[1]);
    try std.testing.expectEqual(@as(u64, 3), change.calls[1]);
    try std.testing.expectEqual(@as(u64, 0), change.elapsed_ns[0]);
}
