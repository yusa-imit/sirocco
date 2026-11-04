//! Carrier mail: how a task is put on another carrier (ADR 0004 section 3, plan 005 item 7).
//!
//! Purpose: a `Mail` names an entry and its argument; `post` hands it to a `Sched` from any thread
//! and the carrier that owns the `Sched` starts a fiber on it, so a fiber is born on, runs on and
//! dies on one carrier (`Fiber.home`). `serve` is the loop of a peer carrier's thread: it starts
//! posted mail, runs fibers while any is alive, and sleeps in the idle path between.
//!
//! Invariants: a `Mail` is caller-owned and is read once, by `drain`, when its fiber is spawned;
//! the caller may reuse it after the entry has started. Mail moves posted (a lock-free stack) ->
//! pending (a FIFO touched by the carrier only) -> a fiber. It waits in pending only while all
//! `fibers_max` fibers are alive, and starts in posting order as fibers end.
//!
//! Limits: the mail posted to one carrier and not yet started never exceeds `outstanding_max`
//! (the placement code bounds tasks per carrier before it posts); `drain` loops bound themselves
//! on that and assert it.
//!
//! Only a `serve` carrier re-drains after its last fiber ends: mail posted to a carrier driven by
//! `Sched.run` alone (carrier 0) can be stranded until the next `run`, so nothing posts there.
//! Mail still posted or pending when `serve` stops is dropped; `Runtime.halt` runs with none.
//!
//! Allocation: none. Threads: `post` any thread; `drain` and `serve` the carrier only.

const std = @import("std");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");

const Io = std.Io;
const assert = stdx.assert;

/// Most mail posted to one carrier and not yet started.
pub const outstanding_max: u32 = 1 << 16;

pub const Mail = struct {
    next: ?*Mail,
    entry: *const fn (arg: ?*anyopaque) void,
    arg: ?*anyopaque,

    pub fn init(entry: *const fn (arg: ?*anyopaque) void, arg: ?*anyopaque) Mail {
        return .{ .next = null, .entry = entry, .arg = arg };
    }
};

/// A carrier's mail: `stack` is written by any thread, `pending_*` by the carrier only.
pub const Mailbox = struct {
    stack: ?*Mail,
    pending_head: ?*Mail,
    pending_tail: ?*Mail,

    pub const empty: Mailbox = .{ .stack = null, .pending_head = null, .pending_tail = null };
};

/// Hands `mail` to `sched`'s carrier and wakes it. Any thread. Preconditions: `mail` stays alive
/// and untouched until its entry has started, and the mail outstanding for `sched` (posted, not
/// yet started) stays within `outstanding_max` counting this one.
pub fn post(sched: *Sched, io: Io, mail: *Mail) void {
    assert(sched.fibers.len > 0);
    mail.next = @atomicLoad(?*Mail, &sched.mailbox.stack, .monotonic);
    while (@cmpxchgWeak(
        ?*Mail,
        &sched.mailbox.stack,
        mail.next,
        mail,
        .release,
        .monotonic,
    )) |seen| {
        mail.next = seen;
    }
    sched.notify(io);
}

/// Moves posted mail to the pending FIFO, then spawns a fiber for each pending mail while a fiber
/// is free. Precondition: carrier thread, outside any fiber's own run (`run_loop` or `serve`).
pub fn drain(sched: *Sched) void {
    assert(sched.current == null);
    mailbox_collect(&sched.mailbox);
    for (0..sched.fibers.len) |_| {
        if (!sched.has_free_fiber()) break;
        const mail = sched.mailbox.pending_head orelse break;
        sched.mailbox.pending_head = mail.next;
        if (sched.mailbox.pending_head == null) sched.mailbox.pending_tail = null;
        const entry = mail.entry;
        const arg = mail.arg;
        _ = sched.spawn(entry, arg) catch |err| switch (err) {
            error.FibersExhausted => unreachable, // `has_free_fiber` held and nothing ran since.
        };
    }
    if (sched.mailbox.pending_head == null) assert(sched.mailbox.pending_tail == null);
}

/// Appends the posted stack to the pending FIFO in posting order; the walk is bounded by
/// `outstanding_max`.
fn mailbox_collect(mailbox: *Mailbox) void {
    // A plain load first: the exchange is a contended write on a line other threads post to.
    if (@atomicLoad(?*Mail, &mailbox.stack, .monotonic) == null) return;
    var reversed: ?*Mail = @atomicRmw(?*Mail, &mailbox.stack, .Xchg, null, .acquire);
    // The stack holds the newest first; reverse it to start mail in the order it was posted.
    var ordered: ?*Mail = null;
    for (0..outstanding_max) |_| {
        const mail = reversed orelse break;
        reversed = mail.next;
        mail.next = ordered;
        ordered = mail;
    }
    assert(reversed == null);
    for (0..outstanding_max) |_| {
        const mail = ordered orelse break;
        ordered = mail.next;
        mail.next = null;
        if (mailbox.pending_tail) |tail| {
            tail.next = mail;
        } else {
            assert(mailbox.pending_head == null);
            mailbox.pending_head = mail;
        }
        mailbox.pending_tail = mail;
    }
    assert(ordered == null);
}

/// Body of a peer carrier's thread (ADR 0004 section 1): starts posted mail, runs the fibers it
/// makes, and sleeps in the idle path between, until `stop` is set; then returns. `Runtime.halt`
/// stores `stop` (release) and then notifies. The version is read before `stop` and the drain so
/// a post between the two is seen. Precondition: not nested, no fiber alive, outside any fiber;
/// when `stop` is set no fiber may be left alive (parked forever fibers would block the exit).
pub fn serve(sched: *Sched, io: Io, stop: *const std.atomic.Value(bool)) void {
    assert(sched.current == null);
    assert(!sched.running);
    assert(sched.live_count == 0);
    // The top-level loop of a carrier thread; it ends when the runtime stops it.
    while (true) {
        const version = @atomicLoad(u32, &sched.inbox_version, .acquire);
        if (stop.load(.acquire)) break;
        drain(sched);
        if (sched.live_count > 0) {
            sched.run(io);
            continue;
        }
        sched.idle_wait(io, version, null);
        assert(sched.live_count == 0);
    }
    assert(sched.inbox == null);
    assert(sched.ready_head == null);
    assert(sched.live_count == 0);
}
