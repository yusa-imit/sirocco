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

/// Reports whether `name` should run given an optional CLI `filter` substring.
fn matchesFilter(name: []const u8, filter: ?[]const u8) bool {
    assert(name.len > 0);
    maybe(filter == null); // Sometimes no filter is given — everything matches.
    if (filter == null) return true;

    const f = filter.?;
    const matches = std.mem.indexOf(u8, name, f) != null;
    if (f.len > name.len) assert(!matches); // A filter longer than the name can never match.
    return matches;
}

const Rates = struct { ops_per_s: u64, ns_per_op: u64 };

/// Derives ops/s and ns/op from a raw op count and elapsed nanoseconds.
/// Both are 0 at the respective zero input rather than dividing by zero.
fn rates(ops: u64, ns: u64) Rates {
    maybe(ops == 0);
    maybe(ns == 0);
    const ns_per_op = if (ops == 0) 0 else ns / ops;
    const ops_per_s = if (ns == 0) 0 else ops * std.time.ns_per_s / ns;
    // Floor division never overshoots its dividend — an independent arithmetic check,
    // not a restatement of the branch just taken.
    if (ops != 0) assert(ns_per_op * ops <= ns);
    if (ns != 0) assert(ops_per_s * ns <= ops * std.time.ns_per_s);
    return .{ .ops_per_s = ops_per_s, .ns_per_op = ns_per_op };
}

pub fn main(init: std.process.Init) !void {
    assert(benches.len > 0);
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const filter: ?[]const u8 = if (args.len > 1) args[1] else null;

    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};

    for (benches) |b| {
        if (!matchesFilter(b.name, filter)) continue;
        const start = std.Io.Clock.Timestamp.now(init.io, .awake);
        const ops = try b.run(gpa);
        // `awake` is monotonic, so elapsed nanoseconds since `start` is always non-negative.
        const ns: u64 = @intCast(start.untilNow(init.io).raw.nanoseconds);
        const r = rates(ops, ns);
        try out.print(
            "{s:<32} {d:>12} ops/s {d:>10} ns/op\n",
            .{ b.name, r.ops_per_s, r.ns_per_op },
        );
        assert(out.end <= buf.len); // Postcondition: no write ever overflows the fixed buffer.
    }
}

test "matchesFilter: no filter always matches" {
    try std.testing.expect(matchesFilter("noop", null));
}

test "matchesFilter: substring filter matches" {
    try std.testing.expect(matchesFilter("noop", "oo"));
}

test "matchesFilter: non-matching filter excludes" {
    try std.testing.expect(!matchesFilter("noop", "zzz"));
}

test "rates: zero ops yields zero ns_per_op" {
    const r = rates(0, 1000);
    try std.testing.expectEqual(@as(u64, 0), r.ns_per_op);
}

test "rates: zero elapsed ns yields zero ops_per_s" {
    const r = rates(10, 0);
    try std.testing.expectEqual(@as(u64, 0), r.ops_per_s);
}

test "rates: normal division computes both rates" {
    const r = rates(2, std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 2), r.ops_per_s);
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s / 2), r.ns_per_op);
}

const assert = sirocco.stdx.assert;
const maybe = sirocco.stdx.maybe;
