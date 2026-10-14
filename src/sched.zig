//! sirocco.Sched — the fiber substrate under every native `std.Io` slot (plan 002 item 4).
//!
//! Purpose: cooperative fibers multiplexed onto one carrier thread (the thread that calls
//! `run`). A fiber is a stack plus a saved `Io.fiber.Context`; switching is
//! `switch_context` (naked per-arch assembly in `src/fiber_switch.zig`, aarch64 and x86_64).
//! `Sched` installs no vtable slot itself: `src/concurrency.zig` builds `async`/`await`/`cancel`
//! and groups on `spawn`, `park`, `unpark` and `run`, `src/futex.zig` the futex slots on the
//! per-fiber `Wait` record. The scheduler owns a timing wheel (`src/timer.zig`, one node per
//! fiber index) that `run` fires before every dispatch, so a timed wait expires even when every
//! fiber is parked, and `src/sleep.zig` builds `sleep` on the same wheel.
//!
//! Invariants: `fibers_max` stacks are allocated in `init` and nowhere else; a fiber is exactly
//! one of free / ready / running / parked, and `live_count` equals the fibers not free. The first
//! eight bytes of every stack hold a canary, checked with `assert_always` on every switch-out and
//! at fiber exit. It catches a linear overflow only: a frame that jumps the canary corrupts the
//! neighbouring stack, and there are no guard pages yet. The `Sched` must not move after `init`
//! (fibers hold a pointer to it), so `init` fills the caller's storage in place.
//!
//! Allocation: `init` allocates three blocks (fiber table, stack arena, wheel nodes) from `gpa`,
//! plus the poller's table under `.poller`; `Sched` stores no allocator, so nothing allocates
//! afterwards, and `deinit` takes the same `gpa` back.
//!
//! Idling (`Options.idle`): with nothing ready the carrier sleeps until the wheel's next deadline
//! or a foreign wake. Under `.futex` it blocks in the baseline futex on `inbox_version`. Under
//! `.poller` (ADR 0003) the `Sched` owns one `backend.poller.Native`, built in `init` and torn
//! down in `deinit`, and the carrier blocks in `Poller.wait` with the time left to that deadline
//! (`null` when none), so sockets armed by `src/net.zig` share the sleep: `src/sched_io.zig` hands
//! each delivered event to `Sched.events`, which unparks the fibers it names, and polls without
//! blocking once per `fibers_max` dispatches so a busy run queue cannot starve sockets.
//!
//! Threads: everything except `unpark_foreign` runs on the carrier thread. `unpark_foreign` may be
//! called from any thread: it pushes onto a lock-free inbox, then wakes the carrier: under
//! `.futex` it bumps `inbox_version` and wakes that word, under `.poller` it calls `Poller.wake`,
//! which is latched, so a wake that lands before the carrier enters `wait` is not lost and the
//! futex word goes unused. The waker's thread must be joined before `deinit`: `unpark_foreign`
//! touches the futex word or the poller after the carrier may have finished.
//!
//! Sketch: `spawn` touches one `Fiber` record and the top cache line of one stack; a switch
//! saves and restores 3 words plus the callee-saved registers (rbx, r12-r15 / x19-x28, d8-d15,
//! x30), pushed on the old stack; zero syscalls on the ready path, one futex wait (or one
//! `kevent`) per idle period.
//! Eager start (`spawn_first`) puts the new fiber at the queue front and runs it before returning.

const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx.zig");
const switch_context = @import("fiber_switch.zig").switch_context;
const Wheel = @import("timer.zig");
const sleep = @import("sleep.zig");
const evented = @import("backend/poller.zig");
const sched_io = @import("sched_io.zig");

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
/// Futex word bumped after every inbox push under `.futex` idling, which the carrier waits on when
/// it has nothing to run; stays 0 under `.poller`.
inbox_version: u32,
/// How the carrier sleeps; chosen by `Options.idle` and fixed for life.
idle: Idle,
/// Handler for futex waiters whose deadline passed; null until `src/futex.zig` installs it.
expiry: ?Expiry,
/// Deadlines of timed waits, keyed by fiber index; a fiber has at most one node.
wheel: Wheel,
/// Fiber `spawn_first` runs from outside `run`; `run_loop` returns once it switches out.
first: ?*Fiber,
/// Names the fibers a delivered poller event wakes; installed by `src/net.zig` before it arms.
events: ?Events,
/// Dispatches since the poller was last polled; `run_loop` polls at `fibers_max`.
since_poll: u32,

