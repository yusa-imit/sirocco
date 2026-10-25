//! Loopback accept latency and idle-connection memory (PRD §5 gates 3 and 4).
//! Run: `zig build bench-latency`.
//!
//! Gate 3: `connections_latency` clients connect at once to one loopback server. The server
//! writes one byte to every accepted stream. A client's latency is the time from just before its
//! `connect` to the arrival of that byte, so it covers connect, accept, the server task start and
//! one write. `latency_rounds` rounds are pooled and p99 is read from the sorted samples. The
//! gate is p99 on `rt.io()` <= p99 on `rt.baselineIo()` of one `Runtime`.
//!
//! Gate 4: `connections_idle` clients connect one after another and stay silent; the server holds
//! one `concurrent` task parked in a read per accepted stream. The resident-set delta over the
//! scenario divided by the number of held tasks is the cost of one idle connection (both
//! descriptors, the registry entry and the server task). `Io.Threaded` may refuse a thread before
//! `connections_idle`; the row then divides by the tasks it did hold and prints that count, so
//! the two rows compare per task. The gate is native bytes per task <= threaded bytes per task.
//!
//! The process raises `RLIMIT_NOFILE` first (macOS starts at 256) and exits with a message when
//! the hard limit refuses, rather than running a smaller N. Resident size is read from the Mach
//! task on macOS only; elsewhere gate 4 prints that it is unsupported.
//! Allocation: sample and stream arrays are allocated once per scenario from `gpa`; the `Runtime`
//! is sized for the largest scenario at `init`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const sirocco = @import("sirocco");
const Runtime = sirocco.Runtime;

const assert = sirocco.stdx.assert;
const maybe = sirocco.stdx.maybe;

const connections_latency: u32 = 1000;
const latency_rounds: u32 = 5;
const connections_idle: u32 = 10_000;
/// Connects issued before the client waits for the server to have started their tasks; it keeps
/// the unaccepted connections below `kernel_backlog`.
const connect_chunk: u32 = 500;

/// Tasks alive at once in the largest scenario: one server task per idle connection, plus the
/// acceptor and the scenario itself; the slack covers the harness task.
const fibers_max: u32 = connections_idle + 64;
const sockets_max: u32 = 2 * connections_idle + 64;
const fiber_stack_size: u32 = 128 * 1024;
const kernel_backlog: u31 = 1024;
/// Descriptors the largest scenario holds: both ends of every connection, the listener, slack.
const files_needed: u64 = 2 * connections_idle + 128;
/// Polls of 1 ms a wait gives up after.
const wait_iterations_max: u32 = 20_000;
/// Time the idle tasks get to park before the resident size is read.
const settle_ms: i64 = 200;

comptime {
    assert(connect_chunk < kernel_backlog);
    assert(connections_latency < kernel_backlog);
    assert(fibers_max > 2 * connections_latency + 2);
}

const Scenario = struct {
    io: Io,
    address: Io.net.IpAddress,
    connections: u32,
    /// Whether the server writes one byte to every accepted stream (gate 3) or stays silent.
    greet: bool,
    served: std.atomic.Value(u32) = .init(0),
    refused: std.atomic.Value(bool) = .init(false),
    failures: std.atomic.Value(u32) = .init(0),
};

const Idle = struct { held: u32, rss_bytes: u64, connected: u32 = 0, failures: u32 = 0 };

fn now_ns(io: Io) u64 {
    const stamp = Io.Clock.Timestamp.now(io, .awake);
    assert(stamp.raw.nanoseconds >= 0);
    return @intCast(stamp.raw.nanoseconds);
}

fn fail(scenario: *Scenario) void {
    _ = scenario.failures.fetchAdd(1, .monotonic);
}

/// Resident bytes of this process, or 0 where the bench cannot read them.
fn rss_bytes() u64 {
    if (builtin.os.tag != .macos) return 0;
    var info = std.mem.zeroes(std.c.mach_task_basic_info);
    var count: std.c.mach_msg_type_number_t = std.c.MACH.TASK.BASIC.INFO_COUNT;
    const status = std.c.task_info(
        std.c.mach_task_self(),
        std.c.MACH.TASK.BASIC.INFO,
        @ptrCast(&info),
        &count,
    );
    assert(status == 0);
    assert(info.resident_size > 0);
    return info.resident_size;
}

