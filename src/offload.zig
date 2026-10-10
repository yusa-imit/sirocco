//! sirocco.Offload — a bounded thread pool that runs a blocking call for a parked fiber
//! (plan 003 item 7, ADR 0002).
//!
//! Purpose: the forwarded `dir*`/`file*`/`net*` slots block their thread inside the kernel, and
//! the one carrier thread runs every fiber, so one such call freezes them all. `call` hands the
//! call to a worker thread, parks the calling fiber, and the worker wakes it through
//! `Sched.unpark_foreign` when the call returns; the carrier keeps running other fibers meanwhile.
//!
//! Invariants: `threads_count` workers are spawned in `init` and joined in `deinit`; nothing
//! else creates a thread. A request record lives on the parked fiber's stack, so the queue links
//! stack memory and is bounded by the fibers alive (`queued_max` is `fibers_max`: a fiber has at
//! most one request). Workers never call `rt.io()` and never run on the carrier, so
//! `Sched.in_fiber` is false on them and a blocking call inside a job cannot re-enter the
//! scheduler. The queue is FIFO behind a spinlock whose critical sections are a handful of
//! pointer writes. A job cannot be interrupted once submitted; cancelation is checked by the
//! caller before `call` (ADR 0001 lets a started call complete).
//!
//! Sizing rule: a job holds its worker until it returns. A job that waits for another job on the
//! same pool (an accept waiting on a connect) deadlocks when `threads_count` is smaller than the
//! jobs that wait on each other, so size the pool for the blocking calls expected in flight.
//!
//! Allocation: `init` allocates the thread handles (one block) from `gpa` and nothing else;
//! `Offload` stores no allocator, `deinit` takes the same `gpa` back. `call` allocates nothing.
//!
//! Sketch: one `call` is one lock round trip, one futex wake, one park, and on the worker one
//! lock round trip, the job, one atomic store and one `unpark_foreign` (a Treiber push plus a
//! futex wake): two syscalls on the carrier-visible path, which is why only calls that block for
//! microseconds or more are worth offloading.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");

const Io = std.Io;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

const Offload = @This();

threads: []std.Thread,
/// Workers spawned so far; equals `threads.len` once `init` returned.
spawned_count: u32,
/// The baseline `Io` (the embedded `Io.Threaded`): futex waits and wakes on the pool's word and
/// the scheduler's inbox word go through it, never through the runtime's own vtable.
io: Io,
sched: *Sched,
/// Futex mutex word: 0 free, 1 held, 2 held with a sleeper. Guards `head`, `tail`,
/// `queued_count` and `closing`.
lock: u32,
head: ?*Request,
tail: ?*Request,
queued_count: u32,
queued_max: u32,
closing: bool,
/// Futex word workers sleep on; bumped after every push and at close.
version: u32,

pub const Options = struct {
    /// Worker threads, spawned in `init`; positive.
    threads_count: u32,
    /// Requests that may be queued at once: the fibers that can be parked in `call`; positive.
    queued_max: u32,
};

pub const InitError = error{ OutOfMemory, ThreadSpawnFailed };

/// A blocking call to run on a worker. Must not touch the scheduler or call `rt.io()`.
pub const Job = *const fn (context: ?*anyopaque) void;

/// One submitted call; lives on the stack of the fiber parked in `call`.
const Request = struct {
    next: ?*Request,
    job: Job,
    context: ?*anyopaque,
    fiber: *Sched.Fiber,
    /// Set by the worker with release order before it wakes the fiber.
    done: bool,
};

/// Futex waits `acquire` may take before it gives up: a critical section is a few pointer writes,
/// so a lock still held after this many wake-ups has leaked.
const wait_max: u32 = 1 << 20;

/// Fills `target` in place and spawns the workers. Preconditions: `options` fields are positive,
/// `io` is the baseline `Io` of the runtime that owns `sched`, and `sched` outlives the pool and
/// does not move. On error nothing is left running or allocated.
pub fn init(
    target: *Offload,
    gpa: std.mem.Allocator,
    io: Io,
    sched: *Sched,
    options: Options,
) InitError!void {
    return init_spawning(target, gpa, io, sched, options, spawn_worker);
}

fn spawn_worker(pool: *Offload) std.Thread.SpawnError!std.Thread {
    return std.Thread.spawn(.{}, worker_main, .{pool});
}

