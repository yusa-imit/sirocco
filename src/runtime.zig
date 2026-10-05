//! sirocco.Runtime — a `std.Io` implementation assembled from `Io.Threaded`'s vtable.
//!
//! Purpose: `Runtime.io()` is sirocco's entire public surface (ADR 0001). `.forward` copies every
//! slot from the embedded `Io.Threaded` and `.fail` copies every slot from `Io.failing`; sirocco's
//! native slots are then written over that base, one group per plan-002 item, so a test that
//! leans on the fallback can be run under `.fail` to fail loudly. Native today: the
//! concurrency set (`async`/`concurrent`/`await`/`cancel`, the three cancel-state slots,
//! `groupAsync`/`groupConcurrent`/`groupAwait`/`groupCancel` and `crashHandler`;
//! `src/concurrency.zig`, on the fibers of `src/sched.zig`) and the futex trio (`futexWait`,
//! `futexWaitUncancelable`, `futexWake`; `src/futex.zig`), installed in both modes. Where
//! `fibers_supported` is false (Windows, 32-bit and other architectures) the set is not installed
//! and stays forwarded, so `.auto` and `.threaded` keep working on every target.
//!
//! Invariants: the vtable has exactly 109 slots (`slots_count`, a comptime guard against a std
//! bump); no field of `Runtime` holds a pointer into `Runtime` — `io()` and `baselineIo()` are
//! the only places that take an address, so a `Runtime` may be moved until the first `io()`
//! call and must stay put afterwards. sirocco state is recovered from `Io.userdata` with
//! `@fieldParentPtr("threaded", t)`. The fiber scheduler is the one self-referential part (fibers
//! point at their `Sched`), so it is built in place by the first `io()` call, never in `init`;
//! `sched_pin` records its address and every later `io()` asserts it did not move.
//!
//! Allocation: `init` allocates nothing itself; `gpa` is handed to `Io.Threaded`, which uses it
//! lazily for `groupAsync`/`groupConcurrent` closures, thread stacks and process spawn. The first
//! `io()` allocates the fiber table and stacks (two blocks) from the same `gpa`, and the native
//! `async` still allocates one task record per started task, as Threaded does; "no allocation
//! after init" becomes true per slot group in later plan-002 items.
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
const Sched = @import("sched.zig");
const concurrency = @import("concurrency.zig");
const futex = @import("futex.zig");

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
/// Fiber scheduler; valid only while `sched_state == .ready`, built in place by the first `io()`.
sched: Sched,
/// The futex wait table (`src/futex.zig`); its records live in the scheduler's fibers.
waits: futex.Table,
sched_state: SchedState,
/// `@intFromPtr(&sched)` when it was built, else 0; asserts the `Runtime` has not moved.
sched_pin: usize,
fibers_max: u32,
fiber_stack_size: u32,

/// True when the native future-producing slots (and with them the fiber scheduler) exist here.
pub const fibers_supported = Sched.supported;

/// Life cycle of `sched`; `.unsupported` is a comptime fact of the target, `.unavailable` is the
/// outcome of an out-of-memory scheduler build (async then runs inline, concurrent refuses).
pub const SchedState = enum { pending, ready, unavailable, unsupported };

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
    /// Always available: slots not native to sirocco run on `Io.Threaded`'s thread pool.
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
    /// Fibers that may be alive at once (async tasks in flight); past it `async` runs inline.
    /// Positive. One stack of `fiber_stack_size` bytes is allocated per fiber at the first `io()`.
    fibers_max: u32,
    /// Bytes per fiber stack: a multiple of 16, at least `Sched.stack_size_min`. std's `Io` call
    /// chain runs on these stacks, so Debug builds want well over the minimum.
    fiber_stack_size: u32,
};

pub const InitError = error{
    /// The requested backend does not exist yet (kqueue, epoll, uring land with plan 003+).
    BackendUnavailable,
};

/// Builds a runtime. Precondition: `options` is fully specified; no default is implied, and the
/// fiber limits satisfy `Sched.Options`. The result becomes self-referential at the first
/// `io()`/`baselineIo()` call (std stores `Threaded.io()` inside `Threaded` itself) and, through
/// the scheduler, at the first `io()`; do not move it after that.
pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Runtime {
    const backend: Backend = switch (options.backend) {
        .auto, .threaded => .threaded,
        .kqueue, .epoll, .uring => return error.BackendUnavailable,
    };
    assert(backend == .threaded);
    assert(options.fibers_max > 0);
    assert(options.fiber_stack_size >= Sched.stack_size_min);
    assert(options.fiber_stack_size % 16 == 0);

    var threaded: Io.Threaded = .init(gpa, .{
        .stack_size = std.Thread.SpawnConfig.default_stack_size,
        .async_limit = null,
        .concurrent_limit = .unlimited,
        .argv0 = options.argv0,
        .environ = options.environ,
        .disable_memory_mapping = false,
    });
    var base: Io.VTable = switch (options.unimplemented) {
        .forward => threaded.io().vtable.*,
        .fail => Io.failing.vtable.*,
    };
    if (fibers_supported) {
        concurrency.install(&base);
        futex.install(&base);
    }
    return .{
        .threaded = threaded,
        .vtable = base,
        .backend = backend,
        .unimplemented = options.unimplemented,
        .sched = undefined,
        .waits = .init(options.fibers_max),
        .sched_state = if (fibers_supported) .pending else .unsupported,
        .sched_pin = 0,
        .fibers_max = options.fibers_max,
        .fiber_stack_size = options.fiber_stack_size,
    };
}

