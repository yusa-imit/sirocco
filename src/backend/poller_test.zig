//! Conformance tests for the evented `Poller` contract (ADR 0003), generic over the backend.
//!
//! Every case is `fn case_x(comptime P: type) !void` and runs against `poller.Native`; on a
//! target with no evented backend (`Native == void`) each test skips. Epoll joins by being the
//! `Native` of its target: the same cases then run against it unchanged. Sockets are
//! non-blocking `socketpair`s, so readiness is real kernel readiness and no clock is mocked;
//! time assertions are lower bounds only (a loaded machine may return late, never early). The
//! one exception is the wake tests: they wait with a generous finite timeout (`wake_wait_ns`)
//! and fail if it ran out, so a lost wake fails the test instead of hanging it.

const std = @import("std");
const stdx = @import("../stdx.zig");
const shared = @import("poller.zig");

const assert = stdx.assert;
const assert_always = stdx.assert_always;
const testing = std.testing;
const posix = std.posix;
const system = posix.system;

const Event = shared.Event;
const Interest = shared.Interest;
const fd_t = shared.fd_t;

const wait_ns_max: u64 = 2_000_000_000;
const ms_ns: u64 = 1_000_000;
const wake_wait_ns: u64 = 5_000_000_000;

const Pair = struct { a: fd_t, b: fd_t };

fn pair_open() Pair {
    var fds: [2]fd_t = undefined;
    const created = system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    assert_always(posix.errno(created) == .SUCCESS);
    for (fds) |fd| nonblocking_set(fd);
    assert(fds[0] != fds[1]);
    return .{ .a = fds[0], .b = fds[1] };
}

fn nonblocking_set(fd: fd_t) void {
    assert(fd >= 0);
    const status = system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    assert_always(posix.errno(status) == .SUCCESS);
    var flags: posix.O = @bitCast(@as(u32, @intCast(status)));
    flags.NONBLOCK = true;
    const rc = system.fcntl(fd, posix.F.SETFL, @as(usize, @as(u32, @bitCast(flags))));
    assert_always(posix.errno(rc) == .SUCCESS);
}

fn pair_close(pair: Pair) void {
    assert(pair.a != pair.b);
    close_fd(pair.a);
    if (pair.b >= 0) close_fd(pair.b);
}

fn close_fd(fd: fd_t) void {
    assert(fd >= 0);
    assert_always(posix.errno(system.close(fd)) == .SUCCESS);
}

fn byte_write(fd: fd_t) void {
    const byte = [1]u8{0x5a};
    assert(fd >= 0);
    assert_always(system.write(fd, &byte, 1) == 1);
}

/// True when a byte was read, false when the socket had none.
fn byte_read(fd: fd_t) bool {
    var byte: [1]u8 = undefined;
    assert(fd >= 0);
    const rc = system.read(fd, &byte, 1);
    if (rc == 1) return true;
    assert_always(posix.errno(rc) == .AGAIN);
    return false;
}

fn now_ns() i96 {
    return std.Io.Clock.awake.now(testing.io).nanoseconds;
}

fn sleep_ms(ms: i64) void {
    std.Io.sleep(testing.io, .fromMilliseconds(ms), .awake) catch |err| switch (err) {
        error.Canceled => {},
    };
}

fn run_case(comptime case: anytype) !void {
    if (comptime shared.Native == void) return error.SkipZigTest;
    try case(shared.Native);
}

fn expect_event(event: Event, token: u64, interest: Interest, hangup: bool) !void {
    try testing.expectEqual(token, event.token);
    try testing.expectEqual(interest, event.interest);
    try testing.expectEqual(hangup, event.hangup);
}

fn case_contract(comptime P: type) !void {
    shared.contract(P);
    try testing.expect(shared.events_max >= 2);
    try testing.expect(shared.registrations_max_limit > 0);
}

