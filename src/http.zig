//! sirocco.http — HTTP/1.1 parser, client (retry/redirect/pool/proxy), server (graceful shutdown), HTTP/2 (HPACK, streams).
//!
//! Planned files (see docs/PRD.md):
//!   - `http/parser.zig`
//!   - `http/client.zig`
//!   - `http/server.zig`
//!   - `http/h2/hpack.zig`
//!   - `http/h2/stream.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "http: module compiles" {
    std.testing.refAllDecls(@This());
}
