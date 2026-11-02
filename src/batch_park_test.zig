//! Tests for the parked batch wait (plan 005 item 5, ADR 0004 section 6): an idle batch of
//! `net_receive`s sits on the poller and the wheel, so between arming and the first event it makes
//! no `recvmsg` (the test-build counter `sys.recvmsg_calls` proves it), a cancel, a timeout and a
//! close each end the wait and give every waiter node back, and a batch that needs more nodes than
//! the pool holds goes whole to the baseline.
//!
//! Every scenario runs inside one fiber (`call_in_fiber`): `Future.await` on the test thread is
//! what turns the scheduler, so a scenario that sleeps or sends must do it from a fiber. The
//! scheduler has one carrier here, so the counter is not raced and a reading taken by a helper
//! fiber while the batch is parked is exact. Sockets are datagram sockets bound on loopback by the
//! scenario, so the registry knows them. The runtime picks its backend (`.auto`); `.threaded`
//! has no parked wait and skips.

const std = @import("std");
const Runtime = @import("runtime.zig");
const stdx = @import("stdx.zig");
const sys = @import("backend/sys.zig");
const Sched = @import("sched.zig");
const concurrency = @import("concurrency.zig");
const batch_park = @import("batch_park.zig");

const Io = std.Io;
const assert = stdx.assert;
const Address = Io.net.IpAddress;
const Socket = Io.net.Socket;

const receivers_max: u32 = 64;
const rounds_max: u32 = 1 << 16;
const idle_ms: i64 = 20;
const ns_per_ms: i96 = 1_000_000;

fn init_rt(batch_ops_max: u32) !Runtime {
    return Runtime.init(std.testing.allocator, .{
        .backend = .auto,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
        .carriers = 1,
        .fibers_max = 16,
        .batch_ops_max = batch_ops_max,
        .fiber_stack_size = 256 * 1024,
        .offload_threads = 2,
        .sockets_max = 160,
    });
}

/// What the scenarios report; the carrier is single, so plain fields are enough.
const Probe = struct {
    rt: *Runtime,
    /// `recvmsg` count when the await began, when the helper fiber acted, when the await returned.
    calls_start: u32,
    calls_event: u32,
    calls_end: u32,
    /// Free spare nodes while the batch was parked (read by the helper fiber), and at the end.
    free_parked: u32,
    free_end: u32,
    /// Slots with a linked waiter while parked, and at the end.
    linked_parked: u32,
    linked_end: u32,
    /// The first completion: its index, and whether it failed.
    index: u32,
    failed: bool,
    canceled: bool,
    later_ok: bool,
    timed_out: bool,
    waited_ns: i96,

    fn init(rt: *Runtime) Probe {
        return std.mem.zeroInit(Probe, .{ .rt = rt });
    }

    fn calls() u32 {
        return sys.recvmsg_calls.load(.monotonic);
    }

    fn look(probe: *Probe, parked: bool) void {
        const free = probe.rt.sched.waiters_free();
        const linked = linked_count(probe.rt);
        if (parked) {
            probe.free_parked = free;
            probe.linked_parked = linked;
        } else {
            probe.free_end = free;
            probe.linked_end = linked;
        }
    }
};

fn linked_count(rt: *Runtime) u32 {
    var linked: u32 = 0;
    for (rt.sockets.slots) |slot| {
        for (slot.waiters) |head| {
            if (head != null) linked += 1;
        }
    }
    return linked;
}

