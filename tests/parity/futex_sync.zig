//! Smoke tests for std's synchronization primitives running on sirocco's fibers (plan 002 item 8).
//!
//! `Io.Event`, `Io.Mutex`, `Io.Condition`, `Io.Semaphore` and `Io.Queue` are built on the three
//! futex slots only, so they work on `rt.io()` exactly when `src/futex.zig` does. Each scenario is
//! a few fibers on one carrier; scheduling is FIFO, so the interleaving is deterministic and the
//! order traces below are exact. Fibers record into a caller-owned struct and the test body asserts
//! after the join (see `scene.zig`). Both `.forward` and `.fail` modes run: a primitive that only
//! works by falling through to `Io.Threaded` would block the carrier and never finish.

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const scene = @import("scene.zig");

const yield = scene.yield;
const run_modes = scene.run_modes;
const expectEqual = std.testing.expectEqual;

const Cancelable = Io.Cancelable;

// ---- Event ------------------------------------------------------------------------------------

const Handoff = struct {
    first: Io.Event = .unset,
    second: Io.Event = .unset,
    trace: [8]u8 = @splat(0),
    len: u32 = 0,

    fn push(h: *Handoff, mark: u8) void {
        std.debug.assert(h.len < h.trace.len);
        h.trace[h.len] = mark;
        h.len += 1;
    }
};

fn handoff_a(io: Io, h: *Handoff) Cancelable!void {
    h.push('a');
    try h.first.wait(io);
    h.push('A');
    h.second.set(io);
}

fn handoff_b(io: Io, h: *Handoff) Cancelable!void {
    h.push('b');
    h.first.set(io);
    h.push('c');
    try h.second.wait(io);
    h.push('B');
}

test "sync: two fibers hand off through two Io.Events in a fixed order" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var h: Handoff = .{};
            var a = io.async(handoff_a, .{ io, &h });
            var b = io.async(handoff_b, .{ io, &h });
            try a.await(io);
            try b.await(io);
            // `set` wakes but does not switch: b runs on to 'c' and parks before a resumes.
            try std.testing.expectEqualStrings("abcAB", h.trace[0..h.len]);
            try std.testing.expect(h.first.isSet());
            try std.testing.expect(h.second.isSet());
        }
    }.scenario);
}

fn set_then_wait(io: Io, event: *Io.Event) Cancelable!void {
    event.set(io);
    event.set(io); // setting twice is not an error
    try event.wait(io);
    event.waitUncancelable(io);
}

test "sync: waiting on an already-set Event returns at once, and reset re-arms it" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var event: Io.Event = .unset;
            try std.testing.expect(!event.isSet());
            var task = io.async(set_then_wait, .{ io, &event });
            try task.await(io);
            try std.testing.expect(event.isSet());
            event.reset();
            try std.testing.expect(!event.isSet());
        }
    }.scenario);
}

const Waiting = struct {
    event: Io.Event = .unset,
    entered: u32 = 0,
    left: u32 = 0,
    set_seen_by_late: u32 = 0,
};

fn event_waiter(io: Io, w: *Waiting) Cancelable!void {
    w.entered += 1;
    try w.event.wait(io);
    w.left += 1;
}

fn event_canceler(io: Io, target: *Io.Future(Cancelable!void)) Cancelable!void {
    return target.cancel(io);
}

test "sync: Event.wait is a cancelation point and a cancel unparks it" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var w: Waiting = .{};
            var waiter = io.async(event_waiter, .{ io, &w });
            var killer = io.async(event_canceler, .{ io, &waiter });
            try std.testing.expectError(error.Canceled, killer.await(io));
            try expectEqual(@as(u32, 1), w.entered);
            try expectEqual(@as(u32, 0), w.left);
            try std.testing.expect(!w.event.isSet());
        }
    }.scenario);
}

fn event_uncancelable_waiter(io: Io, w: *Waiting) bool {
    w.entered += 1;
    w.event.waitUncancelable(io);
    w.left += 1;
    return scene.observes_cancel(io);
}

fn event_cancel_bool(io: Io, target: *Io.Future(bool)) bool {
    return target.cancel(io);
}

