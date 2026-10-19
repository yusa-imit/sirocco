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
//! Purpose: one sweep tries each operation once with the non-blocking syscall `src/submit.zig`
//! already has (`receive_once`, `file_read_once`, `file_write_once`) and moves what completed
//! onto the batch's `completed` list, writing the result through `Io.Operation.Storage` as std's
//! protocol requires. Results are `Io.Threaded`'s: the await returns once at least one operation
//! completed (also one that completed before the call); an operation's own error is its result,
//! only `error.Canceled` leaves through the await, and `Timeout` is `Io.Timeout`'s.
//!
//! Waiting: when a sweep completes nothing the fiber sleeps one wheel slice (50 us growing to 2
//! ms, never past the deadline) and sweeps again. This is a deliberate limit: a fiber can sit on
//! one waiter list only, so waiting on N sockets at the same instant through the poller would
//! need a per-operation waiter node in the registry. What the slice buys is the part of the
//! contract that matters on a single carrier: the carrier is never blocked, other fibers run, a
//! cancel unparks the sleeper, and the wait costs no allocation and no registration (so
//! `ConcurrencyUnavailable` never comes from here; `Io.Threaded` can return it because it may
//! allocate). An idle wait costs one `recvmsg` per operation per slice.
//!
//! Cancelation: a request pending at entry is delivered before any syscall; one that arrives in
//! a sleep ends it with `error.Canceled`. The operations stay submitted, and `Batch.cancel` drops
//! them. `batchCancel` has nothing of its own to release (no pending list, no `userdata`) and
//! forwards to the baseline only for a batch the baseline has served.
//!
//! Invariants: no allocation, no recursion, every loop bounded by `rounds_max` or the storage.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");
const concurrency = @import("concurrency.zig");
const sleep = @import("sleep.zig");
const submit = @import("submit.zig");
const sys = @import("backend/sys.zig");

const Io = std.Io;
const posix = std.posix;
const assert = stdx.assert;
const assert_always = stdx.assert_always;
const OptionalIndex = Io.Operation.OptionalIndex;

/// Slice of one idle sleep in nanoseconds: it starts short for a quick answer and doubles to the
/// cap, so a long idle costs about 500 sweeps a second.
const slice_ns_min: i96 = 50_000;
const slice_ns_max: i96 = 2_000_000;

/// Sweeps per await; at the 2 ms cap this is over 70 years, so the bound is never the exit.
const rounds_max: u64 = 1 << 40;

