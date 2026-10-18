//! `operate` on files (plan 004 item 7, ADR 0003 section 2b): `file_read_streaming` and
//! `file_write_streaming` on a file opened non-blocking park the fiber on the poller; blocking
//! files and `device_io_control` keep the offload thunk. `Io.Threaded` reports `WouldBlock` where
//! sirocco waits, so parking, cancel and registry facts are asserted on `rt.io()` alone and skip
//! on `.threaded`; the ready, empty-buffer, splat, EOF and broken-pipe cases are parity tests.
//! The `net_receive` half and the shared building blocks (`Udp`, `Kind`) are in `operate.zig`.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");
const operate = @import("operate.zig");

const fibers_supported = Runtime.fibers_supported;
const evented = fixtures.backend != .threaded;

const Address = Io.net.IpAddress;
const Socket = Io.net.Socket;
const Udp = operate.Udp;
const Kind = operate.Kind;
const kind_of = operate.kind_of;
const init_rt = operate.init_rt;
const loops_max = operate.loops_max;
const ReceiveOutcome = operate.ReceiveOutcome;

// ---------------------------------------------------------------- building blocks: pipes

const Pipe = struct {
    read: Io.File,
    write: Io.File,

    fn open(nonblocking: bool) !Pipe {
        var fds: [2]posix.fd_t = undefined;
        if (posix.errno(posix.system.pipe(&fds)) != .SUCCESS) return error.PipeFailed;
        if (nonblocking) {
            for (fds) |fd| try nonblocking_set(fd);
        }
        const flags: Io.File.Flags = .{ .nonblocking = nonblocking };
        return .{
            .read = .{ .handle = fds[0], .flags = flags },
            .write = .{ .handle = fds[1], .flags = flags },
        };
    }

    fn close_read(pipe: Pipe) void {
        _ = posix.system.close(pipe.read.handle);
    }

    fn close_write(pipe: Pipe) void {
        _ = posix.system.close(pipe.write.handle);
    }
};

fn nonblocking_set(fd: posix.fd_t) !void {
    const status = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(status) != .SUCCESS) return error.PipeFailed;
    var flags: posix.O = @bitCast(@as(u32, @intCast(status)));
    flags.NONBLOCK = true;
    const rc = posix.system.fcntl(fd, posix.F.SETFL, @as(usize, @as(u32, @bitCast(flags))));
    if (posix.errno(rc) != .SUCCESS) return error.PipeFailed;
}

fn file_read(io: Io, file: Io.File, buffer: []u8) Io.File.ReadStreamingError!usize {
    const bufs = [_][]u8{buffer};
    return file.readStreaming(io, &bufs);
}

fn file_write(io: Io, file: Io.File, bytes: []const u8) Io.File.Writer.Error!usize {
    const data = [_][]const u8{bytes};
    return file.writeStreaming(io, &.{}, &data, 1);
}

fn write_from_thread(io: Io, fd: posix.fd_t, bytes: []const u8, delay_ms: i64) void {
    io.sleep(.fromMilliseconds(delay_ms), .awake) catch return;
    _ = posix.system.write(fd, bytes.ptr, bytes.len);
}

// ---------------------------------------------------------------- (4) non-blocking file parity

const PipeOutcome = struct {
    wrote: usize,
    got: usize,
    empty_read: usize,
    empty_write: usize,
    splat_wrote: usize,
    splat_got: usize,
    eof: Kind,
};

fn pipe_basic(io: Io) !PipeOutcome {
    const pipe = try Pipe.open(true);
    defer pipe.close_read();

    var out: PipeOutcome = undefined;
    const data = [_][]const u8{"c"};
    out.wrote = try pipe.write.writeStreaming(io, "ab", &data, 1);
    var head: [2]u8 = undefined;
    var tail: [8]u8 = undefined;
    const bufs = [_][]u8{ &head, &tail };
    out.got = try pipe.read.readStreaming(io, &bufs);
    var nothing: [0]u8 = undefined;
    const empty = [_][]u8{&nothing};
    out.empty_read = try pipe.read.readStreaming(io, &empty);
    const blank = [_][]const u8{""};
    out.empty_write = try pipe.write.writeStreaming(io, "", &blank, 1);
    const pattern = [_][]const u8{"xy"};
    out.splat_wrote = try pipe.write.writeStreaming(io, "h", &pattern, 3);
    var wide: [32]u8 = undefined;
    const wide_bufs = [_][]u8{&wide};
    out.splat_got = try pipe.read.readStreaming(io, &wide_bufs);
    pipe.close_write();
    out.eof = if (pipe.read.readStreaming(io, &wide_bufs)) |_| .none else |err| kind_of(err);
    return out;
}

