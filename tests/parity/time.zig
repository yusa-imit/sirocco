//! Parity tests for the time slots (P2): `clockResolution` (`now` and `sleep` are not
//! deterministic enough to compare payloads and get their own tests when they turn native).
//!
//! Both slots are delegated today, so these pass trivially; they exist so that the day
//! `clockResolution` turns native the regression is caught by a test that already runs.

const std = @import("std");
const Io = std.Io;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");

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
