//! sirocco.Sched — the fiber substrate under every native `std.Io` slot (plan 002 item 4).
//!
//! Purpose: cooperative fibers multiplexed onto one carrier thread (the thread that calls
//! `run`). A fiber is a stack plus a saved `Io.fiber.Context`; switching is
//! `Io.fiber.contextSwitch` (per-arch assembly in std, aarch64 and x86_64 here).
//! No vtable slot is installed yet: items 5-8 build `async`/`await`/`cancel`, groups and the
//! futex table on `spawn`, `yield`, `park` and `unpark`.
//!
//! Invariants: `fibers_max` stacks are allocated in `init` and nowhere else; a fiber is exactly
//! one of free / ready / running / parked, and `live_count` equals the fibers not free. The first
//! eight bytes of every stack hold a canary, checked with `assert_always` on every switch-out and
//! at fiber exit. It catches a linear overflow only: a frame that jumps the canary corrupts the
//! neighbouring stack, and there are no guard pages yet. The `Sched` must not move after `init`
//! (fibers hold a pointer to it), so `init` fills the caller's storage in place.
//!
//! Known defect: on x86_64 the tests SEGV in ReleaseSmall (aarch64 passes in all four modes);
//! see the open bug issue. Debug, ReleaseSafe and ReleaseFast pass on both.
//!
//! Allocation: `init` allocates two blocks (fiber table, stack arena) from `gpa`; `Sched` stores
//! no allocator, so nothing allocates afterwards, and `deinit` takes the same `gpa` back.
//!
//! Threads: everything except `unpark_foreign` runs on the carrier thread. `unpark_foreign` may be
//! called from any thread: it pushes onto a lock-free inbox and bumps a futex word, and the
//! carrier, when its ready queue drains, blocks in the baseline `futexWaitUncancelable` on that
//! word, so no OS-specific backend file is needed yet. The waker's thread must be joined before
//! `deinit`: `unpark_foreign` touches the futex word after the carrier may have finished.
//!
//! Sketch: `spawn` touches one `Fiber` record and the top cache line of one stack; a switch
//! saves and restores 3 words plus the callee-saved registers std's assembly spills; zero
//! syscalls on the ready path, one futex wait per idle period.

const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx.zig");

const Io = std.Io;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

const Sched = @This();

fibers: []Fiber,
stacks: []align(stack_align) u8,
stack_size: u32,
free_head: ?*Fiber,
ready_head: ?*Fiber,
ready_tail: ?*Fiber,
current: ?*Fiber,
carrier_context: Io.fiber.Context,
live_count: u32,
parked_count: u32,
running: bool,
/// Fibers made ready from other threads; a Treiber stack drained with one exchange.
inbox: ?*Fiber,
/// Futex word bumped after every inbox push; the carrier waits on it when it has nothing to run.
inbox_version: u32,

/// True when `Io.fiber` has context-switch assembly sirocco's entry trampolines also cover.
pub const supported = switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => Io.fiber.supported,
    else => false,
};

/// Smallest accepted stack; a fiber body plus std's `Io` call chain needs room in Debug builds.
pub const stack_size_min: u32 = 16 * 1024;

pub const Options = struct {
    /// Fibers that may be alive at once; one stack is allocated for each.
    fibers_max: u32,
    /// Bytes per stack, a multiple of 16 and at least `stack_size_min`.
    stack_size: u32,
};

pub const InitError = error{
    /// The target has no `Io.fiber` assembly; use the `.threaded` backend.
    FibersUnsupported,
    OutOfMemory,
};

pub const SpawnError = error{
    /// `fibers_max` fibers are already alive.
    FibersExhausted,
};

pub const Entry = *const fn (arg: ?*anyopaque) void;

pub const Fiber = struct {
    context: Io.fiber.Context,
    queue_next: ?*Fiber,
    state: State,
    stack: []u8,

    const State = enum { free, ready, running, parked };
};

const stack_align = 16;
const canary_value: u64 = 0x5afe_c0de_0ddf_00d5;
const canary_size = @sizeOf(u64);

/// Lives at the top of a fiber's stack; the entry trampoline hands its address to `fiber_main`.
const Start = struct {
    sched: *Sched,
    fiber: *Fiber,
    entry: Entry,
    arg: ?*anyopaque,
};

