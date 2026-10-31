//! sirocco.waiter — the node a fiber parked on a socket hangs in the slot's waiter list.
//!
//! Purpose: `src/net_registry.zig` links these nodes, never fibers, so `Fiber.wait.prev/next`
//! belong to the futex table alone (ADR 0004 section 6). `Sched` allocates one node per fiber in
//! `init` (`Sched.waiters`, node `i` for fiber `i`), so a socket wait can never fail for want of
//! a node, and re-exports the type as `Sched.Waiter`.
//!
//! Invariants: every field but `fiber` is written under the registry's lock only; `slot` and
//! `generation` are those of the socket at `waiter_enter`, valid while the node is linked and
//! until the waiter has run. A node that is not linked has `prev` and `next` null.

const Sched = @import("sched.zig");
const poller = @import("backend/poller.zig");

pub const Waiter = struct {
    prev: ?*Waiter,
    next: ?*Waiter,
    fiber: *Sched.Fiber,
    interest: poller.Interest,
    slot: u32,
    generation: u32,
};