/// True when `Io.fiber` has context-switch assembly sirocco's entry trampolines also cover.
/// Windows is excluded: the switch assembly assumes the SysV/AAPCS64 argument registers and
/// does not maintain the TEB stack bounds.
pub const supported = switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => Io.fiber.supported and builtin.os.tag != .windows,
    else => false,
};

/// True on the thread inside `run_loop`, i.e. the carrier. Per thread, so that `in_fiber` answers
/// false, without reading carrier-owned state, when asked from any other thread (for example a
/// worker of the forwarded `Io.Threaded` running a group task).
threadlocal var carrier_active: bool = false;

/// Smallest accepted stack; a fiber body plus std's `Io` call chain needs room in Debug builds.
pub const stack_size_min: u32 = 16 * 1024;

pub const Options = struct {
    /// Fibers that may be alive at once; one stack is allocated for each.
    fibers_max: u32,
    /// Bytes per stack, a multiple of 16 and at least `stack_size_min`.
    stack_size: u32,
    /// `Clock.awake` reading at creation, the wheel's starting time.
    now_ns: u64,
    /// Where the idle carrier sleeps; `.poller` allocates the poller's table in `init`.
    idle: IdleOptions,
};

pub const IdleOptions = union(enum) {
    /// Block in the baseline futex on `inbox_version`.
    futex,
    /// Block in the target's `backend.poller.Native` (`registrations_max` positive).
    poller: evented.Options,
};

const Idle = union(enum) { futex, poller: evented.Native };

pub const InitError = error{
    /// The target has no `Io.fiber` assembly; use the `.threaded` backend.
    FibersUnsupported,
    /// `Options.idle` is `.poller` on a target with no evented backend yet.
    PollerUnsupported,
} || evented.InitError;

pub const SpawnError = error{
    /// `fibers_max` fibers are already alive.
    FibersExhausted,
};

pub const Entry = *const fn (arg: ?*anyopaque) void;

/// What `run_loop` calls for a fiber whose wheel node fired while it waits on a futex address;
/// a sleeping fiber needs no handler (the scheduler unparks it itself). Only the code owning the
/// address table can unlink the waiter from it.
pub const Expiry = struct {
    ctx: *anyopaque,
    /// Runs on the carrier with the fiber parked. Must leave the fiber unparked-and-ready with
    /// outcome `.timed_out`, or untouched when a wake or cancel ended its wait first.
    futex_timeout: *const fn (ctx: *anyopaque, sched: *Sched, fiber: *Fiber) void,
};

/// What `sched_io` calls for each event the poller delivers; runs on the carrier, outside any
/// fiber, and must unpark (via `unpark`) every fiber the event's token names.
pub const Events = struct {
    ctx: *anyopaque,
    ready: *const fn (ctx: *anyopaque, sched: *Sched, event: evented.Event) void,
};

/// Which readiness a fiber parked on a socket waits for (`src/net.zig`); `none` otherwise.
pub const SocketWait = enum(u8) { none, read, write };

/// How a fiber's address wait ended; `futex.zig` owns the transitions.
pub const WaitOutcome = enum { idle, waiting, woken, timed_out, canceled };

/// A fiber's place in the futex table: a fiber waits on at most one address, so the record lives
/// in the fiber and the table can neither allocate nor overflow past `fibers_max`. A sleeping
/// fiber is in no table: it has `sleeping` set and outcome `.waiting`. Deadlines live in the
/// scheduler's wheel, not here.
pub const Wait = struct {
    addr: usize,
    prev: ?*Fiber,
    next: ?*Fiber,
    /// Carrier-only; true while parked in `sleep`.
    sleeping: bool,
    outcome: WaitOutcome,
    /// Carrier-only; set while the fiber is parked on a socket, with `addr` its registry slot.
    socket: SocketWait = .none,

    pub const none: Wait = .{
        .addr = 0,
        .prev = null,
        .next = null,
        .sleeping = false,
        .outcome = .idle,
    };
};