test "a non-blocking pipe with data ready, empty buffers, a splat and EOF matches the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, pipe_basic, .{});
    const got = try harness.call_in_fiber(rt.io(), pipe_basic, .{});
    try std.testing.expectEqual(@as(usize, 3), got.wrote);
    try std.testing.expectEqual(@as(usize, 3), got.got);
    try std.testing.expectEqual(@as(usize, 0), got.empty_read);
    try std.testing.expectEqual(@as(usize, 0), got.empty_write);
    try std.testing.expectEqual(@as(usize, 7), got.splat_wrote);
    try std.testing.expectEqual(@as(usize, 7), got.splat_got);
    try std.testing.expectEqual(Kind.EndOfStream, got.eof);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

fn pipe_broken(io: Io) !Kind {
    const pipe = try Pipe.open(true);
    defer pipe.close_write();

    pipe.close_read();
    return if (file_write(io, pipe.write, "gone")) |_| .none else |err| kind_of(err);
}

test "a write to a non-blocking pipe whose reader is gone is BrokenPipe, as the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, pipe_broken, .{});
    const kind = try harness.call_in_fiber(rt.io(), pipe_broken, .{});
    try std.testing.expectEqual(Kind.BrokenPipe, kind);
}

// ---------------------------------------------------------------- (5) parking on a pipe

test "a non-blocking pipe read parks until the peer writes" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    const pipe = try Pipe.open(true);
    defer pipe.close_read();
    defer pipe.close_write();

    var buffer: [16]u8 = undefined;
    const slice: []u8 = &buffer;
    var reading = io.async(file_read, .{ io, pipe.read, slice });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    try std.testing.expect(rt.sched.armed_any());
    // The registry holds the file for the length of the wait: one slot, gone afterwards.
    try std.testing.expectEqual(@as(u32, 1), rt.sockets.count());
    try std.testing.expectEqual(@as(usize, 5), try file_write(io, pipe.write, "hello"));
    try std.testing.expectEqual(@as(usize, 5), try reading.await(io));
    try std.testing.expectEqualStrings("hello", buffer[0..5]);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
    try std.testing.expect(!rt.sched.armed_any());
}

fn read_canceled(io: Io, file: Io.File, protection: Io.CancelProtection) ReceiveOutcome {
    var out: ReceiveOutcome = .{
        .len = 0,
        .canceled = false,
        .failed = false,
        .canceled_after = false,
    };
    const previous = io.swapCancelProtection(protection);
    var buffer: [16]u8 = undefined;
    if (file_read(io, file, &buffer)) |n| {
        out.len = n;
    } else |err| switch (err) {
        error.Canceled => out.canceled = true,
        else => out.failed = true,
    }
    _ = io.swapCancelProtection(previous);
    io.checkCancel() catch {
        out.canceled_after = true;
    };
    return out;
}

test "a parked pipe read canceled in flight returns Canceled and releases its registration" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    const pipe = try Pipe.open(true);
    defer pipe.close_read();
    defer pipe.close_write();

    var reading = io.async(read_canceled, .{ io, pipe.read, Io.CancelProtection.unblocked });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    const outcome = reading.cancel(io);
    try std.testing.expect(outcome.canceled);
    try std.testing.expect(!outcome.failed);
    try std.testing.expectEqual(@as(u32, 0), rt.sched.parked_count);
    try std.testing.expect(!rt.sched.armed_any());
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
    // The pipe still works after the canceled read.
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try file_write(io, pipe.write, "ok"));
    try std.testing.expectEqual(@as(usize, 2), try file_read(io, pipe.read, &buffer));
}

test "a pipe read under blocked cancel protection completes, then the request is seen" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    const pipe = try Pipe.open(true);
    defer pipe.close_read();
    defer pipe.close_write();

    const writer = try std.Thread.spawn(.{}, write_from_thread, .{
        rt.baselineIo(), pipe.write.handle, @as([]const u8, "x"), @as(i64, 40),
    });
    defer writer.join();

    var reading = io.async(read_canceled, .{ io, pipe.read, Io.CancelProtection.blocked });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    // The request lands while the read is parked; protection holds it back until the data came.
    const outcome = reading.cancel(io);
    try std.testing.expectEqual(@as(usize, 1), outcome.len);
    try std.testing.expect(!outcome.canceled);
    try std.testing.expect(outcome.canceled_after);
    try std.testing.expect(!rt.sched.armed_any());
}

test "a parked pipe read ends with EndOfStream when the writer closes" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    const pipe = try Pipe.open(true);
    defer pipe.close_read();

    var buffer: [16]u8 = undefined;
    const slice: []u8 = &buffer;
    var reading = io.async(file_read, .{ io, pipe.read, slice });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    pipe.close_write();
    try std.testing.expectError(error.EndOfStream, reading.await(io));
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

