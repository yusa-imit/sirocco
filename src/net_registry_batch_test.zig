//! Tests for the batch plumbing of `net_registry.zig` (ADR 0004 section 6, plan 005 item 5):
//! one fiber holding several `Sched.Waiter` nodes, the claim on `wait.outcome`, `batch_enter`,
//! `leave`, the spare-node pool and the claim in `sleep.fire`.
//!
//! Most tests stage the fibers by hand (`running` to enter, `parked` to be woken) and read the
//! ready queue to learn who was woken, as `net_registry_test.zig` does. Events are delivered
//! through the real poller (`deliver`) where the one-shot registration matters. The close on the
//! carrier needs a fiber to call it, so that test runs real fibers.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const poller = @import("backend/poller.zig");
const sched_io = @import("sched_io.zig");
const sleep = @import("sleep.zig");
const sys = @import("backend/sys.zig");
const net_registry = @import("net_registry.zig");

const Registry = net_registry.Registry;
const Waiter = Sched.Waiter;
const Fiber = Sched.Fiber;
const WaitOutcome = Sched.WaitOutcome;
const posix = std.posix;
const system = posix.system;
const assert = stdx.assert;

const supported = Sched.supported and poller.Native != void;
const pairs_count = 3;
// Two wheel ticks (2^17 ns each) before the wheel's start: due at once, however fast the test runs.
const past_ns: u64 = 2 << 17;

const Fixture = struct {
    sched: Sched,
    registry: Registry,
    /// `pairs[k][0]` is socket `k` (the one the tests register), `pairs[k][1]` its peer.
    pairs: [pairs_count][2]sys.fd_t,
    now_ns: u64,

    fn init(fixture: *Fixture, registrations_max: u32) !void {
        fixture.now_ns = @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds);
        const options: Sched.Options = .{
            .fibers_max = 4,
            .batch_ops_max = 4,
            .stack_size = 64 * 1024,
            .now_ns = fixture.now_ns,
            .idle = .{ .poller = .{ .registrations_max = registrations_max } },
        };
        try fixture.sched.init(std.testing.allocator, options);
        errdefer fixture.sched.deinit(std.testing.allocator);

        try fixture.registry.init(std.testing.allocator, pairs_count);
        errdefer fixture.registry.deinit(std.testing.allocator);

        for (&fixture.pairs) |*pair| {
            pair.* = try sys.socket_pair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        }
        fixture.sched.events = .{ .ctx = &fixture.registry, .ready = net_registry.on_event };
    }

    fn deinit(fixture: *Fixture) void {
        for (fixture.pairs) |pair| {
            sched_io.disarm(&fixture.sched, pair[0], .read);
            sched_io.disarm(&fixture.sched, pair[0], .write);
            sys.close(pair[0]);
            sys.close(pair[1]);
        }
        fixture.registry.deinit(std.testing.allocator);
        // Fibers staged by hand were never spawned: forget their states before the checks.
        fixture.sched.live_count = 0;
        fixture.sched.parked_count = 0;
        fixture.sched.inbox = null;
        fixture.sched.deinit(std.testing.allocator);
    }

    fn sock(fixture: *const Fixture, index: usize) sys.fd_t {
        return fixture.pairs[index][0];
    }

    /// Registers sockets `0..count` and returns their slot indices.
    fn register(fixture: *Fixture, comptime count: usize) ![count]u32 {
        var slots: [count]u32 = undefined;
        for (&slots, 0..) |*slot, index| {
            slot.* = try fixture.registry.register(fixture.sock(index));
        }
        return slots;
    }

    /// Fiber `index` as a batch caller sets it up before its first `batch_enter`.
    fn start(fixture: *Fixture, index: usize) *Fiber {
        const fiber = &fixture.sched.fibers[index];
        fiber.state = .running;
        fiber.wait = .{
            .addr = 0,
            .prev = null,
            .next = null,
            .sleeping = false,
            .outcome = .waiting,
            .socket = .batch,
        };
        return fiber;
    }

    /// A node of `fiber`: its own for `first`, else a spare from the pool.
    fn node_of(fixture: *Fixture, fiber: *Fiber, first: bool) *Waiter {
        if (first) return fixture.sched.waiter_of(fiber);
        const node = fixture.sched.waiter_acquire().?;
        node.fiber = fiber;
        return node;
    }

    fn enter(fixture: *Fixture, node: *Waiter, index: usize, interest: poller.Interest) !void {
        const entered = fixture.registry.batch_enter(
            &fixture.sched,
            fixture.sock(index),
            interest,
            node,
        );
        try std.testing.expectEqual(net_registry.Enter.parked, entered);
    }

    /// `leave` as the resumed fiber runs it; the fibers here are staged, so mark it resumed.
    fn leave(fixture: *Fixture, node: *Waiter) Waiter.Outcome {
        node.fiber.state = .running;
        return fixture.registry.leave(&fixture.sched, node);
    }

    fn park(fixture: *Fixture, fiber: *Fiber) void {
        assert(fiber.state == .running);
        fiber.state = .parked;
        fixture.sched.live_count += 1;
        fixture.sched.parked_count += 1;
    }

    /// Makes socket `index` readable and lets the poller deliver it to `on_event`.
    fn deliver(fixture: *Fixture, index: usize) void {
        const byte = [1]u8{0x5a};
        assert(system.write(fixture.pairs[index][1], &byte, 1) == 1);
        sched_io.poll_fair(&fixture.sched);
    }

    fn event(fixture: *Fixture, slot: u32) void {
        const ready: poller.Event = .{ .token = slot, .interest = .read, .hangup = false };
        net_registry.on_event(&fixture.registry, &fixture.sched, ready);
    }

    fn armed_count(fixture: *const Fixture) u32 {
        if (comptime poller.Native == void) return 0;
        return fixture.sched.idle.poller.table.count;
    }

    fn ready_count(fixture: *const Fixture) usize {
        var len: usize = 0;
        var next = fixture.sched.ready_head;
        while (next) |fiber| : (next = fiber.queue_next) len += 1;
        return len;
    }
};

