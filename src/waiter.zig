//! sirocco.waiter — the node a fiber parked on a socket hangs in the slot's waiter list.
//!
//! Purpose: `src/net_registry.zig` links these nodes, never fibers, so `Fiber.wait.prev/next`
//! belong to the futex table alone (ADR 0004 section 6). `Sched` allocates one node per fiber in
//! `init` (`Sched.waiters`, node `i` for fiber `i`), so a single-op socket wait can never fail for
//! want of a node, plus `batch_ops_max` spares that a fiber waiting on several sockets takes from
//! the pool (`Sched.waiter_acquire`). `Sched` re-exports the type as `Sched.Waiter`.
//!
//! Invariants: every field but `fiber` is written under the registry's lock only (the owner sets
//! `fiber` of a spare when it acquires it); `slot` and `generation` are those of the socket at
//! `waiter_enter`, valid while the node is linked and until the waiter has run. A node that is not
//! linked has `prev` and `next` null. `outcome` says how this node's wait ended, whatever the
//! fiber-level `wait.outcome` says: a fiber with several nodes is woken once, by whoever wins the
//! claim on that word, and learns from each node what became of its socket.

const Sched = @import("sched.zig");
const poller = @import("backend/poller.zig");

pub const Waiter = struct {
    prev: ?*Waiter,
    next: ?*Waiter,
    fiber: *Sched.Fiber,
    outcome: Outcome,
    interest: poller.Interest,
    slot: u32,
    generation: u32,

    /// `idle`: not linked and no event for it (also a node that left its list unserved).
    /// `waiting`: linked. `ready`: an event unlinked it. `closed`: the socket was closed on the
    /// carrier and nothing of the slot may be touched. `closing`: a close from another thread
    /// left the fd open for `closing_finish`.
    pub const Outcome = enum(u8) { idle, waiting, ready, closed, closing };
};