fn read_one(io: Io, file: Io.File) Io.File.ReadStreamingError!u8 {
    var byte: [1]u8 = undefined;
    if (try file_read(io, file, &byte) != 1) return error.Unexpected;
    return byte[0];
}

test "two fibers parked on one pipe share one registration and are both served" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    const pipe = try Pipe.open(true);
    defer pipe.close_read();
    defer pipe.close_write();

    var first = io.async(read_one, .{ io, pipe.read });
    var second = io.async(read_one, .{ io, pipe.read });
    try std.testing.expectEqual(@as(u32, 2), rt.sched.parked_count);
    try std.testing.expectEqual(@as(u32, 1), rt.sockets.count());
    try std.testing.expectEqual(@as(usize, 2), try file_write(io, pipe.write, "ab"));
    const a = try first.await(io);
    const b = try second.await(io);
    try std.testing.expectEqual(@as(u32, 'a' + 'b'), @as(u32, a) + @as(u32, b));
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
    try std.testing.expect(!rt.sched.armed_any());
}

const fill_chunk: [4096]u8 = @splat('f');
const fill_chunks: u32 = 64;

fn fill_pipe(io: Io, file: Io.File) Io.File.Writer.Error!u64 {
    var total: u64 = 0;
    for (0..fill_chunks) |_| total += try file_write(io, file, &fill_chunk);
    return total;
}

fn drain_pipe(io: Io, file: Io.File, total_max: u64) Io.File.ReadStreamingError!u64 {
    var total: u64 = 0;
    var buffer: [4096]u8 = undefined;
    for (0..loops_max) |_| {
        if (total >= total_max) break;
        total += try file_read(io, file, &buffer);
    }
    return total;
}

test "a non-blocking pipe write parks while the pipe is full and finishes once it is drained" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    const pipe = try Pipe.open(true);
    defer pipe.close_read();
    defer pipe.close_write();

    const expected: u64 = @as(u64, fill_chunks) * fill_chunk.len;
    var filling = io.async(fill_pipe, .{ io, pipe.write });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    try std.testing.expect(rt.sched.armed_any());
    var draining = io.async(drain_pipe, .{ io, pipe.read, expected });
    try std.testing.expectEqual(expected, try filling.await(io));
    try std.testing.expectEqual(expected, try draining.await(io));
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

test "a parked pipe write canceled in flight returns Canceled" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    const pipe = try Pipe.open(true);
    defer pipe.close_read();
    defer pipe.close_write();

    var filling = io.async(fill_pipe, .{ io, pipe.write });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    try std.testing.expectError(error.Canceled, filling.cancel(io));
    try std.testing.expectEqual(@as(u32, 0), rt.sched.parked_count);
    try std.testing.expect(!rt.sched.armed_any());
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

test "a non-blocking pipe read off a fiber waits in poll" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const pipe = try Pipe.open(true);
    defer pipe.close_read();
    defer pipe.close_write();

    const writer = try std.Thread.spawn(.{}, write_from_thread, .{
        rt.baselineIo(), pipe.write.handle, @as([]const u8, "late"), @as(i64, 40),
    });
    defer writer.join();

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try file_read(rt.io(), pipe.read, &buffer));
    try std.testing.expectEqualStrings("late", buffer[0..4]);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

fn bind_one(io: Io) Address.BindError!Socket {
    const any_port: Address = .{ .ip4 = .loopback(0) };
    return any_port.bind(io, .{ .mode = .dgram });
}

test "a full registry serves a non-blocking pipe read through a worker, not WouldBlock" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try fixtures.init_runtime_sockets(std.testing.allocator, .forward, 16, 2, 1);
    defer rt.deinit();

    const io = rt.io();
    var binding = io.async(bind_one, .{io});
    const socket = try binding.await(io);
    defer socket.close(io);

    try std.testing.expectEqual(@as(u32, 1), rt.sockets.count());
    const pipe = try Pipe.open(true);
    defer pipe.close_read();
    defer pipe.close_write();

    var buffer: [16]u8 = undefined;
    const slice: []u8 = &buffer;
    var reading = io.async(file_read, .{ io, pipe.read, slice });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    try std.testing.expectEqual(@as(u32, 1), rt.sockets.count());
    try std.testing.expectEqual(@as(usize, 3), try file_write(io, pipe.write, "ten"));
    try std.testing.expectEqual(@as(usize, 3), try reading.await(io));
    try std.testing.expectEqualStrings("ten", buffer[0..3]);
    try std.testing.expectEqual(@as(u32, 1), rt.sockets.count());
}

// ---------------------------------------------------------------- (6) what stays on the thunk

const BlockedRead = struct { len: usize, other_fiber_ran: bool };

fn mark_after_sleep(io: Io, ran: *std.atomic.Value(bool)) void {
    io.sleep(.fromMilliseconds(10), .awake) catch return;
    ran.store(true, .release);
}

