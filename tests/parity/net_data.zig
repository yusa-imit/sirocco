//! Data-path socket tests (plan 004 item 5, ADR 0003 section 3): `netRead`, `netWrite`,
//! `netSend` and `netShutdown` are native on the evented backends: a would-block parks the fiber
//! on the poller instead of holding an offload worker, and `header`/`splat` reach the kernel as
//! iovecs without copying the caller's buffers. Under `.threaded` the same tests run the
//! offloaded path.
//!
//! Parity scenarios build their own sockets from the `Io` they are given and return a value with
//! no pointers, so `harness.expectSameResultInFiber` compares `rt.io()` in a fiber with
//! `rt.baselineIo()`. Facts only the evented path defines (a parked read canceled in flight, a
//! close under a parked reader, a short write) are asserted on `rt.io()` alone and skip on
//! `.threaded`, where an offloaded call cannot be interrupted. Shutdown, error-variant, off-fiber
//! and allocation tests are in `net_data_edges.zig`, which shares this file's building blocks.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");

const fibers_supported = Runtime.fibers_supported;
const evented = fixtures.backend != .threaded;

const Address = Io.net.IpAddress;
const Server = Io.net.Server;
const Stream = Io.net.Stream;
const Handle = Io.net.Socket.Handle;
const ReadError = Stream.Reader.Error;
const WriteError = Stream.Writer.Error;

/// Offload workers: a `.threaded` echo blocks three calls at once (read, write, read).
const offload_threads_test: u32 = 6;
const loops_max: u32 = 1 << 22;
const payload_len: usize = 1 << 20;

pub fn init_rt() !Runtime {
    const gpa = std.testing.allocator;
    return fixtures.init_runtime_sockets(gpa, .forward, 16, offload_threads_test, 16);
}

/// Error names the data-path slots declare, as a value the harness can compare.
pub const Kind = enum {
    none,
    other,
    Canceled,
    SystemResources,
    ConnectionResetByPeer,
    Timeout,
    SocketUnconnected,
    AccessDenied,
    NetworkDown,
    FastOpenAlreadyInProgress,
    NetworkUnreachable,
    HostUnreachable,
    ConnectionRefused,
    AddressFamilyUnsupported,
    MessageOversize,
    ConnectionAborted,
    Unexpected,
};

fn kind_of(err: anyerror) Kind {
    return std.meta.stringToEnum(Kind, @errorName(err)) orelse .other;
}

pub fn kind_of_result(result: anytype) Kind {
    if (result) |_| return .none else |err| return kind_of(err);
}

// ---------------------------------------------------------------- building blocks

pub const Pair = struct { client: Stream, served: Stream };

fn accept_one(io: Io, server: *Server) Server.AcceptError!Stream {
    return server.accept(io);
}

fn connect_to(io: Io, address: Address) Address.ConnectError!Stream {
    return address.connect(io, .{ .mode = .stream });
}

pub fn connect_pair(io: Io) !Pair {
    const any_port: Address = .{ .ip4 = .loopback(0) };
    var server = try any_port.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var accepting = io.async(accept_one, .{ io, &server });
    var connecting = io.async(connect_to, .{ io, server.socket.address });
    const client = try connecting.await(io);
    errdefer client.close(io);

    const served = try accepting.await(io);
    return .{ .client = client, .served = served };
}

pub fn pair_close(io: Io, pair: Pair) void {
    pair.client.close(io);
    pair.served.close(io);
}

pub fn raw_read(io: Io, handle: Handle, bufs: [][]u8) ReadError!usize {
    return io.vtable.netRead(io.userdata, handle, bufs);
}

pub fn raw_write(io: Io, handle: Handle, bytes: []const u8) WriteError!usize {
    const data = [_][]const u8{bytes};
    return io.vtable.netWrite(io.userdata, handle, &.{}, &data, 1);
}

pub fn raw_shutdown(io: Io, handle: Handle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    return io.vtable.netShutdown(io.userdata, handle, how);
}

pub fn read_some(io: Io, handle: Handle) ReadError!usize {
    var buffer: [64]u8 = undefined;
    var bufs = [_][]u8{&buffer};
    return raw_read(io, handle, &bufs);
}