pub const Fiber = struct {
    context: Io.fiber.Context,
    queue_next: ?*Fiber,
    state: State,
    stack: []u8,
    /// The `arg` of the `spawn` that made this fiber live; null while free. Lets code running on
    /// the fiber find its own task record from `current_fiber`.
    arg: ?*anyopaque,
    wait: Wait,

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
/// stack arena (and the poller's table under `.poller`), and nothing after.
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

    var wheel: Wheel = undefined; // Filled by `Wheel.init` on the next line, before any read.
    try wheel.init(gpa, .{ .nodes_max = options.fibers_max, .now_ns = options.now_ns });
    errdefer wheel.deinit(gpa);

    var idle = try idle_init(gpa, options.idle);
    errdefer idle_deinit(&idle, gpa);

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
        .idle = idle,
        .expiry = null,
        .wheel = wheel,
        .first = null,
        .events = null,
        .since_poll = 0,
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
            .arg = null,
            .wait = .none,
        };
        target.free_head = &fibers[index];
    }
    assert(target.free_head == &fibers[0]);
}

fn idle_init(gpa: std.mem.Allocator, options: IdleOptions) InitError!Idle {
    switch (options) {
        .futex => return .futex,
        .poller => |poller_options| {
            assert(poller_options.registrations_max > 0);
            if (comptime evented.Native == void) return error.PollerUnsupported;
            var native: evented.Native = undefined; // Filled in place by `init`, before any read.
            try native.init(gpa, poller_options);
            return .{ .poller = native };
        },
    }
}

fn idle_deinit(idle: *Idle, gpa: std.mem.Allocator) void {
    switch (idle.*) {
        .futex => assert(idle.* == .futex),
        .poller => |*native| {
            // Proof: `idle_init` refuses `.poller` on a target without a poller.
            if (comptime evented.Native == void) unreachable;
            native.deinit(gpa);
        },
    }
}

/// Frees the fiber table, stack arena, wheel and poller. Precondition: `gpa` is the allocator
/// given to `init`, no fiber is alive (every spawned fiber ran to completion), and nothing is
/// armed in the poller.
pub fn deinit(sched: *Sched, gpa: std.mem.Allocator) void {
    assert(sched.live_count == 0);
    assert(sched.current == null);
    assert(!sched.running);
    idle_deinit(&sched.idle, gpa);
    sched.wheel.deinit(gpa);
    gpa.free(sched.stacks);
    gpa.free(sched.fibers);
    sched.* = undefined;
}

/// Makes `entry(arg)` runnable on a free fiber; it first runs inside `run`. Precondition: called
/// on the carrier thread only.
pub fn spawn(sched: *Sched, entry: Entry, arg: ?*anyopaque) SpawnError!*Fiber {
    return sched.spawn_placed(entry, arg, .back);
}

/// `spawn`, then runs the new fiber at once. From a fiber the caller yields (it resumes behind
/// every ready fiber) once the new one first parks, yields or ends; from outside `run` the carrier
/// loop runs until it does (`io` drives the loop). Called by the carrier inside `run_loop` (for
/// example from a timers hook) it is a plain `spawn`; other threads breach `spawn`'s contract.
/// No fiber is returned: the new one may be gone, and reused, by then.
pub fn spawn_first(sched: *Sched, io: Io, entry: Entry, arg: ?*anyopaque) SpawnError!void {
    if (!sched.has_free_fiber()) return error.FibersExhausted;
    if (sched.running and !sched.in_fiber()) {
        _ = try sched.spawn(entry, arg);
        return;
    }
    const fiber = sched.spawn_placed(entry, arg, .front) catch |err| switch (err) {
        error.FibersExhausted => unreachable, // `has_free_fiber` held and nothing ran since.
    };
    assert(sched.ready_head == fiber);
    if (sched.in_fiber()) {
        sched.yield();
    } else {
        assert(sched.first == null);
        assert(sched.current == null);
        sched.first = fiber;
        sched.run_loop(io, null);
        assert(sched.first == null);
    }
}
const Placement = enum { back, front };

