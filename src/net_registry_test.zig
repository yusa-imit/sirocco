//! Tests for `net_registry.zig`'s waiter lists: the `Sched.Waiter` nodes it links per slot.
//!
//! Split out of `net_registry.zig` to keep that file under the tidy cap. The fibers here are not
//! run: the tests put them in the states the registry's preconditions ask for (`running` to
//! enter, `parked` to be woken) by hand, and read the ready queue to learn who was woken, in
//! which order.

const std = @import("std");
const Sched = @import("sched.zig");
const poller = @import("backend/poller.zig");
const sched_io = @import("sched_io.zig");
const sys = @import("backend/sys.zig");
const net_registry = @import("net_registry.zig");

const Registry = net_registry.Registry;
const Waiter = Sched.Waiter;
const posix = std.posix;

const supported = Sched.supported and poller.Native != void;

const Fixture = struct {
    sched: Sched,
    registry: Registry,
    fds: [2]sys.fd_t,

    fn init(fixture: *Fixture) !void {
        const options: Sched.Options = .{
            .fibers_max = 4,
            .stack_size = 16 * 1024,
            .now_ns = 0,
            .idle = .{ .poller = .{ .registrations_max = 8 } },
        };
        try fixture.sched.init(std.testing.allocator, options);
        errdefer fixture.sched.deinit(std.testing.allocator);

        try fixture.registry.init(std.testing.allocator, 2);
        errdefer fixture.registry.deinit(std.testing.allocator);

        fixture.fds = try sys.socket_pair(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        fixture.sched.events = .{ .ctx = &fixture.registry, .ready = net_registry.on_event };
    }

    fn deinit(fixture: *Fixture) void {
        sched_io.disarm(&fixture.sched, fixture.fds[0], .read);
        sched_io.disarm(&fixture.sched, fixture.fds[0], .write);
        sys.close(fixture.fds[0]);
        sys.close(fixture.fds[1]);
        fixture.registry.deinit(std.testing.allocator);
        // The fibers were never spawned: forget the hand-made states before the checks of deinit.
        fixture.sched.live_count = 0;
        fixture.sched.parked_count = 0;
        fixture.sched.deinit(std.testing.allocator);
    }

    /// Enters fiber `index` on `(fds[0], interest)` as the carrier would, then parks it by hand.
    fn enter(fixture: *Fixture, index: usize, interest: poller.Interest) !*Waiter {
        const fiber = &fixture.sched.fibers[index];
        fiber.state = .running;
        const node = fixture.sched.waiter_of(fiber);
        const entered = fixture.registry.waiter_enter(
            &fixture.sched,
            fixture.fds[0],
            interest,
            node,
        );
        try std.testing.expectEqual(net_registry.Enter.parked, entered);
        fiber.state = .parked;
        fixture.sched.live_count += 1;
        fixture.sched.parked_count += 1;
        return node;
    }

    /// The fibers of the ready queue, front to back.
    fn ready_order(fixture: *Fixture, out: []*Sched.Fiber) []*Sched.Fiber {
        var len: usize = 0;
        var next = fixture.sched.ready_head;
        while (next) |fiber| : (next = fiber.queue_next) {
            out[len] = fiber;
            len += 1;
        }
        return out[0..len];
    }
};

fn expect_detached(node: *const Waiter) !void {
    try std.testing.expect(node.prev == null);
    try std.testing.expect(node.next == null);
}

test "registry: waiter_enter links nodes newest first and records slot and generation" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const index = try fixture.registry.register(fixture.fds[0]);
    const generation = fixture.registry.slots[index].generation;
    const first = try fixture.enter(0, .read);
    const second = try fixture.enter(1, .read);

    const slot = &fixture.registry.slots[index];
    try std.testing.expect(slot.waiters[0] == second);
    try std.testing.expect(slot.waiters[1] == null);
    try std.testing.expect(second.next == first);
    try std.testing.expect(first.prev == second);
    try std.testing.expect(second.prev == null);
    try std.testing.expect(first.next == null);
    for ([_]*Waiter{ first, second }) |node| {
        try std.testing.expectEqual(index, node.slot);
        try std.testing.expectEqual(generation, node.generation);
        try std.testing.expectEqual(poller.Interest.read, node.interest);
        try std.testing.expectEqual(Sched.WaitOutcome.waiting, node.fiber.wait.outcome);
        try std.testing.expectEqual(Sched.SocketWait.read, node.fiber.wait.socket);
        try std.testing.expectEqual(@as(usize, index), node.fiber.wait.addr);
    }
}

