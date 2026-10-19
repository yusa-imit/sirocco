//! sirocco.net_registry — the table of sockets sirocco made, and the fibers parked on them.
//!
//! Purpose: `src/net.zig` enters every socket it creates here (`Options.sockets_max` slots, keyed
//! by fd, allocated with the scheduler). A slot holds one waiter list per interest, linked through
//! `Fiber.wait.prev/next`, and the poller registration is armed exactly while a list is non-empty.
//!
//! Threads: one spin lock guards the slots, the free list, the key table and every waiter list.
//! Any thread may `lookup`, `register`, `unregister` and close; the carrier joins lists
//! (`waiter_enter`), wakes them (`on_event`) and cancels one waiter (`cancel`). Arming and
//! disarming the poller (carrier-only) happens under the lock too, so a close can never slip
//! between a lookup and an arm. A close on the carrier detaches and wakes the waiters at once
//! (`close_on_carrier`). A close on another thread cannot touch the poller: it marks the slot
//! `closing`, detaches the waiters, hands them to `unpark_foreign` with outcome `.closing`, and
//! leaves the fd open; each woken waiter runs `closing_finish` on the carrier, and the last one
//! releases the slot and tells its caller to close the fd (`close_off_carrier`).
//!
//! A file the caller declared non-blocking (`Io.File.Flags.nonblocking`, plan 004 item 7) may
//! wait on the poller too: `lease` enters it for the length of one `operate` call and
//! `lease_release` removes it again, so a file never stays registered after its call and a
//! recycled fd number cannot inherit a registration. Leases are reference-counted per slot
//! because several fibers may wait on one pipe; they share its slot (and count against
//! `sockets_max` once).
//!
//! Invariants: a pair `(slot, interest)` has at most one poller registration; the event wakes
//! every waiter and each retries, so a loser re-arms. A slot has either leases or a socket's
//! ownership, never both (`leases > 0` marks a borrowed file). Nothing here allocates after
//! `init`.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const poller = @import("backend/poller.zig");
const sched_io = @import("sched_io.zig");
const sys = @import("backend/sys.zig");

const Io = std.Io;
const Fiber = Sched.Fiber;
const assert = stdx.assert;
const assert_always = stdx.assert_always;
const fd_t = sys.fd_t;

const spin_max: u32 = 1 << 28;
const index_none: u32 = std.math.maxInt(u32);

const Slot = struct {
    fd: fd_t,
    next_free: u32,
    /// Head of the doubly linked waiters per interest (`Fiber.wait.prev/next`).
    waiters: [2]?*Fiber,
    /// Set by a close from another thread; the slot lives until `closing_pending` waiters finish.
    closing: bool,
    closing_pending: u32,
    /// Fibers holding a `lease` on this file; 0 for a socket's slot.
    leases: u32,
    /// Bumped each time the slot is freed: tells a woken waiter its socket was closed meanwhile.
    generation: u32,
};

/// What `waiter_enter` did.
pub const Enter = enum { parked, gone, resources };