// Split out so `ThreadSpawnFailed` is provokable: `spawn` is the seam tests replace.
fn init_spawning(
    target: *Offload,
    gpa: std.mem.Allocator,
    io: Io,
    sched: *Sched,
    options: Options,
    comptime spawn: fn (pool: *Offload) std.Thread.SpawnError!std.Thread,
) InitError!void {
    assert(options.threads_count > 0);
    assert(options.queued_max > 0);

    const threads = try gpa.alloc(std.Thread, options.threads_count);
    errdefer gpa.free(threads);

    target.* = .{
        .threads = threads,
        .spawned_count = 0,
        .io = io,
        .sched = sched,
        .lock = 0,
        .head = null,
        .tail = null,
        .queued_count = 0,
        .queued_max = options.queued_max,
        .closing = false,
        .version = 0,
    };
    errdefer target.stop_workers();
    for (threads) |*thread| {
        thread.* = spawn(target) catch return error.ThreadSpawnFailed;
        target.spawned_count += 1;
    }
    assert(target.spawned_count == threads.len);
}

/// Stops and joins every worker, then frees the handles. Preconditions: `gpa` is the allocator
/// given to `init`, and no fiber is parked in `call` (the queue is empty).
pub fn deinit(pool: *Offload, gpa: std.mem.Allocator) void {
    assert(pool.queued_count == 0);
    assert(pool.head == null);
    pool.stop_workers();
    gpa.free(pool.threads);
    pool.* = undefined;
}

fn stop_workers(pool: *Offload) void {
    assert(pool.spawned_count <= pool.threads.len);
    pool.acquire();
    assert(!pool.closing);
    pool.closing = true;
    pool.release();
    _ = @atomicRmw(u32, &pool.version, .Add, 1, .release);
    pool.io.futexWake(u32, &pool.version, pool.spawned_count);
    for (pool.threads[0..pool.spawned_count]) |thread| thread.join();
    pool.spawned_count = 0;
}

/// Runs `job(context)` on a worker thread and returns when it has returned, with the calling
/// fiber parked meanwhile so the carrier runs the others. Preconditions: called from a fiber of
/// `pool.sched`, fewer than `queued_max` fibers are parked here (true when `queued_max` is
/// `fibers_max`), and the job never blocks on a fiber (a worker is no fiber).
pub fn call(pool: *Offload, job: Job, context: ?*anyopaque) void {
    assert(pool.sched.in_fiber());
    var request: Request = .{
        .next = null,
        .job = job,
        .context = context,
        .fiber = pool.sched.current_fiber(),
        .done = false,
    };
    pool.acquire();
    assert_always(pool.queued_count < pool.queued_max);
    assert_always(!pool.closing);
    if (pool.tail) |tail| {
        assert(tail.next == null);
        tail.next = &request;
    } else {
        assert(pool.head == null);
        pool.head = &request;
    }
    pool.tail = &request;
    pool.queued_count += 1;
    pool.release();

    _ = @atomicRmw(u32, &pool.version, .Add, 1, .release);
    pool.io.futexWake(u32, &pool.version, 1);
    // The worker may finish before this fiber parks; `unpark_foreign` allows exactly that.
    pool.sched.park();
    assert_always(@atomicLoad(bool, &request.done, .acquire));
}

/// A futex mutex rather than a spinlock: a worker preempted inside a critical section must not
/// make the carrier burn CPU, and the carrier is the one thread that cannot afford to.
fn acquire(pool: *Offload) void {
    if (@cmpxchgStrong(u32, &pool.lock, 0, 1, .acquire, .monotonic) == null) return;
    for (0..wait_max) |_| {
        // Mark contended; if it was free we own it (a later release may wake nobody, harmlessly).
        if (@atomicRmw(u32, &pool.lock, .Xchg, 2, .acquire) == 0) return;
        pool.io.futexWaitUncancelable(u32, &pool.lock, 2);
    }
    assert_always(false); // A critical section is a few dozen steps: the lock leaked.
}

fn release(pool: *Offload) void {
    const held = @atomicRmw(u32, &pool.lock, .Xchg, 0, .release);
    assert(held == 1 or held == 2);
    if (held == 2) pool.io.futexWake(u32, &pool.lock, 1);
}

/// The next request, or null; sets `closed` when the pool is closing and the queue is empty.
fn pop(pool: *Offload, closed: *bool) ?*Request {
    pool.acquire();
    defer pool.release();

    const request = pool.head orelse {
        assert(pool.tail == null);
        assert(pool.queued_count == 0);
        closed.* = pool.closing;
        return null;
    };
    pool.head = request.next;
    if (pool.head == null) pool.tail = null;
    pool.queued_count -= 1;
    request.next = null;
    return request;
}