fn read_blocking(io: Io, file: Io.File, ran: *const std.atomic.Value(bool)) !BlockedRead {
    var buffer: [16]u8 = undefined;
    const len = try file_read(io, file, &buffer);
    return .{ .len = len, .other_fiber_ran = ran.load(.acquire) };
}

test "a read on a blocking pipe is offloaded: another fiber runs while it waits" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    const pipe = try Pipe.open(false);
    defer pipe.close_read();
    defer pipe.close_write();

    var ran: std.atomic.Value(bool) = .init(false);
    const writer = try std.Thread.spawn(.{}, write_from_thread, .{
        rt.baselineIo(), pipe.write.handle, @as([]const u8, "wake"), @as(i64, 150),
    });
    defer writer.join();

    // If the read ran on the carrier it would sit in the kernel for 150 ms and `ran` stay false.
    var reading = io.async(read_blocking, .{ io, pipe.read, &ran });
    var marking = io.async(mark_after_sleep, .{ io, &ran });
    const got = try reading.await(io);
    marking.await(io);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expect(got.other_fiber_ran);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

fn read_file_head(io: Io, dir: Io.Dir) !struct { usize, u64 } {
    const file = try dir.openFile(io, "operate.txt", .{});
    defer file.close(io);

    var buffer: [8]u8 = undefined;
    const len = try file_read(io, file, &buffer);
    return .{ len, std.hash.Wyhash.hash(0, buffer[0..len]) };
}

test "a read on a blocking regular file takes the offload route and matches the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = rt.baselineIo();
    const file = try tmp.dir.createFile(base, "operate.txt", .{});
    try file.writeStreamingAll(base, "regular file contents");
    file.close(base);

    try harness.expectSameResultInFiber(&rt, read_file_head, .{tmp.dir});
    const len, const hash = try harness.call_in_fiber(rt.io(), read_file_head, .{tmp.dir});
    try std.testing.expectEqual(@as(usize, 8), len);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, "regular "), hash);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

/// An ioctl request no pipe understands: both `Io`s must report the same negative errno.
const request_unknown: u32 = 0;

fn device_control(io: Io) !struct { i32, c_int } {
    const pipe = try Pipe.open(false);
    defer pipe.close_read();
    defer pipe.close_write();

    var argument: c_int = -1;
    const result = try io.operate(.{ .device_io_control = .{
        .file = pipe.read,
        .code = request_unknown,
        .arg = &argument,
    } });
    return .{ result.device_io_control, argument };
}

test "device_io_control keeps the offload thunk and matches the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, device_control, .{});
    const rc, const argument = try harness.call_in_fiber(rt.io(), device_control, .{});
    try std.testing.expect(rc < 0); // The negative errno of the kernel, passed through intact.
    try std.testing.expectEqual(@as(c_int, -1), argument);
    try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

// ---------------------------------------------------------------- (7) allocation

const AllocProbe = struct { before: usize, after: usize };

fn operate_loop(io: Io, udp: Udp, failing: *const std.testing.FailingAllocator) !AllocProbe {
    const pipe = try Pipe.open(true);
    defer pipe.close_read();
    defer pipe.close_write();

    const before = failing.alloc_index;
    var buffer: [32]u8 = undefined;
    for (0..32) |_| {
        try udp.sender.send(io, &udp.receiver.address, "alloc");
        const message = try udp.receiver.receive(io, &buffer);
        try std.testing.expectEqual(@as(usize, 5), message.data.len);
        try std.testing.expectEqual(@as(usize, 3), try file_write(io, pipe.write, "abc"));
        try std.testing.expectEqual(@as(usize, 3), try file_read(io, pipe.read, &buffer));
    }
    return .{ .before = before, .after = failing.alloc_index };
}

test "operate allocates nothing after init, parked or not" {
    if (!fibers_supported) return error.SkipZigTest;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var rt = try fixtures.init_runtime_in(failing.allocator(), .forward, 8);
    defer rt.deinit();

    const io = rt.io();
    var making = io.async(Udp.open, .{io});
    const udp = try making.await(io);
    defer udp.close(io);

    var looping = io.async(operate_loop, .{ io, udp, &failing });
    const probe = try looping.await(io);
    try std.testing.expectEqual(probe.before, probe.after);
    if (!evented) return;

    const pipe = try Pipe.open(true);
    defer pipe.close_read();
    defer pipe.close_write();

    var buffer: [8]u8 = undefined;
    const slice: []u8 = &buffer;
    var reading = io.async(file_read, .{ io, pipe.read, slice });
    const started = failing.alloc_index; // Includes the task record of `reading`.
    _ = try file_write(io, pipe.write, "wake");
    try std.testing.expectEqual(@as(usize, 4), try reading.await(io));
    try std.testing.expectEqual(started, failing.alloc_index);
}
