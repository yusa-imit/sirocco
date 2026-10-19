//! Batch tests (plan 004 item 8, ADR 0003 section 2c): `batchAwaitAsync`, `batchAwaitConcurrent`
//! and `batchCancel` serve a batch of `net_receive`s on registered sockets natively on the
//! evented backends: the fiber waits in short wheel slices instead of holding the carrier in
//! `poll(2)`, so other fibers (and a cancel) run while the batch idles.
//!
//! Parity scenarios build their own sockets from the `Io` they are given and return a value with
//! no pointers, so `harness.expectSameResultInFiber` compares `rt.io()` in a fiber with
//! `rt.baselineIo()`. A scenario that idles on the batch needs a second fiber to make progress,
//! so it skips on `.threaded`, where tasks run inline and nothing could ever wake it.
//!
//! Oracle caveat (Zig 0.16.0): `Io.Threaded.batchAwaitConcurrent` leaves a `net_receive` that was
//! ready on entry on the `submitted` list after completing it, so a later await or `Batch.cancel`
//! trips over it. A comparison against the baseline therefore awaits with `awaitAsync`, or with
//! `awaitConcurrent` only on operations that are idle at entry; the concurrent form with data
//! ready at entry is asserted on `rt.io()` alone.

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");

const fibers_supported = Runtime.fibers_supported;
const evented = fixtures.backend != .threaded;

const Address = Io.net.IpAddress;
const Socket = Io.net.Socket;

const receivers_max: u32 = 64;
const rounds_max: u32 = 1 << 16;

fn init_rt() !Runtime {
    return fixtures.init_runtime_sockets(std.testing.allocator, .forward, 16, 2, 160);
}

/// The slots must be sirocco's own wherever fibers exist; fails fast instead of hanging a test
/// that would idle on the baseline's blocking `poll`.
fn expect_native(rt: *Runtime) !void {
    if (!fibers_supported) return error.SkipZigTest;
    const native = rt.io().vtable;
    const baseline = rt.baselineIo().vtable;
    try std.testing.expect(native.batchAwaitAsync != baseline.batchAwaitAsync);
    try std.testing.expect(native.batchAwaitConcurrent != baseline.batchAwaitConcurrent);
    try std.testing.expect(native.batchCancel != baseline.batchCancel);
}

/// One sender, up to `receivers_max` receivers and the batch storage that serves them.
const Rig = struct {
    sender: Socket,
    receivers: [receivers_max]Socket,
    count: u32,
    storage: [receivers_max]Io.Operation.Storage,
    messages: [receivers_max]Io.net.IncomingMessage,
    buffers: [receivers_max][16]u8,

    fn open(rig: *Rig, io: Io, count: u32) !void {
        std.debug.assert(count >= 1 and count <= receivers_max);
        const any_port: Address = .{ .ip4 = .loopback(0) };
        rig.count = 0;
        rig.sender = try any_port.bind(io, .{ .mode = .dgram });
        errdefer rig.close(io);

        for (0..count) |_| {
            rig.receivers[rig.count] = try any_port.bind(io, .{ .mode = .dgram });
            rig.count += 1;
        }
    }

    fn close(rig: *Rig, io: Io) void {
        for (rig.receivers[0..rig.count]) |receiver| receiver.close(io);
        rig.sender.close(io);
    }

    fn arm_all(rig: *Rig, batch: *Io.Batch) void {
        for (0..rig.count) |i| {
            rig.messages[i] = .init;
            batch.addAt(@intCast(i), .{ .net_receive = .{
                .socket_handle = rig.receivers[i].handle,
                .message_buffer = rig.messages[i..][0..1],
                .data_buffer = &rig.buffers[i],
                .flags = .{},
            } });
        }
    }

    /// Datagram `i` holds the single byte `i`.
    fn send_all(rig: *Rig, io: Io) void {
        for (0..rig.count) |i| {
            const byte = [1]u8{@intCast(i)};
            rig.sender.send(io, &rig.receivers[i].address, &byte) catch return;
        }
    }
};

const Tally = struct { mask: u64, ok: u32, failed: u32 };

const Mode = enum { concurrent, async };

fn collect(rig: *Rig, batch: *Io.Batch, tally: *Tally) void {
    while (batch.next()) |done| {
        const failure, const count = done.result.net_receive;
        if (failure != null or count != 1) {
            tally.failed += 1;
            continue;
        }
        const i = done.index;
        tally.mask |= @as(u64, 1) << @intCast(i);
        const message = rig.messages[i];
        if (message.data.len == 1 and message.data[0] == i) tally.ok += 1;
    }
}