fn expect_detached(node: *const Waiter) !void {
    try std.testing.expect(node.prev == null);
    try std.testing.expect(node.next == null);
}

test "batch: an event readies its node and claims the fiber; leave unlinks and disarms the rest" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(8);
    defer fixture.deinit();

    const slots = try fixture.register(3);
    const fiber = fixture.start(0);
    var nodes: [3]*Waiter = undefined;
    for (&nodes, 0..) |*node, index| {
        node.* = fixture.node_of(fiber, index == 0);
        try fixture.enter(node.*, index, .read);
    }
    fixture.park(fiber);
    try std.testing.expectEqual(@as(u32, 3), fixture.armed_count());
    try std.testing.expectEqual(@as(u32, 2), fixture.sched.waiters_free());

    fixture.deliver(1);
    try std.testing.expectEqual(Waiter.Outcome.ready, nodes[1].outcome);
    try expect_detached(nodes[1]);
    try std.testing.expectEqual(Waiter.Outcome.waiting, nodes[0].outcome);
    try std.testing.expectEqual(Waiter.Outcome.waiting, nodes[2].outcome);
    try std.testing.expect(fixture.registry.slots[slots[0]].waiters[0] == nodes[0]);
    try std.testing.expectEqual(WaitOutcome.woken, fiber.wait.outcome);
    try std.testing.expectEqual(@as(usize, 1), fixture.ready_count());
    try std.testing.expectEqual(@as(u32, 2), fixture.armed_count()); // One-shot: socket 1 is gone.

    const expected = [3]Waiter.Outcome{ .idle, .ready, .idle };
    for (nodes, expected) |node, outcome| {
        try std.testing.expectEqual(outcome, fixture.leave(node));
        try expect_detached(node);
    }
    try std.testing.expectEqual(@as(u32, 0), fixture.armed_count());
    for (slots) |slot| try std.testing.expect(fixture.registry.slots[slot].waiters[0] == null);
    fixture.sched.waiter_release(nodes[1]);
    fixture.sched.waiter_release(nodes[2]);
    try std.testing.expectEqual(@as(u32, 4), fixture.sched.waiters_free());
}

