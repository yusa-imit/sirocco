//! sirocco.net_registry_batch — the registry operations of a fiber that waits on several sockets
//! at once (ADR 0004 section 6, plan 005 item 5), split from `src/net_registry.zig` to keep that
//! file under the tidy cap.
//!
//! Purpose: such a fiber (`wait.socket == .batch`) owns one `Sched.Waiter` per socket, its own plus
//! spares from `Sched.waiter_acquire`. Its `wait.outcome` is a claim: whoever moves it off
//! `.waiting` first (`Sched.claim`) wins and is the only one to wake the fiber, so an event on one
//! socket, a cancel, a timeout and a close from another thread cannot unpark it twice. What became
//! of each socket is in the node's own `outcome`. The resumed fiber calls `leave` on every node
//! before it reads them; a node never needs the registry after that.
//!
//! Threads: `enter`, `leave`, `wake_on_carrier` and `cancel` run on the carrier; `wake_foreign`
//! may run on any thread. Everything that touches a slot's lists holds the registry's lock, as
//! in `net_registry.zig`, which calls `wake_*` from its event and close paths.
//!
//! Invariants: a node is linked exactly while its outcome is `.waiting`; the poller registration of
//! `(slot, interest)` is armed exactly while the list is non-empty. Nothing here allocates.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const sched_io = @import("sched_io.zig");
const sleep = @import("sleep.zig");
const net_registry = @import("net_registry.zig");
const poller = @import("backend/poller.zig");
const sys = @import("backend/sys.zig");

const Io = std.Io;
const Fiber = Sched.Fiber;
const Waiter = Sched.Waiter;
const Registry = net_registry.Registry;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

/// Joins the waiter list of `(fd, interest)` with `node`, one of a batch fiber's nodes, and arms
/// the poller when the list was empty, in one lock hold. As `Registry.waiter_enter`, except that
/// `node.fiber.wait` belongs to the caller (it set `socket = .batch` and `outcome = .waiting`
/// before the first node, and may be claimed by another thread between two calls). `.gone` when
/// `fd` is unknown or closing, `.resources` when the poller refused; either way the node is left
/// idle and unlinked. Carrier-only; the fiber is running.
pub fn enter(
    registry: *Registry,
    sched: *Sched,
    fd: sys.fd_t,
    interest: poller.Interest,
    node: *Waiter,
) net_registry.Enter {
    const fiber = node.fiber;
    assert(fiber.wait.socket == .batch);
    assert(fiber.state == .running);
    assert(node.prev == null);
    assert(node.next == null);
    assert(node.outcome == .idle);
    registry.lock();
    defer registry.mutex.unlock();

    const found = registry.table.get(poller.key(fd, .read)) orelse return .gone;
    const index: u32 = @intCast(found);
    const slot = &registry.slots[index];
    assert_always(slot.fd == fd);
    if (slot.closing) return .gone;
    const list_empty = slot.waiters[net_registry.interest_index(interest)] == null;
    net_registry.waiter_link(slot, index, interest, node);
    assert(node.outcome == .waiting);
    if (list_empty) sched_io.arm(sched, fd, interest, index) catch {
        net_registry.waiter_remove(slot, node);
        node.outcome = .idle;
        return .resources;
    };
    return .parked;
}

/// The resumed fiber's last word on one of its nodes, under the registry's lock: a node still
/// `.waiting` is unlinked (and its interest disarmed when it was the list's last), a `.ready` one
/// becomes `.closed` if its socket was closed, or closed and reused, since the event. Returns the
/// node's final outcome: `.idle` (never served), `.ready` (retry the syscall), `.closed`, or
/// `.closing` (the caller owes `closing_finish`). Call once per node; carrier-only.
pub fn leave(registry: *Registry, sched: *Sched, node: *Waiter) Waiter.Outcome {
    assert(node.fiber.wait.socket == .batch);
    assert(node.fiber.state == .running);
    registry.lock();
    defer registry.mutex.unlock();

    switch (node.outcome) {
        // Nothing of the slot is left to touch, and it may be gone or reused already.
        .idle, .closed, .closing => return node.outcome,
        .waiting => {
            const slot = &registry.slots[node.slot];
            assert_always(slot.generation == node.generation); // Linked: the slot cannot be freed.
            assert_always(!slot.closing); // A close unlinks every waiter first.
            net_registry.waiter_remove(slot, node);
            if (slot.waiters[net_registry.interest_index(node.interest)] == null) {
                sched_io.disarm(sched, slot.fd, node.interest);
            }
            node.outcome = .idle;
        },
        .ready => {
            const slot = &registry.slots[node.slot];
            if (slot.generation != node.generation or slot.closing) node.outcome = .closed;
        },
    }
    assert(node.prev == null);
    assert(node.next == null);
    return node.outcome;
}

/// A cancelation request reached a parked batch fiber: the claim `.canceled` and the wake, nothing
/// else. The nodes stay linked and armed until the fiber runs `leave`. A no-op when an event, a
/// timeout or a close claimed it first. Carrier-only.
pub fn cancel(sched: *Sched, fiber: *Fiber) void {
    assert(fiber.wait.socket == .batch);
    assert(fiber.wait.outcome != .idle);
    wake_on_carrier(sched, fiber, .canceled);
}

/// Claims `fiber` with `outcome` and, if this call wins, takes it off the wheel (a woken fiber
/// must not be fired as timed out) and makes it ready. Carrier-only.
pub fn wake_on_carrier(sched: *Sched, fiber: *Fiber, outcome: Sched.WaitOutcome) void {
    assert(fiber.wait.socket == .batch);
    assert(fiber.state != .free);
    if (!Sched.claim(fiber, outcome)) return;
    assert(fiber.state == .parked); // Claimed from the carrier loop, so it cannot be running.
    if (fiber.wait.sleeping) {
        sleep.disarm(sched, fiber);
        fiber.wait.sleeping = false;
    }
    sched.unpark(fiber);
}

/// Claims `fiber` with `.woken` and, if this call wins, hands it to its carrier. Any thread. The
/// wheel node stays: only the carrier may unlink it, and the resumed fiber does.
pub fn wake_foreign(sched: *Sched, io: Io, fiber: *Fiber) void {
    assert(fiber.wait.socket == .batch); // Stable: the node is still linked, so no `leave` yet.
    assert(fiber.state != .free);
    if (Sched.claim(fiber, .woken)) sched.unpark_foreign(io, fiber);
}
