//! sirocco.batch_sweep — the one-shot attempt at a batch's operations, shared by the parked wait
//! (`src/batch_park.zig`) and the sliced wait (`src/batch.zig`), plus the list surgery that moves a
//! finished operation from `submitted` to `completed`.
//!
//! Purpose: `sweep` tries each submitted operation once with the non-blocking syscall
//! `src/submit.zig` has (`receive_once`, `file_read_once`, `file_write_once`) and completes what
//! finished, writing the result through `Io.Operation.Storage` as std's protocol requires.
//!
//! Invariants: no allocation, no clock, no suspension. Every loop is bounded by the batch storage,
//! and a list longer than the storage is corrupt (`assert_always`).

const std = @import("std");
const stdx = @import("stdx.zig");
const Runtime = @import("runtime.zig");
const submit = @import("submit.zig");
const sys = @import("backend/sys.zig");

const Io = std.Io;
const posix = std.posix;
const assert = stdx.assert;
const assert_always = stdx.assert_always;
const OptionalIndex = Io.Operation.OptionalIndex;
const NetReceive = Io.Operation.NetReceive;

/// Tries every submitted operation once; the ones that finished move to `completed`, in order.
/// `rt` is null only for a batch of files, which the registry does not own (unit tests).
pub fn sweep(rt: ?*Runtime, b: *Io.Batch) void {
    assert(b.storage.len > 0);
    var prev: OptionalIndex = .none;
    var index = b.submitted.head;
    for (0..b.storage.len) |_| {
        if (index == .none) break;
        const storage = &b.storage[index.toIndex()];
        const next = storage.submission.node.next;
        if (try_once(rt, storage.submission.operation)) |result| {
            unlink_submitted(b, prev, index, next);
            complete(b, index, result);
        } else prev = index;
        index = next;
    }
    assert_always(index == .none); // A longer list than the storage is corrupt.
}

/// One attempt at `operation`: its result, or null when it would block.
pub fn try_once(rt: ?*Runtime, operation: Io.Operation) ?Io.Operation.Result {
    switch (operation) {
        .net_receive => |o| {
            // A socket closed while the batch idled must not be read: its fd may be reused. The
            // registry is the truth, as for a parked `receive` (`SocketUnconnected`).
            assert(o.message_buffer.len == 1); // `op_served` refused anything else.
            if (rt.?.sockets.lookup(o.socket_handle) == null) {
                const closed: NetReceive.Result = .{ error.SocketUnconnected, 0 };
                return .{ .net_receive = closed };
            }
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

/// Takes `index` off the `submitted` list; `prev` is its predecessor (`.none` for the head).
pub fn unlink_submitted(
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

/// Appends `index` to `completed`, overwriting its storage with the completion `result`.
pub fn complete(b: *Io.Batch, index: OptionalIndex, result: Io.Operation.Result) void {
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

    sweep(null, &batch);
    try std.testing.expectEqual(OptionalIndex.fromIndex(1), batch.submitted.head);
    try std.testing.expectEqual(OptionalIndex.fromIndex(1), batch.submitted.tail);
    try std.testing.expectEqual(@as(u32, 0), batch.next().?.index);
    try std.testing.expectEqual(@as(u32, 2), batch.next().?.index);
    try std.testing.expect(batch.next() == null);

    try std.testing.expect(posix.system.write(fds[1], "x", 1) == 1);
    sweep(null, &batch);
    try std.testing.expect(batch.submitted.head == .none);
    const done = batch.next().?;
    try std.testing.expectEqual(@as(u32, 1), done.index);
    try std.testing.expectEqual(@as(usize, 1), try done.result.file_read_streaming);
}