fn spawn_placed(sched: *Sched, entry: Entry, arg: ?*anyopaque, place: Placement) SpawnError!*Fiber {
    const fiber = sched.free_head orelse return error.FibersExhausted;
    assert(fiber.state == .free);
    assert(fiber.arg == null);
    sched.free_head = fiber.queue_next;

    const top = @intFromPtr(fiber.stack.ptr) + fiber.stack.len;
    assert(top % stack_align == 0);
    const start_address = std.mem.alignBackward(usize, top - @sizeOf(Start), stack_align);
    const start: *Start = @ptrFromInt(start_address);
    start.* = .{ .sched = sched, .fiber = fiber, .entry = entry, .arg = arg };
    fiber.arg = arg;
    std.mem.writeInt(u64, fiber.stack[0..canary_size], canary_value, .little);
    // x86_64 enters `fiber_main` through a `jmp`, so the word below `Start` plays the return
    // address; zero ends a stack walk (aarch64 zeroes `x30` in `fiber_entry`).
    @as(*usize, @ptrFromInt(start_address - @sizeOf(usize))).* = 0;
    fiber.context = initial_context(start_address);

    sched.live_count += 1;
    if (place == .front) sched.push_front(fiber) else sched.push_ready(fiber);
    assert(fiber.state == .ready);
    return fiber;
}

/// True when the caller is a fiber running inside `run` (as opposed to the carrier loop or any
/// code outside `run`, on any thread). Total: valid in every state and from any thread.
pub fn in_fiber(sched: *const Sched) bool {
    if (!carrier_active) return false;
    if (sched.current) |fiber| {
        assert(fiber.state == .running);
        assert(sched.running);
        return true;
    }
    return false;
}

/// True while any socket readiness is armed in the poller (always false under `.futex`).
pub fn armed_any(sched: *const Sched) bool {
    return sched_io.armed_any(sched);
}

/// True when `spawn` would succeed, i.e. fewer than `fibers_max` fibers are alive.
pub fn has_free_fiber(sched: *const Sched) bool {
    assert(sched.live_count <= sched.fibers.len);
    const free = sched.free_head != null;
    assert(free == (sched.live_count < sched.fibers.len));
    return free;
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
/// carrier next drains the inbox, which happens after the fiber has switched out. The carrier is
/// woken from its idle sleep: through `io` (the baseline) under `.futex`, through the poller's
/// latched wake under `.poller`, where `io` is unused. Precondition: the fiber is running toward
/// `park` or already parked, and is named by at most one waker.
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
    switch (sched.idle) {
        .futex => {
            _ = @atomicRmw(u32, &sched.inbox_version, .Add, 1, .release);
            io.futexWake(u32, &sched.inbox_version, 1);
        },
        .poller => |*native| {
            // Proof: `idle_init` refuses `.poller` on a target without a poller.
            if (comptime evented.Native == void) unreachable;
            native.wake();
        },
    }
}

/// Runs fibers on the calling thread until none is alive. A fiber that parks with nothing else
/// runnable blocks the carrier in the idle sleep (futex or poller) until `unpark_foreign`
/// delivers it.
/// Precondition: not nested, and called from outside any fiber.
pub fn run(sched: *Sched, io: Io) void {
    sched.run_loop(io, null);
    assert(sched.live_count == 0);
    assert(sched.ready_head == null);
    assert(sched.parked_count == 0);
}

/// Like `run`, but returns as soon as `stop.*` is true after a fiber has switched out (or no fiber
/// is alive), leaving the other fibers alive for a later `run`/`run_until`. `stop` is written
/// only by fibers on this thread. Same preconditions as `run`.
pub fn run_until(sched: *Sched, io: Io, stop: *const bool) void {
    sched.run_loop(io, stop);
    if (!stop.*) assert(sched.live_count == 0);
}