/// Fills `target` in place. Precondition: `options.fibers_max > 0`, `options.stack_size` is a
/// multiple of 16 and at least `stack_size_min`. Runs nothing; allocates the fiber table and the
/// stack arena, and nothing after.
pub fn init(target: *Sched, gpa: std.mem.Allocator, options: Options) InitError!void {
    return init_checked(target, gpa, options, supported);
}

// Split out so the `FibersUnsupported` path is provokable on targets where `supported` is true.
fn init_checked(
    target: *Sched,
    gpa: std.mem.Allocator,
    options: Options,
    is_supported: bool,
) InitError!void {
    assert(options.fibers_max > 0);
    assert(options.stack_size >= stack_size_min);
    assert(options.stack_size % stack_align == 0);
    if (!is_supported) return error.FibersUnsupported;

    const arena_size = std.math.mul(usize, options.fibers_max, options.stack_size) catch {
        return error.OutOfMemory;
    };
    const fibers = try gpa.alloc(Fiber, options.fibers_max);
    errdefer gpa.free(fibers);

    const stacks = try gpa.alignedAlloc(u8, .@"16", arena_size);
    errdefer gpa.free(stacks);

    target.* = .{
        .fibers = fibers,
        .stacks = stacks,
        .stack_size = options.stack_size,
        .free_head = null,
        .ready_head = null,
        .ready_tail = null,
        .current = null,
        .carrier_context = std.mem.zeroes(Io.fiber.Context),
        .live_count = 0,
        .parked_count = 0,
        .running = false,
        .inbox = null,
        .inbox_version = 0,
    };
    // Reverse order so the first `spawn` takes fiber 0 and the free list stays address-ordered.
    for (0..fibers.len) |offset| {
        const index = fibers.len - 1 - offset;
        const stack_offset = index * options.stack_size;
        fibers[index] = .{
            .context = std.mem.zeroes(Io.fiber.Context),
            .queue_next = target.free_head,
            .state = .free,
            .stack = stacks[stack_offset..][0..options.stack_size],
        };
        target.free_head = &fibers[index];
    }
    assert(target.free_head == &fibers[0]);
}

/// Frees the fiber table and stack arena. Precondition: `gpa` is the allocator given to `init`,
/// and no fiber is alive (every spawned fiber ran to completion).
pub fn deinit(sched: *Sched, gpa: std.mem.Allocator) void {
    assert(sched.live_count == 0);
    assert(sched.current == null);
    assert(!sched.running);
    gpa.free(sched.stacks);
    gpa.free(sched.fibers);
    sched.* = undefined;
}

/// Makes `entry(arg)` runnable on a free fiber; it first runs inside `run`. Precondition: not
/// called from inside `run`'s switch window on another thread (carrier-thread only).
pub fn spawn(sched: *Sched, entry: Entry, arg: ?*anyopaque) SpawnError!*Fiber {
    const fiber = sched.free_head orelse return error.FibersExhausted;
    assert(fiber.state == .free);
    sched.free_head = fiber.queue_next;

    const top = @intFromPtr(fiber.stack.ptr) + fiber.stack.len;
    assert(top % stack_align == 0);
    const start_address = std.mem.alignBackward(usize, top - @sizeOf(Start), stack_align);
    const start: *Start = @ptrFromInt(start_address);
    start.* = .{ .sched = sched, .fiber = fiber, .entry = entry, .arg = arg };
    std.mem.writeInt(u64, fiber.stack[0..canary_size], canary_value, .little);
    fiber.context = initial_context(start_address);

    sched.live_count += 1;
    sched.push_ready(fiber);
    assert(fiber.state == .ready);
    return fiber;
}

/// The fiber currently executing. Precondition: called from a fiber, inside `run`.
pub fn current_fiber(sched: *const Sched) *Fiber {
    assert_always(sched.current != null);
    const fiber = sched.current.?;
    assert(fiber.state == .running);
    return fiber;
}

/// Gives every other ready fiber a turn first. Precondition: called from a fiber.
pub fn yield(sched: *Sched) void {
    const fiber = sched.current_fiber();
    sched.push_ready(fiber);
    sched.switch_to_carrier(fiber);
    assert(fiber.state == .running);
}

