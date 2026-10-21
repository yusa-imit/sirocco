//! Loopback echo throughput benchmark (PRD §5 gates 1 and 2). Run: `zig build bench-echo`.
//!
//! `connections` clients each connect to one loopback server and echo a 64-byte message in a
//! closed loop: write, flush, read the answer back, repeat. The server runs one `concurrent`
//! task per accepted connection. The same scenario runs on `rt.io()` and on `rt.baselineIo()`
//! (the embedded `Io.Threaded`) of one `Runtime` built with `.auto` (kqueue or epoll where they
//! exist), at 1 and at 1000 connections, for `window_ms` each. The measured window opens after
//! every client has connected and closes before any client closes, so connect cost is excluded;
//! throughput is completed echoes per second over the window. Gate 1 is the ratio at 1000 and
//! must be >= 2.0, gate 2 the ratio at 1 and must be >= 0.9; docs/PRD.md §5 records the numbers.
//! Clients and the server loop use the public `Stream` reader and writer, so the row measures
//! what a consumer gets, not the raw slots.
//!
//! The process raises `RLIMIT_NOFILE` first (macOS starts at 256) and exits with a message when
//! the hard limit refuses, rather than running a smaller N.
//! Allocation: the per-client counters are allocated once per scenario from `gpa`; the `Runtime`
//! is sized for the largest scenario at `init`.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const sirocco = @import("sirocco");
const Runtime = sirocco.Runtime;

const assert = sirocco.stdx.assert;
const maybe = sirocco.stdx.maybe;

const message_size: u32 = 64;
const window_ms: i64 = 5000;
const connections_many: u32 = 1000;
const connections_one: u32 = 1;
const gate_many_ratio_min: f64 = 2.0;
const gate_one_ratio_min: f64 = 0.9;

/// Tasks alive at once in the largest scenario: a client and a server per connection, plus the
/// acceptor and the scenario itself; the slack covers the harness task.
const fibers_max: u32 = 2 * connections_many + 16;
const fiber_stack_size: u32 = 128 * 1024;
const kernel_backlog: u31 = 1024;
/// Descriptors the largest scenario holds: both ends of every connection, the listener, slack.
const files_needed: u64 = 2 * connections_many + 64;
/// Polls of 1 ms the scenario waits for every client to connect before it gives up.
const connect_wait_iterations_max: u32 = 20_000;

const Scenario = struct {
    io: Io,
    address: Io.net.IpAddress,
    connections: u32,
    /// Echoes completed per client, written by that client only and read after the group joined.
    done: []u64,
    connected: std.atomic.Value(u32) = .init(0),
    go: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    failures: std.atomic.Value(u32) = .init(0),
};

const Result = struct { echoes: u64, window_ns: u64, failures: u32 };

fn now_ns(io: Io) u64 {
    const stamp = Io.Clock.Timestamp.now(io, .awake);
    assert(stamp.raw.nanoseconds >= 0);
    return @intCast(stamp.raw.nanoseconds);
}

fn fail(scenario: *Scenario) void {
    _ = scenario.failures.fetchAdd(1, .monotonic);
}

/// Echoes every message back until the client closes its end.
fn serve(scenario: *Scenario, stream: Io.net.Stream) void {
    const io = scenario.io;
    defer stream.close(io);

    var read_buffer: [message_size]u8 = undefined;
    var write_buffer: [message_size]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var message: [message_size]u8 = undefined;
    // A client sends at most one message per round trip, so this bounds the loop by the window.
    for (0..std.math.maxInt(u32)) |_| {
        reader.interface.readSliceAll(&message) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return fail(scenario),
        };
        writer.interface.writeAll(&message) catch return fail(scenario);
        writer.interface.flush() catch return fail(scenario);
    }
    // 2^32 round trips cannot fit in `window_ms`; reaching here means the bound is wrong.
    fail(scenario);
}

/// Accepts exactly `connections` streams and serves each on its own task.
fn acceptor(scenario: *Scenario, server: *Io.net.Server) void {
    const io = scenario.io;
    var servers: Io.Group = .init;
    defer servers.cancel(io);

    for (0..scenario.connections) |_| {
        const stream = server.accept(io) catch return fail(scenario);
        servers.concurrent(io, serve, .{ scenario, stream }) catch {
            stream.close(io);
            return fail(scenario);
        };
    }
    servers.await(io) catch return fail(scenario);
}

/// Connects, waits for the window to open, then echoes until it closes.
fn client(scenario: *Scenario, index: u32) void {
    const io = scenario.io;
    assert(index < scenario.connections);
    const stream = scenario.address.connect(io, .{ .mode = .stream }) catch return fail(scenario);
    defer stream.close(io);

    _ = scenario.connected.fetchAdd(1, .release);
    for (0..connect_wait_iterations_max) |_| {
        if (scenario.go.load(.acquire)) break;
        io.sleep(.fromMilliseconds(1), .awake) catch return fail(scenario);
    } else return fail(scenario);

    var read_buffer: [message_size]u8 = undefined;
    var write_buffer: [message_size]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var message: [message_size]u8 = @splat(@truncate(index));
    var answer: [message_size]u8 = undefined;
    var echoes: u64 = 0;
    while (!scenario.stop.load(.acquire)) {
        writer.interface.writeAll(&message) catch return fail(scenario);
        writer.interface.flush() catch return fail(scenario);
        reader.interface.readSliceAll(&answer) catch return fail(scenario);
        if (!std.mem.eql(u8, &message, &answer)) return fail(scenario);
        echoes += 1;
    }
    scenario.done[index] = echoes;
}

