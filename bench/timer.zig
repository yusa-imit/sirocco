//! Timer wake-error benchmark (PRD §5 gate 7). Run: `zig build bench-timer`.
//!
//! One task sleeps 1 ms, `samples_target` times in a row, on `rt.io()` and on `rt.baselineIo()`
//! (the embedded `Io.Threaded`) from one `Runtime`. Each sample is `elapsed - 1 ms` on
//! `Clock.awake`, the lateness of the wake; the tables print p50, p99 and the maximum. The task
//! runs through `io.async` so that `sleep` executes on a fiber, where it is native; off a fiber
//! it would forward to the baseline and the two rows would measure the same thing. The gate is
//! p99 < 2 ms and sirocco <= Io.Threaded; docs/PRD.md §5 records the machine and numbers.
//! Allocation: the sample array is allocated once up front from `gpa`.

const std = @import("std");
const Io = std.Io;
const sirocco = @import("sirocco");
const Runtime = sirocco.Runtime;

const assert = sirocco.stdx.assert;
const maybe = sirocco.stdx.maybe;

/// Sleeps measured per `Io`.
const samples_target: u32 = 2000;
const sleep_ms: i64 = 1;
const gate_p99_ns_max: u64 = 2 * std.time.ns_per_ms;

const Stats = struct { p50_ns: u64, p99_ns: u64, max_ns: u64 };

const Job = struct {
    io: Io,
    errors_ns: []u64,
};

fn now_ns(io: Io) u64 {
    const stamp = Io.Clock.Timestamp.now(io, .awake);
    assert(stamp.raw.nanoseconds >= 0);
    return @intCast(stamp.raw.nanoseconds);
}

/// Sleeps `sleep_ms` once per slot of `job.errors_ns` and stores how late each wake was.
fn sleep_samples(job: *Job) void {
    assert(job.errors_ns.len > 0);
    const requested_ns: u64 = @intCast(sleep_ms * std.time.ns_per_ms);
    for (job.errors_ns) |*slot| {
        const started_ns = now_ns(job.io);
        job.io.sleep(.fromMilliseconds(sleep_ms), .awake) catch |err| switch (err) {
            // Nothing cancels this task; a wake error sample would be meaningless anyway.
            error.Canceled => @panic("bench task canceled"),
        };
        const elapsed_ns = now_ns(job.io) - started_ns;
        // The wheel and the kernel both round deadlines up, so a wake is never early.
        maybe(elapsed_ns < requested_ns);
        slot.* = elapsed_ns -| requested_ns;
    }
}

fn summarize(errors_ns: []u64) Stats {
    assert(errors_ns.len > 0);
    std.mem.sort(u64, errors_ns, {}, std.sort.asc(u64));
    const last = errors_ns.len - 1;
    const p99_index = @divFloor(errors_ns.len * 99, 100);
    assert(p99_index <= last);
    return .{
        .p50_ns = errors_ns[@divFloor(errors_ns.len, 2)],
        .p99_ns = errors_ns[p99_index],
        .max_ns = errors_ns[last],
    };
}

fn measure(io: Io, errors_ns: []u64) Stats {
    var job: Job = .{ .io = io, .errors_ns = errors_ns };
    var future = io.async(sleep_samples, .{&job});
    future.await(io);
    return summarize(errors_ns);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var rt = try Runtime.init(gpa, .{
        .backend = .threaded,
        .unimplemented = .forward,
        .environ = init.minimal.environ,
        .argv0 = .empty,
        .fibers_max = 4,
        .fiber_stack_size = 64 * 1024,
    });
    defer rt.deinit();

    const errors_ns = try gpa.alloc(u64, samples_target);
    defer gpa.free(errors_ns);

    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};

    const baseline = measure(rt.baselineIo(), errors_ns);
    const native = measure(rt.io(), errors_ns);
    try out.print("{s:<10} {s:>12} {s:>12} {s:>12}\n", .{ "io", "p50_ns", "p99_ns", "max_ns" });
    const rows = [_]struct { name: []const u8, stats: Stats }{
        .{ .name = "threaded", .stats = baseline },
        .{ .name = "sirocco", .stats = native },
    };
    for (rows) |row| {
        try out.print(
            "{s:<10} {d:>12} {d:>12} {d:>12}\n",
            .{ row.name, row.stats.p50_ns, row.stats.p99_ns, row.stats.max_ns },
        );
    }
    const pass = native.p99_ns < gate_p99_ns_max and native.p99_ns <= baseline.p99_ns;
    try out.print("gate 7: {s}\n", .{if (pass) "pass" else "FAIL"});
}