fn fill_pattern(seed: u64, bytes: []u8) void {
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(bytes);
}

/// What an echo delivered: the length and a streaming hash of the bytes.
const Digest = struct {
    len: u64,
    hash: u64,

    fn of(bytes: []const u8) Digest {
        return .{ .len = bytes.len, .hash = std.hash.Wyhash.hash(0, bytes) };
    }
};

/// Reads until EOF through two buffers per call and digests what arrived.
fn receive_all(io: Io, handle: Handle) ReadError!Digest {
    var hasher = std.hash.Wyhash.init(0);
    var first: [8192]u8 = undefined;
    var second: [8192]u8 = undefined;
    var bufs = [_][]u8{ &first, &second };
    var total: u64 = 0;
    for (0..loops_max) |_| {
        const n = try raw_read(io, handle, &bufs);
        if (n == 0) break;
        const in_first = @min(n, first.len);
        hasher.update(first[0..in_first]);
        hasher.update(second[0 .. n - in_first]);
        total += n;
    } else unreachable; // Proof: loops_max reads of 16 KiB exceed any payload of these tests.
    return .{ .len = total, .hash = hasher.final() };
}

/// Reads through three buffers and writes every byte back until EOF, then shuts its send side.
fn echo_serve(io: Io, stream: Stream) !void {
    var a: [1000]u8 = undefined;
    var b: [3000]u8 = undefined;
    var c: [20000]u8 = undefined;
    var bufs = [_][]u8{ &a, &b, &c };
    var out: [64]u8 = undefined;
    var writer = stream.writer(io, &out);
    for (0..loops_max) |_| {
        const n = try raw_read(io, stream.socket.handle, &bufs);
        if (n == 0) break;
        var pieces: [3][]const u8 = undefined;
        var count: usize = 0;
        var left = n;
        for (bufs) |buf| {
            if (left == 0) break;
            const take = @min(left, buf.len);
            pieces[count] = buf[0..take];
            count += 1;
            left -= take;
        }
        try writer.interface.writeVecAll(pieces[0..count]);
    }
    try writer.interface.flush();
    try raw_shutdown(io, stream.socket.handle, .send);
}

/// Sends `head` (buffered, so it travels as the drain's `header`), then the payload as vectors.
fn send_vectored(io: Io, stream: Stream, payload: []const u8) !void {
    var buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    const w = &writer.interface;
    try w.writeAll(payload[0..7]);
    var offset: usize = 7;
    for (0..loops_max) |_| {
        const left = payload.len - offset;
        if (left == 0) break;
        const take = @min(left, 9000);
        const third = take / 3;
        var parts = [_][]const u8{
            payload[offset..][0..third],
            payload[offset + third ..][0..third],
            payload[offset + 2 * third ..][0 .. take - 2 * third],
        };
        try w.writeVecAll(&parts);
        offset += take;
    }
    try w.flush();
    try raw_shutdown(io, stream.socket.handle, .send);
}

/// Sends `head`, `middle`, then `pattern` repeated `splat` times in one `writeSplatAll`.
fn send_splat(
    io: Io,
    stream: Stream,
    head: []const u8,
    middle: []const u8,
    pattern: []const u8,
    splat: usize,
) !void {
    var buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(head);
    var data = [_][]const u8{ middle, pattern };
    try writer.interface.writeSplatAll(&data, splat);
    try writer.interface.flush();
    try raw_shutdown(io, stream.socket.handle, .send);
}

fn echo_vectored(io: Io, payload: []const u8) !Digest {
    const pair = try connect_pair(io);
    defer pair_close(io, pair);

    var serving = io.async(echo_serve, .{ io, pair.served });
    var sending = io.async(send_vectored, .{ io, pair.client, payload });
    const echoed = try receive_all(io, pair.client.socket.handle);
    try sending.await(io);
    try serving.await(io);
    return echoed;
}

fn echo_splat(
    io: Io,
    head: []const u8,
    middle: []const u8,
    pattern: []const u8,
    splat: usize,
) !Digest {
    const pair = try connect_pair(io);
    defer pair_close(io, pair);

    var serving = io.async(echo_serve, .{ io, pair.served });
    var sending = io.async(send_splat, .{ io, pair.client, head, middle, pattern, splat });
    const echoed = try receive_all(io, pair.client.socket.handle);
    try sending.await(io);
    try serving.await(io);
    return echoed;
}