/// The sockets sirocco created on fibers and the fibers waiting on them.
pub const Registry = struct {
    slots: []Slot,
    table: poller.Table,
    free_head: u32,
    mutex: std.atomic.Mutex,

    pub const empty: Registry = .{
        .slots = &.{},
        .table = undefined,
        .free_head = index_none,
        .mutex = .unlocked,
    };

    pub fn init(
        target: *Registry,
        gpa: std.mem.Allocator,
        sockets_max: u32,
    ) error{OutOfMemory}!void {
        assert(sockets_max > 0);
        assert(sockets_max <= poller.registrations_max_limit);
        const slots = try gpa.alloc(Slot, sockets_max);
        errdefer gpa.free(slots);

        try poller.Table.init(&target.table, gpa, sockets_max);
        for (slots, 0..) |*slot, index| {
            const next: u32 = @intCast(index + 1);
            slot.* = .{
                .fd = -1,
                .next_free = if (next == slots.len) index_none else next,
                .waiters = .{ null, null },
                .closing = false,
                .closing_pending = 0,
                .leases = 0,
                .generation = 0,
            };
        }
        target.slots = slots;
        target.free_head = 0;
        target.mutex = .unlocked;
        assert(target.table.count == 0);
    }

    pub fn deinit(registry: *Registry, gpa: std.mem.Allocator) void {
        if (registry.slots.len == 0) return;
        assert(registry.table.count <= registry.table.count_max);
        registry.table.deinit(gpa);
        gpa.free(registry.slots);
        registry.* = .empty;
    }

    /// False under `.threaded`, where every slot takes the offload path.
    pub fn enabled(registry: *const Registry) bool {
        return registry.slots.len > 0;
    }

    /// Sockets entered, closing ones included; 0 for a disabled registry. Any thread.
    pub fn count(registry: *Registry) u32 {
        if (!registry.enabled()) return 0;

        registry.lock();
        defer registry.mutex.unlock();

        return registry.table.count;
    }

    /// True while a slot is free. Any thread; a hint, since another thread may take the slot.
    pub fn has_room(registry: *Registry) bool {
        registry.lock();
        defer registry.mutex.unlock();

        return registry.free_head != index_none;
    }

    /// The slot of `fd`, or null when it is unknown or being closed. Any thread.
    pub fn lookup(registry: *Registry, fd: fd_t) ?u32 {
        registry.lock();
        defer registry.mutex.unlock();

        const found = registry.table.get(poller.key(fd, .read)) orelse return null;
        const index: u32 = @intCast(found);
        if (registry.slots[index].closing) return null;
        return index;
    }

    /// Enters `fd`, replacing the stale entry of a recycled fd number. `error.Full` when no slot
    /// is free. Any thread. A stale entry still holding waiters means someone closed a registered
    /// socket behind the runtime's back while fibers waited on it: a caller bug, asserted.
    pub fn register(registry: *Registry, fd: fd_t) error{Full}!u32 {
        assert(fd >= 0);
        registry.lock();
        defer registry.mutex.unlock();

        if (registry.table.get(poller.key(fd, .read))) |stale| {
            const old = &registry.slots[@intCast(stale)];
            assert_always(old.waiters[0] == null and old.waiters[1] == null);
            assert_always(!old.closing);
            release_locked(registry, stale);
        }
        return insert_locked(registry, fd);
    }

    /// What `lease` found: `.held` when the caller now owes a `lease_release`, `.socket` when
    /// `fd` belongs to a socket sirocco made (or is closing), which needs no release.
    pub const Lease = enum { held, socket };

    /// Enters `fd`, a file declared non-blocking, for one `operate` call, or joins the lease of
    /// another fiber on the same file. `error.Full` when no slot is free. Carrier-only in
    /// practice; the lock makes any thread safe.
    pub fn lease(registry: *Registry, fd: fd_t) error{Full}!Lease {
        assert(fd >= 0);
        registry.lock();
        defer registry.mutex.unlock();

        if (registry.table.get(poller.key(fd, .read))) |found| {
            const slot = &registry.slots[@intCast(found)];
            if (slot.leases == 0) return .socket;
            slot.leases += 1;
            return .held;
        }
        const index = try insert_locked(registry, fd);
        registry.slots[index].leases = 1;
        return .held;
    }

    /// Ends one `lease`; the last one frees the slot. Tolerates an entry that is gone or no
    /// longer a lease (the file was closed and its number reused under the call, a caller bug
    /// that must not corrupt a socket's slot). The leaser has left every waiter list by now.
    pub fn lease_release(registry: *Registry, fd: fd_t) void {
        assert(fd >= 0);
        registry.lock();
        defer registry.mutex.unlock();

        const found = registry.table.get(poller.key(fd, .read)) orelse return;
        const slot = &registry.slots[@intCast(found)];
        if (slot.leases == 0) return;
        slot.leases -= 1;
        if (slot.leases > 0) return;
        assert_always(slot.waiters[0] == null);
        assert_always(slot.waiters[1] == null);
        release_locked(registry, found);
    }

    fn insert_locked(registry: *Registry, fd: fd_t) error{Full}!u32 {
        const index = registry.free_head;
        if (index == index_none) return error.Full;
        const slot = &registry.slots[index];
        registry.free_head = slot.next_free;
        slot.* = .{
            .fd = fd,
            .next_free = index_none,
            .waiters = .{ null, null },
            .closing = false,
            .closing_pending = 0,
            .leases = 0,
            .generation = slot.generation,
        };
        assert(registry.table.count < registry.table.count_max);
        registry.table.insert(poller.key(fd, .read), index) catch |err| switch (err) {
            // Proof: every table entry owns one occupied slot and the table holds as many entries
            // as there are slots; a free slot was just taken, so `count < count_max` (asserted).
            error.SystemResources => unreachable,
        };
        return index;
    }

    /// Removes `fd`, which must have no waiters; false when it was not entered. Any thread.
    pub fn unregister(registry: *Registry, fd: fd_t) bool {
        registry.lock();
        defer registry.mutex.unlock();

        const index = registry.table.get(poller.key(fd, .read)) orelse return false;
        const slot = &registry.slots[@intCast(index)];
        assert_always(slot.waiters[0] == null and slot.waiters[1] == null);
        release_locked(registry, index);
        return true;
    }

    /// Joins the waiter list of `(fd, interest)` and arms the poller when the list was empty,
    /// in one lock hold. `.gone` when `fd` is unknown or closing, `.resources` when the poller
    /// refused (the fiber is not left on the list). Carrier-only.
    pub fn waiter_enter(
        registry: *Registry,
        sched: *Sched,
        fd: fd_t,
        interest: poller.Interest,
        fiber: *Fiber,
    ) Enter {
        assert(fiber.wait.outcome == .idle);
        assert(fiber.state == .running);
        registry.lock();
        defer registry.mutex.unlock();

        const found = registry.table.get(poller.key(fd, .read)) orelse return .gone;
        const index: u32 = @intCast(found);
        const slot = &registry.slots[index];
        assert_always(slot.fd == fd);
        if (slot.closing) return .gone;
        const list_empty = slot.waiters[interest_index(interest)] == null;
        waiter_push(slot, index, interest, fiber);
        if (list_empty) sched_io.arm(sched, fd, interest, index) catch {
            waiter_remove(slot, fiber);
            fiber.wait = .none;
            return .resources;
        };
        return .parked;
    }

    /// The generation of slot `index`, to be compared later by `still_open`. Any thread.
    pub fn generation_of(registry: *Registry, index: u32) u32 {
        registry.lock();
        defer registry.mutex.unlock();

        assert(index < registry.slots.len);
        return registry.slots[index].generation;
    }

    /// True while slot `index` still holds `fd` as the same, not closing, socket it held when
    /// `generation` was read. A fiber woken by an event checks it before retrying its syscall:
    /// a close in the window between wake and run left the fd closed or reused. Any thread.
    pub fn still_open(registry: *Registry, index: u32, generation: u32, fd: fd_t) bool {
        registry.lock();
        defer registry.mutex.unlock();

        assert(index < registry.slots.len);
        const slot = &registry.slots[index];
        if (slot.generation != generation) return false;
        assert_always(slot.fd == fd); // Same generation, same socket.
        return !slot.closing;
    }

    /// One waiter leaves because a cancelation reached it: unlink, disarm when it was the last,
    /// make it runnable with outcome `.canceled`. A no-op when an event or a close ended its wait
    /// first. Carrier-only; `fiber.wait.socket != .none`.
    pub fn cancel(registry: *Registry, sched: *Sched, fiber: *Fiber) void {
        assert(fiber.wait.socket != .none);
        registry.lock();
        defer registry.mutex.unlock();

        if (fiber.wait.outcome != .waiting) return;
        assert(fiber.state == .parked);
        const slot = &registry.slots[@intCast(fiber.wait.addr)];
        const interest = interest_of(fiber);
        waiter_remove(slot, fiber);
        if (slot.waiters[interest_index(interest)] == null) {
            sched_io.disarm(sched, slot.fd, interest);
        }
        fiber.wait.outcome = .canceled;
        sched.unpark(fiber);
    }

    /// Close of `fd` on the carrier, from a fiber: disarm, wake every waiter with `.closed`
    /// (they touch nothing of the slot again) and free the slot. True when the caller closes the fd
    /// (also when `fd` is not entered); false when a close from another thread got there first and
    /// left the fd to its last waiter, so a second close must not touch it.
    pub fn close_on_carrier(registry: *Registry, sched: *Sched, fd: fd_t) bool {
        assert(sched.in_fiber());
        registry.lock();
        defer registry.mutex.unlock();

        const found = registry.table.get(poller.key(fd, .read)) orelse return true;
        const index: u32 = @intCast(found);
        const slot = &registry.slots[index];
        if (slot.closing) return false;
        for (slot.waiters, 0..) |head, side| {
            if (head == null) continue;
            sched_io.disarm(sched, fd, if (side == 0) .read else .write);
            var waiter = head;
            for (0..sched.fibers.len + 1) |_| {
                const fiber = waiter orelse break;
                waiter = fiber.wait.next;
                fiber.wait.prev = null;
                fiber.wait.next = null;
                fiber.wait.outcome = .closed;
                sched.unpark(fiber);
            }
            assert_always(waiter == null); // More waiters than fibers: the list is corrupt.
        }
        release_locked(registry, index);
        return true;
    }

    /// Close of `fd` from a thread that is not the carrier's fiber. With no waiter the slot is
    /// freed and the result is true: the caller closes the fd. With waiters the slot is marked
    /// closing, they are woken with `.closing`, and the result is false: the fd stays open until
    /// the last waiter has run `closing_finish`. A second close of a closing slot is a no-op.
    pub fn close_off_carrier(registry: *Registry, sched: *Sched, io: Io, fd: fd_t) bool {
        registry.lock();
        defer registry.mutex.unlock();

        const found = registry.table.get(poller.key(fd, .read)) orelse return true;
        const index: u32 = @intCast(found);
        const slot = &registry.slots[index];
        if (slot.closing) return false;
        var pending: u32 = 0;
        for (slot.waiters) |head| {
            var waiter = head;
            for (0..sched.fibers.len + 1) |_| {
                const fiber = waiter orelse break;
                waiter = fiber.wait.next;
                pending += 1;
            }
            assert_always(waiter == null); // More waiters than fibers: the list is corrupt.
        }
        if (pending == 0) {
            release_locked(registry, index);
            return true;
        }
        slot.closing = true;
        slot.closing_pending = pending;
        const heads = slot.waiters;
        slot.waiters = .{ null, null };
        for (heads) |head| {
            var waiter = head;
            for (0..sched.fibers.len + 1) |_| {
                const fiber = waiter orelse break;
                waiter = fiber.wait.next; // Read before the hand-off: the carrier may reuse it.
                fiber.wait.prev = null;
                fiber.wait.next = null;
                fiber.wait.outcome = .closing;
                sched.unpark_foreign(io, fiber);
            }
            assert_always(waiter == null); // Counted above: the list is intact.
        }
        return false;
    }

    /// A waiter woken with `.closing` leaves: disarm its interest (idempotent) and count itself
    /// out. True for the last one, whose slot is freed and whose caller must close the fd.
    /// Carrier-only.
    pub fn closing_finish(
        registry: *Registry,
        sched: *Sched,
        fd: fd_t,
        interest: poller.Interest,
    ) bool {
        registry.lock();
        defer registry.mutex.unlock();

        const found = registry.table.get(poller.key(fd, .read));
        assert_always(found != null); // The fd stays open, so its entry stays, until the last.
        const index: u32 = @intCast(found.?);
        const slot = &registry.slots[index];
        assert_always(slot.closing);
        assert_always(slot.closing_pending > 0);
        sched_io.disarm(sched, fd, interest);
        slot.closing_pending -= 1;
        if (slot.closing_pending > 0) return false;
        release_locked(registry, index);
        return true;
    }

    fn release_locked(registry: *Registry, index: u64) void {
        const slot = &registry.slots[@intCast(index)];
        assert(slot.fd >= 0);
        assert_always(registry.table.remove(poller.key(slot.fd, .read)) == index);
        slot.fd = -1;
        slot.waiters = .{ null, null };
        slot.closing = false;
        slot.closing_pending = 0;
        slot.leases = 0;
        slot.generation +%= 1;
        slot.next_free = registry.free_head;
        registry.free_head = @intCast(index);
    }

    fn lock(registry: *Registry) void {
        for (0..spin_max) |_| {
            if (registry.mutex.tryLock()) return;
            std.atomic.spinLoopHint();
        }
        assert_always(false); // The lock is held for a hash lookup; this is a deadlock.
    }
};

