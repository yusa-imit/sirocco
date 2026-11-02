//! sirocco.batch — the native `batchAwaitAsync`, `batchAwaitConcurrent` and `batchCancel` slots
//! on fibers (plan 004 item 8, ADR 0003 section 2c), for a batch of `net_receive` operations on
//! registered sockets and `file_read_streaming` / `file_write_streaming` operations on files
//! whose `flags.nonblocking` says their caller made them non-blocking.
//!
//! Scope, stated as a subset: a batch is served here only when it is awaited on a fiber of an
//! evented runtime and EVERY submitted operation is one of the above (a `net_receive` with exactly
//! one message slot, on a socket the registry knows). Any other batch (a `device_io_control`, a
//! blocking file, an unregistered handle, several message slots, a CPU-time clock timeout, a call
//! off a fiber, `.threaded`) is forwarded whole to the embedded `Io.Threaded`, as v0.4.0 did.
//!
//! Purpose: a sweep (`src/batch_sweep.zig`) tries each operation once with the non-blocking
//! syscall `src/submit.zig` already has (`receive_once`, `file_read_once`, `file_write_once`) and
//! moves what completed onto the batch's `completed` list, writing the result through
//! `Io.Operation.Storage` as std's protocol requires. Results are `Io.Threaded`'s: the await
//! returns once at least one operation completed (also one that completed before the call); an
//! operation's own error is its result, only `error.Canceled` leaves through the await, and
//! `Timeout` is `Io.Timeout`'s.
//!
//! Waiting, two ways. A batch of nothing but `net_receive`s (at most `batch_park.ops_max` of them,
//! and no more than the free waiter nodes plus the fiber's own) PARKS (`src/batch_park.zig`, ADR
//! 0004 section 6): a node per operation joins its socket's waiter list, the deadline goes on the
//! wheel, and an idle wait makes no syscall until the first event. A batch that holds any file
//! operation is the fallback, `wait_sliced`: nonblocking files are not registry sockets, so there
//! is nothing for the poller to hold, and the fiber sleeps one wheel slice (50 us growing to 2 ms,
//! never past the deadline) and sweeps again. What the slice buys is the part of the contract that
//! matters on a single carrier: the carrier is never blocked, other fibers run, a cancel unparks
//! the sleeper, and the wait costs no allocation and no registration (so `ConcurrencyUnavailable`
//! never comes from here; `Io.Threaded` can return it because it may allocate). A batch whose
//! `net_receive`s need more nodes than the pool has, even one with files, is forwarded whole,
//! before any syscall.
//!
//! Cancelation: a request pending at entry is delivered before any syscall; one that arrives while
//! the fiber is parked or asleep ends it with `error.Canceled`. The operations stay submitted, and
//! `Batch.cancel` drops them. `batchCancel` has nothing of its own to release (no pending list, no
//! `userdata`) and forwards to the baseline only for a batch the baseline has served.
//!
//! Invariants: no allocation, no recursion, every loop bounded by `rounds_max` or the storage.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");
const concurrency = @import("concurrency.zig");
const batch_park = @import("batch_park.zig");
const batch_sweep = @import("batch_sweep.zig");
const sleep = @import("sleep.zig");

const Io = std.Io;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

/// Slice of one idle sleep in nanoseconds: it starts short for a quick answer and doubles to the
/// cap, so a long idle costs about 500 sweeps a second.
const slice_ns_min: i96 = 50_000;
const slice_ns_max: i96 = 2_000_000;

/// Sweeps per sliced await; at the 2 ms cap this is about 70 years, so the bound is never the exit.
const slice_rounds_max: u64 = 1 << 40;

/// A batch this runtime serves: the task that awaits it and how.
const Served = struct {
    task: *concurrency.Task,
    /// True when every operation is a `net_receive` and the nodes suffice: the parked wait.
    parked: bool,
};

fn slot_await_async(userdata: ?*anyopaque, b: *Io.Batch) Io.Cancelable!void {
    const rt = concurrency.runtime_of(userdata);
    const served = served_task(rt, b) orelse {
        const baseline = rt.baselineIo();
        return baseline.vtable.batchAwaitAsync(baseline.userdata, b);
    };
    wait(rt, served, b, .none) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        // Proof: `.none` has no deadline and `wait` never refuses for want of resources.
        error.Timeout, error.ConcurrencyUnavailable => unreachable,
    };
}

fn slot_await_concurrent(
    userdata: ?*anyopaque,
    b: *Io.Batch,
    timeout: Io.Timeout,
) Io.Batch.AwaitConcurrentError!void {
    const rt = concurrency.runtime_of(userdata);
    const served = served_task(rt, b);
    if (served == null or !sleep.on_wall_wheel(timeout)) {
        const baseline = rt.baselineIo();
        return baseline.vtable.batchAwaitConcurrent(baseline.userdata, b, timeout);
    }
    return wait(rt, served.?, b, timeout);
}