test "batch: a second event after the claim marks its node ready and does not unpark again" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(8);
    defer fixture.deinit();

    const slots = try fixture.register(2);
    const fiber = fixture.start(0);
    const first = fixture.node_of(fiber, true);
    const second = fixture.node_of(fiber, false);
    try fixture.enter(first, 0, .read);
    try fixture.enter(second, 1, .read);
    fixture.park(fiber);

    fixture.event(slots[0]);
    try std.testing.expectEqual(WaitOutcome.woken, fiber.wait.outcome);
    try std.testing.expectEqual(@as(usize, 1), fixture.ready_count());
    fixture.event(slots[1]); // The claim is lost; `unpark` would assert on a ready fiber.
    try std.testing.expectEqual(@as(usize, 1), fixture.ready_count());
    try std.testing.expectEqual(WaitOutcome.woken, fiber.wait.outcome);
    for ([_]*Waiter{ first, second }) |node| {
        try std.testing.expectEqual(Waiter.Outcome.ready, node.outcome);
        try expect_detached(node);
        try std.testing.expectEqual(Waiter.Outcome.ready, fixture.leave(node));
    }
    fixture.sched.waiter_release(second);
}

test "batch: cancel claims the fiber and leaves its nodes linked until leave" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(8);
    defer fixture.deinit();

    const slots = try fixture.register(2);
    const fiber = fixture.start(0);
    const first = fixture.node_of(fiber, true);
    const second = fixture.node_of(fiber, false);
    try fixture.enter(first, 0, .read);
    try fixture.enter(second, 1, .read);
    fixture.park(fiber);

    fixture.registry.cancel(&fixture.sched, fiber);
    try std.testing.expectEqual(WaitOutcome.canceled, fiber.wait.outcome);
    try std.testing.expectEqual(@as(usize, 1), fixture.ready_count());
    try std.testing.expect(fixture.registry.slots[slots[0]].waiters[0] == first);
    try std.testing.expect(fixture.registry.slots[slots[1]].waiters[0] == second);
    try std.testing.expectEqual(@as(u32, 2), fixture.armed_count());
    fixture.registry.cancel(&fixture.sched, fiber); // The claim is lost: nothing happens.
    try std.testing.expectEqual(@as(usize, 1), fixture.ready_count());
    try std.testing.expectEqual(WaitOutcome.canceled, fiber.wait.outcome);

    for ([_]*Waiter{ first, second }) |node| {
        try std.testing.expectEqual(Waiter.Outcome.idle, fixture.leave(node));
        try expect_detached(node);
    }
    try std.testing.expectEqual(@as(u32, 0), fixture.armed_count());
    fixture.sched.waiter_release(second);
}

test "batch: a claim by an event or a cancel takes the fiber's sleep off the wheel" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(8);
    defer fixture.deinit();

    const slots = try fixture.register(2);
    const far_ns: i96 = @as(i96, fixture.now_ns) + 10_000_000_000;
    var nodes: [2]*Waiter = undefined;
    var fibers: [2]*Fiber = undefined;
    for (&fibers, &nodes, 0..) |*fiber, *node, index| {
        fiber.* = fixture.start(index);
        node.* = fixture.node_of(fiber.*, true);
        try fixture.enter(node.*, index, .read);
        fiber.*.wait.sleeping = true;
        sleep.arm(&fixture.sched, fiber.*, .{ .at = far_ns });
        fixture.park(fiber.*);
    }
    try std.testing.expectEqual(@as(u32, 2), fixture.sched.wheel.count());

    fixture.event(slots[0]);
    try std.testing.expectEqual(@as(u32, 1), fixture.sched.wheel.count());
    try std.testing.expect(!fibers[0].wait.sleeping);
    try std.testing.expectEqual(WaitOutcome.woken, fibers[0].wait.outcome);

    fixture.registry.cancel(&fixture.sched, fibers[1]);
    try std.testing.expectEqual(@as(u32, 0), fixture.sched.wheel.count());
    try std.testing.expect(!fibers[1].wait.sleeping);
    try std.testing.expectEqual(WaitOutcome.canceled, fibers[1].wait.outcome);
    try std.testing.expectEqual(@as(usize, 2), fixture.ready_count());
    for (nodes) |node| _ = fixture.leave(node);
}

