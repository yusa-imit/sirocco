//! Tests of the carrier mailbox (`src/mail.zig`, ADR 0004 section 3): a task posted from any
//! thread is started as a fiber on the posted-to carrier, whose `serve` loop runs it. Each test
//! runs a real peer thread and waits on an atomic count with a bounded spin.

const std = @import("std");
const stdx = @import("stdx.zig");
const mail = @import("mail.zig");
const Sched = @import("sched.zig");

const Io = std.Io;
const Mail = mail.Mail;
const assert = stdx.assert;

const poller_supported = @import("backend/poller.zig").Native != void;
const stack_size_test: u32 = 64 * 1024;
const spin_max: u32 = 20_000_000;

const Probe = struct {
    sched: *Sched,
    /// Mails whose entry ran to its end; the test thread spins on it.
    done: std.atomic.Value(u32),
    /// Written by the carrier only, read by the test after `done` reached its target.
    ids: [8]u32,
    ids_len: u32,
    /// Fibers recorded as `home` of the running fiber, and whether `here()` named the carrier.
    here_ok: bool,
    home_ok: bool,
    carrier_thread: ?std.Thread.Id,
    release: std.atomic.Value(u32),
    started: std.atomic.Value(u32),
    parked: ?*Sched.Fiber,

    fn record(probe: *Probe, id: u32) void {
        assert(probe.ids_len < probe.ids.len);
        probe.ids[probe.ids_len] = id;
        @atomicStore(u32, &probe.ids_len, probe.ids_len + 1, .release);
    }
};

const Job = struct { probe: *Probe, id: u32, mail: Mail };

fn probe_make(sched: *Sched) Probe {
    return .{
        .sched = sched,
        .done = .init(0),
        .ids = @splat(0),
        .ids_len = 0,
        .here_ok = false,
        .home_ok = false,
        .carrier_thread = null,
        .release = .init(0),
        .started = .init(0),
        .parked = null,
    };
}

fn job_make(probe: *Probe, id: u32, entry: *const fn (?*anyopaque) void) Job {
    return .{ .probe = probe, .id = id, .mail = .init(entry, null) };
}

fn job_post(job: *Job, io: Io) void {
    job.mail.arg = job;
    mail.post(job.probe.sched, io, &job.mail);
}

fn job_of(arg: ?*anyopaque) *Job {
    return @ptrCast(@alignCast(arg.?));
}

fn entry_plain(arg: ?*anyopaque) void {
    const job = job_of(arg);
    const probe = job.probe;
    probe.here_ok = Sched.here() == probe.sched;
    probe.home_ok = probe.sched.current_fiber().home == probe.sched;
    probe.carrier_thread = std.Thread.getCurrentId();
    probe.record(job.id);
    _ = probe.done.fetchAdd(1, .release);
}

/// Holds its fiber until `release` is set, so a second mail finds no free fiber.
fn entry_hold(arg: ?*anyopaque) void {
    const job = job_of(arg);
    const probe = job.probe;
    probe.started.store(1, .release);
    for (0..spin_max) |_| {
        if (probe.release.load(.acquire) == 1) break;
        probe.sched.yield();
    }
    probe.record(job.id);
    _ = probe.done.fetchAdd(1, .release);
}

/// Parks until the next mail unparks it: the second mail arrives while a fiber is alive.
fn entry_park(arg: ?*anyopaque) void {
    const job = job_of(arg);
    const probe = job.probe;
    probe.record(job.id);
    probe.parked = probe.sched.current_fiber();
    probe.sched.park();
    probe.record(job.id + 10);
    _ = probe.done.fetchAdd(1, .release);
}

fn entry_unpark(arg: ?*anyopaque) void {
    const job = job_of(arg);
    const probe = job.probe;
    probe.record(job.id);
    probe.sched.unpark(probe.parked.?);
    _ = probe.done.fetchAdd(1, .release);
}

fn serve_main(sched: *Sched, io: Io, stop: *const std.atomic.Value(bool)) void {
    mail.serve(sched, io, stop);
}

const Peer = struct {
    sched: Sched,
    stop: std.atomic.Value(bool),
    thread: std.Thread,

    fn start(peer: *Peer, options: Sched.Options, io: Io) !void {
        try peer.sched.init(std.testing.allocator, options);
        errdefer peer.sched.deinit(std.testing.allocator);

        peer.stop = .init(false);
        peer.thread = try std.Thread.spawn(.{}, serve_main, .{ &peer.sched, io, &peer.stop });
    }

    fn halt(peer: *Peer, io: Io) void {
        peer.stop.store(true, .release);
        peer.sched.notify(io);
        peer.thread.join();
    }

    fn finish(peer: *Peer, io: Io) void {
        peer.halt(io);
        peer.sched.deinit(std.testing.allocator);
    }
};

