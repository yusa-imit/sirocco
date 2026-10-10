//! Parity tests for the directory slots (forwarded to `Io.Threaded` until sirocco owns them).
//!
//! Covers both outcome tags of `dirAccess`: a path that exists (value) and one that does not
//! (error name), so the harness's tag and error-name comparison run against a real slot.

const std = @import("std");
const Io = std.Io;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");

fn access(io: Io, sub_path: []const u8) Io.Dir.AccessError!void {
    return Io.Dir.cwd().access(io, sub_path, .{});
}

fn stat_file(io: Io, sub_path: []const u8) Io.Dir.StatFileError!Io.File.Kind {
    const stat = try Io.Dir.cwd().statFile(io, sub_path, .{});
    return stat.kind;
}

test "dirAccess agrees on an existing and a missing path" {
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    try harness.expectSameResult(&rt, access, .{"."});
    try harness.expectSameResult(&rt, access, .{"sirocco-parity-no-such-path"});
    try harness.expectSameResultInFiber(&rt, access, .{"."});
    try harness.expectSameResultInFiber(&rt, access, .{"sirocco-parity-no-such-path"});
    try std.testing.expectError(
        error.FileNotFound,
        access(rt.io(), "sirocco-parity-no-such-path"),
    );
}

test "dirStatFile agrees on the kind of the working directory and of a missing path" {
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    try harness.expectSameResult(&rt, stat_file, .{"."});
    try harness.expectSameResult(&rt, stat_file, .{"sirocco-parity-no-such-path"});
    try harness.expectSameResultInFiber(&rt, stat_file, .{"."});
    try harness.expectSameResultInFiber(&rt, stat_file, .{"sirocco-parity-no-such-path"});
    try std.testing.expectEqual(Io.File.Kind.directory, try stat_file(rt.io(), "."));
}
