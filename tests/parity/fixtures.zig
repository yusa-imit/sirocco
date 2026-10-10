//! The one construction path for a `Runtime` in the differential suite.
//!
//! Every parity test builds its runtime here, so the option set (`.threaded`, empty environment,
//! fiber limits) is written once and a later item that runs the suite a second time under `.fail`
//! changes one call, not every test. Ownership: the caller `deinit`s the returned runtime; it must
//! not move after its first `io()`.

const std = @import("std");
const Runtime = @import("sirocco").Runtime;

/// Fibers a default test runtime may have alive at once.
pub const fibers_max_default: u32 = 64;
/// Bytes per fiber stack in tests; Debug builds of std's `Io` call chain fit comfortably.
pub const fiber_stack_size_default: u32 = 128 * 1024;

/// A runtime on the `.threaded` backend whose unimplemented slots follow `unimplemented`.
pub fn init_runtime(unimplemented: Runtime.Unimplemented) Runtime.InitError!Runtime {
    return init_runtime_in(std.testing.allocator, unimplemented, fibers_max_default);
}

/// Like `init_runtime` with an explicit allocator and fiber limit, for exhaustion and OOM tests.
pub fn init_runtime_in(
    gpa: std.mem.Allocator,
    unimplemented: Runtime.Unimplemented,
    fibers_max: u32,
) Runtime.InitError!Runtime {
    return Runtime.init(gpa, .{
        .backend = .threaded,
        .unimplemented = unimplemented,
        .environ = .empty,
        .argv0 = .empty,
        .fibers_max = fibers_max,
        .fiber_stack_size = fiber_stack_size_default,
        .offload_threads = 2,
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