fn await_all(io: Io, rig: *Rig, batch: *Io.Batch, mode: Mode, timeout: Io.Timeout) !Tally {
    var tally: Tally = .{ .mask = 0, .ok = 0, .failed = 0 };
    for (0..rounds_max) |_| {
        if (@popCount(tally.mask) + tally.failed >= rig.count) return tally;
        switch (mode) {
            .concurrent => try batch.awaitConcurrent(io, timeout),
            .async => try batch.awaitAsync(io),
        }
        collect(rig, batch, &tally);
    }
    return error.TestUnexpectedResult;
}

fn await_ready(io: Io, rig: *Rig, mode: Mode) !Tally {
    var batch = Io.Batch.init(rig.storage[0..rig.count]);
    defer batch.cancel(io);

    rig.arm_all(&batch);
    return await_all(io, rig, &batch, mode, .none);
}

// ---------------------------------------------------------------- (1) the completion set

fn scenario_ready(io: Io, count: u32, mode: Mode) !Tally {
    var rig: Rig = undefined;
    try rig.open(io, count);
    defer rig.close(io);

    var batch = Io.Batch.init(rig.storage[0..count]);
    defer batch.cancel(io);

    rig.arm_all(&batch);
    rig.send_all(io);
    return await_all(io, &rig, &batch, mode, .none);
}

test "64 sockets with data ready complete as the baseline" {
    var rt = try init_rt();
    defer rt.deinit();

    try expect_native(&rt);
    const args = .{ receivers_max, Mode.async };
    try harness.expectSameResultInFiber(&rt, scenario_ready, args);
    const got = try harness.call_in_fiber(rt.io(), scenario_ready, args);
    try std.testing.expectEqual(~@as(u64, 0), got.mask);
    try std.testing.expectEqual(receivers_max, got.ok);
    try std.testing.expectEqual(@as(u32, 0), got.failed);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

test "64 sockets with data ready complete through awaitConcurrent on rt.io()" {
    if (!fibers_supported or !evented) return error.SkipZigTest; // The oracle is unsound here.
    var rt = try init_rt();
    defer rt.deinit();

    try expect_native(&rt);
    const args = .{ receivers_max, Mode.concurrent };
    const got = try harness.call_in_fiber(rt.io(), scenario_ready, args);
    try std.testing.expectEqual(~@as(u64, 0), got.mask);
    try std.testing.expectEqual(receivers_max, got.ok);
}

fn send_all_later(io: Io, rig: *Rig, delay_ms: i64) void {
    io.sleep(.fromMilliseconds(delay_ms), .awake) catch return;
    rig.send_all(io);
}

fn scenario_late(io: Io, mode: Mode) !Tally {
    var rig: Rig = undefined;
    try rig.open(io, receivers_max);
    defer rig.close(io);

    var sending = io.async(send_all_later, .{ io, &rig, @as(i64, 20) });
    defer sending.cancel(io);

    return await_ready(io, &rig, mode);
}

fn scenario_first(io: Io) !bool {
    var rig: Rig = undefined;
    try rig.open(io, receivers_max);
    defer rig.close(io);

    var sending = io.async(send_all_later, .{ io, &rig, @as(i64, 20) });
    defer sending.cancel(io);

    var batch = Io.Batch.init(rig.storage[0..rig.count]);
    defer batch.cancel(io);

    rig.arm_all(&batch);
    try batch.awaitConcurrent(io, .none);
    var tally: Tally = .{ .mask = 0, .ok = 0, .failed = 0 };
    collect(&rig, &batch, &tally);
    return tally.ok >= 1 and tally.failed == 0;
}

test "64 idle sockets wake the batch when their datagrams arrive later, as the baseline" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try expect_native(&rt);
    try harness.expectSameResultInFiber(&rt, scenario_late, .{Mode.async});
    try harness.expectSameResultInFiber(&rt, scenario_first, .{});
    const io = rt.io();
    for ([_]Mode{ .concurrent, .async }) |mode| {
        const got = try harness.call_in_fiber(io, scenario_late, .{mode});
        try std.testing.expectEqual(~@as(u64, 0), got.mask);
        try std.testing.expectEqual(receivers_max, got.ok);
    }
    try std.testing.expect(try harness.call_in_fiber(io, scenario_first, .{}));
    try std.testing.expect(!rt.sched.armed_any());
}

test "sockets the registry does not know are served by the baseline for the whole batch" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try expect_native(&rt);
    const base = rt.baselineIo();
    var rig: Rig = undefined;
    try rig.open(base, 4);
    defer rig.close(base);

    rig.send_all(base);
    const io = rt.io();
    var future = io.async(await_ready, .{ io, &rig, Mode.async });
    const got = try future.await(io);
    try std.testing.expectEqual(@as(u64, 0b1111), got.mask);
    try std.testing.expectEqual(@as(u32, 4), got.ok);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