fn case_read_readiness(comptime P: type) !void {
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = 4 });
    defer poller.deinit(testing.allocator);

    const pair = pair_open();
    defer pair_close(pair);

    try poller.arm(pair.a, .read, 7);
    try testing.expect(poller.is_armed(pair.a, .read));
    try testing.expect(!poller.is_armed(pair.a, .write));
    byte_write(pair.b);
    var out: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 1), poller.wait(wait_ns_max, &out));
    try expect_event(out[0], 7, .read, false);
    // One-shot: the registration is gone while the byte is still unread.
    try testing.expect(!poller.is_armed(pair.a, .read));
    try testing.expectEqual(@as(u32, 0), poller.wait(0, &out));
    try testing.expect(byte_read(pair.a));
}

test "poller: contract compiles" {
    try run_case(case_contract);
}

test "poller: read readiness is one-shot" {
    try run_case(case_read_readiness);
}

fn case_write_readiness(comptime P: type) !void {
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = 4 });
    defer poller.deinit(testing.allocator);

    const pair = pair_open();
    defer pair_close(pair);

    try poller.arm(pair.a, .write, 9);
    var out: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 1), poller.wait(wait_ns_max, &out));
    try expect_event(out[0], 9, .write, false);
    try testing.expect(!poller.is_armed(pair.a, .write));
}

test "poller: write readiness on an empty buffer" {
    try run_case(case_write_readiness);
}

fn case_read_and_write_one_fd(comptime P: type) !void {
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = 4 });
    defer poller.deinit(testing.allocator);

    const pair = pair_open();
    defer pair_close(pair);

    try poller.arm(pair.a, .read, 100);
    try poller.arm(pair.a, .write, 200);
    try testing.expect(poller.is_armed(pair.a, .read));
    try testing.expect(poller.is_armed(pair.a, .write));
    byte_write(pair.b);
    var out: [4]Event = undefined;
    var seen_read = false;
    var seen_write = false;
    const attempts_max: u32 = 4;
    for (0..attempts_max) |_| {
        if (seen_read and seen_write) break;
        const n = poller.wait(wait_ns_max, &out);
        for (out[0..n]) |event| switch (event.interest) {
            .read => {
                try expect_event(event, 100, .read, false);
                seen_read = true;
            },
            .write => {
                try expect_event(event, 200, .write, false);
                seen_write = true;
            },
        };
    }
    try testing.expect(seen_read);
    try testing.expect(seen_write);
    try testing.expect(!poller.is_armed(pair.a, .read));
    try testing.expect(!poller.is_armed(pair.a, .write));
}

test "poller: read and write on one fd are independent registrations" {
    try run_case(case_read_and_write_one_fd);
}

fn case_disarm(comptime P: type) !void {
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = 4 });
    defer poller.deinit(testing.allocator);

    const pair = pair_open();
    defer pair_close(pair);

    var out: [4]Event = undefined;
    try poller.arm(pair.a, .read, 1);
    poller.disarm(pair.a, .read);
    try testing.expect(!poller.is_armed(pair.a, .read));
    byte_write(pair.b);
    try testing.expectEqual(@as(u32, 0), poller.wait(0, &out));
    poller.disarm(pair.a, .read); // idempotent
    poller.disarm(pair.a, .write); // never armed
    try poller.arm(pair.a, .read, 2);
    try testing.expectEqual(@as(u32, 1), poller.wait(wait_ns_max, &out));
    try expect_event(out[0], 2, .read, false);
}

test "poller: disarm drops the registration, is idempotent, and rearm works" {
    try run_case(case_disarm);
}

fn case_disarm_drops_pending_event(comptime P: type) !void {
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = 4 });
    defer poller.deinit(testing.allocator);

    const pair = pair_open();
    defer pair_close(pair);

    var out: [4]Event = undefined;
    try poller.arm(pair.a, .write, 5);
    // The write readiness is already pending in the kernel; disarm must still erase it.
    poller.disarm(pair.a, .write);
    try testing.expectEqual(@as(u32, 0), poller.wait(0, &out));
    try testing.expect(!poller.is_armed(pair.a, .write));
}

test "poller: disarm erases an event already pending in the kernel" {
    try run_case(case_disarm_drops_pending_event);
}

fn case_hangup(comptime P: type) !void {
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = 4 });
    defer poller.deinit(testing.allocator);

    var pair = pair_open();
    defer pair_close(pair);

    try poller.arm(pair.a, .read, 33);
    close_fd(pair.b);
    pair.b = -1;
    var out: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 1), poller.wait(wait_ns_max, &out));
    try expect_event(out[0], 33, .read, true);
    try testing.expect(!poller.is_armed(pair.a, .read));
}

