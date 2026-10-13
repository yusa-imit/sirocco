//! sirocco.backend.kqueue — the `Poller` for Darwin (FreeBSD later; ADR 0003).
//!
//! Purpose: one kernel queue per scheduler. `arm` registers one `(fd, interest)` pair as a
//! one-shot filter whose `udata` carries the caller's token; `wait` turns delivered filters into
//! `Event`s; `wake` triggers a user filter so any thread can end the carrier's `wait`.
//!
//! Invariants: the bounded `Table` holds exactly the pairs the kernel holds (a one-shot filter
//! leaves both together, in `wait`), so `disarm` knows whether `EV_DELETE` is due and a full
//! table is a typed error before the kernel is asked. Ident 0 of `EVFILT_USER` is the wake
//! latch (`EV_CLEAR`): a trigger before `wait` makes it return at once, triggers coalesce, and
//! delivery resets it. Nothing here reads a clock or allocates after `init`. Only `wake` may run
//! on a thread other than the carrier's.

const std = @import("std");
const stdx = @import("../stdx.zig");
const shared = @import("poller.zig");

const assert = stdx.assert;
const assert_always = stdx.assert_always;
const maybe = stdx.maybe;
const c = std.c;

const Event = shared.Event;
const Interest = shared.Interest;
const fd_t = shared.fd_t;

const Poller = @This();

comptime {
    shared.contract(Poller);
    // The token rides in `Kevent.udata`, a pointer-sized field.
    assert(@sizeOf(usize) == @sizeOf(u64));
}

kq: fd_t,
table: shared.Table,

/// Bounded retries of a kernel call that `EINTR` may interrupt.
const attempts_max: u32 = 8;

/// Longest timeout handed to the kernel; longer requests wait this long and the caller loops.
const timeout_sec_max: u64 = 1 << 30;

const ns_per_s: u64 = 1_000_000_000;

const Filter = @FieldType(c.Kevent, "filter");
const Flags = @FieldType(c.Kevent, "flags");

pub fn init(
    target: *Poller,
    gpa: std.mem.Allocator,
    options: shared.Options,
) shared.InitError!void {
    assert(options.registrations_max > 0);
    assert(options.registrations_max <= shared.registrations_max_limit);
    const kq = c.kqueue();
    if (kq < 0) return switch (c.errno(kq)) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => unreachable, // proof: kqueue(2) documents only EMFILE, ENFILE and ENOMEM.
    };
    errdefer close_fd(kq);

    const latch = event_make(0, c.EVFILT.USER, c.EV.ADD | c.EV.CLEAR, 0, 0);
    if (change_apply(kq, &latch) != .SUCCESS) return error.SystemResources;
    try shared.Table.init(&target.table, gpa, options.registrations_max);
    target.kq = kq;
    assert(target.table.count == 0);
    assert(target.table.count_max == options.registrations_max);
}

pub fn deinit(poller: *Poller, gpa: std.mem.Allocator) void {
    assert(poller.table.count == 0);
    assert(poller.kq >= 0);
    poller.table.deinit(gpa);
    close_fd(poller.kq);
    poller.* = undefined;
}

/// Registers a one-shot filter. Precondition: `(fd, interest)` is not armed and `fd` is an open
/// descriptor other than the queue itself. `SystemResources` when the table or the kernel is
/// full, `Unpollable` when the kernel refuses to poll this kind of descriptor.
pub fn arm(poller: *Poller, fd: fd_t, interest: Interest, token: u64) shared.ArmError!void {
    assert(fd >= 0);
    assert(fd != poller.kq);
    assert_always(!poller.is_armed(fd, interest));
    if (poller.table.count == poller.table.count_max) return error.SystemResources;

    const flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT;
    const change = event_make(@intCast(fd), filter_of(interest), flags, 0, token);
    switch (change_apply(poller.kq, &change)) {
        .SUCCESS => {},
        .NOMEM, .INTR => return error.SystemResources, // INTR: retries exhausted.
        .INVAL => return error.Unpollable,
        else => trap(), // EBADF and the rest: the caller armed a descriptor it does not own.
    }
    // proof: the count was checked above and nothing ran in between, so a slot is free.
    poller.table.insert(shared.key(fd, interest), token) catch unreachable;
    assert(poller.is_armed(fd, interest));
}