const CloseProbe = struct {
    fixture: *Fixture,
    nodes: [2]*Waiter,
    fiber_outcome: WaitOutcome,
    node_outcomes: [2]Waiter.Outcome,
    second_linked: bool,
    left: [2]Waiter.Outcome,
    closed: bool,
};

fn close_waiter(arg: ?*anyopaque) void {
    const probe: *CloseProbe = @ptrCast(@alignCast(arg.?));
    const sched = &probe.fixture.sched;
    const fiber = sched.current_fiber();
    fiber.wait = .{
        .addr = 0,
        .prev = null,
        .next = null,
        .sleeping = false,
        .outcome = .waiting,
        .socket = .batch,
    };
    probe.nodes = .{ sched.waiter_of(fiber), sched.waiter_acquire().? };
    probe.nodes[1].fiber = fiber;
    for (probe.nodes, 0..) |node, index| {
        const fd = probe.fixture.sock(index);
        assert(probe.fixture.registry.batch_enter(sched, fd, .read, node) == .parked);
    }
    sched.park();
    probe.fiber_outcome = fiber.wait.outcome;
    for (probe.nodes, 0..) |node, index| probe.node_outcomes[index] = node.outcome;
    const second_slot = probe.fixture.registry.lookup(probe.fixture.sock(1)).?;
    probe.second_linked = probe.fixture.registry.slots[second_slot].waiters[0] == probe.nodes[1];
    for (probe.nodes, 0..) |node, index| {
        probe.left[index] = probe.fixture.registry.leave(sched, node);
    }
    sched.waiter_release(probe.nodes[1]);
    fiber.wait = .none;
}

fn close_closer(arg: ?*anyopaque) void {
    const probe: *CloseProbe = @ptrCast(@alignCast(arg.?));
    const fd = probe.fixture.sock(0);
    probe.closed = probe.fixture.registry.close_on_carrier(&probe.fixture.sched, fd);
}

test "batch: close on the carrier marks only the closed socket's node and wakes the fiber" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(8);
    defer fixture.deinit();

    _ = try fixture.register(2);
    var probe: CloseProbe = undefined;
    probe.fixture = &fixture;
    probe.closed = false;
    _ = try fixture.sched.spawn(close_waiter, &probe);
    _ = try fixture.sched.spawn(close_closer, &probe);
    fixture.sched.run(std.testing.io);

    try std.testing.expect(probe.closed);
    try std.testing.expectEqual(WaitOutcome.woken, probe.fiber_outcome);
    try std.testing.expectEqual(Waiter.Outcome.closed, probe.node_outcomes[0]);
    try std.testing.expectEqual(Waiter.Outcome.waiting, probe.node_outcomes[1]);
    try std.testing.expect(probe.second_linked);
    try std.testing.expectEqual(Waiter.Outcome.closed, probe.left[0]);
    try std.testing.expectEqual(Waiter.Outcome.idle, probe.left[1]);
    try std.testing.expectEqual(@as(u32, 1), fixture.registry.count()); // Socket 1 remains.
    try std.testing.expectEqual(@as(u32, 0), fixture.armed_count());
    try std.testing.expectEqual(@as(u32, 4), fixture.sched.waiters_free());
}

