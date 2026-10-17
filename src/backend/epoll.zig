//! sirocco.backend.epoll — the `Poller` for Linux (ADR 0003).
//!
//! Purpose: one epoll instance per scheduler. `arm` registers one `(fd, interest)` pair as a
//! one-shot interest whose token lives in the bounded table; `wait` turns delivered readiness
//! into `Event`s; `wake` writes an `eventfd` so any thread can end the carrier's `wait`.
//!
//! Invariants: epoll keeps one registration per fd, so read and write interest of one fd share
//! it. The bounded `Table` is the truth about which pairs are armed; the kernel entry of an fd
//! is enabled exactly while some pair of that fd is armed, and may linger disabled after its
//! last one-shot fired (closing the fd removes it, and `arm` re-enables it with `EPOLL_CTL_MOD`
//! when `EPOLL_CTL_ADD` reports `EEXIST`). One raw event yields at most one `Event`: when both
//! interests of an fd are armed, the other one is re-armed and, epoll being level-triggered, is
//! reported by the next `wait`. The `eventfd` is the wake latch (level-triggered, never
//! one-shot): a `wake` before `wait` makes it return at once, wakes coalesce in the counter,
//! and `wait` reads it to reset. Nothing here reads a clock or allocates after `init`. Only
//! `wake` may run on a thread other than the carrier's. Timeouts round up to whole
//! milliseconds, because `epoll_wait` has no finer unit: `wait` may return up to 1 ms late,
//! never early.

const std = @import("std");
const stdx = @import("../stdx.zig");
const shared = @import("poller.zig");

const assert = stdx.assert;
const assert_always = stdx.assert_always;
const maybe = stdx.maybe;
const linux = std.os.linux;

const Event = shared.Event;
const Interest = shared.Interest;
const fd_t = shared.fd_t;

const Poller = @This();

comptime {
    shared.contract(Poller);
    // The token is table-resident; `data` carries the fd, which fits an `i32`.
    assert(@sizeOf(linux.epoll_data) == 8);
}

epfd: fd_t,
wake_fd: fd_t,
table: shared.Table,

/// Bounded retries of a kernel call that `EINTR` may interrupt.
const attempts_max: u32 = 8;

/// Longest timeout handed to the kernel in milliseconds; longer requests wait this long and the
/// caller loops.
const timeout_ms_max: u64 = std.math.maxInt(i32);

const ns_per_ms: u64 = 1_000_000;

/// `epoll_event.data` of the wake latch; no fd produces it.
const wake_data: u64 = std.math.maxInt(u64);

pub fn init(
    target: *Poller,
    gpa: std.mem.Allocator,
    options: shared.Options,
) shared.InitError!void {
    assert(options.registrations_max > 0);
    assert(options.registrations_max <= shared.registrations_max_limit);
    const epfd = try fd_create(linux.epoll_create1(linux.EPOLL.CLOEXEC));
    errdefer close_fd(epfd);

    const wake_flags: u32 = linux.EFD.NONBLOCK | linux.EFD.CLOEXEC;
    const wake_fd = try fd_create(linux.eventfd(0, wake_flags));
    errdefer close_fd(wake_fd);

    var latch: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = wake_data } };
    switch (linux.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, wake_fd, &latch))) {
        .SUCCESS => {},
        else => return error.SystemResources,
    }
    try shared.Table.init(&target.table, gpa, options.registrations_max);
    target.epfd = epfd;
    target.wake_fd = wake_fd;
    assert(target.table.count == 0);
    assert(target.table.count_max == options.registrations_max);
}

pub fn deinit(poller: *Poller, gpa: std.mem.Allocator) void {
    assert(poller.table.count == 0);
    assert(poller.epfd >= 0);
    assert(poller.wake_fd >= 0);
    poller.table.deinit(gpa);
    close_fd(poller.wake_fd);
    close_fd(poller.epfd);
    poller.* = undefined;
}