// ---------------------------------------------------------------- (1) echo parity

test "a 1 MiB vectored echo through a fiber pair matches the baseline and the payload" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const payload = try std.testing.allocator.alloc(u8, payload_len);
    defer std.testing.allocator.free(payload);

    fill_pattern(0x5eed, payload);
    try harness.expectSameResultInFiber(&rt, echo_vectored, .{@as([]const u8, payload)});
    const echoed = try echo_vectored(rt.io(), payload);
    try std.testing.expectEqual(Digest.of(payload), echoed);
    if (evented) try std.testing.expectEqual(@as(u32, 0), rt.sockets.count());
}

fn splat_expected(
    gpa: std.mem.Allocator,
    head: []const u8,
    middle: []const u8,
    pattern: []const u8,
    splat: usize,
) ![]u8 {
    const total = head.len + middle.len + pattern.len * splat;
    const bytes = try gpa.alloc(u8, total);
    @memcpy(bytes[0..head.len], head);
    @memcpy(bytes[head.len..][0..middle.len], middle);
    var at = head.len + middle.len;
    for (0..splat) |_| {
        @memcpy(bytes[at..][0..pattern.len], pattern);
        at += pattern.len;
    }
    return bytes;
}

fn splat_case(pattern: []const u8, splat: usize) !void {
    var rt = try init_rt();
    defer rt.deinit();

    const gpa = std.testing.allocator;
    const head = "head-bytes";
    var middle: [777]u8 = undefined;
    fill_pattern(0xabc, &middle);
    const expected = try splat_expected(gpa, head, &middle, pattern, splat);
    defer gpa.free(expected);

    try std.testing.expect(expected.len >= 1_000_000);
    const middle_bytes: []const u8 = &middle;
    const args = .{ @as([]const u8, head), middle_bytes, pattern, splat };
    try harness.expectSameResultInFiber(&rt, echo_splat, args);
    const echoed = try echo_splat(rt.io(), head, &middle, pattern, splat);
    try std.testing.expectEqual(Digest.of(expected), echoed);
}

test "a 1 MiB splat echo of a one-byte pattern matches the baseline and the bytes" {
    if (!fibers_supported) return error.SkipZigTest;
    try splat_case("q", payload_len);
}

test "a 1 MiB splat echo of a multi-byte pattern matches the baseline and the bytes" {
    if (!fibers_supported) return error.SkipZigTest;
    try splat_case("abcdefg", 150_000);
}

// ---------------------------------------------------------------- (2) read-cancel parity

const ReadOutcome = struct {
    bytes: usize,
    canceled: bool,
    failed: bool,
    canceled_after: bool,
};

fn read_once(io: Io, handle: Handle, protection: Io.CancelProtection) ReadOutcome {
    var out: ReadOutcome = .{
        .bytes = 0,
        .canceled = false,
        .failed = false,
        .canceled_after = false,
    };
    const previous = io.swapCancelProtection(protection);
    if (read_some(io, handle)) |n| {
        out.bytes = n;
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

fn write_later(io: Io, handle: Handle) WriteError!void {
    io.sleep(.fromMilliseconds(40), .awake) catch {};
    _ = try raw_write(io, handle, "x");
}

fn read_cancel(io: Io, protection: Io.CancelProtection) !ReadOutcome {
    const pair = try connect_pair(io);
    defer pair_close(io, pair);

    var reading = io.async(read_once, .{ io, pair.served.socket.handle, protection });
    var writing = io.async(write_later, .{ io, pair.client.socket.handle });
    const outcome = reading.cancel(io);
    try writing.await(io);
    return outcome;
}

test "a read canceled in flight returns Canceled, as the baseline" {
    if (!fibers_supported or !evented) return error.SkipZigTest; // Offloaded: no interrupt.
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, read_cancel, .{Io.CancelProtection.unblocked});
    const outcome = try read_cancel(rt.io(), .unblocked);
    try std.testing.expect(outcome.canceled);
    try std.testing.expectEqual(@as(usize, 0), outcome.bytes);
    try std.testing.expect(!rt.sched.armed_any());
}

test "a read under blocked cancel protection completes, then the request is seen" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    try harness.expectSameResultInFiber(&rt, read_cancel, .{Io.CancelProtection.blocked});
    const outcome = try read_cancel(rt.io(), .blocked);
    try std.testing.expectEqual(@as(usize, 1), outcome.bytes);
    try std.testing.expect(!outcome.canceled);
    try std.testing.expect(outcome.canceled_after);
    if (evented) try std.testing.expect(!rt.sched.armed_any());
}

