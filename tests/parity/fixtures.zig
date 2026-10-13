//! The one construction path for a `Runtime` in the differential suite.
//!
//! Every parity test builds its runtime here, so the option set (empty environment, fiber limits)
//! is written once and a later item that runs the suite a second time under `.fail` changes one
//! call, not every test. The backend comes from the build: `build.zig` compiles this suite once
//! per backend (`parity_config.backend`, `.threaded` always, `.kqueue` on Darwin), so one source
//! tree is checked under both idle paths. Ownership: the caller `deinit`s the returned runtime;
//! it must not move after its first `io()`.

const std = @import("std");
const Runtime = @import("sirocco").Runtime;
const parity_config = @import("parity_config");

/// The backend this build of the suite runs on; never `.auto`, so a result names its path.
pub const backend: Runtime.Backend = std.meta.stringToEnum(
    Runtime.Backend,
    parity_config.backend,
) orelse @compileError("parity_config.backend names no Runtime.Backend");

/// Sockets (registry entries) a default test runtime may hold.
pub const sockets_max_default: u32 = 16;
/// Fibers a default test runtime may have alive at once.
pub const fibers_max_default: u32 = 64;
/// Bytes per fiber stack in tests; Debug builds of std's `Io` call chain fit comfortably.
pub const fiber_stack_size_default: u32 = 128 * 1024;

/// A runtime on the suite's backend whose unimplemented slots follow `unimplemented`.
pub fn init_runtime(unimplemented: Runtime.Unimplemented) Runtime.InitError!Runtime {
    return init_runtime_in(std.testing.allocator, unimplemented, fibers_max_default);
}

/// Like `init_runtime` with an explicit allocator and fiber limit, for exhaustion and OOM tests.
pub fn init_runtime_in(
    gpa: std.mem.Allocator,
    unimplemented: Runtime.Unimplemented,
    fibers_max: u32,
) Runtime.InitError!Runtime {
    return init_runtime_pool(gpa, unimplemented, fibers_max, 2);
}

/// Like `init_runtime_in` with an explicit offload pool size, for tests of the sizing rule.
pub fn init_runtime_pool(
    gpa: std.mem.Allocator,
    unimplemented: Runtime.Unimplemented,
    fibers_max: u32,
    offload_threads: u32,
) Runtime.InitError!Runtime {
    return Runtime.init(gpa, .{
        .backend = backend,
        .unimplemented = unimplemented,
        .environ = .empty,
        .argv0 = .empty,
        .fibers_max = fibers_max,
        .fiber_stack_size = fiber_stack_size_default,
        .offload_threads = offload_threads,
        .sockets_max = sockets_max_default,
    });
}

test "init_runtime builds a runtime in either mode" {
    var forwarding = try init_runtime(.forward);
    defer forwarding.deinit();

    var failing = try init_runtime(.fail);
    defer failing.deinit();

    try std.testing.expectEqual(Runtime.Unimplemented.forward, forwarding.unimplemented);
    try std.testing.expectEqual(Runtime.Unimplemented.fail, failing.unimplemented);
    try std.testing.expectEqual(backend, forwarding.backend);
}
