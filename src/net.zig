//! sirocco.net — the native socket-creation slots on the evented poller (plan 004 item 4,
//! ADR 0003 section 3): `netListenIp`, `netBindIp`, `netAccept`, `netConnectIp`,
//! `netListenUnix`, `netConnectUnix`, `netSocketCreatePair`, plus `netClose`, which keeps the
//! registry honest until item 5 moves the data path.
//!
//! Purpose: a socket made on a fiber is `O_NONBLOCK | O_CLOEXEC` and entered in the `Registry`
//! (`Options.sockets_max` entries, keyed by fd, allocated with the scheduler). A would-block
//! arms the poller and parks the fiber; the event, or a cancel, ends the park. Dispatch per ADR:
//! registered handle on a fiber: syscall, park on would-block; registered handle off a fiber:
//! syscall, `poll(2)` on would-block; foreign handle, a full registry, a socket created off a
//! fiber, or an option set this file does not serve (non-TCP mode, interface scopes, connect
//! timeouts, abstract Unix paths): the v0.4.0 offload thunk (which forwards off a fiber).
//!
//! Invariants: a pair `(slot, interest)` has at most one poller registration, armed exactly while
//! its waiter list is non-empty; the event wakes every waiter and each retries, so a loser
//! re-arms. The list links through `Fiber.wait.prev/next`. Under `.threaded` the registry is
//! empty (`enabled` is false) and every slot takes the thunk. A closed fd leaves the registry in
//! `netClose`; waiters on it are woken and see the kernel's error (item 5 sharpens that).
//!
//! Allocation: none after `Registry.init`. Cancelation: a pending request is delivered before the
//! first syscall; one that arrives while parked disarms and unparks (`cancel`), the call closes
//! what it created and returns `error.Canceled`.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");
const concurrency = @import("concurrency.zig");
const offload_slots = @import("offload_slots.zig");
const poller = @import("backend/poller.zig");
const sched_io = @import("sched_io.zig");
const sys = @import("backend/sys.zig");

const Io = std.Io;
const posix = std.posix;
const Fiber = Sched.Fiber;
const assert = stdx.assert;
const assert_always = stdx.assert_always;
const fd_t = sys.fd_t;
const IpAddress = Io.net.IpAddress;
const Socket = Io.net.Socket;

/// Most wake-ups one call tolerates before reporting `WouldBlock` (a spurious-wake guard).
const wakeups_max: u32 = 1 << 24;
const spin_max: u32 = 1 << 28;
const index_none: u32 = std.math.maxInt(u32);

const Slot = struct {
    fd: fd_t,
    next_free: u32,
    /// Head of the doubly linked waiters per interest (`Fiber.wait.prev/next`).
    waiters: [2]?*Fiber,
};