test "poller: peer close reports hangup" {
    try run_case(case_hangup);
}

fn case_wake_unblocks(comptime P: type) !void {
    const Waker = struct {
        fn run(poller: *const P) void {
            sleep_ms(20);
            poller.wake();
        }
    };
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = 4 });
    defer poller.deinit(testing.allocator);

    const thread = try std.Thread.spawn(.{}, Waker.run, .{&poller});
    defer thread.join(); // Declared after `poller.deinit`'s defer, so it runs first.

    var out: [4]Event = undefined;
    const started = now_ns();
    try testing.expectEqual(@as(u32, 0), poller.wait(wake_wait_ns, &out));
    // A lost wake would have burned the whole timeout.
    try testing.expect(now_ns() - started < wake_wait_ns);
}

test "poller: wake from another thread unblocks an unbounded wait" {
    try run_case(case_wake_unblocks);
}

fn case_wake_latched(comptime P: type) !void {
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = 4 });
    defer poller.deinit(testing.allocator);

    var out: [4]Event = undefined;
    poller.wake();
    poller.wake();
    poller.wake();
    // Latched: the wake that landed before the wait makes it return at once, with no event.
    const woken = now_ns();
    try testing.expectEqual(@as(u32, 0), poller.wait(wake_wait_ns, &out));
    try testing.expect(now_ns() - woken < wake_wait_ns);
    // Coalesced: the three wakes were one, so the next wait blocks the whole timeout.
    const started = now_ns();
    try testing.expectEqual(@as(u32, 0), poller.wait(10 * ms_ns, &out));
    try testing.expect(now_ns() - started >= 10 * ms_ns);
}

test "poller: wakes are latched and coalesced" {
    try run_case(case_wake_latched);
}

fn case_timeout(comptime P: type) !void {
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = 4 });
    defer poller.deinit(testing.allocator);

    var out: [4]Event = undefined;
    const started = now_ns();
    try testing.expectEqual(@as(u32, 0), poller.wait(10 * ms_ns, &out));
    try testing.expect(now_ns() - started >= 10 * ms_ns);
    try testing.expectEqual(@as(u32, 0), poller.wait(0, &out));
}

test "poller: a timed wait blocks its timeout and a zero wait polls" {
    try run_case(case_timeout);
}

fn case_registrations_max(comptime P: type) !void {
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = 2 });
    defer poller.deinit(testing.allocator);

    const first = pair_open();
    defer pair_close(first);

    const second = pair_open();
    defer pair_close(second);

    try poller.arm(first.a, .read, 1);
    try poller.arm(first.a, .write, 2);
    try testing.expectError(error.SystemResources, poller.arm(second.a, .read, 3));
    try testing.expect(!poller.is_armed(second.a, .read));
    poller.disarm(first.a, .write);
    try poller.arm(second.a, .read, 3);
    try testing.expect(poller.is_armed(second.a, .read));
    poller.disarm(first.a, .read);
    poller.disarm(second.a, .read);
}

test "poller: registrations_max bounds the armed pairs" {
    try run_case(case_registrations_max);
}

fn case_events_do_not_fit(comptime P: type) !void {
    const pairs_max = 4;
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = pairs_max });
    defer poller.deinit(testing.allocator);

    var pairs: [pairs_max]Pair = undefined;
    var opened: usize = 0;
    defer for (pairs[0..opened]) |pair| pair_close(pair);

    for (&pairs, 0..) |*pair, index| {
        pair.* = pair_open();
        opened += 1;
        try poller.arm(pair.a, .read, 10 + index);
        byte_write(pair.b);
    }

    var out: [2]Event = undefined;
    var seen = [_]bool{false} ** pairs_max;
    for ([_]u32{ 2, 2, 0 }) |expected| {
        const n = poller.wait(wait_ns_max * @intFromBool(expected > 0), &out);
        try testing.expectEqual(expected, n);
        for (out[0..n]) |event| {
            try testing.expect(event.token >= 10 and event.token < 10 + pairs_max);
            try testing.expect(!seen[event.token - 10]);
            seen[event.token - 10] = true;
        }
    }
    for (seen) |was_seen| try testing.expect(was_seen);
}