pub fn disarm(poller: *Poller, fd: fd_t, interest: Interest) void {
    assert(fd >= 0);
    assert(fd != poller.kq);
    if (poller.table.remove(shared.key(fd, interest)) == null) return;

    const change = event_make(@intCast(fd), filter_of(interest), c.EV.DELETE, 0, 0);
    switch (change_apply(poller.kq, &change)) {
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
    var raw: [shared.events_max]c.Kevent = undefined;
    var no_changes: [1]c.Kevent = undefined;
    var timeout: c.timespec = undefined;
    const timeout_ptr: ?*const c.timespec = if (timeout_ns) |ns|
        timeout_make(&timeout, ns)
    else
        null;

    const rc = c.kevent(poller.kq, &no_changes, 0, &raw, @intCast(out_max), timeout_ptr);
    if (rc < 0) switch (c.errno(rc)) {
        .INTR => return 0,
        else => trap(),
    };
    const raw_count: u32 = @intCast(rc);
    assert(raw_count <= out_max);

    var out_count: u32 = 0;
    for (raw[0..raw_count]) |raw_event| {
        if (raw_event.filter == c.EVFILT.USER) continue;
        out[out_count] = poller.event_take(raw_event);
        out_count += 1;
    }
    assert(out_count <= raw_count);
    return out_count;
}

/// Latched, coalescing, callable from any thread. `change_apply` retries across `EINTR`; any
/// other outcome, including exhausted retries, traps.
pub fn wake(poller: *const Poller) void {
    assert(poller.kq >= 0);
    const trigger = event_make(0, c.EVFILT.USER, 0, c.NOTE.TRIGGER, 0);
    const result = change_apply(poller.kq, &trigger);
    if (result != .SUCCESS) trap();
    assert(result == .SUCCESS);
}

/// One delivered filter becomes one `Event`; its registration left the kernel, so it leaves the
/// table too. A filter the table does not know would be a stale event, which disarm-before-close
/// makes impossible.
fn event_take(poller: *Poller, raw_event: c.Kevent) Event {
    const interest = interest_of(raw_event.filter);
    const entry = poller.table.remove(shared.key(@intCast(raw_event.ident), interest));
    assert_always(entry != null);
    assert_always(entry.? == raw_event.udata);
    const hangup = raw_event.flags & (c.EV.EOF | c.EV.ERROR) != 0;
    maybe(hangup);
    return .{ .token = raw_event.udata, .interest = interest, .hangup = hangup };
}

fn event_make(ident: usize, filter: Filter, flags: Flags, fflags: u32, udata: u64) c.Kevent {
    return .{
        .ident = ident,
        .filter = filter,
        .flags = flags,
        .fflags = fflags,
        .data = 0,
        .udata = @intCast(udata),
    };
}

fn filter_of(interest: Interest) Filter {
    return switch (interest) {
        .read => c.EVFILT.READ,
        .write => c.EVFILT.WRITE,
    };
}

fn interest_of(filter: anytype) Interest {
    if (filter == c.EVFILT.READ) return .read;
    if (filter == c.EVFILT.WRITE) return .write;
    trap(); // Only the two filters `arm` registers can be delivered.
}

/// Applies one change record without asking for events; returns the errno, `.SUCCESS` or `.INTR`
/// being the only outcomes that are not a caller bug or a resource limit.
fn change_apply(kq: fd_t, change: *const c.Kevent) c.E {
    var unused: [1]c.Kevent = undefined;
    for (0..attempts_max) |_| {
        const rc = c.kevent(kq, @ptrCast(change), 1, &unused, 0, null);
        if (rc >= 0) return .SUCCESS;
        const errno = c.errno(rc);
        if (errno != .INTR) return errno;
    }
    return .INTR;
}

fn timeout_make(target: *c.timespec, timeout_ns: u64) *const c.timespec {
    const sec = @min(@divFloor(timeout_ns, ns_per_s), timeout_sec_max);
    const nsec = if (sec == timeout_sec_max) 0 else timeout_ns - sec * ns_per_s;
    assert(nsec < ns_per_s);
    target.* = .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
    return target;
}

fn close_fd(fd: fd_t) void {
    assert(fd >= 0);
    const rc = c.close(fd);
    assert(rc == 0);
}

fn trap() noreturn {
    @trap();
}
