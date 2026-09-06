//! sirocco.tls — TLS 1.3 client/server on std.crypto.tls with async handshake.
//! Covers ALPN, SNI, PEM loading.
//!
//! Planned files (see docs/PRD.md):
//!   - `tls/client.zig`
//!   - `tls/server.zig`
//!   - `tls/pem.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "tls: module compiles" {
    std.testing.refAllDecls(@This());
}