test "poller: events that do not fit in out stay pending" {
    try run_case(case_events_do_not_fit);
}

fn case_flat_allocations(comptime P: type) !void {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var poller: P = undefined;
    try P.init(&poller, gpa, .{ .registrations_max = 8 });
    defer poller.deinit(gpa);

    const pair = pair_open();
    defer pair_close(pair);

    const alloc_index = failing.alloc_index;
    const resize_index = failing.resize_index;
    const freed_bytes = failing.freed_bytes;
    var out: [4]Event = undefined;
    const cycles_max: u32 = 10_000;
    for (0..cycles_max) |_| {
        try poller.arm(pair.a, .read, 1);
        byte_write(pair.b);
        try testing.expectEqual(@as(u32, 1), poller.wait(wait_ns_max, &out));
        try testing.expect(byte_read(pair.a));
        try poller.arm(pair.a, .write, 2);
        poller.disarm(pair.a, .write);
    }
    try testing.expectEqual(alloc_index, failing.alloc_index);
    try testing.expectEqual(resize_index, failing.resize_index);
    try testing.expectEqual(freed_bytes, failing.freed_bytes);
}

test "poller: no allocation after init over 10_000 cycles" {
    try run_case(case_flat_allocations);
}

fn case_init_oom_leaks_no_fd(comptime P: type) !void {
    const pair = pair_open();
    defer pair_close(pair);

    const probe_before = fd_probe(pair.a);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var poller: P = undefined;
    try testing.expectError(
        error.OutOfMemory,
        P.init(&poller, failing.allocator(), .{ .registrations_max = 8 }),
    );
    try testing.expectEqual(probe_before, fd_probe(pair.a));
    try testing.expectEqual(@as(usize, 0), failing.allocated_bytes - failing.freed_bytes);
}

/// The lowest free descriptor number: a leaked kernel queue would shift it.
fn fd_probe(open_fd: fd_t) fd_t {
    const rc = system.dup(open_fd);
    assert_always(posix.errno(rc) == .SUCCESS);
    const fd: fd_t = @intCast(rc);
    close_fd(fd);
    return fd;
}

test "poller: init out of memory leaves no descriptor open" {
    try run_case(case_init_oom_leaks_no_fd);
}

fn case_unpollable(comptime P: type) !void {
    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = 4 });
    defer poller.deinit(testing.allocator);

    // The kernel queue refuses character devices such as /dev/null: EINVAL on macOS, EPERM on
    // Linux.
    const opened = system.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    assert_always(posix.errno(opened) == .SUCCESS);
    const fd: fd_t = @intCast(opened);
    defer close_fd(fd);

    try testing.expectError(error.Unpollable, poller.arm(fd, .read, 1));
    try testing.expect(!poller.is_armed(fd, .read));
}

test "poller: an fd the kernel will not poll is Unpollable" {
    if (comptime shared.Native == void) return error.SkipZigTest;
    try run_case(case_unpollable);
}

/// The model test's world: eight socket pairs, a shadow of what is armed, and which bytes
/// are in flight. The poller must agree with the shadow after every operation.
const Shadow = struct {
    const pairs_max = 8;

    pairs: [pairs_max]Pair,
    armed: [pairs_max][2]bool,
    pending: [pairs_max]bool,

    fn token(index: usize, interest: Interest) u64 {
        return index * 2 + @intFromEnum(interest) + 1;
    }

    fn ready(shadow: *const Shadow, index: usize, interest: Interest) bool {
        return switch (interest) {
            .read => shadow.pending[index],
            .write => true,
        };
    }

    fn expected_count(shadow: *const Shadow) u32 {
        var count: u32 = 0;
        for (0..pairs_max) |index| {
            for ([_]Interest{ .read, .write }) |interest| {
                const is_armed = shadow.armed[index][@intFromEnum(interest)];
                if (is_armed and shadow.ready(index, interest)) count += 1;
            }
        }
        return count;
    }

    fn poke(shadow: *Shadow, index: usize) void {
        if (shadow.pending[index]) return;
        byte_write(shadow.pairs[index].b);
        shadow.pending[index] = true;
    }

    fn drain(shadow: *Shadow, index: usize) !void {
        if (!shadow.pending[index]) return;
        try testing.expect(byte_read(shadow.pairs[index].a));
        shadow.pending[index] = false;
    }

    /// An event is valid when its pair was armed and ready; it then consumes the registration.
    fn consume(shadow: *Shadow, event: Event) !void {
        const index: usize = @intCast((event.token - 1) / 2);
        const slot = &shadow.armed[index][@intFromEnum(event.interest)];
        try testing.expectEqual(token(index, event.interest), event.token);
        try testing.expect(slot.*);
        try testing.expect(shadow.ready(index, event.interest));
        try testing.expect(!event.hangup);
        slot.* = false;
    }
};

