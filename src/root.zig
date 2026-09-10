//! sirocco — The wind that drives the fleet — async I/O runtime and network stack for Zig
//!
//! Library root. Consumers `@import("sirocco")` and reach modules as
//! `sirocco.<module>`. Every module is independent; import only what you use.
//!
//! See docs/PRD.md for the full design and docs/milestones.md for progress.

const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 2, .patch = 0 };

pub const stdx = @import("stdx.zig");

pub const io = @import("io.zig");
pub const net = @import("net.zig");
pub const tls = @import("tls.zig");
pub const http = @import("http.zig");
pub const ws = @import("ws.zig");
pub const task = @import("task.zig");

test {
    std.testing.refAllDecls(@This());
}