/// Suspends the calling fiber until `unpark` or `unpark_foreign` names it. Precondition: called
/// from a fiber. The caller must have published the fiber (`current_fiber`) to its waker first.
pub fn park(sched: *Sched) void {
    const fiber = sched.current_fiber();
    fiber.state = .parked;
    sched.parked_count += 1;
    assert(sched.parked_count <= sched.live_count);
    sched.switch_to_carrier(fiber);
    assert(fiber.state == .running);
}

/// Makes a parked fiber ready. Precondition: carrier thread only, and `fiber` already parked.
pub fn unpark(sched: *Sched, fiber: *Fiber) void {
    assert(fiber.state == .parked);
    assert(sched.parked_count > 0);
    sched.parked_count -= 1;
    sched.push_ready(fiber);
    assert(fiber.state == .ready);
}

/// `unpark` from any thread. The fiber may not have parked yet; it is made ready only once the
/// carrier next drains the inbox, which happens after the fiber has switched out. Precondition:
/// the fiber is running toward `park` or already parked, and is named by at most one waker.
pub fn unpark_foreign(sched: *Sched, io: Io, fiber: *Fiber) void {
    // `fiber.state` is carrier-owned and not read here: the carrier may be writing it.
    fiber.queue_next = @atomicLoad(?*Fiber, &sched.inbox, .monotonic);
    while (@cmpxchgWeak(
        ?*Fiber,
        &sched.inbox,
        fiber.queue_next,
        fiber,
        .release,
        .monotonic,
    )) |seen| {
        fiber.queue_next = seen;
    }
    _ = @atomicRmw(u32, &sched.inbox_version, .Add, 1, .release);
    io.futexWake(u32, &sched.inbox_version, 1);
}

/// Runs fibers on the calling thread until none is alive. A fiber that parks with nothing else
/// runnable blocks the carrier in the baseline futex until `unpark_foreign` delivers it.
/// Precondition: not nested, and called from outside any fiber.
pub fn run(sched: *Sched, io: Io) void {
    assert(sched.current == null);
    assert(!sched.running);
    sched.running = true;
    defer sched.running = false;

    while (sched.live_count > 0) {
        const version = @atomicLoad(u32, &sched.inbox_version, .acquire);
        sched.inbox_drain();
        const fiber = sched.pop_ready() orelse {
            // Every live fiber is parked on something that only another thread can deliver.
            assert(sched.parked_count == sched.live_count);
            io.futexWaitUncancelable(u32, &sched.inbox_version, version);
            continue;
        };
        fiber.state = .running;
        sched.current = fiber;
        switch_context(&sched.carrier_context, &fiber.context);
        assert(sched.current == null);
    }
    assert(sched.ready_head == null);
    assert(sched.parked_count == 0);
}

fn push_ready(sched: *Sched, fiber: *Fiber) void {
    fiber.state = .ready;
    fiber.queue_next = null;
    if (sched.ready_tail) |tail| {
        assert(tail.queue_next == null);
        tail.queue_next = fiber;
    } else {
        assert(sched.ready_head == null);
        sched.ready_head = fiber;
    }
    sched.ready_tail = fiber;
}

fn pop_ready(sched: *Sched) ?*Fiber {
    const fiber = sched.ready_head orelse {
        assert(sched.ready_tail == null);
        return null;
    };
    assert(fiber.state == .ready);
    sched.ready_head = fiber.queue_next;
    if (sched.ready_head == null) sched.ready_tail = null;
    fiber.queue_next = null;
    return fiber;
}

fn inbox_drain(sched: *Sched) void {
    var reversed: ?*Fiber = @atomicRmw(?*Fiber, &sched.inbox, .Xchg, null, .acquire);
    // The inbox is a stack, so reverse it to wake fibers in the order they were unparked.
    var ordered: ?*Fiber = null;
    for (0..sched.fibers.len) |_| {
        const fiber = reversed orelse break;
        reversed = fiber.queue_next;
        fiber.queue_next = ordered;
        ordered = fiber;
    }
    assert(reversed == null);
    for (0..sched.fibers.len) |_| {
        const fiber = ordered orelse break;
        ordered = fiber.queue_next;
        // A wake for a fiber that did not park would queue it twice; that is a contract breach.
        assert_always(fiber.state == .parked);
        sched.unpark(fiber);
    }
    assert(ordered == null);
}

fn switch_to_carrier(sched: *Sched, fiber: *Fiber) void {
    assert(sched.current == fiber);
    // Checked on every switch-out, so an overflow is caught while the fiber is still parked.
    assert_always(canary_intact(fiber.stack));
    sched.current = null;
    switch_context(&fiber.context, &sched.carrier_context);
}