test "batch: a close from another thread counts every node and wakes the fiber once" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(8);
    defer fixture.deinit();

    const slots = try fixture.register(1);
    const fiber = fixture.start(0);
    const reader = fixture.node_of(fiber, true);
    const writer = fixture.node_of(fiber, false);
    try fixture.enter(reader, 0, .read);
    try fixture.enter(writer, 0, .write);
    fixture.park(fiber);

    const fd = fixture.sock(0);
    try std.testing.expect(!fixture.registry.close_off_carrier(&fixture.sched, std.testing.io, fd));
    const slot = &fixture.registry.slots[slots[0]];
    try std.testing.expect(slot.closing);
    try std.testing.expectEqual(@as(u32, 2), slot.closing_pending); // The lost claim counts too.
    try std.testing.expectEqual(WaitOutcome.woken, fiber.wait.outcome);
    try std.testing.expect(fixture.sched.inbox == fiber);
    try std.testing.expect(fiber.queue_next == null); // Handed to the carrier exactly once.
    for ([_]*Waiter{ reader, writer }) |node| {
        try std.testing.expectEqual(Waiter.Outcome.closing, node.outcome);
        try expect_detached(node);
        try std.testing.expectEqual(Waiter.Outcome.closing, fixture.leave(node));
    }
    try std.testing.expect(!fixture.registry.closing_finish(&fixture.sched, fd, .read));
    try std.testing.expect(fixture.registry.closing_finish(&fixture.sched, fd, .write));
    try std.testing.expectEqual(@as(u32, 0), fixture.registry.count());
    fixture.sched.waiter_release(writer);
}

test "batch: leave downgrades a ready node whose socket was closed or reused meanwhile" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(8);
    defer fixture.deinit();

    const slots = try fixture.register(3);
    const fiber = fixture.start(0);
    var nodes: [3]*Waiter = undefined;
    for (&nodes, 0..) |*node, index| {
        node.* = fixture.node_of(fiber, index == 0);
        try fixture.enter(node.*, index, .read);
    }
    fixture.park(fiber);
    for (slots) |slot| fixture.event(slot);
    for (nodes) |node| try std.testing.expectEqual(Waiter.Outcome.ready, node.outcome);

    // Socket 0 is closed and its number registered again: same slot, another generation.
    try std.testing.expect(fixture.registry.unregister(fixture.sock(0)));
    try std.testing.expectEqual(slots[0], try fixture.registry.register(fixture.sock(0)));
    // Socket 1 is being closed by another thread.
    fixture.registry.slots[slots[1]].closing = true;

    try std.testing.expectEqual(Waiter.Outcome.closed, fixture.leave(nodes[0]));
    try std.testing.expectEqual(Waiter.Outcome.closed, fixture.leave(nodes[1]));
    try std.testing.expectEqual(Waiter.Outcome.ready, fixture.leave(nodes[2]));
    fixture.registry.slots[slots[1]].closing = false;
    fixture.sched.waiter_release(nodes[1]);
    fixture.sched.waiter_release(nodes[2]);
}

test "batch: the spare pool hands out each node once, refuses past its size, takes them back" {
    if (!Sched.supported) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var sched: Sched = undefined;
    const options: Sched.Options = .{
        .fibers_max = 2,
        .batch_ops_max = 3,
        .stack_size = Sched.stack_size_min,
        .now_ns = 0,
        .idle = .futex,
    };
    try sched.init(gpa, options);
    defer sched.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), failing.alloc_index); // Same blocks as before.
    try std.testing.expectEqual(@as(u32, 3), sched.waiters_free());
    var taken: [3]*Waiter = undefined;
    for (&taken, 0..) |*node, index| {
        node.* = sched.waiter_acquire().?;
        try std.testing.expect(node.*.prev == null);
        try std.testing.expect(node.*.next == null);
        for (sched.fibers) |*fiber| try std.testing.expect(node.* != sched.waiter_of(fiber));
        for (taken[0..index]) |other| try std.testing.expect(other != node.*);
    }
    try std.testing.expectEqual(@as(?*Waiter, null), sched.waiter_acquire());
    try std.testing.expectEqual(@as(u32, 0), sched.waiters_free());
    sched.waiter_release(taken[1]);
    try std.testing.expectEqual(@as(u32, 1), sched.waiters_free());
    try std.testing.expect(sched.waiter_acquire().? == taken[1]);
    for (taken) |node| sched.waiter_release(node);
    try std.testing.expectEqual(@as(u32, 3), sched.waiters_free());
    try std.testing.expectEqual(@as(usize, 4), failing.alloc_index); // Nothing allocated since.
}

