//! Tiger Style assertion helpers shared across sirocco's entry points and modules.
//!
//! `assert` documents a condition that always holds; `maybe` documents one that holds only
//! sometimes, so a reader never mistakes silence for "nobody thought about it." Lives here
//! until zuda ships a shared home for it (`citadel/core/rules/tiger-style.md` §1.6).

const std = @import("std");

pub const assert = std.debug.assert;

/// No-op that documents a condition which is legitimately sometimes true.
pub fn maybe(ok: bool) void {
    _ = ok;
}