/// Releases the scheduler and the embedded `Io.Threaded` (joins its worker threads).
/// Preconditions: no `Io` value obtained from this runtime is used afterwards, and every future
/// from `async` was awaited or cancelled (no fiber is alive).
pub fn deinit(rt: *Runtime) void {
    assert(rt.backend == .threaded);
    if (rt.sched_state == .ready) {
        assert(rt.sched_pin == @intFromPtr(&rt.sched));
        rt.sched.deinit(rt.threaded.allocator);
    }
    rt.threaded.deinit();
    // Poison so a use-after-deinit through a stale `Io` trips safety checks in Debug.
    rt.* = undefined;
}

/// The whole public surface. Takes the address of `rt`, so `rt` must not move afterwards. The
/// first call also builds the fiber scheduler in place (allocating its two blocks).
pub fn io(rt: *Runtime) Io {
    assert(rt.backend == .threaded);
    assert(@intFromPtr(&rt.threaded) != 0);
    if (fibers_supported) concurrency.sched_ensure(rt);
    assert(rt.sched_state != .pending);
    return .{ .userdata = &rt.threaded, .vtable = &rt.vtable };
}

/// The same runtime's `Io.Threaded`, for differential tests and as an escape hatch.
pub fn baselineIo(rt: *Runtime) Io {
    const baseline = rt.threaded.io();
    assert(baseline.userdata == @as(?*anyopaque, &rt.threaded));
    return baseline;
}

fn test_options(backend: Backend, unimplemented: Unimplemented) Options {
    return .{
        .backend = backend,
        .unimplemented = unimplemented,
        .environ = .empty,
        .argv0 = .empty,
        .fibers_max = 4,
        .fiber_stack_size = 64 * 1024,
    };
}

// The slots `concurrency.zig` installs: native where fibers exist, forwarded elsewhere.
const future_slots = .{
    "async",
    "concurrent",
    "await",
    "cancel",
    "checkCancel",
    "recancel",
    "swapCancelProtection",
    "groupAsync",
    "groupConcurrent",
    "groupAwait",
    "groupCancel",
    "crashHandler",
    "futexWait",
    "futexWaitUncancelable",
    "futexWake",
};

fn is_future_slot(comptime name: []const u8) bool {
    inline for (future_slots) |future_slot| {
        if (std.mem.eql(u8, name, future_slot)) return true;
    }
    return false;
}

test "io() and baselineIo() share userdata but not the vtable" {
    var rt: Runtime = try .init(std.testing.allocator, test_options(.threaded, .forward));
    defer rt.deinit();

    const native = rt.io();
    const baseline = rt.baselineIo();
    try std.testing.expect(native.vtable != baseline.vtable);
    try std.testing.expectEqual(native.userdata, baseline.userdata);
    try std.testing.expect(native.userdata != null);
}

test "forward mode installs every baseline slot except the native future set" {
    var rt: Runtime = try .init(std.testing.allocator, test_options(.threaded, .forward));
    defer rt.deinit();

    const native = rt.io().vtable;
    const baseline = rt.baselineIo().vtable;
    inline for (@typeInfo(Io.VTable).@"struct".fields) |field| {
        const forwarded = @field(native, field.name) == @field(baseline, field.name);
        try std.testing.expectEqual(!(fibers_supported and is_future_slot(field.name)), forwarded);
    }
}

test "fail mode installs every Io.failing slot except the native future set" {
    var rt: Runtime = try .init(std.testing.allocator, test_options(.threaded, .fail));
    defer rt.deinit();

    const native = rt.io().vtable;
    inline for (@typeInfo(Io.VTable).@"struct".fields) |field| {
        const failing = @field(native, field.name) == @field(Io.failing.vtable, field.name);
        try std.testing.expectEqual(!(fibers_supported and is_future_slot(field.name)), failing);
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
    var rt: Runtime = try .init(std.testing.allocator, test_options(.threaded, .forward));
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

test "the scheduler is built by the first io() and pinned there" {
    var rt: Runtime = try .init(std.testing.allocator, test_options(.threaded, .forward));
    defer rt.deinit();

    if (!fibers_supported) {
        try std.testing.expectEqual(SchedState.unsupported, rt.sched_state);
        _ = rt.io();
        try std.testing.expectEqual(SchedState.unsupported, rt.sched_state);
        return;
    }
    // `init` and `baselineIo` leave it unbuilt, so a `Runtime` returned by value can still move.
    try std.testing.expectEqual(SchedState.pending, rt.sched_state);
    _ = rt.baselineIo();
    try std.testing.expectEqual(SchedState.pending, rt.sched_state);
    try std.testing.expectEqual(@as(usize, 0), rt.sched_pin);

    _ = rt.io();
    try std.testing.expectEqual(SchedState.ready, rt.sched_state);
    try std.testing.expectEqual(@intFromPtr(&rt.sched), rt.sched_pin);
    // A second `io()` neither rebuilds nor moves it.
    _ = rt.io();
    try std.testing.expectEqual(@intFromPtr(&rt.sched), rt.sched_pin);
    try std.testing.expectEqual(@as(u32, 4), @as(u32, @intCast(rt.sched.fibers.len)));
}

test "unavailable backends are refused, auto resolves" {
    const options_unavailable: [3]Options = .{
        test_options(.kqueue, .forward),
        test_options(.epoll, .fail),
        test_options(.uring, .forward),
    };
    for (options_unavailable) |options| {
        try std.testing.expectError(
            error.BackendUnavailable,
            Runtime.init(std.testing.allocator, options),
        );
    }
    var rt: Runtime = try .init(std.testing.allocator, test_options(.auto, .forward));
    defer rt.deinit();
    try std.testing.expectEqual(Backend.threaded, rt.backend);
}