// ---------------------------------------------------------------- (2) timeout

const Idle = struct { timed_out: bool, waited: bool, later_ok: bool };

fn scenario_idle(io: Io) !Idle {
    var rig: Rig = undefined;
    try rig.open(io, 1);
    defer rig.close(io);

    var batch = Io.Batch.init(rig.storage[0..1]);
    defer batch.cancel(io);

    rig.arm_all(&batch);
    const started = Io.Clock.awake.now(io);
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } };
    var out: Idle = .{ .timed_out = false, .waited = false, .later_ok = false };
    if (batch.awaitConcurrent(io, timeout)) |_| {} else |err| switch (err) {
        error.Timeout => out.timed_out = true,
        error.Canceled, error.ConcurrencyUnavailable => return err,
    }
    const waited = started.durationTo(Io.Clock.awake.now(io));
    out.waited = waited.nanoseconds >= 10 * std.time.ns_per_ms;
    // The op is still armed after a timeout: a datagram now completes it.
    rig.send_all(io);
    const tally = try await_all(io, &rig, &batch, .async, .none);
    out.later_ok = tally.ok == 1;
    return out;
}

test "10 ms of idle ends in Timeout after at least 10 ms and leaves the op armed" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try expect_native(&rt);
    try harness.expectSameResultInFiber(&rt, scenario_idle, .{});
    const got = try harness.call_in_fiber(rt.io(), scenario_idle, .{});
    try std.testing.expect(got.timed_out);
    try std.testing.expect(got.waited);
    try std.testing.expect(got.later_ok);
}

// ---------------------------------------------------------------- (3) cancel

fn wait_forever(io: Io, rig: *Rig) bool {
    var batch = Io.Batch.init(rig.storage[0..1]);
    defer batch.cancel(io);

    rig.arm_all(&batch);
    batch.awaitConcurrent(io, .none) catch |err| switch (err) {
        error.Canceled => return true,
        error.Timeout, error.ConcurrencyUnavailable => return false,
    };
    return false;
}

fn scenario_cancel(io: Io) !bool {
    var rig: Rig = undefined;
    try rig.open(io, 1);
    defer rig.close(io);

    // The safety net: a wait that is not interrupted sees a datagram instead of hanging.
    var sending = io.async(send_all_later, .{ io, &rig, @as(i64, 400) });
    defer sending.cancel(io);

    var waiting = io.async(wait_forever, .{ io, &rig });
    io.sleep(.fromMilliseconds(5), .awake) catch {};
    return waiting.cancel(io);
}

test "a cancel in the middle of a batch wait ends it with Canceled, as the baseline" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try expect_native(&rt);
    try harness.expectSameResultInFiber(&rt, scenario_cancel, .{});
    try std.testing.expect(try harness.call_in_fiber(rt.io(), scenario_cancel, .{}));
    try std.testing.expect(!rt.sched.armed_any());
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

// ---------------------------------------------------------------- (4) no allocation

/// Allocations the batch calls made: `io.async` and sockets are measured outside the window.
fn scenario_flat(io: Io, counting: *std.testing.FailingAllocator) !usize {
    var rig: Rig = undefined;
    try rig.open(io, receivers_max);
    defer rig.close(io);

    var batch = Io.Batch.init(rig.storage[0..rig.count]);
    rig.arm_all(&batch);
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(3), .clock = .awake } };
    const before = counting.alloc_index;
    if (batch.awaitConcurrent(io, timeout)) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.Timeout => {},
        error.Canceled, error.ConcurrencyUnavailable => return err,
    }
    rig.send_all(io);
    var tally: Tally = .{ .mask = 0, .ok = 0, .failed = 0 };
    for (0..rounds_max) |_| {
        if (@popCount(tally.mask) >= rig.count) break;
        try batch.awaitAsync(io);
        collect(&rig, &batch, &tally);
    }
    batch.cancel(io);
    const delta = counting.alloc_index - before;
    if (tally.ok != receivers_max) return error.TestUnexpectedResult;
    return delta;
}

test "batch waits allocate nothing after init" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var rt = try fixtures.init_runtime_sockets(counting.allocator(), .forward, 16, 2, 160);
    defer rt.deinit();

    try expect_native(&rt);
    const io = rt.io();
    const delta = try harness.call_in_fiber(io, scenario_flat, .{&counting});
    try std.testing.expectEqual(@as(usize, 0), delta);
}