fn wait_done(probe: *Probe, count: u32) !void {
    for (0..spin_max) |_| {
        if (probe.done.load(.acquire) >= count) return;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    return error.MailNeverRan;
}

fn options_futex(fibers_max: u32) Sched.Options {
    return .{
        .fibers_max = fibers_max,
        .batch_ops_max = 0,
        .stack_size = stack_size_test,
        .now_ns = 0,
        .idle = .futex,
    };
}

fn options_poller(fibers_max: u32) Sched.Options {
    var options = options_futex(fibers_max);
    options.idle = .{ .poller = .{ .registrations_max = 8 } };
    return options;
}

fn run_one_mail(options: Sched.Options) !void {
    const io = std.testing.io;
    var peer: Peer = undefined;
    try peer.start(options, io);
    var probe = probe_make(&peer.sched);
    var job = job_make(&probe, 5, entry_plain);

    job_post(&job, io);
    wait_done(&probe, 1) catch |err| {
        peer.finish(io);
        return err;
    };
    peer.finish(io);

    try std.testing.expect(probe.here_ok);
    try std.testing.expect(probe.home_ok);
    try std.testing.expect(probe.carrier_thread.? != std.Thread.getCurrentId());
    try std.testing.expectEqualSlices(u32, &.{5}, probe.ids[0..probe.ids_len]);
}

test "a mail posted to an idle futex carrier runs as a fiber on that carrier" {
    if (!Sched.supported) return error.SkipZigTest;
    try run_one_mail(options_futex(2));
}

test "a mail posted to an idle poller carrier runs as a fiber on that carrier" {
    if (!Sched.supported or !poller_supported) return error.SkipZigTest;
    try run_one_mail(options_poller(2));
}

test "mail finding no free fiber waits and starts, in order, as fibers end" {
    if (!Sched.supported) return error.SkipZigTest;
    const io = std.testing.io;
    var peer: Peer = undefined;
    try peer.start(options_futex(1), io);
    var probe = probe_make(&peer.sched);
    var first = job_make(&probe, 1, entry_hold);
    var second = job_make(&probe, 2, entry_plain);
    var third = job_make(&probe, 3, entry_plain);

    job_post(&first, io);
    // The only fiber is held, so these two cannot start until it ends.
    for (0..spin_max) |_| {
        if (probe.started.load(.acquire) == 1) break;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    job_post(&second, io);
    job_post(&third, io);
    probe.release.store(1, .release);
    wait_done(&probe, 3) catch |err| {
        peer.finish(io);
        return err;
    };
    peer.finish(io);

    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, probe.ids[0..probe.ids_len]);
}

test "a mail arriving while a fiber is parked is started and can wake it" {
    if (!Sched.supported) return error.SkipZigTest;
    const io = std.testing.io;
    var peer: Peer = undefined;
    try peer.start(options_futex(2), io);
    var probe = probe_make(&peer.sched);
    var parker = job_make(&probe, 1, entry_park);
    var waker = job_make(&probe, 2, entry_unpark);

    job_post(&parker, io);
    // One carrier is cooperative: the waker cannot start before the parker has switched out.
    for (0..spin_max) |_| {
        if (@atomicLoad(u32, &probe.ids_len, .acquire) >= 1) break;
        std.Thread.yield() catch {}; // A scheduling hint only; spinning again is the fallback.
    }
    job_post(&waker, io);
    wait_done(&probe, 2) catch |err| {
        peer.finish(io);
        return err;
    };
    peer.finish(io);

    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 11 }, probe.ids[0..probe.ids_len]);
}

test "a drained mailbox is empty once the carrier has stopped" {
    if (!Sched.supported) return error.SkipZigTest;
    const io = std.testing.io;
    var peer: Peer = undefined;
    try peer.start(options_futex(1), io);
    var probe = probe_make(&peer.sched);
    var job = job_make(&probe, 4, entry_plain);

    job_post(&job, io);
    wait_done(&probe, 1) catch |err| {
        peer.finish(io);
        return err;
    };
    peer.halt(io);
    defer peer.sched.deinit(std.testing.allocator);

    try std.testing.expect(peer.sched.mailbox.stack == null);
    try std.testing.expect(peer.sched.mailbox.pending_head == null);
    try std.testing.expectEqual(@as(u32, 1), probe.done.load(.acquire));
}

const producers = 3;
const mails_per_producer = 20;

const Burst = struct { jobs: [mails_per_producer]Job };

fn entry_count(arg: ?*anyopaque) void {
    _ = job_of(arg).probe.done.fetchAdd(1, .release);
}

fn producer_main(burst: *Burst, io: Io) void {
    for (&burst.jobs) |*job| job_post(job, io);
}

test "mail posted by several threads at once all runs, none twice" {
    if (!Sched.supported) return error.SkipZigTest;
    const io = std.testing.io;
    var peer: Peer = undefined;
    try peer.start(options_futex(4), io);
    var probe = probe_make(&peer.sched);
    var bursts: [producers]Burst = undefined;
    var threads: [producers]std.Thread = undefined;
    for (&bursts, &threads) |*burst, *thread| {
        for (&burst.jobs) |*job| job.* = job_make(&probe, 0, entry_count);
        thread.* = try std.Thread.spawn(.{}, producer_main, .{ burst, io });
    }
    for (&threads) |thread| thread.join();
    wait_done(&probe, producers * mails_per_producer) catch |err| {
        peer.finish(io);
        return err;
    };
    peer.finish(io);

    const total: u32 = producers * mails_per_producer;
    try std.testing.expectEqual(total, probe.done.load(.acquire));
}