fn event_late_setter(io: Io, w: *Waiting) void {
    w.set_seen_by_late = w.left;
    w.event.set(io);
}

test "sync: Event.waitUncancelable stays parked through a cancel until set" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var w: Waiting = .{};
            var waiter = io.async(event_uncancelable_waiter, .{ io, &w });
            var killer = io.async(event_cancel_bool, .{ io, &waiter });
            var setter = io.async(event_late_setter, .{ io, &w });
            try std.testing.expect(killer.await(io));
            setter.await(io);
            try expectEqual(@as(u32, 0), w.set_seen_by_late);
            try expectEqual(@as(u32, 1), w.left);
        }
    }.scenario);
}

// ---- Mutex ------------------------------------------------------------------------------------

const workers_n = 6;

const Contended = struct {
    mutex: Io.Mutex = .init,
    holders: u32 = 0,
    holders_max: u32 = 0,
    counter: u32 = 0,
    order: [workers_n]u8 = @splat(0xff),
};

/// Parks twice while holding the lock, so every other worker finds it held and parks on it.
fn locker(io: Io, c: *Contended, id: u8) Cancelable!void {
    try c.mutex.lock(io);
    defer c.mutex.unlock(io);
    c.holders += 1;
    c.holders_max = @max(c.holders_max, c.holders);
    yield(io);
    yield(io);
    c.order[c.counter] = id;
    c.counter += 1;
    c.holders -= 1;
}

test "sync: N fibers contend for an Io.Mutex held across a park; exactly one holds it at a time" {
    try run_modes(16, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var c: Contended = .{};
            var workers: [workers_n]Io.Future(Cancelable!void) = undefined;
            for (&workers, 0..) |*worker, id| {
                worker.* = io.async(locker, .{ io, &c, @as(u8, @intCast(id)) });
            }
            for (&workers) |*worker| try worker.await(io);

            try expectEqual(@as(u32, workers_n), c.counter);
            try expectEqual(@as(u32, 1), c.holders_max);
            try expectEqual(@as(u32, 0), c.holders);
            // Every worker got the lock exactly once.
            var seen: [workers_n]bool = @splat(false);
            for (c.order) |id| seen[id] = true;
            try std.testing.expectEqualSlices(bool, &@as([workers_n]bool, @splat(true)), &seen);
            try std.testing.expect(c.mutex.tryLock()); // released at the end
            c.mutex.unlock(io);
        }
    }.scenario);
}

fn holder_then_try(io: Io, c: *Contended) Cancelable!void {
    try c.mutex.lock(io);
    defer c.mutex.unlock(io);
    yield(io);
    c.counter += 1;
}

fn try_while_held(io: Io, c: *Contended) void {
    // Runs while `holder_then_try` is parked inside its critical section.
    if (c.mutex.tryLock()) {
        c.holders += 1; // wrongly acquired
        c.mutex.unlock(io);
    }
}

test "sync: tryLock fails while another fiber holds the Io.Mutex across a park" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var c: Contended = .{};
            var holder = io.async(holder_then_try, .{ io, &c });
            var prober = io.async(try_while_held, .{ io, &c });
            prober.await(io);
            try holder.await(io);
            try expectEqual(@as(u32, 0), c.holders); // tryLock never succeeded
            try expectEqual(@as(u32, 1), c.counter);
        }
    }.scenario);
}

// ---- Condition --------------------------------------------------------------------------------

const Gate = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    ready: bool = false,
    waiting: u32 = 0,
    woke: u32 = 0,
    seen: [3]u32 = @splat(0),
};

fn gate_waiter(io: Io, g: *Gate) Cancelable!void {
    try g.mutex.lock(io);
    defer g.mutex.unlock(io);
    g.waiting += 1;
    while (!g.ready) try g.cond.wait(io, &g.mutex);
    g.woke += 1;
}

fn gate_opener(io: Io, g: *Gate) void {
    g.mutex.lockUncancelable(io);
    g.ready = true;
    g.seen[0] = g.waiting;
    g.mutex.unlock(io);
    g.cond.signal(io);
    yield(io);
    g.seen[1] = g.woke;
    g.cond.broadcast(io);
    yield(io);
    g.seen[2] = g.woke;
}

