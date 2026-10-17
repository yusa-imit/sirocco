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
//! Invariants: the table, the waiter lists and the close protocol live in `src/net_registry.zig`;
//! a pair `(slot, interest)` has at most one poller registration, armed exactly while its waiter
//! list is non-empty, and the event wakes every waiter, each of which retries. Under `.threaded`
//! the registry is empty (`enabled` is false) and every slot takes the thunk. `netClose` takes the
//! fd out of the registry first; a fiber waiting on it wakes with `error.SocketNotListening`
//! without touching the fd again.
//!
//! Allocation: none after `Registry.init`. Cancelation: a pending request is delivered before the
//! first syscall; one that arrives while parked disarms and unparks (`cancel`), the call closes
//! what it created and returns `error.Canceled`. A socket is entered in the registry right after
//! it is created, so a registry that filled up in between falls back before any side effect.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const Runtime = @import("runtime.zig");
const concurrency = @import("concurrency.zig");
const offload_slots = @import("offload_slots.zig");
const poller = @import("backend/poller.zig");
const registry_mod = @import("net_registry.zig");
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
pub const wakeups_max: u32 = 1 << 24;

pub const Registry = registry_mod.Registry;
pub const on_event = registry_mod.on_event;

/// A cancelation request reached a fiber parked on a socket: leave the list, disarm if it was the
/// last waiter, and make it runnable with outcome `.canceled`. A no-op when an event woke it this
/// turn already. Precondition: carrier thread, `fiber.wait.socket != .none`.
pub fn cancel(rt: *Runtime, fiber: *Fiber) void {
    rt.sockets.cancel(&rt.sched, fiber);
}

pub const WaitError = error{ Canceled, SystemResources, Closed };

/// Parks the calling fiber until `(fd, interest)` is ready or a cancel arrives. `error.Closed`
/// when the handle was closed before or during the wait: the caller must not touch the fd.
fn park(
    rt: *Runtime,
    task: *concurrency.Task,
    fd: fd_t,
    interest: poller.Interest,
) WaitError!void {
    const fiber = rt.sched.current_fiber();
    assert(fiber.wait.outcome == .idle);
    // A cancel that arrived while this fiber was woken (not parked) found nothing to unpark, so
    // every re-park after a spurious wake looks at the request again, as `futex` does.
    if (concurrency.task_acknowledge_cancel(task)) return error.Canceled;
    switch (rt.sockets.waiter_enter(&rt.sched, fd, interest, fiber)) {
        .parked => {},
        .gone => return error.Closed,
        .resources => return error.SystemResources,
    }
    const index: u32 = @intCast(fiber.wait.addr);
    const generation = rt.sockets.generation_of(index);
    concurrency.task_cancel_wake(task, fiber);
    rt.sched.park();
    concurrency.task_cancel_wake(task, null);
    const outcome = fiber.wait.outcome;
    fiber.wait = .none;
    switch (outcome) {
        .woken => {
            // A close between the wake and this run left the fd closed or reused: leave it be.
            if (!rt.sockets.still_open(index, generation, fd)) return error.Closed;
        },
        .canceled => {
            // `cancel` ran because the request is pending and the task unprotected.
            assert_always(concurrency.task_acknowledge_cancel(task));
            return error.Canceled;
        },
        .closed => return error.Closed,
        .closing => {
            // A close from another thread left the fd open for the last waiter to close.
            if (rt.sockets.closing_finish(&rt.sched, fd, interest)) close_baseline(rt, fd);
            return error.Closed;
        },
        .idle, .waiting, .timed_out => unreachable, // Only the registry unparks it, with these.
    }
}

fn close_baseline(rt: *Runtime, fd: fd_t) void {
    assert(fd >= 0);
    const baseline = rt.baselineIo();
    baseline.vtable.netClose(baseline.userdata, &.{fd});
}

pub const Route = union(enum) { fallback, fiber: *concurrency.Task, blocking };