fn slot_await_async(userdata: ?*anyopaque, b: *Io.Batch) Io.Cancelable!void {
    const rt = concurrency.runtime_of(userdata);
    const task = served_task(rt, b) orelse {
        const baseline = rt.baselineIo();
        return baseline.vtable.batchAwaitAsync(baseline.userdata, b);
    };
    wait(rt, task, b, .none) catch |err| switch (err) {
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
    const task = served_task(rt, b);
    if (task == null or !sleep.on_wall_wheel(timeout)) {
        const baseline = rt.baselineIo();
        return baseline.vtable.batchAwaitConcurrent(baseline.userdata, b, timeout);
    }
    return wait(rt, task.?, b, timeout);
}

fn slot_cancel(userdata: ?*anyopaque, b: *Io.Batch) void {
    const rt = concurrency.runtime_of(userdata);
    assert(b.submitted.head == .none); // `Batch.cancel` emptied it before calling.
    // Nothing native holds a resource; only a batch the baseline served can.
    if (b.userdata == null and b.pending.head == .none) return;
    const baseline = rt.baselineIo();
    baseline.vtable.batchCancel(baseline.userdata, b);
}

/// The current task when this runtime serves `b` natively, null when it goes to the baseline.
fn served_task(rt: *Runtime, b: *const Io.Batch) ?*concurrency.Task {
    assert(b.storage.len > 0);
    if (rt.sched_state != .ready or !rt.sockets.enabled()) return null;
    const task = concurrency.current_task(rt) orelse return null;
    if (b.pending.head != .none) return null;

    var index = b.submitted.head;
    for (0..b.storage.len) |_| {
        if (index == .none) break;
        const submission = &b.storage[index.toIndex()].submission;
        if (!op_served(rt, submission.operation)) return null;
        index = submission.node.next;
    }
    assert_always(index == .none); // A longer list than the storage is corrupt.
    return task;
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
    task: *concurrency.Task,
    b: *Io.Batch,
    timeout: Io.Timeout,
) Io.Batch.AwaitConcurrentError!void {
    assert(rt.sched.in_fiber());
    assert(sleep.on_wall_wheel(timeout));
    if (concurrency.task_acknowledge_cancel(task)) return error.Canceled;

    const limit = sleep.limit_of(rt, timeout);
    var slice_ns: i96 = slice_ns_min;
    for (0..rounds_max) |_| {
        sweep(b);
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

/// Tries every submitted operation once; the ones that finished move to `completed`, in order.
fn sweep(b: *Io.Batch) void {
    assert(b.storage.len > 0);
    var prev: OptionalIndex = .none;
    var index = b.submitted.head;
    for (0..b.storage.len) |_| {
        if (index == .none) break;
        const storage = &b.storage[index.toIndex()];
        const next = storage.submission.node.next;
        if (try_once(storage.submission.operation)) |result| {
            unlink_submitted(b, prev, index, next);
            complete(b, index, result);
        } else prev = index;
        index = next;
    }
    assert_always(index == .none); // A longer list than the storage is corrupt.
}

fn try_once(operation: Io.Operation) ?Io.Operation.Result {
    switch (operation) {
        .net_receive => |o| {
            const result = submit.receive_once(o) catch return null;
            return .{ .net_receive = result };
        },
        .file_read_streaming => |o| {
            const result = submit.file_read_once(o) catch return null;
            return .{ .file_read_streaming = result };
        },
        .file_write_streaming => |o| {
            const result = submit.file_write_once(o) catch return null;
            return .{ .file_write_streaming = result };
        },
        .device_io_control => unreachable, // Proof: `op_served` refuses it.
    }
}

fn unlink_submitted(
    b: *Io.Batch,
    prev: OptionalIndex,
    index: OptionalIndex,
    next: OptionalIndex,
) void {
    assert(index != .none);
    assert(prev != index);
    switch (prev) {
        .none => b.submitted.head = next,
        else => b.storage[prev.toIndex()].submission.node.next = next,
    }
    if (next == .none) b.submitted.tail = prev;
}

fn complete(b: *Io.Batch, index: OptionalIndex, result: Io.Operation.Result) void {
    assert(index != .none);
    switch (b.completed.tail) {
        .none => b.completed.head = index,
        else => |tail| b.storage[tail.toIndex()].completion.node.next = index,
    }
    const completion: Io.Operation.Storage.Completion = .{
        .node = .{ .next = .none },
        .result = result,
    };
    b.storage[index.toIndex()] = .{ .completion = completion };
    b.completed.tail = index;
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

test "the sweep moves finished operations to completed in order and keeps the rest submitted" {
    var fds: [2]sys.fd_t = undefined;
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(posix.system.pipe(&fds)));
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    try sys.blocking_set(fds[0], false);
    const reader: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = true } };
    const writer: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = true } };
    var byte: [1]u8 = undefined;
    var buffers = [_][]u8{&byte};
    // An empty write completes with 0 and never reaches the descriptor; an empty pipe blocks.
    const empty_write: Io.Operation = .{ .file_write_streaming = .{
        .file = writer,
        .header = &.{},
        .data = &[_][]const u8{&.{}},
        .splat = 1,
    } };
    var storage: [3]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    try std.testing.expectEqual(@as(u32, 0), batch.add(empty_write));
    try std.testing.expectEqual(@as(u32, 1), batch.add(.{ .file_read_streaming = .{
        .file = reader,
        .data = &buffers,
    } }));
    try std.testing.expectEqual(@as(u32, 2), batch.add(empty_write));

    sweep(&batch);
    try std.testing.expectEqual(OptionalIndex.fromIndex(1), batch.submitted.head);
    try std.testing.expectEqual(OptionalIndex.fromIndex(1), batch.submitted.tail);
    try std.testing.expectEqual(@as(u32, 0), batch.next().?.index);
    try std.testing.expectEqual(@as(u32, 2), batch.next().?.index);
    try std.testing.expect(batch.next() == null);

    try std.testing.expect(posix.system.write(fds[1], "x", 1) == 1);
    sweep(&batch);
    try std.testing.expect(batch.submitted.head == .none);
    const done = batch.next().?;
    try std.testing.expectEqual(@as(u32, 1), done.index);
    try std.testing.expectEqual(@as(usize, 1), try done.result.file_read_streaming);
}