test "a parked read leaves the poller armed once and clean after the cancel" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    var making = io.async(connect_pair, .{io});
    const pair = try making.await(io);
    defer pair_close(io, pair);

    const unblocked = Io.CancelProtection.unblocked;
    var reading = io.async(read_once, .{ io, pair.served.socket.handle, unblocked });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    try std.testing.expect(rt.sched.armed_any());
    const outcome = reading.cancel(io);
    try std.testing.expect(outcome.canceled);
    try std.testing.expectEqual(@as(u32, 0), rt.sched.parked_count);
    try std.testing.expect(!rt.sched.armed_any());
    // The socket still works after the canceled read.
    _ = try raw_write(io, pair.client.socket.handle, "ok");
    try std.testing.expectEqual(@as(usize, 2), try read_some(io, pair.served.socket.handle));
}

// ---------------------------------------------------------------- (3) close under a reader

fn close_stream(io: Io, stream: Stream) void {
    stream.close(io);
}

fn close_after(io: Io, stream: Stream, go: *std.atomic.Value(bool)) void {
    for (0..loops_max) |_| {
        if (go.load(.acquire)) break;
        std.atomic.spinLoopHint();
    }
    stream.close(io);
}

test "closing the socket a fiber is reading from a fiber gives the reader an error" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    var making = io.async(connect_pair, .{io});
    const pair = try making.await(io);
    defer pair.client.close(io);

    var reading = io.async(read_some, .{ io, pair.served.socket.handle });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    var closing = io.async(close_stream, .{ io, pair.served });
    closing.await(io);
    try std.testing.expectError(error.SocketUnconnected, reading.await(io));
    try std.testing.expectEqual(@as(u32, 1), rt.sockets.count());
    try std.testing.expect(!rt.sched.armed_any());
}

test "closing the socket a fiber is reading from another thread gives the reader an error" {
    if (!fibers_supported or !evented) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const io = rt.io();
    var making = io.async(connect_pair, .{io});
    const pair = try making.await(io);
    defer pair.client.close(io);

    var reading = io.async(read_some, .{ io, pair.served.socket.handle });
    try std.testing.expectEqual(@as(u32, 1), rt.sched.parked_count);
    var go: std.atomic.Value(bool) = .init(false);
    const closer = try std.Thread.spawn(.{}, close_after, .{ io, pair.served, &go });
    go.store(true, .release);
    try std.testing.expectError(error.SocketUnconnected, reading.await(io));
    closer.join();
    try std.testing.expectEqual(@as(u32, 1), rt.sockets.count());
    try std.testing.expect(!rt.sched.armed_any());
}

// ---------------------------------------------------------------- (4) short write, partial send

fn buffers_shrink(handle: Handle) void {
    const small: c_int = 4096;
    const bytes = std.mem.asBytes(&small);
    for ([_]u32{ posix.SO.SNDBUF, posix.SO.RCVBUF }) |name| {
        const rc = posix.system.setsockopt(handle, posix.SOL.SOCKET, name, bytes, @sizeOf(c_int));
        std.debug.assert(posix.errno(rc) == .SUCCESS);
    }
}

fn send_all_then_shutdown(io: Io, stream: Stream, payload: []const u8) !void {
    var buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
    try raw_shutdown(io, stream.socket.handle, .send);
}

/// The sender fills a tiny socket buffer while the receiver sleeps, so writes come up short and
/// the writer waits for room; the receiver then drains everything.
fn flood(io: Io, payload: []const u8) !Digest {
    const pair = try connect_pair(io);
    defer pair_close(io, pair);

    buffers_shrink(pair.client.socket.handle);
    buffers_shrink(pair.served.socket.handle);
    var sending = io.async(send_all_then_shutdown, .{ io, pair.client, payload });
    try io.sleep(.fromMilliseconds(30), .awake);
    const received = try receive_all(io, pair.served.socket.handle);
    try sending.await(io);
    return received;
}