/// The sockets sirocco created on fibers. Lookups may come from any thread (an off-fiber call),
/// mutation of the table and free list is under a short spin lock, waiter lists are carrier-only.
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

    pub fn count(registry: *Registry) u32 {
        registry.lock();
        defer registry.mutex.unlock();

        return registry.table.count;
    }

    pub fn has_room(registry: *Registry) bool {
        registry.lock();
        defer registry.mutex.unlock();

        return registry.free_head != index_none;
    }

    pub fn lookup(registry: *Registry, fd: fd_t) ?u32 {
        registry.lock();
        defer registry.mutex.unlock();

        const found = registry.table.get(poller.key(fd, .read)) orelse return null;
        return @intCast(found);
    }

    /// Enters `fd`, replacing a stale entry of a recycled fd number. `error.Full` when no slot
    /// is free. Carrier-only.
    pub fn register(registry: *Registry, fd: fd_t) error{Full}!u32 {
        assert(fd >= 0);
        registry.lock();
        defer registry.mutex.unlock();

        if (registry.table.get(poller.key(fd, .read))) |stale| release_locked(registry, stale);
        const index = registry.free_head;
        if (index == index_none) return error.Full;
        const slot = &registry.slots[index];
        registry.free_head = slot.next_free;
        slot.* = .{ .fd = fd, .next_free = index_none, .waiters = .{ null, null } };
        // Proof: the key was removed above and a free slot exists, so the table has room.
        registry.table.insert(poller.key(fd, .read), index) catch unreachable; // proof: above
        return index;
    }

    /// Removes `fd`; returns its slot's waiters (read, write) for the caller to wake.
    pub fn unregister(registry: *Registry, fd: fd_t) ?[2]?*Fiber {
        registry.lock();
        defer registry.mutex.unlock();

        const index = registry.table.get(poller.key(fd, .read)) orelse return null;
        const waiters = registry.slots[@intCast(index)].waiters;
        release_locked(registry, index);
        return waiters;
    }

    fn release_locked(registry: *Registry, index: u64) void {
        const slot = &registry.slots[@intCast(index)];
        assert(slot.fd >= 0);
        assert_always(registry.table.remove(poller.key(slot.fd, .read)) == index);
        slot.fd = -1;
        slot.waiters = .{ null, null };
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

fn waiter_push(registry: *Registry, index: u32, interest: poller.Interest, fiber: *Fiber) void {
    const head = &registry.slots[index].waiters[interest_index(interest)];
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

fn waiter_remove(registry: *Registry, fiber: *Fiber) void {
    const index: u32 = @intCast(fiber.wait.addr);
    const interest: poller.Interest = if (fiber.wait.socket == .read) .read else .write;
    const head = &registry.slots[index].waiters[interest_index(interest)];
    if (fiber.wait.prev) |prev| prev.wait.next = fiber.wait.next else head.* = fiber.wait.next;
    if (fiber.wait.next) |next| next.wait.prev = fiber.wait.prev;
    fiber.wait.prev = null;
    fiber.wait.next = null;
}

/// The handler `Sched` calls for each event: wake every fiber waiting on the slot and interest.
pub fn on_event(ctx: *anyopaque, sched: *Sched, event: poller.Event) void {
    const registry: *Registry = @ptrCast(@alignCast(ctx));
    const index: usize = @intCast(event.token);
    assert(index < registry.slots.len);
    const head = &registry.slots[index].waiters[interest_index(event.interest)];
    assert_always(head.* != null); // Armed exactly while the list is non-empty.
    var waiter = head.*;
    head.* = null;
    for (0..sched.fibers.len) |_| {
        const fiber = waiter orelse break;
        waiter = fiber.wait.next;
        fiber.wait.prev = null;
        fiber.wait.next = null;
        fiber.wait.outcome = .woken;
        sched.unpark(fiber);
    } else assert_always(false); // More waiters than fibers: the list is corrupt.
    assert(waiter == null);
}

/// A cancelation request reached a fiber parked on a socket: leave the list, disarm if it was the
/// last waiter, and make it runnable with outcome `.canceled`. A no-op when an event woke it this
/// turn already. Precondition: carrier thread, `fiber.wait.socket != .none`.
pub fn cancel(rt: *Runtime, fiber: *Fiber) void {
    assert(fiber.wait.socket != .none);
    if (fiber.wait.outcome != .waiting) return;
    assert(fiber.state == .parked);
    const index: u32 = @intCast(fiber.wait.addr);
    const interest: poller.Interest = if (fiber.wait.socket == .read) .read else .write;
    const slot = &rt.sockets.slots[index];
    waiter_remove(&rt.sockets, fiber);
    if (slot.waiters[interest_index(interest)] == null) {
        sched_io.disarm(&rt.sched, slot.fd, interest);
    }
    fiber.wait.outcome = .canceled;
    rt.sched.unpark(fiber);
}

pub const WaitError = error{ Canceled, SystemResources };

/// Parks the calling fiber until `(fd, interest)` is ready or a cancel arrives.
fn park(
    rt: *Runtime,
    task: *concurrency.Task,
    fd: fd_t,
    interest: poller.Interest,
) WaitError!void {
    const index = rt.sockets.lookup(fd) orelse return; // Closed under us: the retry reports it.
    const fiber = rt.sched.current_fiber();
    assert(fiber.wait.outcome == .idle);
    const list_empty = rt.sockets.slots[index].waiters[interest_index(interest)] == null;
    waiter_push(&rt.sockets, index, interest, fiber);
    if (list_empty) {
        sched_io.arm(&rt.sched, fd, interest, index) catch {
            waiter_remove(&rt.sockets, fiber);
            fiber.wait = .none;
            return error.SystemResources;
        };
    }
    concurrency.task_cancel_wake(task, fiber);
    rt.sched.park();
    concurrency.task_cancel_wake(task, null);
    const outcome = fiber.wait.outcome;
    fiber.wait = .none;
    switch (outcome) {
        .woken => {},
        .canceled => {
            // `cancel` ran because the request is pending and the task unprotected.
            assert_always(concurrency.task_acknowledge_cancel(task));
            return error.Canceled;
        },
        .idle, .waiting, .timed_out => unreachable, // Only `on_event` and `cancel` unpark it.
    }
}

const Route = union(enum) { fallback, fiber: *concurrency.Task, blocking };

fn route(rt: *Runtime, fd: ?fd_t) Route {
    if (!rt.sockets.enabled()) return .fallback;
    const task = concurrency.current_task(rt);
    if (fd) |handle| {
        if (rt.sockets.lookup(handle) == null) return .fallback;
        return if (task) |t| .{ .fiber = t } else .blocking;
    }
    const creator = task orelse return .fallback;
    if (!rt.sockets.has_room()) return .fallback;
    return .{ .fiber = creator };
}

fn cancel_check(r: Route) Io.Cancelable!void {
    switch (r) {
        .fiber => |task| if (concurrency.task_acknowledge_cancel(task)) return error.Canceled,
        .blocking, .fallback => {},
    }
}

fn wait_for(
    comptime E: type,
    rt: *Runtime,
    r: Route,
    fd: fd_t,
    interest: poller.Interest,
) E!void {
    switch (r) {
        .fiber => |task| park(rt, task, fd, interest) catch |err| return narrow(E, err),
        .blocking => sys.poll_block(fd, switch (interest) {
            .read => .read,
            .write => .write,
        }),
        .fallback => unreachable, // Proof: every slot takes the thunk before it can wait.
    }
}

/// `err` as a member of the slot's error set, or `error.Unexpected` when the set has no such name.
fn narrow(comptime E: type, err: anyerror) E {
    inline for (@typeInfo(E).error_set.?) |member| {
        if (std.mem.eql(u8, member.name, @errorName(err))) return @field(E, member.name);
    }
    return error.Unexpected;
}

fn enroll(rt: *Runtime, fd: fd_t) void {
    // Proof: `route` saw a free slot and nothing parked since, on the only thread that registers.
    _ = rt.sockets.register(fd) catch unreachable; // proof: above
}

fn thunk(
    comptime name: []const u8,
    userdata: ?*anyopaque,
    args: anytype,
) offload_slots.ReturnOf(name) {
    return @call(.auto, offload_slots.Thunk(name).call, .{userdata} ++ args);
}

fn address_plain(address: *const IpAddress) bool {
    return switch (address.*) {
        .ip4 => true,
        .ip6 => |ip6| ip6.interface.index == 0,
    };
}

fn family_of(address: *const IpAddress) u32 {
    return switch (address.*) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
}

fn kind_of(mode: Socket.Mode) ?u32 {
    return switch (mode) {
        .stream => posix.SOCK.STREAM,
        .dgram => posix.SOCK.DGRAM,
        .seqpacket => posix.SOCK.SEQPACKET,
        .raw, .rdm => null,
    };
}

fn slot_listen_ip(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.ListenOptions,
) IpAddress.ListenError!Socket {
    const E = IpAddress.ListenError;
    const rt = concurrency.runtime_of(userdata);
    const served = options.mode == .stream and options.protocol == .tcp and address_plain(address);
    const r = if (served) route(rt, null) else Route.fallback;
    if (r == .fallback) return thunk("netListenIp", userdata, .{ address, options });
    try cancel_check(r);

    const family = family_of(address);
    const fd = sys.socket_open(family, posix.SOCK.STREAM, 0) catch |e| return narrow(E, e);
    errdefer sys.close(fd);

    if (options.reuse_address) sys.reuse_address_set(fd) catch |e| return narrow(E, e);
    var addr = sys.addr_from_ip(address.*);
    sys.bind(fd, &addr) catch |e| return narrow(E, e);
    sys.listen(fd, options.kernel_backlog) catch |e| return narrow(E, e);
    const resolved = resolved_address(fd) orelse address.*;
    enroll(rt, fd);
    return .{ .handle = fd, .address = resolved };
}

fn resolved_address(fd: fd_t) ?IpAddress {
    var bound: sys.Addr = undefined; // Filled by `socket_name` before any read.
    sys.socket_name(fd, &bound) catch return null;
    return sys.addr_to_ip(&bound);
}

fn slot_bind_ip(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.BindOptions,
) IpAddress.BindError!Socket {
    const E = IpAddress.BindError;
    const rt = concurrency.runtime_of(userdata);
    const kind = kind_of(options.mode);
    const served = kind != null and options.protocol == null and !options.ip6_only and
        !options.allow_broadcast and address_plain(address);
    const r = if (served) route(rt, null) else Route.fallback;
    if (r == .fallback) return thunk("netBindIp", userdata, .{ address, options });
    try cancel_check(r);

    const fd = sys.socket_open(family_of(address), kind.?, 0) catch |e| return narrow(E, e);
    errdefer sys.close(fd);

    var addr = sys.addr_from_ip(address.*);
    sys.bind(fd, &addr) catch |e| return narrow(E, e);
    const resolved = resolved_address(fd) orelse address.*;
    enroll(rt, fd);
    return .{ .handle = fd, .address = resolved };
}

fn slot_accept(
    userdata: ?*anyopaque,
    server: Socket.Handle,
    options: Io.net.Server.AcceptOptions,
) Io.net.Server.AcceptError!Socket {
    const E = Io.net.Server.AcceptError;
    const rt = concurrency.runtime_of(userdata);
    const r = route(rt, server);
    if (r == .fallback) return thunk("netAccept", userdata, .{ server, options });
    try cancel_check(r);

    for (0..wakeups_max) |_| {
        var peer: sys.Addr = undefined; // Filled by `accept` before any read.
        if (sys.accept(server, &peer)) |fd| {
            const address = sys.addr_to_ip(&peer) orelse IpAddress{ .ip4 = .loopback(0) };
            _ = rt.sockets.register(fd) catch {
                // Registry full: the accepted fd is ours alone, so it can be made blocking and
                // served by the offload path for life (ADR 0003 section 3).
                sys.blocking_set(fd, true) catch |e| {
                    sys.close(fd);
                    return narrow(E, e);
                };
            };
            return .{ .handle = fd, .address = address };
        } else |err| switch (err) {
            error.WouldBlock => try wait_for(E, rt, r, server, .read),
            else => return narrow(E, err),
        }
    }
    return error.WouldBlock;
}

fn slot_connect_ip(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.ConnectOptions,
) IpAddress.ConnectError!Socket {
    const E = IpAddress.ConnectError;
    const rt = concurrency.runtime_of(userdata);
    const tcp = options.protocol == null or options.protocol.? == .tcp;
    const served = options.mode == .stream and tcp and options.timeout == .none and
        address_plain(address);
    const r = if (served) route(rt, null) else Route.fallback;
    if (r == .fallback) return thunk("netConnectIp", userdata, .{ address, options });
    try cancel_check(r);

    const family = family_of(address);
    const fd = sys.socket_open(family, posix.SOCK.STREAM, 0) catch |e| return narrow(E, e);
    enroll(rt, fd);
    errdefer connect_abandon(rt, fd);

    var addr = sys.addr_from_ip(address.*);
    try connect_wait(E, rt, r, fd, &addr);
    // Like the baseline, the socket's address is its local end, not the peer's.
    return .{ .handle = fd, .address = resolved_address(fd) orelse address.* };
}

/// Starts the connect on `fd` and, on `InProgress`, waits for write readiness and reads `SO_ERROR`.
fn connect_wait(comptime E: type, rt: *Runtime, r: Route, fd: fd_t, addr: *const sys.Addr) E!void {
    for (0..wakeups_max) |_| {
        sys.connect(fd, addr) catch |err| switch (err) {
            error.InProgress => {
                try wait_for(E, rt, r, fd, .write);
                return sys.socket_error(fd) catch |e| narrow(E, e);
            },
            error.WouldBlock => {
                try wait_for(E, rt, r, fd, .write);
                continue;
            },
            else => return narrow(E, err),
        };
        return;
    }
    return error.WouldBlock;
}

/// Drops a socket this call created and did not hand out.
fn connect_abandon(rt: *Runtime, fd: fd_t) void {
    const waiters = rt.sockets.unregister(fd);
    assert(waiters != null);
    sys.close(fd);
}

fn slot_listen_unix(
    userdata: ?*anyopaque,
    address: *const Io.net.UnixAddress,
    options: Io.net.UnixAddress.ListenOptions,
) Io.net.UnixAddress.ListenError!Socket.Handle {
    const E = Io.net.UnixAddress.ListenError;
    const rt = concurrency.runtime_of(userdata);
    const addr_unix = sys.addr_from_unix(address.path);
    const r = if (addr_unix != null) route(rt, null) else Route.fallback;
    if (r == .fallback) return thunk("netListenUnix", userdata, .{ address, options });
    try cancel_check(r);

    const fd = sys.socket_open(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |e| return narrow(E, e);
    errdefer sys.close(fd);

    sys.bind(fd, &addr_unix.?) catch |e| return narrow(E, e);
    sys.listen(fd, options.kernel_backlog) catch |e| return narrow(E, e);
    enroll(rt, fd);
    return fd;
}

fn slot_connect_unix(
    userdata: ?*anyopaque,
    address: *const Io.net.UnixAddress,
) Io.net.UnixAddress.ConnectError!Socket.Handle {
    const E = Io.net.UnixAddress.ConnectError;
    const rt = concurrency.runtime_of(userdata);
    const addr_unix = sys.addr_from_unix(address.path);
    const r = if (addr_unix != null) route(rt, null) else Route.fallback;
    if (r == .fallback) return thunk("netConnectUnix", userdata, .{address});
    try cancel_check(r);

    const fd = sys.socket_open(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |e| return narrow(E, e);
    enroll(rt, fd);
    errdefer connect_abandon(rt, fd);

    try connect_wait(E, rt, r, fd, &addr_unix.?);
    return fd;
}

fn slot_socket_pair(
    userdata: ?*anyopaque,
    options: Socket.CreatePairOptions,
) Socket.CreatePairError![2]Socket {
    const E = Socket.CreatePairError;
    const rt = concurrency.runtime_of(userdata);
    const kind = kind_of(options.mode);
    const served = kind != null and options.protocol == null and rt.sockets.has_room();
    const r = if (served) route(rt, null) else Route.fallback;
    if (r == .fallback) return thunk("netSocketCreatePair", userdata, .{options});
    try cancel_check(r);

    const domain: u32 = switch (options.family) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
    const fds = sys.socket_pair(domain, kind.?, 0) catch |e| return narrow(E, e);
    const first = rt.sockets.register(fds[0]) catch return pair_overflow(fds, userdata, options);
    _ = first;
    _ = rt.sockets.register(fds[1]) catch {
        _ = rt.sockets.unregister(fds[0]);
        return pair_overflow(fds, userdata, options);
    };
    const unspecified: IpAddress = .{ .ip4 = .loopback(0) };
    return .{
        .{ .handle = fds[0], .address = resolved_address(fds[0]) orelse unspecified },
        .{ .handle = fds[1], .address = resolved_address(fds[1]) orelse unspecified },
    };
}

/// The registry could not hold both ends: close them and let the offload path make the pair.
fn pair_overflow(
    fds: [2]fd_t,
    userdata: ?*anyopaque,
    options: Socket.CreatePairOptions,
) Socket.CreatePairError![2]Socket {
    sys.close(fds[0]);
    sys.close(fds[1]);
    return thunk("netSocketCreatePair", userdata, .{options});
}

fn slot_close(userdata: ?*anyopaque, handles: []const Socket.Handle) void {
    const rt = concurrency.runtime_of(userdata);
    for (handles) |handle| {
        if (!rt.sockets.enabled()) break;
        const waiters = rt.sockets.unregister(handle) orelse continue;
        // Armed exactly while a list is non-empty, so a closed fd with waiters is disarmed here
        // and its waiters retry into the kernel's error (item 5 gives them a typed one).
        for (waiters, 0..) |head, side| {
            if (head == null) continue;
            const interest: poller.Interest = if (side == 0) .read else .write;
            sched_io.disarm(&rt.sched, handle, interest);
            var waiter = head;
            for (0..rt.sched.fibers.len) |_| {
                const fiber = waiter orelse break;
                waiter = fiber.wait.next;
                fiber.wait.prev = null;
                fiber.wait.next = null;
                fiber.wait.outcome = .woken;
                rt.sched.unpark(fiber);
            }
        }
    }
    const baseline = rt.baselineIo();
    baseline.vtable.netClose(baseline.userdata, handles);
}

/// Overwrites the eight slots of `vtable`. Precondition: `Sched.supported`, `vtable` holds the
/// baseline's functions with the offload thunks over them (the fallbacks call those thunks).
pub fn install(vtable: *Io.VTable) void {
    assert(Sched.supported);
    assert(vtable.netAccept != slot_accept);
    vtable.netListenIp = slot_listen_ip;
    vtable.netBindIp = slot_bind_ip;
    vtable.netAccept = slot_accept;
    vtable.netConnectIp = slot_connect_ip;
    vtable.netListenUnix = slot_listen_unix;
    vtable.netConnectUnix = slot_connect_unix;
    vtable.netSocketCreatePair = slot_socket_pair;
    vtable.netClose = slot_close;
}

/// The slots this file replaces.
pub fn is_native(comptime name: []const u8) bool {
    const names = [_][]const u8{
        "netListenIp",
        "netBindIp",
        "netAccept",
        "netConnectIp",
        "netListenUnix",
        "netConnectUnix",
        "netSocketCreatePair",
        "netClose",
    };
    inline for (names) |native| {
        if (comptime std.mem.eql(u8, name, native)) return true;
    }
    return false;
}

test "narrow keeps a name the set has and maps the rest to Unexpected" {
    const Small = error{ AddressInUse, Unexpected };
    try std.testing.expectEqual(@as(Small, error.AddressInUse), narrow(Small, error.AddressInUse));
    const unknown = narrow(Small, error.ConnectionRefused);
    try std.testing.expectEqual(@as(Small, error.Unexpected), unknown);
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
    // fd 10 was closed behind our back and the number reused: the stale entry is replaced.
    _ = try registry.register(10);
    try std.testing.expectEqual(@as(u32, 2), registry.count());
    try std.testing.expect(registry.unregister(11) != null);
    try std.testing.expect(registry.unregister(11) == null);
    try std.testing.expect(registry.has_room());
    try std.testing.expect(registry.unregister(10) != null);
    try std.testing.expectEqual(@as(u32, 0), registry.count());
}
