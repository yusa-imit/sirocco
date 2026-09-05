//! sirocco benchmark harness. Run: `zig build bench -- [filter]`
//! Each benchmark prints `name  ops/s  ns/op` so results can be pasted into docs/milestones.md.

const std = @import("std");
const sirocco = @import("sirocco");

const Bench = struct { name: []const u8, run: *const fn (std.mem.Allocator) anyerror!u64 };

fn noop(_: std.mem.Allocator) !u64 {
    return 1;
}

const benches = [_]Bench{
    .{ .name = "noop", .run = noop },
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    const filter: ?[]const u8 = if (args.len > 1) args[1] else null;

    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    defer out.flush() catch {};

    for (benches) |b| {
        if (filter) |f| if (std.mem.indexOf(u8, b.name, f) == null) continue;
        var timer = try std.time.Timer.start();
        const ops = try b.run(gpa);
        const ns = timer.read();
        const ns_per_op = if (ops == 0) 0 else ns / ops;
        const ops_per_s = if (ns == 0) 0 else ops * std.time.ns_per_s / ns;
        try out.print("{s:<32} {d:>12} ops/s {d:>10} ns/op\n", .{ b.name, ops_per_s, ns_per_op });
    }
}