/// Greets the client when asked to, then parks in a read until the client closes its end.
fn serve(scenario: *Scenario, stream: Io.net.Stream) void {
    const io = scenario.io;
    defer stream.close(io);

    var read_buffer: [1]u8 = undefined;
    var write_buffer: [1]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    if (scenario.greet) {
        writer.interface.writeAll("g") catch return fail(scenario);
        writer.interface.flush() catch return fail(scenario);
    }
    _ = scenario.served.fetchAdd(1, .release);
    var sink: [1]u8 = undefined;
    // The client never writes, so this returns on its close or reset; both end the task, and the
    // error carries nothing more to report.
    _ = reader.interface.readSliceShort(&sink) catch 0;
}

/// Accepts up to `connections` streams and serves each on its own task. A task the runtime
/// refuses sets `refused` and ends the loop: that is a measurement, not a failure.
fn acceptor(scenario: *Scenario, server: *Io.net.Server) void {
    const io = scenario.io;
    var servers: Io.Group = .init;
    defer servers.cancel(io);

    for (0..scenario.connections) |_| {
        const stream = server.accept(io) catch return fail(scenario);
        servers.concurrent(io, serve, .{ scenario, stream }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                stream.close(io);
                scenario.refused.store(true, .release);
                return;
            },
        };
    }
    servers.await(io) catch return fail(scenario);
}

fn listen(scenario: *Scenario) ?Io.net.Server {
    const server = scenario.address.listen(scenario.io, .{
        .kernel_backlog = kernel_backlog,
        .reuse_address = true,
        .mode = .stream,
        .protocol = .tcp,
    }) catch return null;
    scenario.address = server.socket.address;
    return server;
}

/// Times connect to first byte for client `index`; a zero sample marks a failure.
fn latency_client(scenario: *Scenario, samples: []u64, index: u32) void {
    const io = scenario.io;
    assert(index < samples.len);
    assert(samples[index] == 0);
    const started_ns = now_ns(io);
    const stream = scenario.address.connect(io, .{ .mode = .stream }) catch return fail(scenario);
    defer stream.close(io);

    var read_buffer: [1]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var byte: [1]u8 = undefined;
    reader.interface.readSliceAll(&byte) catch return fail(scenario);
    samples[index] = @max(1, now_ns(io) - started_ns);
}

/// One round of gate 3: every client connects at once and `samples` receives one latency each.
fn run_latency(scenario: *Scenario, samples: []u64) void {
    const io = scenario.io;
    assert(scenario.greet);
    assert(samples.len == scenario.connections);
    var server = listen(scenario) orelse return fail(scenario);
    defer server.deinit(io);

    var accepting = io.concurrent(acceptor, .{ scenario, &server }) catch return fail(scenario);
    var clients: Io.Group = .init;
    defer clients.cancel(io);

    for (0..scenario.connections) |index| {
        clients.concurrent(io, latency_client, .{ scenario, samples, @as(u32, @intCast(index)) }) catch {
            fail(scenario);
            break;
        };
    }
    clients.await(io) catch fail(scenario);
    if (scenario.failures.load(.acquire) == 0) accepting.await(io) else accepting.cancel(io);
}

/// Waits until `target` server tasks are parked; false when the runtime refused one or a step
/// failed, so the caller stops connecting.
fn served_wait(scenario: *Scenario, target: u32) bool {
    for (0..wait_iterations_max) |_| {
        if (scenario.served.load(.acquire) >= target) return true;
        if (scenario.refused.load(.acquire)) return false;
        if (scenario.failures.load(.acquire) != 0) return false;
        scenario.io.sleep(.fromMilliseconds(1), .awake) catch return false;
    }
    return false;
}