fn worker_main(pool: *Offload) void {
    // A worker is neither the carrier nor a fiber, so a job cannot re-enter the scheduler.
    assert(!pool.sched.in_fiber());
    // A worker's loop is the top-level event loop of its thread; it ends only through `closed`.
    while (true) {
        // Read before the pop: a push after the pop bumps the word and the wait returns at once.
        const seen = @atomicLoad(u32, &pool.version, .acquire);
        var closed = false;
        const request = pool.pop(&closed) orelse {
            if (closed) return;
            pool.io.futexWaitUncancelable(u32, &pool.version, seen);
            continue;
        };
        request.job(request.context);
        assert(!pool.sched.in_fiber());
        // `request` belongs to the fiber's stack and may vanish once the fiber runs again.
        const fiber = request.fiber;
        @atomicStore(bool, &request.done, true, .release);
        pool.sched.unpark_foreign(pool.io, fiber);
    }
}

// Tests build a scheduler plus a pool and run fibers on the test thread (the carrier).

const ns_per_ms: i96 = 1_000_000;

fn test_sched_options(fibers_max: u32) Sched.Options {
    return .{ .fibers_max = fibers_max, .stack_size = 64 * 1024, .now_ns = 0 };
}

const TestRun = struct {
    sched: Sched,
    pool: Offload,
    /// Jobs finished, in completion order.
    done_order: [32]u32,
    done_count: u32,
    job_ms: i64,
    carrier_thread: std.Thread.Id,
    off_carrier: u32,
    /// Jobs inside `test_job` right now, and the most there ever were at once.
    in_flight: u32,
    in_flight_peak: u32,
};

const TestCall = struct { run: *TestRun, id: u32 };

fn test_job(context: ?*anyopaque) void {
    const slot: *TestCall = @ptrCast(@alignCast(context.?));
    const run = slot.run;
    const now_in_flight = @atomicRmw(u32, &run.in_flight, .Add, 1, .acq_rel) + 1;
    _ = @atomicRmw(u32, &run.in_flight_peak, .Max, now_in_flight, .monotonic);
    defer _ = @atomicRmw(u32, &run.in_flight, .Sub, 1, .acq_rel);
    if (run.job_ms > 0) {
        // A private futex word nobody wakes is a timer; `Io.sleep` on `Io.Threaded` serializes
        // concurrent sleepers on this host, which would hide the overlap under test.
        var word: u32 = 0;
        const timeout: Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(run.job_ms),
            .clock = .awake,
        } };
        std.testing.io.futexWaitTimeout(u32, &word, 0, timeout) catch {};
    }
    if (std.Thread.getCurrentId() != run.carrier_thread) {
        _ = @atomicRmw(u32, &run.off_carrier, .Add, 1, .monotonic);
    }
    const index = @atomicRmw(u32, &run.done_count, .Add, 1, .monotonic);
    run.done_order[index] = slot.id;
}

fn test_caller(arg: ?*anyopaque) void {
    const slot: *TestCall = @ptrCast(@alignCast(arg.?));
    slot.run.pool.call(test_job, slot);
}

fn test_run_init(
    run: *TestRun,
    gpa: std.mem.Allocator,
    fibers_max: u32,
    threads_count: u32,
    job_ms: i64,
) !void {
    try run.sched.init(gpa, test_sched_options(fibers_max));
    errdefer run.sched.deinit(gpa);
    try run.pool.init(gpa, std.testing.io, &run.sched, .{
        .threads_count = threads_count,
        .queued_max = fibers_max,
    });
    run.done_order = @splat(0);
    run.done_count = 0;
    run.job_ms = job_ms;
    run.carrier_thread = std.Thread.getCurrentId();
    run.off_carrier = 0;
    run.in_flight = 0;
    run.in_flight_peak = 0;
}

fn test_run_deinit(run: *TestRun, gpa: std.mem.Allocator) void {
    run.pool.deinit(gpa);
    run.sched.deinit(gpa);
}

fn test_spawn_callers(run: *TestRun, slots: []TestCall) !void {
    for (slots, 0..) |*slot, id| {
        slot.* = .{ .run = run, .id = @intCast(id) };
        _ = try run.sched.spawn(test_caller, slot);
    }
}