/// Registers a one-shot interest. Precondition: `(fd, interest)` is not armed and `fd` is an
/// open descriptor other than the poller's own. `SystemResources` when the table or the kernel
/// is full, `Unpollable` when the kernel refuses to poll this kind of descriptor (regular files).
pub fn arm(poller: *Poller, fd: fd_t, interest: Interest, token: u64) shared.ArmError!void {
    assert(fd >= 0);
    assert(fd != poller.epfd);
    assert(fd != poller.wake_fd);
    assert_always(!poller.is_armed(fd, interest));
    if (poller.table.count == poller.table.count_max) return error.SystemResources;

    const other = other_of(interest);
    const mask = events_of(interest) | if (poller.is_armed(fd, other)) events_of(other) else 0;
    // The kernel entry exists and is enabled while the other interest is armed.
    const op: u32 = if (poller.is_armed(fd, other)) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
    switch (poller.ctl(op, fd, mask)) {
        .SUCCESS => {},
        // A one-shot that fired left a disabled entry behind; re-enable it.
        .EXIST => switch (poller.ctl(linux.EPOLL.CTL_MOD, fd, mask)) {
            .SUCCESS => {},
            else => trap(), // The entry was just reported to exist.
        },
        .NOMEM, .NOSPC, .INTR => return error.SystemResources, // INTR: retries exhausted.
        .PERM => return error.Unpollable,
        else => trap(), // EBADF and the rest: the caller armed a descriptor it does not own.
    }
    // proof: the count was checked above and nothing ran in between, so a slot is free.
    poller.table.insert(shared.key(fd, interest), token) catch unreachable;
    assert(poller.is_armed(fd, interest));
}

pub fn disarm(poller: *Poller, fd: fd_t, interest: Interest) void {
    assert(fd >= 0);
    assert(fd != poller.epfd);
    if (poller.table.remove(shared.key(fd, interest)) == null) return;

    // The kernel entry is enabled while a pair of this fd is armed; keep it for the other one.
    const other = other_of(interest);
    const result = if (poller.is_armed(fd, other))
        poller.ctl(linux.EPOLL.CTL_MOD, fd, events_of(other))
    else
        poller.ctl(linux.EPOLL.CTL_DEL, fd, 0);
    switch (result) {
        .SUCCESS => {},
        else => trap(), // The table said armed, so the kernel must hold it.
    }
    assert(!poller.is_armed(fd, interest));
}

pub fn is_armed(poller: *const Poller, fd: fd_t, interest: Interest) bool {
    assert(fd >= 0);
    assert(poller.table.count <= poller.table.count_max);
    return poller.table.get(shared.key(fd, interest)) != null;
}

/// Blocks until an event, a wake or the timeout. `null` waits forever, `0` polls. Returns the
/// number of events written to `out`; 0 is also a wake, an interrupt, or a timeout. At most
/// `shared.events_max` events move per call: a longer `out` is clamped, not rejected, and the
/// rest stay pending in the kernel.
pub fn wait(poller: *Poller, timeout_ns: ?u64, out: []Event) u32 {
    assert(out.len >= 1);
    const out_max: u32 = @intCast(@min(out.len, shared.events_max));
    assert(out_max >= 1);
    var raw: [shared.events_max]linux.epoll_event = undefined;
    const timeout_ms = timeout_make(timeout_ns);

    const rc = linux.epoll_wait(poller.epfd, &raw, out_max, timeout_ms);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .INTR => return 0,
        else => trap(),
    }
    const raw_count: u32 = @intCast(rc);
    assert(raw_count <= out_max);

    var out_count: u32 = 0;
    for (raw[0..raw_count]) |raw_event| {
        if (raw_event.data.u64 == wake_data) {
            poller.wake_reset();
            continue;
        }
        out[out_count] = poller.event_take(raw_event);
        out_count += 1;
    }
    assert(out_count <= raw_count);
    return out_count;
}

/// Latched, coalescing, callable from any thread. A full counter (`EAGAIN`) already holds a
/// pending wake; `EINTR` retries; any other outcome traps.
pub fn wake(poller: *const Poller) void {
    assert(poller.wake_fd >= 0);
    const one: u64 = 1;
    for (0..attempts_max) |_| {
        const rc = linux.write(poller.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .AGAIN => return,
            .INTR => continue,
            else => trap(),
        }
    }
    trap(); // Interrupted `attempts_max` times in a row.
}

