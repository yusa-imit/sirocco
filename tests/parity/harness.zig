//! Differential-test harness: one call, two `Io` values (PRD §8, plan 002 item 3).
//!
//! `expectSameResult` runs `call(io, args...)` once on `rt.io()` (sirocco's vtable) and once on
//! `rt.baselineIo()` (the embedded `Io.Threaded`, the oracle) and compares the outcome: the tag
//! (value or error), the payload of a value, and the name of an error. Every later plan-002 slot
//! verifies itself through this function; a slot that legitimately differs is named in
//! `slots.divergent` with the contract that permits it, never patched around here.
//!
//! Limits, stated so a later item does not trip over them: both calls run in order against the
//! same real world, so a slot that mutates state (`dirCreateDir`, `fileWrite*`) or returns a
//! handle (`dirOpenFile`, `netConnectIp`) needs its own setup/projection helper before it can be
//! compared; payloads containing pointers are refused at compile time for the same reason.
//!
//! The harness compares outcomes only. It keeps no state, allocates nothing, and reports every
//! mismatch as `error.TestExpectedEqual`, the error `std.testing` uses for a failed comparison.

const std = @import("std");
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");

const assert = std.debug.assert;

/// Runs `call(io, args...)` on both of `rt`'s `Io` values and requires the same outcome.
/// Preconditions: `call` is a function whose first parameter is `std.Io`; `args` is a tuple of the
/// remaining arguments (each call gets its own copy, so `call` may not rely on shared mutation);
/// `rt` has been initialised and has not moved since its first `io()`.
pub fn expectSameResult(rt: *Runtime, comptime call: anytype, args: anytype) !void {
    const fn_info = @typeInfo(@TypeOf(call)).@"fn";
    comptime assert(fn_info.params.len == args.len + 1);
    comptime assert(fn_info.params[0].type == std.Io);

    const native_io = rt.io();
    const baseline_io = rt.baselineIo();
    assert(native_io.vtable != baseline_io.vtable);

    const native = @call(.auto, call, .{native_io} ++ args);
    const baseline = @call(.auto, call, .{baseline_io} ++ args);
    return expectSameOutcome(native, baseline);
}

fn expectSameOutcome(native: anytype, baseline: anytype) !void {
    const Outcome = @TypeOf(native);
    comptime assert(Outcome == @TypeOf(baseline));
    if (@typeInfo(Outcome) != .error_union) {
        return expect_same_payload(baseline, native);
    }
    if (native) |native_payload| {
        const baseline_payload = baseline catch return error.TestExpectedEqual;
        return expect_same_payload(baseline_payload, native_payload);
    } else |native_error| {
        _ = baseline catch |baseline_error| {
            const same = std.mem.eql(u8, @errorName(native_error), @errorName(baseline_error));
            return if (same) {} else error.TestExpectedEqual;
        };
        return error.TestExpectedEqual;
    }
}

// Quiet on purpose: a deliberate mismatch in the negative tests must not print a diff that reads
// like a failed build. Pointer-bearing payloads are refused because `std.meta.eql` would compare
// addresses, which differ between the two calls by construction.
fn expect_same_payload(expected: anytype, actual: @TypeOf(expected)) !void {
    const Payload = @TypeOf(expected);
    if (@typeInfo(Payload) == .pointer) {
        @compileError("parity payload contains a pointer; project it to a value first");
    }
    if (!std.meta.eql(expected, actual)) return error.TestExpectedEqual;
}

// Probes that answer differently depending on which vtable they are handed: the harness must see
// the difference, which a same-result call by construction never shows.
fn is_native(io: std.Io, native_vtable: *const std.Io.VTable) bool {
    return io.vtable == native_vtable;
}

fn native_only_error(io: std.Io, native_vtable: *const std.Io.VTable) error{Native}!u32 {
    if (io.vtable == native_vtable) return error.Native;
    return 7;
}

fn error_names_differ(
    io: std.Io,
    native_vtable: *const std.Io.VTable,
) error{ Native, Baseline }!u32 {
    if (io.vtable == native_vtable) return error.Native;
    return error.Baseline;
}

fn both_error(io: std.Io, unused: u32) error{Both}!u32 {
    _ = io;
    _ = unused;
    return error.Both;
}

fn both_value(io: std.Io, addend: u32) u32 {
    _ = io;
    return 40 + addend;
}

test "identical values and identical errors pass" {
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    try expectSameResult(&rt, both_value, .{2});
    try expectSameResult(&rt, both_error, .{0});
}

test "a payload mismatch is caught" {
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    const native_vtable: *const std.Io.VTable = rt.io().vtable;
    const result = expectSameResult(&rt, is_native, .{native_vtable});
    try std.testing.expectError(error.TestExpectedEqual, result);
}

test "a tag mismatch is caught in both directions" {
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    const native_vtable: *const std.Io.VTable = rt.io().vtable;
    const native_errors = expectSameResult(&rt, native_only_error, .{native_vtable});
    try std.testing.expectError(error.TestExpectedEqual, native_errors);
    // Swapping which side is "native" makes the baseline the erroring one.
    const swapped_vtable: *const std.Io.VTable = rt.baselineIo().vtable;
    const baseline_errors = expectSameResult(&rt, native_only_error, .{swapped_vtable});
    try std.testing.expectError(error.TestExpectedEqual, baseline_errors);
}

test "different error names are caught" {
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    const native_vtable: *const std.Io.VTable = rt.io().vtable;
    const result = expectSameResult(&rt, error_names_differ, .{native_vtable});
    try std.testing.expectError(error.TestExpectedEqual, result);
}