fn run_loop(sched: *Sched, io: Io, stop: ?*const bool) void {
    assert(sched.current == null);
    assert(!sched.running);
    assert(!carrier_active);
    sched.running = true;
    carrier_active = true;
    defer {
        carrier_active = false;
        sched.running = false;
    }

    while (sched.live_count > 0) {
        if (stop) |flag| {
            if (flag.*) break;
        }
        const version = @atomicLoad(u32, &sched.inbox_version, .acquire);
        sched.inbox_drain();
        const deadline_ns = sleep.fire(sched, io);
        const fiber = sched.pop_ready() orelse {
            // Every live fiber is parked on a timer or on something another thread must deliver.
            assert(sched.parked_count == sched.live_count);
            sched.idle_wait(io, version, deadline_ns);
            continue;
        };
        fiber.state = .running;
        sched.current = fiber;
        switch_context(&sched.carrier_context, &fiber.context);
        assert(sched.current == null);
        sched.since_poll += 1;
        if (sched.since_poll >= sched.fibers.len) sched_io.poll_fair(sched);
        if (sched.first == fiber) {
            sched.first = null;
            break;
        }
    }
}

/// Blocks the carrier until a foreign wake or, when given, `deadline_ns` (`Clock.awake`) passes:
/// on `inbox_version` under `.futex` (`version` is the value read before the inbox drain), in
/// the poller under `.poller`. Returning early is fine: `run_loop` re-checks everything.
fn idle_wait(sched: *Sched, io: Io, version: u32, deadline_ns: ?i96) void {
    switch (sched.idle) {
        .futex => idle_wait_futex(&sched.inbox_version, io, version, deadline_ns),
        .poller => |*native| {
            // Proof: `idle_init` refuses `.poller` on a target without a poller.
            if (comptime evented.Native == void) unreachable;
            _ = native;
            assert(sched.inbox_version == 0);
            sched_io.idle_wait(sched, io, deadline_ns);
        },
    }
}

fn idle_wait_futex(word: *const u32, io: Io, version: u32, deadline_ns: ?i96) void {
    const at = deadline_ns orelse {
        return io.futexWaitUncancelable(u32, word, version);
    };
    const raw: Io.Timestamp = .fromNanoseconds(at);
    const timeout: Io.Timeout = .{ .deadline = .{ .raw = raw, .clock = .awake } };
    io.futexWaitTimeout(u32, word, version, timeout) catch |err| switch (err) {
        // The carrier is no `Io` task, so nothing can cancel it; looping again is harmless anyway.
        error.Canceled => {},
    };
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

fn push_front(sched: *Sched, fiber: *Fiber) void {
    assert((sched.ready_head == null) == (sched.ready_tail == null));
    fiber.state = .ready;
    fiber.queue_next = sched.ready_head;
    sched.ready_head = fiber;
    if (sched.ready_tail == null) sched.ready_tail = fiber;
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

fn canary_intact(stack: []const u8) bool {
    return std.mem.readInt(u64, stack[0..canary_size], .little) == canary_value;
}

/// Runs on the fiber's own stack; never returns, it switches to the carrier for good.
fn fiber_main(start: *Start) callconv(.withStackAlign(.c, @alignOf(Start))) noreturn {
    const sched = start.sched;
    const fiber = start.fiber;
    assert(sched.current == fiber);
    start.entry(start.arg);

    assert_always(canary_intact(fiber.stack));
    assert(fiber.state == .running);
    fiber.state = .free;
    fiber.arg = null;
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
/// only argument.
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
            \\ mov x30, xzr
            \\ b %[fiber_main]
            :
            : [fiber_main] "X" (&fiber_main),
        ),
        else => unreachable, // `supported` is false and `init` refused.
    }
}

fn test_options(fibers_max: u32, stack_size: u32) Options {
    return .{ .fibers_max = fibers_max, .stack_size = stack_size, .now_ns = 0, .idle = .futex };
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
    const options: Options = test_options(1, stack_size_min);
    try std.testing.expectError(
        error.FibersUnsupported,
        sched.init_checked(failing.allocator(), options, false),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}
