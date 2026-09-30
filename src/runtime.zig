//! sirocco.Runtime — a `std.Io` implementation assembled from `Io.Threaded`'s vtable.
//!
//! Purpose: `Runtime.io()` is sirocco's entire public surface (ADR 0001). This walking skeleton
//! installs no native slot yet: `.forward` copies every slot from the embedded `Io.Threaded`
//! and `.fail` copies every slot from `Io.failing`, so each later plan-002 item replaces one
//! slot group here and a test that leans on the fallback can be run under `.fail` to fail loudly.
//!
//! Invariants: the vtable has exactly 109 slots (`slots_count`, a comptime guard against a std
//! bump); no field of `Runtime` holds a pointer into `Runtime` — `io()` and `baselineIo()` are
//! the only places that take an address, so a `Runtime` may be moved until the first `io()`
//! call and must stay put afterwards. sirocco state is recovered from `Io.userdata` with
//! `@fieldParentPtr("threaded", t)`.
//!
//! Allocation: `init` allocates nothing itself; `gpa` is handed to `Io.Threaded`, which uses it
//! lazily for `async`/`concurrent`/`groupAsync`/`groupConcurrent` closures, thread stacks and
//! process spawn, so "no allocation after init" is not yet true; it becomes true per slot group
//! as native slots replace the forwarded ones (plan 002 items 4-8).
//!
//! Process-wide effects: `Io.Threaded.init` installs `SIGIO`/`SIGPIPE` handlers and `deinit`
//! restores them, so overlapping runtimes must be torn down in reverse order of creation.
//!
//! Slot groups that exchange tokens (`async`/`await`/`cancel`, `groupAsync`/`groupAwait`/
//! `groupCancel`, `batch*`) must be replaced atomically: under `.fail`, `Io.failing`'s `await`
//! and `cancel` are `unreachable`, sound only while its `async` returns no future.

const std = @import("std");
const Io = std.Io;
const stdx = @import("stdx.zig");

const assert = stdx.assert;

const Runtime = @This();

/// Forwarding target for the declared hybrid and the differential-test oracle. Its address is
/// this runtime's `Io.userdata`.
threaded: Io.Threaded,
/// `Threaded`'s (or `Io.failing`'s) vtable with sirocco's slots written over it. Never shared.
vtable: Io.VTable,
/// The resolved backend; never `.auto`.
backend: Backend,
unimplemented: Unimplemented,

// Number of `Io.VTable` slots in the pinned std; ADR 0001 requires a build failure on a bump.
const slots_count = 109;

comptime {
    assert(@typeInfo(Io.VTable).@"struct".fields.len == slots_count);
}

pub const Backend = enum {
    /// Picks the best backend available on this target; today that is `.threaded`.
    auto,
    kqueue,
    epoll,
    uring,
    /// Always available: every slot runs on `Io.Threaded`'s thread pool.
    threaded,
};

/// What a slot sirocco has not implemented natively does. `.forward` is the shipping hybrid;
/// `.fail` installs `Io.failing`'s stub so a test cannot pass by accident on the fallback.
pub const Unimplemented = enum { forward, fail };

/// Every field is required: a default here would be a decision nobody reviewed.
pub const Options = struct {
    backend: Backend,
    unimplemented: Unimplemented,
    /// Environment handed to forwarded `process*` slots; pass `init.environ` from `main`.
    environ: std.process.Environ,
    /// Program name for `processExecutablePath` on OpenBSD and Haiku; `.empty` elsewhere.
    argv0: Io.Threaded.Argv0,
};

pub const InitError = error{
    /// The requested backend does not exist yet (kqueue, epoll, uring land with plan 003+).
    BackendUnavailable,
};

/// Builds a runtime. Precondition: `options` is fully specified; no default is implied. The
/// result becomes self-referential at the first `io()`/`baselineIo()` call (std stores
/// `Threaded.io()` inside `Threaded` itself), so do not move it after that.
pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Runtime {
    const backend: Backend = switch (options.backend) {
        .auto, .threaded => .threaded,
        .kqueue, .epoll, .uring => return error.BackendUnavailable,
    };
    assert(backend == .threaded);

    var threaded: Io.Threaded = .init(gpa, .{
        .stack_size = std.Thread.SpawnConfig.default_stack_size,
        .async_limit = null,
        .concurrent_limit = .unlimited,
        .argv0 = options.argv0,
        .environ = options.environ,
        .disable_memory_mapping = false,
    });
    const base: Io.VTable = switch (options.unimplemented) {
        .forward => threaded.io().vtable.*,
        .fail => Io.failing.vtable.*,
    };
    return .{
        .threaded = threaded,
        .vtable = base,
        .backend = backend,
        .unimplemented = options.unimplemented,
    };
}