test "a write through a tiny socket buffer delivers the baseline's total" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const payload = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(payload);

    fill_pattern(0xf100d, payload);
    try harness.expectSameResultInFiber(&rt, flood, .{@as([]const u8, payload)});
    const received = try flood(rt.io(), payload);
    try std.testing.expectEqual(Digest.of(payload), received);
}

const ShortWrite = struct { first: usize, total: u64 };

fn short_write(io: Io, payload: []const u8) !ShortWrite {
    const pair = try connect_pair(io);
    defer pair_close(io, pair);

    buffers_shrink(pair.client.socket.handle);
    buffers_shrink(pair.served.socket.handle);
    const first = try raw_write(io, pair.client.socket.handle, payload);
    var sending = io.async(send_all_then_shutdown, .{ io, pair.client, payload[first..] });
    const received = try receive_all(io, pair.served.socket.handle);
    try sending.await(io);
    return .{ .first = first, .total = received.len };
}

test "a native write against a full socket buffer is short and the rest follows" {
    if (!fibers_supported or !evented) return error.SkipZigTest; // A blocking write waits for all.
    var rt = try init_rt();
    defer rt.deinit();

    const payload = try std.testing.allocator.alloc(u8, payload_len);
    defer std.testing.allocator.free(payload);

    fill_pattern(0x5407, payload);
    const io = rt.io();
    var future = io.async(short_write, .{ io, @as([]const u8, payload) });
    const result = try future.await(io);
    try std.testing.expect(result.first > 0);
    try std.testing.expect(result.first < payload.len);
    try std.testing.expectEqual(@as(u64, payload.len - result.first), result.total);
}

const send_buffer: [70_000]u8 = @splat('z');

const SendOutcome = struct { kind: Kind, sent: usize, len0: usize, len1: usize, len2: usize };

fn send_partial(io: Io, receiver: Address) !SendOutcome {
    const any_port: Address = .{ .ip4 = .loopback(0) };
    const sender = try any_port.bind(io, .{ .mode = .dgram });
    defer sender.close(io);

    var messages = [_]Io.net.OutgoingMessage{
        .{ .address = &receiver, .data_ptr = &send_buffer, .data_len = 100 },
        .{ .address = &receiver, .data_ptr = &send_buffer, .data_len = 200 },
        .{ .address = &receiver, .data_ptr = &send_buffer, .data_len = send_buffer.len },
    };
    const failure, const sent = io.vtable.netSend(io.userdata, sender.handle, &messages, .{});
    return .{
        .kind = if (failure) |err| kind_of(err) else .none,
        .sent = sent,
        .len0 = messages[0].data_len,
        .len1 = messages[1].data_len,
        .len2 = messages[2].data_len,
    };
}

test "a send that fails on its third datagram returns the count of two, as the baseline" {
    if (!fibers_supported) return error.SkipZigTest;
    var rt = try init_rt();
    defer rt.deinit();

    const base = rt.baselineIo();
    const any_port: Address = .{ .ip4 = .loopback(0) };
    const receiver = try any_port.bind(base, .{ .mode = .dgram });
    defer receiver.close(base);

    try harness.expectSameResultInFiber(&rt, send_partial, .{receiver.address});
    const outcome = try send_partial(rt.io(), receiver.address);
    try std.testing.expectEqual(Kind.MessageOversize, outcome.kind);
    try std.testing.expectEqual(@as(usize, 2), outcome.sent);
    try std.testing.expectEqual(@as(usize, 100), outcome.len0);
    try std.testing.expectEqual(@as(usize, 200), outcome.len1);
    // Three runs (baseline, native in a fiber, native off a fiber) delivered two datagrams each.
    var buffer: [512]u8 = undefined;
    var arrived: usize = 0;
    for (0..6) |_| {
        const message = try receiver.receive(base, &buffer);
        try std.testing.expect(message.data.len == 100 or message.data.len == 200);
        arrived += message.data.len;
    }
    try std.testing.expectEqual(@as(usize, 3 * 300), arrived);
}