/// One raw readiness becomes one `Event`; the pair it names leaves the table. When the fd's
/// other interest is still armed it is re-armed in the kernel (the one-shot disabled the whole
/// entry) and reported by the next `wait`. A readiness the table does not know would be a stale
/// event, which disarm-before-close makes impossible.
fn event_take(poller: *Poller, raw_event: linux.epoll_event) Event {
    const fd: fd_t = @intCast(raw_event.data.u64);
    const ready = raw_event.events;
    const hangup = ready & (linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP) != 0;
    maybe(hangup);
    // HUP and ERR are reported whatever was asked for, and either interest may consume them.
    const read_mask = linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.ERR | linux.EPOLL.HUP;
    const read_ready = ready & read_mask != 0;
    const interest: Interest = if (read_ready and poller.is_armed(fd, .read))
        .read
    else if (poller.is_armed(fd, .write))
        .write
    else
        trap(); // An enabled entry always has an armed interest behind it.

    const entry = poller.table.remove(shared.key(fd, interest));
    assert_always(entry != null);
    const other = other_of(interest);
    if (poller.is_armed(fd, other)) {
        switch (poller.ctl(linux.EPOLL.CTL_MOD, fd, events_of(other))) {
            .SUCCESS => {},
            else => trap(), // The entry was enabled a moment ago.
        }
    }
    return .{ .token = entry.?, .interest = interest, .hangup = hangup };
}

fn wake_reset(poller: *const Poller) void {
    var counter: u64 = undefined;
    const rc = linux.read(poller.wake_fd, std.mem.asBytes(&counter), @sizeOf(u64));
    switch (linux.errno(rc)) {
        .SUCCESS => assert(counter >= 1),
        .AGAIN, .INTR => {}, // Already reset, or the next `wait` finds the latch still set.
        else => trap(),
    }
}

/// One `epoll_ctl` for `fd` with the one-shot `mask`; returns the errno, `.INTR` only after
/// `attempts_max` interrupted tries.
fn ctl(poller: *const Poller, op: u32, fd: fd_t, mask: u32) linux.E {
    var event: linux.epoll_event = .{
        .events = mask | linux.EPOLL.ONESHOT,
        .data = .{ .u64 = @intCast(fd) },
    };
    for (0..attempts_max) |_| {
        const errno = linux.errno(linux.epoll_ctl(poller.epfd, op, fd, &event));
        if (errno != .INTR) return errno;
    }
    return .INTR;
}

fn events_of(interest: Interest) u32 {
    return switch (interest) {
        .read => linux.EPOLL.IN | linux.EPOLL.RDHUP,
        .write => linux.EPOLL.OUT,
    };
}

fn other_of(interest: Interest) Interest {
    return switch (interest) {
        .read => .write,
        .write => .read,
    };
}

/// Milliseconds for `epoll_wait`: -1 waits forever, otherwise the request rounded up so the
/// wait is never early, capped at `timeout_ms_max`.
fn timeout_make(timeout_ns: ?u64) i32 {
    const ns = timeout_ns orelse return -1;
    // proof: `ns_per_ms` is a nonzero constant, so `divCeil` has no error to return.
    const ms = @min(std.math.divCeil(u64, ns, ns_per_ms) catch unreachable, timeout_ms_max);
    assert(ms <= timeout_ms_max);
    return @intCast(ms);
}

fn fd_create(rc: usize) shared.InitError!fd_t {
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM, .NODEV => return error.SystemResources,
        else => unreachable, // proof: epoll_create1(2) and eventfd2(2) document only these.
    }
    return @intCast(rc);
}

fn close_fd(fd: fd_t) void {
    assert(fd >= 0);
    const rc = linux.close(fd);
    assert(linux.errno(rc) == .SUCCESS);
}

fn trap() noreturn {
    @trap();
}

const testing = std.testing;

test "timeout_make: null forever, zero polls, rounds up, caps" {
    try testing.expectEqual(@as(i32, -1), timeout_make(null));
    try testing.expectEqual(@as(i32, 0), timeout_make(0));
    try testing.expectEqual(@as(i32, 1), timeout_make(1));
    try testing.expectEqual(@as(i32, 1), timeout_make(ns_per_ms));
    try testing.expectEqual(@as(i32, 2), timeout_make(ns_per_ms + 1));
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), timeout_make(std.math.maxInt(u64)));
}