/// Connects clients in chunks until `streams` is full or the server stops serving; returns how
/// many are connected.
fn connect_idle(scenario: *Scenario, streams: []Io.net.Stream) u32 {
    var connected: u32 = 0;
    while (connected < streams.len) {
        const chunk_end: u32 = @min(connected + connect_chunk, @as(u32, @intCast(streams.len)));
        while (connected < chunk_end) {
            const stream = scenario.address.connect(scenario.io, .{ .mode = .stream }) catch {
                fail(scenario);
                return connected;
            };
            streams[connected] = stream;
            connected += 1;
        }
        if (!served_wait(scenario, connected)) return connected;
    }
    return connected;
}

/// Gate 4: holds as many idle connections as the runtime serves and reads the resident size.
fn run_idle(scenario: *Scenario, streams: []Io.net.Stream) Idle {
    const io = scenario.io;
    assert(!scenario.greet);
    assert(streams.len == scenario.connections);
    var server = listen(scenario) orelse return .{ .held = 0, .rss_bytes = 0 };
    defer server.deinit(io);

    var accepting = io.concurrent(acceptor, .{ scenario, &server }) catch {
        fail(scenario);
        return .{ .held = 0, .rss_bytes = 0 };
    };
    const before = rss_bytes();
    const connected = connect_idle(scenario, streams);
    io.sleep(.fromMilliseconds(settle_ms), .awake) catch fail(scenario);
    const after = rss_bytes();
    const held = scenario.served.load(.acquire);
    maybe(held < connected);
    for (streams[0..connected]) |stream| stream.close(io);
    accepting.await(io);
    return .{ .held = held, .rss_bytes = after -| before, .connected = connected, .failures = scenario.failures.load(.acquire) };
}

fn measure_latency(gpa: std.mem.Allocator, io: Io, pooled: []u64) !u32 {
    assert(pooled.len == connections_latency * latency_rounds);
    const samples = try gpa.alloc(u64, connections_latency);
    defer gpa.free(samples);

    var failures: u32 = 0;
    for (0..latency_rounds) |round| {
        @memset(samples, 0);
        var scenario: Scenario = .{
            .io = io,
            .address = .{ .ip4 = .loopback(0) },
            .connections = connections_latency,
            .greet = true,
        };
        var future = io.async(run_latency, .{ &scenario, samples });
        future.await(io);
        failures += scenario.failures.load(.acquire);
        const slot = pooled[round * connections_latency ..][0..connections_latency];
        @memcpy(slot, samples);
    }
    return failures;
}

fn measure_idle(gpa: std.mem.Allocator, io: Io) !Idle {
    const streams = try gpa.alloc(Io.net.Stream, connections_idle);
    defer gpa.free(streams);

    var scenario: Scenario = .{
        .io = io,
        .address = .{ .ip4 = .loopback(0) },
        .connections = connections_idle,
        .greet = false,
    };
    var future = io.async(run_idle, .{ &scenario, streams });
    const idle = future.await(io);
    return idle;
}

/// Sorts `pooled` and returns the value at the given percentile; zero samples are failures.
fn percentile_ns(pooled: []u64, percent: u32) u64 {
    assert(percent > 0 and percent <= 100);
    assert(pooled.len > 0);
    const index: usize = @divFloor(pooled.len * percent + 99, 100) - 1;
    return pooled[index];
}

fn nofile_raise(need: u64) error{NofileRefused}!void {
    var limit = posix.getrlimit(.NOFILE) catch return error.NofileRefused;
    if (limit.cur >= need) return;
    if (limit.max < need) return error.NofileRefused;
    limit.cur = need;
    posix.setrlimit(.NOFILE, limit) catch return error.NofileRefused;
}

