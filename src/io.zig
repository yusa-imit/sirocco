//! sirocco.io — Event loop, completions, timers, cancellation. Backends: kqueue, epoll, io_uring, iocp.
//!
//! Planned files (see docs/PRD.md):
//!   - `io/completion.zig`
//!   - `io/loop.zig`
//!   - `io/timer.zig`
//!   - `io/backend/kqueue.zig`
//!   - `io/backend/epoll.zig`
//!   - `io/backend/io_uring.zig`
//!   - `io/backend/iocp.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "io: module compiles" {
    std.testing.refAllDecls(@This());
}
