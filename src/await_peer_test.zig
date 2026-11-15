//! Tests of `Io.Future.await` called from a fiber on a peer carrier (ADR 0004 section 3, plan 005
//! item 7): the awaiter registers in the join word, parks on its own carrier and is resumed
//! there by the finisher on carrier 0, whether the task finished before or after the await.
//! Built on `.threaded` and `.auto` so both idle paths cover the peer threads.

const std = @import("std");
const Runtime = @import("runtime.zig");
const Sched = @import("sched.zig");
const mail = @import("mail.zig");
const join = @import("join.zig");
const concurrency = @import("concurrency.zig");

const Io = std.Io;
const assert = @import("stdx.zig").assert;

const spin_max: u32 = 20_000_000;
const peers_count: u32 = 3;

fn options(backend: Runtime.Backend) Runtime.Options {
    return .{
        .backend = backend,
        .unimplemented = .forward,
        .environ = .empty,
        .argv0 = .empty,
        .carriers = peers_count + 1,
        .fibers_max = 4,
        .batch_ops_max = 8,
        .fiber_stack_size = 128 * 1024,
        .offload_threads = 2,
        .sockets_max = 8,
    };
}

/// Sleeps first, so the task is parked on carrier 0 (not finished) when `async` returns.
fn add_slowly(io: Io, a: u32, b: u32) u32 {
    io.sleep(.fromMilliseconds(5), .awake) catch return 0;
    return a + b;
}

const Case = struct {
    rt: *Runtime,
    future: *Io.Future(u32),
    peer: *Sched,
    result: u32,
    on_home: bool,
    resumed: std.atomic.Value(bool),
    stop: bool,
    mail: mail.Mail,
};

/// Fiber body mailed to a peer: awaits the future there, then lets the driver return.
fn entry_awaiter(arg: ?*anyopaque) void {
    const case: *Case = @ptrCast(@alignCast(arg.?));
    const here = Sched.here().?;
    case.result = case.future.await(case.rt.io());
    case.on_home = here == case.peer;
    case.resumed.store(true, .release);
    @atomicStore(bool, &case.stop, true, .release);
    case.rt.sched.notify(case.rt.baselineIo());
}

fn spin_until(flag: *const std.atomic.Value(bool)) !void {
    for (0..spin_max) |_| {
        if (flag.load(.acquire)) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.NeverHappened;
}

fn spin_until_parked(task: *const concurrency.Task) !void {
    // A fiber marker is any join word value above the running, done and driver markers.
    for (0..spin_max) |_| {
        if (task.join.load(.acquire) > 2) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.NeverParked;
}

/// Runs one case: an add task on carrier 0 awaited by a fiber on `peer_offset`'s carrier, with
/// the awaiter registered before (`await_first`) or after the task ran.
fn run_case(rt: *Runtime, peer_offset: u32, await_first: bool, values: [2]u32) !void {
    assert(peer_offset < peers_count);
    const rio = rt.io();
    if (rt.sched_state != .ready) return error.SkipZigTest;
    var future = rio.async(add_slowly, .{ rio, values[0], values[1] });
    const task: *concurrency.Task = @ptrCast(@alignCast(future.any_future.?));
    var case: Case = .{
        .rt = rt,
        .future = &future,
        .peer = &rt.peers[peer_offset].sched,
        .result = 0,
        .on_home = false,
        .resumed = .init(false),
        .stop = false,
        .mail = undefined,
    };
    case.mail = .init(entry_awaiter, &case);
    if (await_first) {
        mail.post(case.peer, rt.baselineIo(), &case.mail);
        try spin_until_parked(task);
        rt.sched.run_until(rt.baselineIo(), &case.stop);
    } else {
        // Every fiber of carrier 0 ends (the task), then the awaiter finds the word done.
        rt.sched.run_until(rt.baselineIo(), &case.stop);
        try std.testing.expect(join.is_done(&task.join));
        mail.post(case.peer, rt.baselineIo(), &case.mail);
    }
    try spin_until(&case.resumed);
    try std.testing.expectEqual(values[0] + values[1], case.result);
    try std.testing.expect(case.on_home);
    try std.testing.expectEqual(@as(u32, 0), rt.sched.live_count);
    // The awaiter fiber ends on the peer's thread a moment after it sets `resumed`.
    for (0..spin_max) |_| {
        if (@atomicLoad(u32, &case.peer.live_count, .acquire) == 0) break;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    try std.testing.expectEqual(@as(u32, 0), @atomicLoad(u32, &case.peer.live_count, .acquire));
}

test "a fiber on a peer carrier awaits a task of carrier 0 and resumes on its own carrier" {
    if (!Runtime.fibers_supported) return error.SkipZigTest;
    const backends = [_]Runtime.Backend{ .threaded, .auto };
    for (backends) |backend| {
        var rt: Runtime = try .init(std.testing.allocator, options(backend));
        defer rt.deinit();

        for (0..peers_count) |peer_offset| {
            const offset: u32 = @intCast(peer_offset);
            try run_case(&rt, offset, true, .{ offset, 100 });
            try run_case(&rt, offset, false, .{ offset, 200 });
        }
    }
}