/// Blocks until every client has connected, or `failures` says one cannot.
fn connected_wait(scenario: *Scenario) bool {
    for (0..connect_wait_iterations_max) |_| {
        if (scenario.connected.load(.acquire) == scenario.connections) return true;
        if (scenario.failures.load(.acquire) != 0) return false;
        scenario.io.sleep(.fromMilliseconds(1), .awake) catch return false;
    }
    return false;
}

fn run(scenario: *Scenario) Result {
    const io = scenario.io;
    assert(scenario.connections > 0);
    assert(scenario.done.len == scenario.connections);
    var server = scenario.address.listen(io, .{
        .kernel_backlog = kernel_backlog,
        .reuse_address = true,
        .mode = .stream,
        .protocol = .tcp,
    }) catch return .{ .echoes = 0, .window_ns = 1, .failures = 1 };
    defer server.deinit(io);

    scenario.address = server.socket.address;
    var accepting = io.concurrent(acceptor, .{ scenario, &server }) catch {
        return .{ .echoes = 0, .window_ns = 1, .failures = 1 };
    };
    var clients: Io.Group = .init;
    defer clients.cancel(io);

    var started: u32 = 0;
    while (started < scenario.connections) : (started += 1) {
        clients.concurrent(io, client, .{ scenario, started }) catch {
            fail(scenario);
            break;
        };
    }
    const window_ns: u64 = if (started == scenario.connections and connected_wait(scenario)) blk: {
        scenario.go.store(true, .release);
        const opened_ns = now_ns(io);
        io.sleep(.fromMilliseconds(window_ms), .awake) catch fail(scenario);
        scenario.stop.store(true, .release);
        break :blk now_ns(io) - opened_ns;
    } else blk: {
        fail(scenario);
        scenario.stop.store(true, .release);
        scenario.go.store(true, .release);
        break :blk 1;
    };
    clients.await(io) catch fail(scenario);
    accepting.await(io);

    var echoes: u64 = 0;
    for (scenario.done) |count| echoes += count;
    maybe(echoes == 0);
    const failures = scenario.failures.load(.acquire);
    return .{ .echoes = echoes, .window_ns = window_ns, .failures = failures };
}

fn measure(gpa: std.mem.Allocator, io: Io, connections: u32) !Result {
    const done = try gpa.alloc(u64, connections);
    defer gpa.free(done);

    @memset(done, 0);
    var scenario: Scenario = .{
        .io = io,
        .address = .{ .ip4 = .loopback(0) },
        .connections = connections,
        .done = done,
    };
    var future = io.async(run, .{&scenario});
    return future.await(io);
}

fn rate_per_s(result: Result) f64 {
    assert(result.window_ns > 0);
    const echoes: f64 = @floatFromInt(result.echoes);
    const seconds: f64 = @as(f64, @floatFromInt(result.window_ns)) / std.time.ns_per_s;
    return echoes / seconds;
}

fn nofile_raise(need: u64) error{NofileRefused}!void {
    var limit = posix.getrlimit(.NOFILE) catch return error.NofileRefused;
    if (limit.cur >= need) return;
    if (limit.max < need) return error.NofileRefused;
    limit.cur = need;
    posix.setrlimit(.NOFILE, limit) catch return error.NofileRefused;
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
    var rt = try Runtime.init(init.gpa, .{
        .backend = .auto,
        .unimplemented = .forward,
        .environ = init.minimal.environ,
        .argv0 = .empty,
        .fibers_max = fibers_max,
        .fiber_stack_size = fiber_stack_size,
        .offload_threads = 4,
        .sockets_max = fibers_max,
    });
    defer rt.deinit();

    try out.print("{s:<10} {s:>6} {s:>14} {s:>8}\n", .{ "io", "conns", "echoes/s", "failures" });
    var ratios: [2]f64 = undefined;
    for ([_]u32{ connections_one, connections_many }, 0..) |connections, row| {
        const baseline = try measure(init.gpa, rt.baselineIo(), connections);
        const native = try measure(init.gpa, rt.io(), connections);
        try out.print(
            "{s:<10} {d:>6} {d:>14.0} {d:>8}\n",
            .{ "threaded", connections, rate_per_s(baseline), baseline.failures },
        );
        try out.print(
            "{s:<10} {d:>6} {d:>14.0} {d:>8}\n",
            .{ @tagName(rt.backend), connections, rate_per_s(native), native.failures },
        );
        const clean = baseline.failures == 0 and native.failures == 0;
        ratios[row] = if (clean) rate_per_s(native) / rate_per_s(baseline) else 0;
    }
    try out.print("gate 2 (1 conn, >= {d:.1}x): {d:.2}x {s}\n", .{
        gate_one_ratio_min, ratios[0], if (ratios[0] >= gate_one_ratio_min) "pass" else "FAIL",
    });
    try out.print("gate 1 ({d} conns, >= {d:.1}x): {d:.2}x {s}\n", .{
        connections_many,                                         gate_many_ratio_min, ratios[1],
        if (ratios[1] >= gate_many_ratio_min) "pass" else "FAIL",
    });
}
