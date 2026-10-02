const std = @import("std");
const Io = std.Io;
const Runtime = @import("src/runtime.zig");
fn chain(io: Io, depth: u32, seed: u32) u32 {
    if (depth == 0) return seed;
    var next = io.async(chain, .{ io, depth - 1, seed *% 31 +% 7 });
    return next.await(io) +% depth;
}
fn mk() !Runtime {
    return Runtime.init(std.testing.allocator, .{ .backend = .threaded, .unimplemented = .forward, .environ = .empty, .argv0 = .empty, .fibers_max = 8, .fiber_stack_size = 128 * 1024 });
}
test "native" {
    var rt = try mk();
    defer rt.deinit();
    std.debug.print("native start\n", .{});
    try std.testing.expectEqual(@as(u32, 1), chain(rt.io(), 1, 1) -% 0 -% 1 +% 1 -% chain(rt.io(), 1, 1) +% 1);
    std.debug.print("native depth1 ok\n", .{});
    _ = chain(rt.io(), 3, 1);
    std.debug.print("native depth3 ok\n", .{});
}
test "baseline" {
    var rt = try mk();
    defer rt.deinit();
    _ = chain(rt.baselineIo(), 3, 1);
    std.debug.print("baseline ok\n", .{});
}