fn model_check_armed(comptime P: type, poller: *const P, shadow: *const Shadow) !void {
    for (0..Shadow.pairs_max) |index| {
        for ([_]Interest{ .read, .write }) |interest| {
            const want = shadow.armed[index][@intFromEnum(interest)];
            try testing.expectEqual(want, poller.is_armed(shadow.pairs[index].a, interest));
        }
    }
}

fn model_arm(comptime P: type, poller: *P, shadow: *Shadow, index: usize, i: Interest) !void {
    const slot = &shadow.armed[index][@intFromEnum(i)];
    if (slot.*) return;
    try poller.arm(shadow.pairs[index].a, i, Shadow.token(index, i));
    slot.* = true;
}

fn model_disarm(comptime P: type, poller: *P, shadow: *Shadow, index: usize, i: Interest) void {
    poller.disarm(shadow.pairs[index].a, i);
    shadow.armed[index][@intFromEnum(i)] = false;
}

/// Polls until the kernel has nothing more to report. A backend may split the two ready
/// interests of one fd over successive waits (epoll reports one raw event per fd), so the count
/// is checked over the rounds, at most one per interest plus the empty one that ends them.
fn model_wait(comptime P: type, poller: *P, shadow: *Shadow) !void {
    var out: [shared.events_max]Event = undefined;
    const expected = shadow.expected_count();
    const rounds_max: u32 = 3;
    var total: u32 = 0;
    var last: u32 = undefined;
    for (0..rounds_max) |_| {
        last = poller.wait(0, &out);
        for (out[0..last]) |event| try shadow.consume(event);
        total += last;
        if (last == 0) break;
    }
    try testing.expectEqual(@as(u32, 0), last);
    try testing.expectEqual(expected, total);
}

fn case_model(comptime P: type) !void {
    const ops_max: u32 = 10_000;
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();

    var poller: P = undefined;
    try P.init(&poller, testing.allocator, .{ .registrations_max = Shadow.pairs_max * 2 });
    defer poller.deinit(testing.allocator);

    var shadow: Shadow = .{
        .pairs = undefined,
        .armed = .{.{ false, false }} ** Shadow.pairs_max,
        .pending = .{false} ** Shadow.pairs_max,
    };
    for (&shadow.pairs) |*pair| pair.* = pair_open();
    defer for (shadow.pairs) |pair| pair_close(pair);

    for (0..ops_max) |_| {
        const index = random.uintLessThan(usize, Shadow.pairs_max);
        const interest: Interest = @enumFromInt(random.uintLessThan(u8, 2));
        switch (random.uintLessThan(u8, 5)) {
            0 => try model_arm(P, &poller, &shadow, index, interest),
            1 => model_disarm(P, &poller, &shadow, index, interest),
            2 => shadow.poke(index),
            3 => try shadow.drain(index),
            else => try model_wait(P, &poller, &shadow),
        }
        try model_check_armed(P, &poller, &shadow);
    }
    for (0..Shadow.pairs_max) |index| {
        model_disarm(P, &poller, &shadow, index, .read);
        model_disarm(P, &poller, &shadow, index, .write);
    }
    try model_check_armed(P, &poller, &shadow);
}

test "poller: seeded model test against a shadow armed set" {
    try run_case(case_model);
}