fn slot_cancel(userdata: ?*anyopaque, b: *Io.Batch) void {
    const rt = concurrency.runtime_of(userdata);
    assert(b.submitted.head == .none); // `Batch.cancel` emptied it before calling.
    // Nothing native holds a resource; only a batch the baseline served can.
    if (b.userdata == null and b.pending.head == .none) return;
    const baseline = rt.baselineIo();
    baseline.vtable.batchCancel(baseline.userdata, b);
}

/// How this runtime serves `b`, null when it goes whole to the baseline. The node count is checked
/// here, before any syscall: the parked wait needs a waiter node per `net_receive`, the fiber's own
/// plus the free spares.
fn served_task(rt: *Runtime, b: *const Io.Batch) ?Served {
    assert(b.storage.len > 0);
    if (rt.sched_state != .ready or !rt.sockets.enabled()) return null;
    const task = concurrency.current_task(rt) orelse return null;
    if (b.pending.head != .none) return null;

    var sockets: u32 = 0;
    var files: u32 = 0;
    var index = b.submitted.head;
    for (0..b.storage.len) |_| {
        if (index == .none) break;
        const submission = &b.storage[index.toIndex()].submission;
        if (!op_served(rt, submission.operation)) return null;
        switch (submission.operation) {
            .net_receive => sockets += 1,
            .file_read_streaming, .file_write_streaming => files += 1,
            .device_io_control => unreachable, // Proof: `op_served` refused it.
        }
        index = submission.node.next;
    }
    assert_always(index == .none); // A longer list than the storage is corrupt.
    if (sockets > batch_park.ops_max) return null;
    if (sockets > rt.sched.waiters_free() + 1) return null;
    return .{ .task = task, .parked = files == 0 };
}

fn op_served(rt: *Runtime, operation: Io.Operation) bool {
    assert(rt.sockets.enabled());
    return switch (operation) {
        .net_receive => |o| one: {
            if (o.message_buffer.len != 1) break :one false;
            break :one rt.sockets.lookup(o.socket_handle) != null;
        },
        .file_read_streaming => |o| o.file.flags.nonblocking,
        .file_write_streaming => |o| o.file.flags.nonblocking,
        .device_io_control => false,
    };
}

fn wait(
    rt: *Runtime,
    served: Served,
    b: *Io.Batch,
    timeout: Io.Timeout,
) Io.Batch.AwaitConcurrentError!void {
    assert(rt.sched.in_fiber());
    assert(sleep.on_wall_wheel(timeout));
    if (served.parked) return batch_park.wait(rt, served.task, b, timeout);
    return wait_sliced(rt, served.task, b, timeout);
}

/// The wait of a batch that holds a file operation: sweep, sleep a wheel slice, sweep again.
fn wait_sliced(
    rt: *Runtime,
    task: *concurrency.Task,
    b: *Io.Batch,
    timeout: Io.Timeout,
) Io.Batch.AwaitConcurrentError!void {
    assert(rt.sched.in_fiber());
    assert(sleep.on_wall_wheel(timeout));
    if (b.submitted.head == .none) return; // Nothing to wait for; a cancel stays pending.
    if (concurrency.task_acknowledge_cancel(task)) return error.Canceled;

    const limit = sleep.limit_of(rt, timeout);
    var slice_ns: i96 = slice_ns_min;
    for (0..slice_rounds_max) |_| {
        batch_sweep.sweep(rt, b);
        if (b.completed.head != .none or b.submitted.head == .none) return;

        const nap_ns: i96 = switch (limit) {
            .forever => slice_ns,
            .expired => return error.Timeout,
            .at => |deadline_ns| remaining: {
                const left_ns = deadline_ns - Io.Clock.awake.now(rt.baselineIo()).nanoseconds;
                if (left_ns <= 0) return error.Timeout;
                break :remaining @min(slice_ns, left_ns);
            },
        };
        const duration: Io.Duration = .fromNanoseconds(nap_ns);
        rt.io().sleep(duration, .awake) catch return error.Canceled;
        slice_ns = @min(slice_ns * 2, slice_ns_max);
    }
    assert_always(false); // 2^40 sweeps of at least 50 us each is not a wait, it is a hang.
}

/// Overwrites the three batch slots of `vtable`. Precondition: `Sched.supported`, `vtable` holds
/// the baseline's functions (the fallbacks call the baseline directly).
pub fn install(vtable: *Io.VTable) void {
    assert(Sched.supported);
    assert(vtable.batchAwaitAsync != slot_await_async);
    vtable.batchAwaitAsync = slot_await_async;
    vtable.batchAwaitConcurrent = slot_await_concurrent;
    vtable.batchCancel = slot_cancel;
}

/// The slots this file replaces.
pub fn is_native(comptime name: []const u8) bool {
    return comptime std.mem.eql(u8, name, "batchAwaitAsync") or
        std.mem.eql(u8, name, "batchAwaitConcurrent") or
        std.mem.eql(u8, name, "batchCancel");
}
