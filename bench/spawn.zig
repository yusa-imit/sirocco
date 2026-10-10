//! `io.async` -> body-entered latency benchmark (PRD §5 gate 6). Run: `zig build bench-spawn`.
//!
//! For each in-flight count (1 and 1000) it spawns that many tasks through `io.async` on
//! `rt.io()` and on `rt.baselineIo()` (the embedded `Io.Threaded`) from one `Runtime`, stamps the
//! clock just before each `async` and as the first thing in each body, awaits them all, and
//! prints the mean and maximum latency over many rounds. Both sides run the identical workload;
//! the gate is `sirocco <= Io.Threaded` at both counts, and the table in docs/PRD.md §5 records
//! the machine and numbers. Allocation: everything is allocated once up front from `gpa`.

const std = @import("std");
const Io = std.Io;
const sirocco = @import("sirocco");
const Runtime = sirocco.Runtime;

const assert = sirocco.stdx.assert;
const maybe = sirocco.stdx.maybe;

/// In-flight counts the gate names.
const in_flight_counts = [_]u32{ 1, 1000 };
/// Tasks measured per in-flight count, so every count averages over the same sample size.
const samples_target: u32 = 20_000;
const in_flight_max: u32 = 1000;

const Slot = struct {
    spawned_ns: u64,
    entered_ns: u64,
    clock: Io,
};

const Stats = struct { mean_ns: u64, max_ns: u64, samples: u64 };

fn now_ns(io: Io) u64 {
    const stamp = Io.Clock.Timestamp.now(io, .awake);
    assert(stamp.raw.nanoseconds >= 0);
    return @intCast(stamp.raw.nanoseconds);
}

fn body(slot: *Slot) void {
    slot.entered_ns = now_ns(slot.clock);
}

/// Spawns `slots.len` tasks, awaits them all, and folds latencies into `total_ns` / `max_ns`.
fn run_round(io: Io, futures: []Io.Future(void), slots: []Slot, total_ns: *u64, max_ns: *u64) void {
    assert(futures.len == slots.len);
    assert(slots.len > 0);
    for (slots, futures) |*slot, *future| {
        slot.clock = io;
        slot.entered_ns = 0;
        slot.spawned_ns = now_ns(io);
        future.* = io.async(body, .{slot});
    }
    for (futures) |*future| future.await(io);
    for (slots) |slot| {
        // The clock is monotonic and the body runs after the stamp, so entry never precedes spawn.
        assert(slot.entered_ns >= slot.spawned_ns);
        const latency = slot.entered_ns - slot.spawned_ns;
        total_ns.* += latency;
        max_ns.* = @max(max_ns.*, latency);
    }
}

fn measure(io: Io, futures: []Io.Future(void), slots: []Slot) Stats {
    maybe(slots.len == 1);
    assert(slots.len > 0);
    assert(slots.len <= in_flight_max);
    const rounds: u32 = @divExact(samples_target, @as(u32, @intCast(slots.len)));
    var total_ns: u64 = 0;
    var max_ns: u64 = 0;
    for (0..rounds) |_| run_round(io, futures, slots, &total_ns, &max_ns);
    const samples: u64 = @as(u64, rounds) * slots.len;
    return .{ .mean_ns = @divFloor(total_ns, samples), .max_ns = max_ns, .samples = samples };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var rt = try Runtime.init(gpa, .{
        .backend = .threaded,
        .unimplemented = .forward,
        .environ = init.minimal.environ,
        .argv0 = .empty,
        .fibers_max = in_flight_max,
        .fiber_stack_size = 64 * 1024,
        .offload_threads = 1,
    });
    defer rt.deinit();

    const futures = try gpa.alloc(Io.Future(void), in_flight_max);
    defer gpa.free(futures);

    const slots = try gpa.alloc(Slot, in_flight_max);
    defer gpa.free(slots);

    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};

    try out.print("{s:<10} {s:>10} {s:>12} {s:>12}\n", .{ "io", "in_flight", "mean_ns", "max_ns" });
    for (in_flight_counts) |count| {
        const used = slots[0..count];
        const baseline = measure(rt.baselineIo(), futures[0..count], used);
        const native = measure(rt.io(), futures[0..count], used);
        const rows = [_]struct { name: []const u8, stats: Stats }{
            .{ .name = "threaded", .stats = baseline },
            .{ .name = "sirocco", .stats = native },
        };
        for (rows) |row| {
            try out.print(
                "{s:<10} {d:>10} {d:>12} {d:>12}\n",
                .{ row.name, count, row.stats.mean_ns, row.stats.max_ns },
            );
        }
    }
}
