//! sirocco.net — Sockets (tcp, udp, unix), address parsing, DNS resolver, connection pool.
//!
//! Planned files (see docs/PRD.md):
//!   - `net/address.zig`
//!   - `net/tcp.zig`
//!   - `net/udp.zig`
//!   - `net/unix.zig`
//!   - `net/dns.zig`
//!   - `net/pool.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "net: module compiles" {
    std.testing.refAllDecls(@This());
}