test "batch: a pool of zero spares serves nothing and costs no block" {
    if (!Sched.supported) return error.SkipZigTest;
    var sched: Sched = undefined;
    const options: Sched.Options = .{
        .fibers_max = 2,
        .batch_ops_max = 0,
        .stack_size = Sched.stack_size_min,
        .now_ns = 0,
        .idle = .futex,
    };
    try sched.init(std.testing.allocator, options);
    defer sched.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), sched.waiters_free());
    try std.testing.expectEqual(@as(?*Waiter, null), sched.waiter_acquire());
    try std.testing.expectEqual(@as(usize, 2), sched.waiters.len);
}

test "batch: sleep.fire claims a waiting sleeper and skips one a foreign close already claimed" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(8);
    defer fixture.deinit();

    // Fiber 0: a foreign close claimed it (`woken`) and left the wheel node for the carrier.
    // Fiber 1: nobody got there first.
    var fibers: [2]*Fiber = undefined;
    for (&fibers, 0..) |*fiber, index| {
        fiber.* = fixture.start(index);
        fiber.*.wait.sleeping = true;
        sleep.arm(&fixture.sched, fiber.*, .{ .at = fixture.now_ns - past_ns });
        fixture.park(fiber.*);
    }
    fibers[0].wait.outcome = .woken;

    const next_ns = sleep.fire(&fixture.sched, std.testing.io);
    try std.testing.expectEqual(@as(?i96, null), next_ns);
    try std.testing.expectEqual(@as(u32, 0), fixture.sched.wheel.count());
    try std.testing.expectEqual(WaitOutcome.woken, fibers[0].wait.outcome);
    try std.testing.expect(fibers[0].wait.sleeping); // The resumed fiber clears it.
    try std.testing.expect(fibers[0].state == .parked);
    try std.testing.expectEqual(WaitOutcome.timed_out, fibers[1].wait.outcome);
    try std.testing.expect(!fibers[1].wait.sleeping);
    try std.testing.expect(fibers[1].state == .ready);
    try std.testing.expectEqual(@as(usize, 1), fixture.ready_count());
}

test "batch: batch_enter says gone for an unknown or closing fd and unlinks on resources" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(1); // The poller holds one registration.
    defer fixture.deinit();

    const slots = try fixture.register(2);
    const fiber = fixture.start(0);
    const first = fixture.node_of(fiber, true);
    const second = fixture.node_of(fiber, false);
    const third = fixture.node_of(fiber, false);
    const registry = &fixture.registry;
    const sched = &fixture.sched;

    try fixture.enter(first, 0, .read);
    try std.testing.expectEqual(Waiter.Outcome.waiting, first.outcome);
    try std.testing.expectEqual(slots[0], first.slot);
    try std.testing.expectEqual(registry.slots[slots[0]].generation, first.generation);
    // `fiber.wait` stays the caller's.
    try std.testing.expectEqual(WaitOutcome.waiting, fiber.wait.outcome);
    try std.testing.expectEqual(Sched.SocketWait.batch, fiber.wait.socket);

    const resources = registry.batch_enter(sched, fixture.sock(1), .read, second);
    try std.testing.expectEqual(net_registry.Enter.resources, resources);
    try std.testing.expect(registry.slots[slots[1]].waiters[0] == null);
    try std.testing.expectEqual(Waiter.Outcome.idle, second.outcome);
    try expect_detached(second);
    try std.testing.expectEqual(WaitOutcome.waiting, fiber.wait.outcome);
    try std.testing.expectEqual(Sched.SocketWait.batch, fiber.wait.socket);

    const unknown = registry.batch_enter(sched, fixture.pairs[2][1], .read, third);
    try std.testing.expectEqual(net_registry.Enter.gone, unknown);
    registry.slots[slots[0]].closing = true;
    const closing = registry.batch_enter(sched, fixture.sock(0), .write, third);
    try std.testing.expectEqual(net_registry.Enter.gone, closing);
    registry.slots[slots[0]].closing = false;
    try std.testing.expectEqual(Waiter.Outcome.idle, third.outcome);
    try expect_detached(third);

    try std.testing.expectEqual(Waiter.Outcome.idle, fixture.leave(first));
    try std.testing.expectEqual(@as(u32, 0), fixture.armed_count());
    sched.waiter_release(second);
    sched.waiter_release(third);
}