fn interest_index(interest: poller.Interest) usize {
    return @intFromEnum(interest);
}

fn interest_of(fiber: *const Fiber) poller.Interest {
    assert(fiber.wait.socket != .none);
    return if (fiber.wait.socket == .read) .read else .write;
}

fn waiter_push(slot: *Slot, index: u32, interest: poller.Interest, fiber: *Fiber) void {
    const head = &slot.waiters[interest_index(interest)];
    fiber.wait = .{
        .addr = index,
        .prev = null,
        .next = head.*,
        .sleeping = false,
        .outcome = .waiting,
        .socket = switch (interest) {
            .read => .read,
            .write => .write,
        },
    };
    if (head.*) |first| first.wait.prev = fiber;
    head.* = fiber;
}

fn waiter_remove(slot: *Slot, fiber: *Fiber) void {
    const head = &slot.waiters[interest_index(interest_of(fiber))];
    if (fiber.wait.prev) |prev| prev.wait.next = fiber.wait.next else head.* = fiber.wait.next;
    if (fiber.wait.next) |next| next.wait.prev = fiber.wait.prev;
    fiber.wait.prev = null;
    fiber.wait.next = null;
}

/// The handler `Sched` calls for each event: wake every fiber waiting on the slot and interest.
/// A closing slot has no waiters left (a foreign close detached them), so its event is dropped.
pub fn on_event(ctx: *anyopaque, sched: *Sched, event: poller.Event) void {
    const registry: *Registry = @ptrCast(@alignCast(ctx));
    registry.lock();
    defer registry.mutex.unlock();

    const index: usize = @intCast(event.token);
    assert(index < registry.slots.len);
    const slot = &registry.slots[index];
    const head = &slot.waiters[interest_index(event.interest)];
    if (slot.closing) return assert(head.* == null);

    assert_always(head.* != null); // Armed exactly while the list is non-empty.
    var waiter = head.*;
    head.* = null;
    for (0..sched.fibers.len + 1) |_| {
        const fiber = waiter orelse break;
        waiter = fiber.wait.next;
        fiber.wait.prev = null;
        fiber.wait.next = null;
        fiber.wait.outcome = .woken;
        sched.unpark(fiber);
    }
    assert_always(waiter == null); // More waiters than fibers: the list is corrupt.
}

