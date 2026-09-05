//! sirocco.ws — WebSocket (RFC 6455) client and server framing, ping/pong, close handshake.
//!
//! Planned files (see docs/PRD.md):
//!   - `ws/frame.zig`
//!   - `ws/client.zig`
//!   - `ws/server.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "ws: module compiles" {
    std.testing.refAllDecls(@This());
}