// `noinline` is load-bearing: `Io.fiber.contextSwitch` clobbers x30 and x29 (the link and frame
// registers), which LLVM cannot honour as asm clobbers once the switch is inlined into a caller
// that keeps a live value in them; in ReleaseFast/ReleaseSmall `run` then read a garbage `sched`
// after a switch. Its own frame saves and restores them. `build.zig` runs these tests in every
// optimize mode to keep this honest.
noinline fn switch_context(old: *Io.fiber.Context, new: *Io.fiber.Context) void {
    const message: Io.fiber.Switch = .{ .old = old, .new = new };
    _ = Io.fiber.contextSwitch(&message);
}

fn canary_intact(stack: []const u8) bool {
    return std.mem.readInt(u64, stack[0..canary_size], .little) == canary_value;
}

/// Runs on the fiber's own stack; never returns, it switches to the carrier for good.
fn fiber_main(
    start: *Start,
    message: *const Io.fiber.Switch,
) callconv(.withStackAlign(.c, @alignOf(Start))) noreturn {
    _ = message; // The carrier's switch descriptor; nothing in it is needed to start.
    const sched = start.sched;
    const fiber = start.fiber;
    assert(sched.current == fiber);
    start.entry(start.arg);

    assert_always(canary_intact(fiber.stack));
    assert(fiber.state == .running);
    fiber.state = .free;
    fiber.queue_next = sched.free_head;
    sched.free_head = fiber;
    sched.live_count -= 1;
    sched.switch_to_carrier(fiber);
    // A free fiber is never made ready again, so its context is never resumed.
    unreachable;
}

fn initial_context(start_address: usize) Io.fiber.Context {
    return switch (builtin.cpu.arch) {
        .x86_64 => .{
            .rsp = start_address - @sizeOf(usize),
            .rbp = 0,
            .rip = @intFromPtr(&fiber_entry),
        },
        .aarch64 => .{
            .sp = start_address,
            .fp = 0,
            .pc = @intFromPtr(&fiber_entry),
        },
        else => unreachable, // `supported` is false and `init` refused.
    };
}

/// First instruction of a new fiber: turns the stack-top `Start` record into `fiber_main`'s
/// first argument. The second argument (the switch message) is already in place.
fn fiber_entry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ leaq 8(%%rsp), %%rdi
            \\ jmp %[fiber_main:P]
            :
            : [fiber_main] "X" (&fiber_main),
        ),
        .aarch64 => asm volatile (
            \\ mov x0, sp
            \\ b %[fiber_main]
            :
            : [fiber_main] "X" (&fiber_main),
        ),
        else => unreachable, // `supported` is false and `init` refused.
    }
}

const TestLog = struct {
    sched: *Sched,
    ids: [64]u32,
    len: u32,
    fiber: ?*Fiber,
    flag: u32,

    fn record(log: *TestLog, id: u32) void {
        log.ids[log.len] = id;
        log.len += 1;
    }
};

const TestSlot = struct { log: *TestLog, id: u32 };

fn test_yielder(arg: ?*anyopaque) void {
    const slot: *TestSlot = @ptrCast(@alignCast(arg.?));
    slot.log.record(slot.id);
    slot.log.sched.yield();
    slot.log.record(slot.id + 100);
}

test "spawn fibers_max fibers, round-robin them, recycle the stacks" {
    if (!supported) return error.SkipZigTest;
    const fibers_max = 8;
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, .{ .fibers_max = fibers_max, .stack_size = 64 * 1024 });
    defer sched.deinit(std.testing.allocator);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    var slots: [fibers_max]TestSlot = undefined;
    // Two rounds prove a finished fiber's stack is reusable and its canary re-armed.
    for (0..2) |_| {
        log.len = 0;
        for (&slots, 0..) |*slot, id| {
            slot.* = .{ .log = &log, .id = @intCast(id) };
            _ = try sched.spawn(test_yielder, slot);
        }
        try std.testing.expectError(error.FibersExhausted, sched.spawn(test_yielder, &slots[0]));
        sched.run(std.testing.io);

        try std.testing.expectEqual(@as(u32, 2 * fibers_max), log.len);
        for (0..fibers_max) |id| {
            try std.testing.expectEqual(@as(u32, @intCast(id)), log.ids[id]);
            try std.testing.expectEqual(@as(u32, @intCast(id)) + 100, log.ids[fibers_max + id]);
        }
        try std.testing.expectEqual(@as(u32, 0), sched.live_count);
    }
}