test "fibers_max fibers each offload a 20 ms job and the jobs overlap in flight" {
    if (!Sched.supported) return error.SkipZigTest;
    var run: TestRun = undefined;
    try test_run_init(&run, std.testing.allocator, 16, 16, 20);
    defer test_run_deinit(&run, std.testing.allocator);

    var slots: [16]TestCall = undefined;
    try test_spawn_callers(&run, &slots);
    run.sched.run(std.testing.io);

    try std.testing.expectEqual(@as(u32, 16), run.done_count);
    try std.testing.expectEqual(@as(u32, 16), run.off_carrier);
    try std.testing.expectEqual(@as(u32, 0), run.in_flight);
    // A serial pool never has two jobs in flight; the wall clock is deliberately not asserted.
    try std.testing.expect(run.in_flight_peak >= 2);
}

test "one worker serves more fibers than threads, in submission order" {
    if (!Sched.supported) return error.SkipZigTest;
    var run: TestRun = undefined;
    try test_run_init(&run, std.testing.allocator, 6, 1, 0);
    defer test_run_deinit(&run, std.testing.allocator);

    var slots: [6]TestCall = undefined;
    try test_spawn_callers(&run, &slots);
    run.sched.run(std.testing.io);

    try std.testing.expectEqual(@as(u32, 6), run.done_count);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, run.done_order[0..6]);
}

test "init allocates the thread handles once and call allocates nothing" {
    if (!Sched.supported) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var run: TestRun = undefined;
    try run.sched.init(gpa, test_sched_options(4));
    defer run.sched.deinit(gpa);

    const allocs_before = failing.alloc_index;
    try run.pool.init(gpa, std.testing.io, &run.sched, .{ .threads_count = 2, .queued_max = 4 });
    defer run.pool.deinit(gpa);
    try std.testing.expectEqual(allocs_before + 1, failing.alloc_index);

    run.done_order = @splat(0);
    run.done_count = 0;
    run.job_ms = 0;
    run.carrier_thread = std.Thread.getCurrentId();
    run.off_carrier = 0;
    run.in_flight = 0;
    run.in_flight_peak = 0;
    var slots: [4]TestCall = undefined;
    try test_spawn_callers(&run, &slots);
    run.sched.run(std.testing.io);
    try std.testing.expectEqual(@as(u32, 4), run.done_count);
    try std.testing.expectEqual(allocs_before + 1, failing.alloc_index);
}

test "deinit wakes and joins workers that are idle on the futex word" {
    if (!Sched.supported) return error.SkipZigTest;
    var run: TestRun = undefined;
    try test_run_init(&run, std.testing.allocator, 2, 3, 0);
    // Workers are blocked on the futex word with nothing queued; deinit must wake and join them.
    try std.testing.expectEqual(@as(u32, 3), run.pool.spawned_count);
    try std.testing.expectEqual(@as(u32, 0), run.pool.queued_count);
    test_run_deinit(&run, std.testing.allocator);
}

test "init reports allocation failure and frees nothing it did not take" {
    if (!Sched.supported) return error.SkipZigTest;
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, test_sched_options(1));
    defer sched.deinit(std.testing.allocator);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var pool: Offload = undefined;
    const options: Options = .{ .threads_count = 1, .queued_max = 1 };
    try std.testing.expectError(
        error.OutOfMemory,
        pool.init(failing.allocator(), std.testing.io, &sched, options),
    );
}

// Tests run one at a time, so a global is a safe way to steer the spawn seam.
var test_spawn_budget: u32 = 0;

fn test_spawn_limited(pool: *Offload) std.Thread.SpawnError!std.Thread {
    if (test_spawn_budget == 0) return error.SystemResources;
    test_spawn_budget -= 1;
    return spawn_worker(pool);
}

test "init reports ThreadSpawnFailed and joins the workers it started" {
    if (!Sched.supported) return error.SkipZigTest;
    var sched: Sched = undefined;
    try sched.init(std.testing.allocator, test_sched_options(1));
    defer sched.deinit(std.testing.allocator);

    var pool: Offload = undefined;
    const options: Options = .{ .threads_count = 3, .queued_max = 1 };
    test_spawn_budget = 2;
    try std.testing.expectError(
        error.ThreadSpawnFailed,
        pool.init_spawning(
            std.testing.allocator,
            std.testing.io,
            &sched,
            options,
            test_spawn_limited,
        ),
    );
    try std.testing.expectEqual(@as(u32, 0), test_spawn_budget);
}