test "registry: cancel of the middle node unlinks it, on_event wakes the rest newest first" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const index = try fixture.registry.register(fixture.fds[0]);
    const oldest = try fixture.enter(0, .read);
    const middle = try fixture.enter(1, .read);
    const newest = try fixture.enter(2, .read);

    fixture.registry.cancel(&fixture.sched, middle.fiber);
    try expect_detached(middle);
    try std.testing.expectEqual(Sched.WaitOutcome.canceled, middle.fiber.wait.outcome);
    const slot = &fixture.registry.slots[index];
    try std.testing.expect(slot.waiters[0] == newest);
    try std.testing.expect(newest.next == oldest);
    try std.testing.expect(oldest.prev == newest);
    try std.testing.expect(sched_io.armed_any(&fixture.sched)); // Two are still waiting.

    const event: poller.Event = .{ .token = index, .interest = .read, .hangup = false };
    net_registry.on_event(&fixture.registry, &fixture.sched, event);
    try std.testing.expect(slot.waiters[0] == null);
    try std.testing.expect(slot.waiters[1] == null);
    for ([_]*Waiter{ oldest, middle, newest }) |node| try expect_detached(node);
    try std.testing.expectEqual(Sched.WaitOutcome.woken, newest.fiber.wait.outcome);
    try std.testing.expectEqual(Sched.WaitOutcome.woken, oldest.fiber.wait.outcome);
    // Ready order: the cancel first, then the event's list from its head (the newest waiter).
    var buffer: [4]*Sched.Fiber = undefined;
    const order = fixture.ready_order(&buffer);
    try std.testing.expectEqual(@as(usize, 3), order.len);
    try std.testing.expect(order[0] == middle.fiber);
    try std.testing.expect(order[1] == newest.fiber);
    try std.testing.expect(order[2] == oldest.fiber);
}

test "registry: a close from another thread detaches both lists and hands out the nodes" {
    if (!supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const index = try fixture.registry.register(fixture.fds[0]);
    const reader_old = try fixture.enter(0, .read);
    const reader_new = try fixture.enter(1, .read);
    const writer = try fixture.enter(2, .write);

    const closed = fixture.registry.close_off_carrier(
        &fixture.sched,
        std.testing.io,
        fixture.fds[0],
    );
    try std.testing.expect(!closed); // Three waiters hold the fd open.
    const slot = &fixture.registry.slots[index];
    try std.testing.expect(slot.closing);
    try std.testing.expectEqual(@as(u32, 3), slot.closing_pending);
    try std.testing.expect(slot.waiters[0] == null);
    try std.testing.expect(slot.waiters[1] == null);
    for ([_]*Waiter{ reader_old, reader_new, writer }) |node| {
        try expect_detached(node);
        try std.testing.expectEqual(Sched.WaitOutcome.closing, node.fiber.wait.outcome);
    }
    // Each woken waiter finishes on the carrier; the last one frees the slot.
    const registry = &fixture.registry;
    const fd = fixture.fds[0];
    try std.testing.expect(!registry.closing_finish(&fixture.sched, fd, .read));
    try std.testing.expect(!registry.closing_finish(&fixture.sched, fd, .read));
    try std.testing.expect(registry.closing_finish(&fixture.sched, fd, .write));
    try std.testing.expectEqual(@as(u32, 0), fixture.registry.count());
}