test "init allocates, spawn and run do not" {
    if (!supported) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var sched: Sched = undefined;
    try sched.init(gpa, .{ .fibers_max = 4, .stack_size = 32 * 1024 });
    defer sched.deinit(gpa);
    // Fiber table and stack arena; nothing else.
    try std.testing.expectEqual(@as(usize, 2), failing.alloc_index);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    var slots: [4]TestSlot = undefined;
    for (&slots, 0..) |*slot, id| {
        slot.* = .{ .log = &log, .id = @intCast(id) };
        _ = try sched.spawn(test_yielder, slot);
    }
    sched.run(std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), failing.alloc_index);
    try std.testing.expectEqual(@as(u32, 8), log.len);
}

test "init reports allocation failure at either block and frees the first" {
    if (!supported) return error.SkipZigTest;
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var sched: Sched = undefined;
        try std.testing.expectError(
            error.OutOfMemory,
            sched.init(failing.allocator(), .{ .fibers_max = 2, .stack_size = 16 * 1024 }),
        );
    }
}

fn test_parker(arg: ?*anyopaque) void {
    const log: *TestLog = @ptrCast(@alignCast(arg.?));
    log.fiber = log.sched.current_fiber();
    log.record(1);
    log.sched.park();
    log.record(3);
}

fn test_waker(arg: ?*anyopaque) void {
    const log: *TestLog = @ptrCast(@alignCast(arg.?));
    log.record(2);
    log.sched.unpark(log.fiber.?);
    log.record(2);
}

test "park suspends a fiber until another fiber unparks it" {
    if (!supported) return error.SkipZigTest;
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, .{ .fibers_max = 2, .stack_size = 32 * 1024 });
    defer sched.deinit(std.testing.allocator);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    _ = try sched.spawn(test_parker, &log);
    _ = try sched.spawn(test_waker, &log);
    sched.run(std.testing.io);

    // The waker keeps running after `unpark`; the parker resumes only on the next turn.
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 2, 3 }, log.ids[0..log.len]);
}

fn test_foreign_parker(arg: ?*anyopaque) void {
    const log: *TestLog = @ptrCast(@alignCast(arg.?));
    log.fiber = log.sched.current_fiber();
    @atomicStore(u32, &log.flag, 1, .release);
    log.sched.park();
    log.record(7);
}

fn test_foreign_waker(log: *TestLog, io: Io) void {
    // `flag` is set just before the fiber parks; `unpark_foreign` tolerates that window.
    for (0..std.math.maxInt(u32)) |_| {
        if (@atomicLoad(u32, &log.flag, .acquire) == 1) break;
        std.Thread.yield() catch {}; // Only a scheduling hint; spinning again is the fallback.
    }
    log.sched.unpark_foreign(io, log.fiber.?);
}

test "unpark_foreign wakes a carrier blocked on an empty ready queue" {
    if (!supported) return error.SkipZigTest;
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, .{ .fibers_max = 1, .stack_size = 32 * 1024 });
    defer sched.deinit(std.testing.allocator);

    var log: TestLog = .{ .sched = &sched, .ids = @splat(0), .len = 0, .fiber = null, .flag = 0 };
    _ = try sched.spawn(test_foreign_parker, &log);
    const waker = try std.Thread.spawn(.{}, test_foreign_waker, .{ &log, std.testing.io });
    sched.run(std.testing.io);
    waker.join();

    try std.testing.expectEqualSlices(u32, &.{7}, log.ids[0..log.len]);
}

test "canary detects a clobbered stack base" {
    var stack: [64]u8 = @splat(0);
    std.mem.writeInt(u64, stack[0..canary_size], canary_value, .little);
    try std.testing.expect(canary_intact(&stack));
    stack[3] ^= 0x01;
    try std.testing.expect(!canary_intact(&stack));
}

test "init reports FibersUnsupported before allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var sched: Sched = undefined;
    const options: Options = .{ .fibers_max = 1, .stack_size = stack_size_min };
    try std.testing.expectError(
        error.FibersUnsupported,
        sched.init_checked(failing.allocator(), options, false),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}