test "sync: Condition.signal wakes one waiter and broadcast wakes the rest" {
    try run_modes(16, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var g: Gate = .{};
            var waiters: [4]Io.Future(Cancelable!void) = undefined;
            for (&waiters) |*waiter| waiter.* = io.async(gate_waiter, .{ io, &g });
            var opener = io.async(gate_opener, .{ io, &g });
            opener.await(io);
            for (&waiters) |*waiter| try waiter.await(io);

            try expectEqual(@as(u32, 4), g.seen[0]); // all four waiting under the condition
            try expectEqual(@as(u32, 1), g.seen[1]); // signal released exactly one
            try expectEqual(@as(u32, 4), g.seen[2]); // broadcast released the other three
        }
    }.scenario);
}

fn gate_canceler(io: Io, target: *Io.Future(Cancelable!void)) Cancelable!void {
    return target.cancel(io);
}

test "sync: Condition.wait canceled while parked returns Canceled with the mutex released" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var g: Gate = .{};
            var waiter = io.async(gate_waiter, .{ io, &g });
            var killer = io.async(gate_canceler, .{ io, &waiter });
            try std.testing.expectError(error.Canceled, killer.await(io));
            try expectEqual(@as(u32, 1), g.waiting);
            try expectEqual(@as(u32, 0), g.woke);
            // `wait` re-takes the lock before returning an error and the waiter's `defer` frees it.
            try std.testing.expect(g.mutex.tryLock());
            g.mutex.unlock(io);
        }
    }.scenario);
}

// ---- Semaphore and Queue ----------------------------------------------------------------------

const Permits = struct {
    sem: Io.Semaphore = .{},
    done: u32 = 0,
    seen: [2]u32 = @splat(0),
};

fn permit_taker(io: Io, p: *Permits) Cancelable!void {
    try p.sem.wait(io);
    p.done += 1;
}

fn permit_poster(io: Io, p: *Permits) void {
    p.sem.post(io);
    p.sem.post(io);
    yield(io);
    p.seen[0] = p.done;
    p.sem.post(io);
    yield(io);
    p.seen[1] = p.done;
}

test "sync: Semaphore releases one waiter per post" {
    try run_modes(16, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var p: Permits = .{};
            var takers: [3]Io.Future(Cancelable!void) = undefined;
            for (&takers) |*taker| taker.* = io.async(permit_taker, .{ io, &p });
            var poster = io.async(permit_poster, .{ io, &p });
            poster.await(io);
            for (&takers) |*taker| try taker.await(io);

            try expectEqual(@as(u32, 2), p.seen[0]);
            try expectEqual(@as(u32, 3), p.seen[1]);
        }
    }.scenario);
}

const items_n = 5;

const Pipe = struct {
    queue: Io.Queue(u32),
    buffer: [1]u32 = undefined,
    got: [items_n]u32 = @splat(0xffff),
    got_len: u32 = 0,
};

fn pipe_producer(io: Io, pipe: *Pipe) !void {
    for (0..items_n) |item| try pipe.queue.putOne(io, @intCast(item));
}

fn pipe_consumer(io: Io, pipe: *Pipe) !void {
    for (0..items_n) |_| {
        pipe.got[pipe.got_len] = try pipe.queue.getOne(io);
        pipe.got_len += 1;
    }
}

test "sync: a one-slot Io.Queue passes items between two fibers in order" {
    try run_modes(8, struct {
        fn scenario(rt: *Runtime) anyerror!void {
            const io = rt.io();
            var pipe: Pipe = .{ .queue = undefined };
            pipe.queue = .init(&pipe.buffer);
            // Consumer first: it parks on the empty queue, then the producer fills and parks on
            // the full one (capacity 1), so both directions of the handoff are exercised.
            var consumer = io.async(pipe_consumer, .{ io, &pipe });
            var producer = io.async(pipe_producer, .{ io, &pipe });
            try consumer.await(io);
            try producer.await(io);

            try expectEqual(@as(u32, items_n), pipe.got_len);
            try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, &pipe.got);
        }
    }.scenario);
}