pub fn route(rt: *Runtime, fd: ?fd_t) Route {
    assert(rt.sched_state == .ready);
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

pub fn cancel_check(r: Route) Io.Cancelable!void {
    switch (r) {
        .fiber => |task| if (concurrency.task_acknowledge_cancel(task)) return error.Canceled,
        .blocking, .fallback => {},
    }
}

/// Waits until `(fd, interest)` is ready (on a fiber: parks; off one: `poll(2)`). A handle closed
/// during the wait ends the call with `closed`, the slot's own reading of "closed under me":
/// `SocketNotListening` for an accept, `SocketUnconnected` for the data path.
pub fn wait_for(
    comptime E: type,
    rt: *Runtime,
    r: Route,
    fd: fd_t,
    interest: poller.Interest,
    closed: anyerror,
) E!void {
    assert(fd >= 0);
    assert(r != .fallback);
    switch (r) {
        .fiber => |task| park(rt, task, fd, interest) catch |err| switch (err) {
            // The handle was closed under the call, as `shutdown` does to a blocked accept.
            error.Closed => return narrow(E, closed),
            else => return narrow(E, err),
        },
        .blocking => sys.poll_block(fd, switch (interest) {
            .read => .read,
            .write => .write,
        }),
        .fallback => unreachable, // Proof: every slot takes the thunk before it can wait.
    }
}

/// `err` as a member of the slot's error set, or `error.Unexpected` when the set has no such name.
pub fn narrow(comptime E: type, err: anyerror) E {
    assert(@typeInfo(E) == .error_set);
    inline for (@typeInfo(E).error_set.?) |member| {
        if (std.mem.eql(u8, member.name, @errorName(err))) return @field(E, member.name);
    }
    return error.Unexpected;
}

/// A new non-blocking socket, entered in the registry before anything else can fail or leak.
/// Null when other threads filled the registry since `route` looked: nothing was created.
fn socket_enrolled(rt: *Runtime, domain: u32, kind: u32) sys.Error!?fd_t {
    const fd = try sys.socket_open(domain, kind, 0);
    _ = rt.sockets.register(fd) catch {
        sys.close(fd);
        return null;
    };
    return fd;
}

/// Drops a socket this call created and did not hand out.
fn abandon(rt: *Runtime, fd: fd_t) void {
    assert_always(rt.sockets.unregister(fd));
    sys.close(fd);
}

pub fn thunk(
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

    const made = socket_enrolled(rt, family_of(address), posix.SOCK.STREAM);
    const fd = (made catch |e| return narrow(E, e)) orelse {
        return thunk("netListenIp", userdata, .{ address, options });
    };
    errdefer abandon(rt, fd);

    if (options.reuse_address) sys.reuse_address_set(fd) catch |e| return narrow(E, e);
    var addr = sys.addr_from_ip(address.*);
    sys.bind(fd, &addr) catch |e| return narrow(E, e);
    sys.listen(fd, options.kernel_backlog) catch |e| return narrow(E, e);
    return .{ .handle = fd, .address = resolved_address(fd) orelse address.* };
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

    const made = socket_enrolled(rt, family_of(address), kind.?);
    const fd = (made catch |e| return narrow(E, e)) orelse {
        return thunk("netBindIp", userdata, .{ address, options });
    };
    errdefer abandon(rt, fd);

    var addr = sys.addr_from_ip(address.*);
    sys.bind(fd, &addr) catch |e| return narrow(E, e);
    return .{ .handle = fd, .address = resolved_address(fd) orelse address.* };
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
            // A peer with no IP address (a Unix socket) reads as loopback port 0, as the baseline.
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
            error.WouldBlock => try wait_for(E, rt, r, server, .read, error.SocketNotListening),
            error.Interrupted => continue,
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

    const made = socket_enrolled(rt, family_of(address), posix.SOCK.STREAM);
    const fd = (made catch |e| return narrow(E, e)) orelse {
        return thunk("netConnectIp", userdata, .{ address, options });
    };
    errdefer abandon(rt, fd);

    var addr = sys.addr_from_ip(address.*);
    try connect_wait(E, rt, r, fd, &addr);
    // Like the baseline, the socket's address is its local end, not the peer's.
    return .{ .handle = fd, .address = resolved_address(fd) orelse address.* };
}

/// Starts the connect on `fd` and, on `InProgress`, waits for write readiness and reads `SO_ERROR`.
fn connect_wait(comptime E: type, rt: *Runtime, r: Route, fd: fd_t, addr: *const sys.Addr) E!void {
    for (0..wakeups_max) |_| {
        sys.connect(fd, addr) catch |err| switch (err) {
            // `EINTR` on a connect leaves the handshake running, like `EINPROGRESS`.
            error.InProgress, error.Interrupted => {
                try wait_for(E, rt, r, fd, .write, error.SocketNotListening);
                return sys.socket_error(fd) catch |e| narrow(E, e);
            },
            error.WouldBlock => {
                try wait_for(E, rt, r, fd, .write, error.SocketNotListening);
                continue;
            },
            else => return narrow(E, err),
        };
        return;
    }
    return error.WouldBlock;
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

    const made = socket_enrolled(rt, posix.AF.UNIX, posix.SOCK.STREAM);
    const fd = (made catch |e| return narrow(E, e)) orelse {
        return thunk("netListenUnix", userdata, .{ address, options });
    };
    errdefer abandon(rt, fd);

    sys.bind(fd, &addr_unix.?) catch |e| return narrow(E, e);
    sys.listen(fd, options.kernel_backlog) catch |e| return narrow(E, e);
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

    const made = socket_enrolled(rt, posix.AF.UNIX, posix.SOCK.STREAM);
    const fd = (made catch |e| return narrow(E, e)) orelse {
        return thunk("netConnectUnix", userdata, .{address});
    };
    errdefer abandon(rt, fd);

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
    _ = rt.sockets.register(fds[0]) catch return pair_overflow(fds, userdata, options);
    _ = rt.sockets.register(fds[1]) catch {
        assert_always(rt.sockets.unregister(fds[0]));
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
        assert(handle >= 0);
        if (!rt.sockets.enabled() or close_registered(rt, handle)) close_baseline(rt, handle);
    }
}

/// Detaches `fd` from the registry and its waiters. True when the caller closes the fd now; false
/// when a close from another thread left it to the last waiter (`net_registry.zig`).
fn close_registered(rt: *Runtime, fd: fd_t) bool {
    if (rt.sched.in_fiber()) {
        return rt.sockets.close_on_carrier(&rt.sched, fd);
    }
    return rt.sockets.close_off_carrier(&rt.sched, rt.baselineIo(), fd);
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