test "registry: slots recycle, a recycled fd replaces a stale entry, a full registry says so" {
    var registry: Registry = .empty;
    try registry.init(std.testing.allocator, 2);
    defer registry.deinit(std.testing.allocator);

    try std.testing.expect(registry.enabled());
    const first = try registry.register(10);
    const second = try registry.register(11);
    try std.testing.expect(first != second);
    try std.testing.expectError(error.Full, registry.register(12));
    try std.testing.expectEqual(@as(?u32, first), registry.lookup(10));
    // fd 10 was closed behind our back and the number reused: the stale entry is replaced and
    // its slot is the one handed out again.
    try std.testing.expectEqual(first, try registry.register(10));
    try std.testing.expectEqual(@as(u32, 2), registry.count());
    try std.testing.expect(registry.unregister(11));
    try std.testing.expect(!registry.unregister(11));
    try std.testing.expect(registry.has_room());
    try std.testing.expect(registry.unregister(10));
    try std.testing.expectEqual(@as(u32, 0), registry.count());
}

test "registry: a closing slot is invisible to lookup and its table entry stays" {
    var registry: Registry = .empty;
    try registry.init(std.testing.allocator, 2);
    defer registry.deinit(std.testing.allocator);

    const index = try registry.register(7);
    registry.slots[index].closing = true;
    try std.testing.expectEqual(@as(?u32, null), registry.lookup(7));
    try std.testing.expectEqual(@as(u32, 1), registry.count());
    registry.slots[index].closing = false;
    try std.testing.expect(registry.unregister(7));
}