fn bytes_per_task(idle: Idle) u64 {
    if (idle.held == 0) return 0;
    return @divFloor(idle.rss_bytes, idle.held);
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var w = Io.File.stdout().writer(init.io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};

    nofile_raise(files_needed) catch |err| switch (err) {
        error.NofileRefused => {
            const message = "RLIMIT_NOFILE below {d}: refusing to run a smaller N\n";
            try out.print(message, .{files_needed});
            return;
        },
    };
    const rss_before_init = rss_bytes();
    var rt = try Runtime.init(init.gpa, .{
        .backend = .auto,
        .unimplemented = .forward,
        .environ = init.minimal.environ,
        .argv0 = .empty,
        .fibers_max = fibers_max,
        .fiber_stack_size = fiber_stack_size,
        .offload_threads = 4,
        .sockets_max = sockets_max,
    });
    defer rt.deinit();

    try out.print("runtime init resident delta: {d} KiB\n", .{
        @divFloor(rss_bytes() -| rss_before_init, 1024),
    });
    try out.flush();
    try gate_3(init.gpa, &rt, out);
    try out.flush();
    try gate_4(init.gpa, &rt, out);
}

fn gate_3(gpa: std.mem.Allocator, rt: *Runtime, out: *Io.Writer) !void {
    const pooled = try gpa.alloc(u64, connections_latency * latency_rounds);
    defer gpa.free(pooled);

    const baseline_failures = try measure_latency(gpa, rt.baselineIo(), pooled);
    try out.print("threaded latency rounds done\n", .{});
    try out.flush();
    std.mem.sort(u64, pooled, {}, std.sort.asc(u64));
    const baseline_p50 = percentile_ns(pooled, 50);
    const baseline_p99 = percentile_ns(pooled, 99);
    const native_failures = try measure_latency(gpa, rt.io(), pooled);
    std.mem.sort(u64, pooled, {}, std.sort.asc(u64));
    const native_p50 = percentile_ns(pooled, 50);
    const native_p99 = percentile_ns(pooled, 99);

    try out.print("{s:<10} {s:>6} {s:>10} {s:>10} {s:>8}\n", .{ "io", "conns", "p50 us", "p99 us", "failures" });
    try out.print("{s:<10} {d:>6} {d:>10} {d:>10} {d:>8}\n", .{
        "threaded",                    connections_latency,
        @divFloor(baseline_p50, 1000), @divFloor(baseline_p99, 1000),
        baseline_failures,
    });
    try out.print("{s:<10} {d:>6} {d:>10} {d:>10} {d:>8}\n", .{
        @tagName(rt.backend),        connections_latency,
        @divFloor(native_p50, 1000), @divFloor(native_p99, 1000),
        native_failures,
    });
    const clean = baseline_failures == 0 and native_failures == 0 and baseline_p50 > 0;
    try out.print("gate 3 ({d} conns, p99 <= Io.Threaded): {s}\n", .{
        connections_latency,
        if (clean and native_p99 <= baseline_p99) "pass" else "FAIL",
    });
}

fn gate_4(gpa: std.mem.Allocator, rt: *Runtime, out: *Io.Writer) !void {
    if (rss_bytes() == 0) {
        try out.print("gate 4: resident size is unsupported on this OS\n", .{});
        return;
    }
    const baseline = try measure_idle(gpa, rt.baselineIo());
    try out.print("threaded idle done held={d} conn={d} fail={d} rss={d}\n", .{ baseline.held, baseline.connected, baseline.failures, baseline.rss_bytes });
    try out.flush();
    const native = try measure_idle(gpa, rt.io());

    try out.print("{s:<10} {s:>6} {s:>12} {s:>14}\n", .{ "io", "held", "rss KiB", "bytes/task" });
    try out.print("{s:<10} {d:>6} {d:>12} {d:>14}\n", .{
        "threaded", baseline.held, @divFloor(baseline.rss_bytes, 1024), bytes_per_task(baseline),
    });
    try out.print("{s:<10} {d:>6} {d:>12} {d:>14}\n", .{
        @tagName(rt.backend), native.held, @divFloor(native.rss_bytes, 1024), bytes_per_task(native),
    });
    const complete = native.held == connections_idle and baseline.held > 0;
    const pass = complete and bytes_per_task(native) <= bytes_per_task(baseline);
    try out.print("gate 4 ({d} idle, bytes/task <= Io.Threaded): {s}\n", .{
        connections_idle, if (pass) "pass" else "FAIL",
    });
}