/// Releases the embedded `Io.Threaded` (joins its worker threads). Precondition: no `Io` value
/// obtained from this runtime is used afterwards.
pub fn deinit(rt: *Runtime) void {
    assert(rt.backend == .threaded);
    rt.threaded.deinit();
    // Poison so a use-after-deinit through a stale `Io` trips safety checks in Debug.
    rt.* = undefined;
}

/// The whole public surface. Takes the address of `rt`, so `rt` must not move afterwards.
pub fn io(rt: *Runtime) Io {
    assert(rt.backend == .threaded);
    assert(@intFromPtr(&rt.threaded) != 0);
    return .{ .userdata = &rt.threaded, .vtable = &rt.vtable };
}

/// The same runtime's `Io.Threaded`, for differential tests and as an escape hatch.
pub fn baselineIo(rt: *Runtime) Io {
    const baseline = rt.threaded.io();
    assert(baseline.userdata == @as(?*anyopaque, &rt.threaded));
    return baseline;
}

test "io() and baselineIo() share userdata but not the vtable" {
    var rt: Runtime = try .init(std.testing.allocator, .{
        .backend = .threaded,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
    });
    defer rt.deinit();

    const native = rt.io();
    const baseline = rt.baselineIo();
    try std.testing.expect(native.vtable != baseline.vtable);
    try std.testing.expectEqual(native.userdata, baseline.userdata);
    try std.testing.expect(native.userdata != null);
}

test "forward mode installs every baseline slot" {
    var rt: Runtime = try .init(std.testing.allocator, .{
        .backend = .threaded,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
    });
    defer rt.deinit();

    const native = rt.io().vtable;
    const baseline = rt.baselineIo().vtable;
    inline for (@typeInfo(Io.VTable).@"struct".fields) |field| {
        try std.testing.expect(@field(native, field.name) == @field(baseline, field.name));
    }
}

test "fail mode installs every Io.failing slot" {
    var rt: Runtime = try .init(std.testing.allocator, .{
        .backend = .threaded,
        .unimplemented = .fail,
        .environ = .empty,
        .argv0 = .empty,
    });
    defer rt.deinit();

    const native = rt.io().vtable;
    inline for (@typeInfo(Io.VTable).@"struct".fields) |field| {
        try std.testing.expect(@field(native, field.name) == @field(Io.failing.vtable, field.name));
    }
    // The baseline stays a working Threaded whatever the mode.
    const baseline = rt.baselineIo();
    try std.testing.expect(baseline.vtable != rt.io().vtable);
    var buffer: [8]u8 = @splat(0);
    try baseline.randomSecure(&buffer);
    try std.testing.expect(!std.mem.allEqual(u8, &buffer, 0));

    // Behaviour, not just pointer identity: Io.failing reports an unusable environment.
    try std.testing.expectError(error.EntropyUnavailable, rt.io().randomSecure(&buffer));
    try std.testing.expectError(error.ConcurrencyUnavailable, rt.io().concurrent(add, .{ 1, 2 }));
}

test "forwarded slots do real work" {
    var rt: Runtime = try .init(std.testing.allocator, .{
        .backend = .threaded,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
    });
    defer rt.deinit();

    const rio = rt.io();
    var buffer: [32]u8 = @splat(0);
    try rio.randomSecure(&buffer);
    try std.testing.expect(!std.mem.allEqual(u8, &buffer, 0));

    var future = rio.async(add, .{ 40, 2 });
    try std.testing.expectEqual(@as(u32, 42), future.await(rio));
}

fn add(a: u32, b: u32) u32 {
    return a + b;
}

test "unavailable backends are refused, auto resolves" {
    const options_unavailable: [3]Options = .{
        .{ .backend = .kqueue, .unimplemented = .forward, .environ = .empty, .argv0 = .empty },
        .{ .backend = .epoll, .unimplemented = .fail, .environ = .empty, .argv0 = .empty },
        .{ .backend = .uring, .unimplemented = .forward, .environ = .empty, .argv0 = .empty },
    };
    for (options_unavailable) |options| {
        try std.testing.expectError(
            error.BackendUnavailable,
            Runtime.init(std.testing.allocator, options),
        );
    }
    var rt: Runtime = try .init(std.testing.allocator, .{
        .backend = .auto,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
    });
    defer rt.deinit();
    try std.testing.expectEqual(Backend.threaded, rt.backend);
}