test "registry: a freed slot changes generation, so a woken waiter sees the close" {
    var registry: Registry = .empty;
    try registry.init(std.testing.allocator, 1);
    defer registry.deinit(std.testing.allocator);

    const index = try registry.register(9);
    const generation = registry.generation_of(index);
    try std.testing.expect(registry.still_open(index, generation, 9));
    try std.testing.expect(registry.unregister(9));
    // The same fd number registered again lands in the same slot, yet is not the same socket.
    try std.testing.expectEqual(index, try registry.register(9));
    try std.testing.expect(!registry.still_open(index, generation, 9));
    registry.slots[index].closing = true;
    try std.testing.expect(!registry.still_open(index, registry.generation_of(index), 9));
    registry.slots[index].closing = false;
    try std.testing.expect(registry.unregister(9));
}

test "registry: leases share one slot, the last release frees it, a socket is never leased" {
    var registry: Registry = .empty;
    try registry.init(std.testing.allocator, 2);
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(Registry.Lease.held, try registry.lease(20));
    try std.testing.expectEqual(Registry.Lease.held, try registry.lease(20));
    try std.testing.expectEqual(@as(u32, 1), registry.count());
    registry.lease_release(20);
    try std.testing.expectEqual(@as(u32, 1), registry.count());
    registry.lease_release(20);
    try std.testing.expectEqual(@as(u32, 0), registry.count());
    registry.lease_release(20); // Already gone: tolerated.

    _ = try registry.register(21);
    try std.testing.expectEqual(Registry.Lease.socket, try registry.lease(21));
    registry.lease_release(21); // Not a lease: the socket's slot survives.
    try std.testing.expect(registry.lookup(21) != null);
    try std.testing.expect(registry.unregister(21));
}

test "registry: a lease on a full registry says so and leaves the registry alone" {
    var registry: Registry = .empty;
    try registry.init(std.testing.allocator, 1);
    defer registry.deinit(std.testing.allocator);

    _ = try registry.register(30);
    try std.testing.expectError(error.Full, registry.lease(31));
    try std.testing.expectEqual(@as(u32, 1), registry.count());
    try std.testing.expect(registry.unregister(30));
    try std.testing.expectEqual(Registry.Lease.held, try registry.lease(31));
    registry.lease_release(31);
    try std.testing.expectEqual(@as(u32, 0), registry.count());
}