/// One sender, `count` receivers and the batch storage that serves them.
const Rig = struct {
    sender: Socket,
    receivers: [receivers_max]Socket,
    count: u32,
    closed_mask: u64,
    storage: [receivers_max]Io.Operation.Storage,
    messages: [receivers_max]Io.net.IncomingMessage,
    buffers: [receivers_max][16]u8,

    fn open(rig: *Rig, io: Io, count: u32) !void {
        assert(count >= 1);
        assert(count <= receivers_max);
        const any_port: Address = .{ .ip4 = .loopback(0) };
        rig.count = 0;
        rig.closed_mask = 0;
        rig.sender = try any_port.bind(io, .{ .mode = .dgram });
        errdefer rig.close(io);

        for (0..count) |_| {
            rig.receivers[rig.count] = try any_port.bind(io, .{ .mode = .dgram });
            rig.count += 1;
        }
    }

    fn close(rig: *Rig, io: Io) void {
        for (rig.receivers[0..rig.count], 0..) |receiver, index| {
            const bit = @as(u64, 1) << @intCast(index);
            if (rig.closed_mask & bit == 0) receiver.close(io);
        }
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
    fn send_to(rig: *Rig, io: Io, i: u32) void {
        const byte = [1]u8{@intCast(i)};
        rig.sender.send(io, &rig.receivers[i].address, &byte) catch return;
    }

    fn close_one(rig: *Rig, io: Io, i: u32) void {
        rig.closed_mask |= @as(u64, 1) << @intCast(i);
        rig.receivers[i].close(io);
    }
};

/// Takes the first completion into the probe; the datagram of op `i` holds the byte `i`.
fn take_first(rig: *Rig, batch: *Io.Batch, probe: *Probe) void {
    const done = batch.next().?;
    const failure, const count = done.result.net_receive;
    probe.index = done.index;
    probe.failed = failure != null or count != 1;
    if (!probe.failed) assert(rig.messages[done.index].data[0] == done.index);
}

fn send_after(io: Io, rig: *Rig, probe: *Probe, target: u32, delay_ms: i64) void {
    io.sleep(.fromMilliseconds(delay_ms), .awake) catch return;
    probe.calls_event = Probe.calls();
    probe.look(true);
    rig.send_to(io, target);
}

fn close_after(io: Io, rig: *Rig, probe: *Probe, target: u32, delay_ms: i64) void {
    io.sleep(.fromMilliseconds(delay_ms), .awake) catch return;
    probe.calls_event = Probe.calls();
    probe.look(true);
    rig.close_one(io, target);
}

fn call_in_fiber(io: Io, comptime call: anytype, args: anytype) !void {
    var future = io.async(call, .{io} ++ args);
    return future.await(io);
}

fn runtime_ready(rt: *Runtime) !void {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    if (rt.backend == .threaded) return error.SkipZigTest;
}

// ---------------------------------------------------------------- idle: no syscall

fn scenario_idle(io: Io, probe: *Probe) !void {
    const target: u32 = 37;
    var rig: Rig = undefined;
    try rig.open(io, receivers_max);
    defer rig.close(io);

    var batch = Io.Batch.init(rig.storage[0..rig.count]);
    defer batch.cancel(io);

    rig.arm_all(&batch);
    var sending = io.async(send_after, .{ io, &rig, probe, target, idle_ms });
    defer sending.cancel(io);

    probe.calls_start = Probe.calls();
    try batch.awaitConcurrent(io, .none);
    probe.calls_end = Probe.calls();
    probe.look(false);
    take_first(&rig, &batch, probe);
    assert(batch.next() == null);
}

test "an idle batch of 64 sockets makes no recvmsg between arming and the first event" {
    var rt = try init_rt(receivers_max);
    defer rt.deinit();

    try runtime_ready(&rt);
    var probe: Probe = .init(&rt);
    try call_in_fiber(rt.io(), scenario_idle, .{&probe});
    // One sweep of the 64 operations at entry, then nothing while 20 ms passed.
    try std.testing.expectEqual(receivers_max, probe.calls_event - probe.calls_start);
    // The event wakes the batch; only the operation it named is read again.
    try std.testing.expectEqual(@as(u32, 1), probe.calls_end - probe.calls_event);
    try std.testing.expectEqual(@as(u32, 37), probe.index);
    try std.testing.expect(!probe.failed);
    // Own node plus 63 spares were out while parked, all back after.
    try std.testing.expectEqual(@as(u32, 1), probe.free_parked);
    try std.testing.expectEqual(receivers_max, probe.linked_parked);
    try std.testing.expectEqual(receivers_max, probe.free_end);
    try std.testing.expectEqual(@as(u32, 0), probe.linked_end);
    try std.testing.expect(!rt.sched.armed_any());
}

// ---------------------------------------------------------------- cancel

fn wait_forever(io: Io, rig: *Rig) bool {
    var batch = Io.Batch.init(rig.storage[0..rig.count]);
    defer batch.cancel(io);

    rig.arm_all(&batch);
    batch.awaitConcurrent(io, .none) catch |err| switch (err) {
        error.Canceled => return true,
        error.Timeout, error.ConcurrencyUnavailable => return false,
    };
    return false;
}

fn scenario_cancel(io: Io, probe: *Probe) !void {
    var rig: Rig = undefined;
    try rig.open(io, receivers_max);
    defer rig.close(io);

    // The safety net: a wait that is not interrupted sees a datagram instead of hanging.
    var sending = io.async(send_after, .{ io, &rig, probe, 0, 400 });
    defer sending.cancel(io);

    var waiting = io.async(wait_forever, .{ io, &rig });
    try io.sleep(.fromMilliseconds(5), .awake);
    probe.look(true);
    probe.canceled = waiting.cancel(io);
    probe.look(false);
}

test "a cancel of a parked batch returns Canceled and gives every node back" {
    var rt = try init_rt(receivers_max);
    defer rt.deinit();

    try runtime_ready(&rt);
    var probe: Probe = .init(&rt);
    try call_in_fiber(rt.io(), scenario_cancel, .{&probe});
    try std.testing.expectEqual(@as(u32, 1), probe.free_parked);
    try std.testing.expectEqual(receivers_max, probe.linked_parked);
    try std.testing.expect(probe.canceled);
    try std.testing.expectEqual(receivers_max, probe.free_end);
    try std.testing.expectEqual(@as(u32, 0), probe.linked_end);
    try std.testing.expect(!rt.sched.armed_any());
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

// ---------------------------------------------------------------- close

fn scenario_close(io: Io, probe: *Probe) !void {
    const closed_index: u32 = 5;
    const later_index: u32 = 7;
    var rig: Rig = undefined;
    try rig.open(io, receivers_max);
    defer rig.close(io);

    var batch = Io.Batch.init(rig.storage[0..rig.count]);
    defer batch.cancel(io);

    rig.arm_all(&batch);
    var closing = io.async(close_after, .{ io, &rig, probe, closed_index, idle_ms });
    defer closing.cancel(io);

    try batch.awaitConcurrent(io, .none);
    probe.calls_end = Probe.calls();
    probe.look(false);
    take_first(&rig, &batch, probe);
    // The 63 others are still armed: a datagram to one of them completes it.
    rig.send_to(io, later_index);
    try batch.awaitConcurrent(io, .none);
    const done = batch.next().?;
    probe.later_ok = done.index == later_index and done.result.net_receive[0] == null;
}

test "a socket closed while the batch idles completes with SocketUnconnected" {
    var rt = try init_rt(receivers_max);
    defer rt.deinit();

    try runtime_ready(&rt);
    var probe: Probe = .init(&rt);
    try call_in_fiber(rt.io(), scenario_close, .{&probe});
    try std.testing.expectEqual(@as(u32, 5), probe.index);
    try std.testing.expect(probe.failed);
    // The close wakes the batch and the closed operation is not read: no recvmsg after it.
    try std.testing.expectEqual(probe.calls_event, probe.calls_end);
    try std.testing.expectEqual(receivers_max, probe.free_end);
    try std.testing.expectEqual(@as(u32, 0), probe.linked_end);
    try std.testing.expect(probe.later_ok);
    try std.testing.expect(!rt.sched.armed_any());
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

// ---------------------------------------------------------------- timeout

fn scenario_timeout(io: Io, probe: *Probe) !void {
    var rig: Rig = undefined;
    try rig.open(io, receivers_max);
    defer rig.close(io);

    var batch = Io.Batch.init(rig.storage[0..rig.count]);
    defer batch.cancel(io);

    rig.arm_all(&batch);
    const started = Io.Clock.awake.now(io);
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } };
    probe.calls_start = Probe.calls();
    if (batch.awaitConcurrent(io, timeout)) |_| {} else |err| switch (err) {
        error.Timeout => probe.timed_out = true,
        error.Canceled, error.ConcurrencyUnavailable => return err,
    }
    probe.calls_end = Probe.calls();
    probe.waited_ns = started.durationTo(Io.Clock.awake.now(io)).nanoseconds;
    probe.look(false);
    // The operations stay armed after a timeout: a datagram now completes one.
    rig.send_to(io, 3);
    try batch.awaitConcurrent(io, .none);
    take_first(&rig, &batch, probe);
}

test "a timeout returns Timeout after the deadline and gives every node back" {
    var rt = try init_rt(receivers_max);
    defer rt.deinit();

    try runtime_ready(&rt);
    var probe: Probe = .init(&rt);
    try call_in_fiber(rt.io(), scenario_timeout, .{&probe});
    try std.testing.expect(probe.timed_out);
    try std.testing.expect(probe.waited_ns >= 10 * ns_per_ms);
    // The entry sweep only: 10 ms of idle added no read.
    try std.testing.expectEqual(receivers_max, probe.calls_end - probe.calls_start);
    try std.testing.expectEqual(receivers_max, probe.free_end);
    try std.testing.expectEqual(@as(u32, 0), probe.linked_end);
    try std.testing.expectEqual(@as(u32, 3), probe.index);
    try std.testing.expect(!probe.failed);
    try std.testing.expect(!rt.sched.armed_any());
}

// ---------------------------------------------------------------- too few nodes

fn scenario_many(io: Io, probe: *Probe) !void {
    const count: u32 = 8;
    var rig: Rig = undefined;
    try rig.open(io, count);
    defer rig.close(io);

    var batch = Io.Batch.init(rig.storage[0..rig.count]);
    defer batch.cancel(io);

    rig.arm_all(&batch);
    for (0..count) |i| rig.send_to(io, @intCast(i));
    // The first await sees 8 operations for 5 nodes. Once completions shrink the batch to what the
    // pool serves, later awaits are native, so only the first is measured for the baseline.
    probe.calls_start = Probe.calls();
    var mask: u64 = 0;
    for (0..rounds_max) |round| {
        if (@popCount(mask) >= count) break;
        try batch.awaitAsync(io);
        if (round == 0) probe.calls_end = Probe.calls();
        while (batch.next()) |done| {
            const failure, const received = done.result.net_receive;
            if (failure == null and received == 1) mask |= @as(u64, 1) << @intCast(done.index);
        }
    }
    probe.index = @popCount(mask);
    probe.look(false);
}

test "a batch that needs more nodes than the pool holds goes whole to the baseline" {
    // Own node plus 4 spares serve 5 operations; the batch has 8.
    var rt = try init_rt(4);
    defer rt.deinit();

    try runtime_ready(&rt);
    var probe: Probe = .init(&rt);
    try call_in_fiber(rt.io(), scenario_many, .{&probe});
    try std.testing.expectEqual(@as(u32, 8), probe.index);
    // The baseline reads with its own syscalls: sirocco's `recvmsg` was never called.
    try std.testing.expectEqual(probe.calls_start, probe.calls_end);
    try std.testing.expectEqual(@as(u32, 4), probe.free_end);
    try std.testing.expectEqual(@as(u32, 0), probe.linked_end);
}

// ---------------------------------------------------------------- pool short during the wait

const spares_max: u32 = 4;

/// Spare nodes the test holds so that the pool is short when the wait starts.
const Hoard = struct {
    nodes: [spares_max]*Sched.Waiter,
    count: u32,

    fn take_all(hoard: *Hoard, sched: *Sched) void {
        hoard.count = 0;
        for (0..spares_max) |_| {
            const node = sched.waiter_acquire() orelse break;
            hoard.nodes[hoard.count] = node;
            hoard.count += 1;
        }
        assert(hoard.count == spares_max);
        assert(sched.waiters_free() == 0);
    }

    fn give_back(hoard: *Hoard, sched: *Sched) void {
        assert(hoard.count == spares_max);
        for (hoard.nodes[0..hoard.count]) |node| sched.waiter_release(node);
        hoard.count = 0;
    }
};

/// While the waiter naps on a short pool: reads the counter, gives the nodes back, lets the wait
/// park on them, reads the pool, then sends the datagram that completes the wait.
fn restock_then_send(io: Io, rig: *Rig, probe: *Probe, hoard: *Hoard, target: u32) void {
    io.sleep(.fromMilliseconds(idle_ms), .awake) catch return;
    probe.calls_event = Probe.calls();
    hoard.give_back(&probe.rt.sched);
    io.sleep(.fromMilliseconds(idle_ms), .awake) catch return;
    probe.look(true);
    rig.send_to(io, target);
}

fn scenario_pool_short(io: Io, probe: *Probe) !void {
    const target: u32 = 1;
    const count: u32 = 3; // The fiber's own node and two spares.
    var rig: Rig = undefined;
    try rig.open(io, count);
    defer rig.close(io);

    var batch = Io.Batch.init(rig.storage[0..rig.count]);
    defer batch.cancel(io);

    rig.arm_all(&batch);
    var hoard: Hoard = undefined;
    hoard.take_all(&probe.rt.sched);
    var restocking = io.async(restock_then_send, .{ io, &rig, probe, &hoard, target });
    defer restocking.cancel(io);

    // `served_task` would send this batch to the baseline, so the parked wait is called directly:
    // the pool is short at the start of its first round, as when another batch fiber took the
    // spares since the await began.
    const task = concurrency.current_task(probe.rt).?;
    probe.calls_start = Probe.calls();
    try batch_park.wait(probe.rt, task, &batch, .none);
    probe.calls_end = Probe.calls();
    probe.look(false);
    take_first(&rig, &batch, probe);
    assert(batch.next() == null);
}

test "a wait that finds the node pool short naps and sweeps, then parks once nodes return" {
    var rt = try init_rt(spares_max);
    defer rt.deinit();

    try runtime_ready(&rt);
    var probe: Probe = .init(&rt);
    try call_in_fiber(rt.io(), scenario_pool_short, .{&probe});
    // The entry sweep reads 3 sockets; the naps of the 20 ms that follow read them again.
    try std.testing.expect(probe.calls_event - probe.calls_start > 3);
    // After the restock the wait parked: own node and two spares out, three nodes linked.
    try std.testing.expectEqual(spares_max - 2, probe.free_parked);
    try std.testing.expectEqual(@as(u32, 3), probe.linked_parked);
    try std.testing.expectEqual(@as(u32, 1), probe.index);
    try std.testing.expect(!probe.failed);
    try std.testing.expectEqual(spares_max, probe.free_end);
    try std.testing.expectEqual(@as(u32, 0), probe.linked_end);
    try std.testing.expect(!rt.sched.armed_any());
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}
