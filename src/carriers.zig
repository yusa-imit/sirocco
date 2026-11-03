//! Peer carriers: the schedulers and threads of carriers `1..carriers-1` (ADR 0004 section 1).
//!
//! Purpose: `Runtime` owns carrier 0 as `rt.sched`, run by the driver thread. A runtime built
//! with `Options.carriers = N` also owns `N - 1` peers, each a `Sched` of its own (fiber table,
//! stacks, wheel, poller) plus a thread that runs `Sched.serve` until `rt.stop` is set. Nothing
//! is placed on a peer yet (plan 005 items 7 and 8), so a peer only idles; carriers = 1 has no
//! peer and no thread, and behaves exactly as v0.5.0 did.
//!
//! Ownership: `alloc` takes the peers block in `Runtime.init`, once, from the runtime's
//! allocator. `start` (first `io()`) builds each peer in place, so the block must not move, then
//! spawns the threads; on failure it undoes itself and leaves the block as `alloc` made it.
//! `halt` (deinit, or a failed start) stops, wakes and joins the threads, then frees the
//! schedulers. `free` returns the block.
//!
//! Invariants: peer `i` has a `Sched` only while `i < built`, and a thread only after every
//! `Sched` is built (threads are spawned last, so a failed build never has a thread to join).

const std = @import("std");
const Io = std.Io;
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");
const futex = @import("futex.zig");
const net = @import("net.zig");
const Runtime = @import("runtime.zig");

const assert = stdx.assert;

/// One peer carrier: valid `sched` while built, `thread` set while its loop runs.
pub const Peer = struct {
    sched: Sched,
    thread: ?std.Thread,
};

/// The peers block for `carriers` carriers: `carriers - 1` entries, none built, no thread.
pub fn alloc(gpa: std.mem.Allocator, carriers: u32) std.mem.Allocator.Error![]Peer {
    assert(carriers >= 1);
    assert(carriers <= Runtime.carriers_max);
    const peers = try gpa.alloc(Peer, carriers - 1);
    for (peers) |*peer| peer.thread = null;
    assert(peers.len == carriers - 1);
    assert(peers.len < Runtime.carriers_max);
    return peers;
}

/// Returns the block of `alloc`. Precondition: every peer was halted (no thread, no `Sched`).
pub fn free(gpa: std.mem.Allocator, peers: []Peer) void {
    assert(peers.len < Runtime.carriers_max);
    for (peers) |*peer| assert(peer.thread == null);
    gpa.free(peers);
}

/// Builds every peer `Sched` with `options` (the same as carrier 0's) and spawns the threads.
/// Returns false, with nothing built and nothing running, if a build or a spawn failed; the
/// runtime then goes `.unavailable` like any other failed start. Precondition: `rt` is pinned
/// and still `.pending`, and `rt.stop` is clear.
pub fn start(rt: *Runtime, options: Sched.Options) bool {
    assert(rt.sched_state == .pending);
    assert(!rt.stop.load(.monotonic));
    const gpa = rt.threaded.allocator;
    var built: usize = 0;
    for (rt.peers, 0..) |*peer, offset| {
        assert(peer.thread == null);
        peer.sched.init(gpa, options) catch |err| switch (err) {
            error.OutOfMemory,
            error.FibersUnsupported,
            error.PollerUnsupported,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            => {
                halt(rt, built);
                return false;
            },
        };
        peer.sched.index = @intCast(offset + 1);
        // The handlers carrier 0 gets in `concurrency.sched_ensure`; they read shared tables.
        peer.sched.expiry = futex.expiry(&rt.waits);
        if (rt.backend != .threaded) {
            peer.sched.events = .{ .ctx = &rt.sockets, .ready = net.on_event };
        }
        built += 1;
    }
    assert(built == rt.peers.len);
    const io = rt.baselineIo();
    for (rt.peers) |*peer| {
        // Any spawn failure is the same outcome here: no thread for this peer.
        peer.thread = std.Thread.spawn(.{}, peer_main, .{ &peer.sched, io, &rt.stop }) catch {
            halt(rt, built);
            return false;
        };
    }
    return true;
}

fn peer_main(sched: *Sched, io: Io, stop: *const std.atomic.Value(bool)) void {
    sched.serve(io, stop);
}

/// Stops the first `built` peers: sets `rt.stop`, wakes and joins every running thread, then
/// frees each `Sched`, and clears `rt.stop`. Precondition: peers `built..` hold nothing, and no
/// fiber is alive on any peer.
pub fn halt(rt: *Runtime, built: usize) void {
    assert(built <= rt.peers.len);
    assert(rt.sched_state != .unsupported);
    const io = rt.baselineIo();
    rt.stop.store(true, .release);
    for (rt.peers[0..built]) |*peer| {
        const thread = peer.thread orelse continue;
        peer.sched.notify(io);
        thread.join();
        peer.thread = null;
    }
    for (rt.peers[0..built]) |*peer| peer.sched.deinit(rt.threaded.allocator);
    for (rt.peers) |*peer| assert(peer.thread == null);
    rt.stop.store(false, .release);
}
