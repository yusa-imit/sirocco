//! The one construction path for a `Runtime` in the differential suite.
//!
//! Every parity test builds its runtime here, so the option set (`.threaded`, empty environment)
//! is written once and a later item that runs the suite a second time under `.fail` changes one
//! call, not every test. Ownership: the caller `deinit`s the returned runtime; it must not move
//! after its first `io()`.

const std = @import("std");
const Runtime = @import("sirocco").Runtime;

/// A runtime on the `.threaded` backend whose unimplemented slots follow `unimplemented`.
pub fn init_runtime(unimplemented: Runtime.Unimplemented) Runtime.InitError!Runtime {
    return Runtime.init(std.testing.allocator, .{
        .backend = .threaded,
        .unimplemented = unimplemented,
        .environ = .empty,
        .argv0 = .empty,
    });
}

test "init_runtime builds a runtime in either mode" {
    var forwarding = try init_runtime(.forward);
    defer forwarding.deinit();

    var failing = try init_runtime(.fail);
    defer failing.deinit();

    try std.testing.expectEqual(Runtime.Unimplemented.forward, forwarding.unimplemented);
    try std.testing.expectEqual(Runtime.Unimplemented.fail, failing.unimplemented);
}
