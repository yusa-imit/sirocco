//! sirocco.task — Thread pool, bounded channel, wait group.
//! Hierarchical cancellation, multi-loop scheduler.
//!
//! Planned files (see docs/PRD.md):
//!   - `task/thread_pool.zig`
//!   - `task/channel.zig`
//!   - `task/cancel.zig`
//!   - `task/scheduler.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "task: module compiles" {
    std.testing.refAllDecls(@This());
}
