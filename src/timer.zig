//! Hierarchical timing wheel for sirocco's fiber sleeps and futex timeouts (plan 003 item 3).
//!
//! Model: a node is an integer id below `nodes_max` (the scheduler uses the fiber index) with a
//! deadline in nanoseconds on whatever clock the caller reads. The wheel never reads a clock:
//! `insert` and `expire` take the time as an argument, so a seeded test replays it exactly. A
//! deadline is rounded *up* to a multiple of `tick_ns` (131 us, under the 250 us budget that keeps
//! a 1 ms sleep inside PRD gate 7), so a node fires between zero and one tick late and never
//! early. `expire` only moves due nodes to a due list; `pop_due` hands them out one at a time, so
//! the caller decides when work happens. Nodes due in different ticks come out in tick order;
//! nodes of one tick come out in no promised order. `next_deadline` reports the rounded time at
//! which the earliest node fires, so a caller that sleeps until it and calls `expire` finds it due.
//! A deadline in the last tick below 2^64 ns saturates and may fire up to one tick early.
//!
//! Layout: four levels of 64 slots (6 bits of the tick number each, 2^24 ticks ~ 36 minutes of
//! horizon) plus one overflow list for later deadlines, entered block by block once the lower
//! levels run empty. A node sits at the level of the highest bit in which its tick differs from
//! the wheel's current tick, in the slot named by its own digit at that level; every occupied
//! slot therefore starts strictly after the current tick.
//! `expire` jumps the current tick from occupied slot to occupied slot (never tick by tick, so an
//! idle hour costs nothing) and re-places each visited slot's nodes against the new tick, so a
//! node moves down at most once per level. A level has a 64-bit mask of occupied slots, so
//! `next_deadline` and the jump are a count-trailing-zeros, plus one scan of the winning slot.
//!
//! Cost sketch: `insert` and `remove` O(1), no syscall, two cache lines (node, slot head);
//! `expire` O(nodes re-placed), at most four moves per node below the overflow list. Entering the
//! overflow list scans it (O(overflow nodes), bounded by `nodes_max`), and so does `next_deadline`
//! while only overflow nodes are linked; the scheduler's bound is the fiber count. A node is 32
//! bytes.
//!
//! Allocation: `init` allocates the node array (`nodes_max` entries) and nothing else; no other
//! function allocates or takes an allocator. Ownership: the wheel owns the array; ids belong to
//! the caller. Threads: none; the owner serialises calls (the carrier).

const std = @import("std");
const stdx = @import("stdx.zig");

const Wheel = @This();

const assert = stdx.assert;

/// Wheel resolution in nanoseconds: 2^17 = 131072 ns.
pub const tick_ns: u64 = 1 << tick_shift;

pub const Options = struct {
    /// Number of distinct node ids; ids are `0..nodes_max`. Must be above zero.
    nodes_max: u32,
    /// The clock reading the wheel starts at; no later call may pass an earlier time.
    now_ns: u64,
};

nodes: []Node,
/// Slot heads: levels `0..levels_count`, and the overflow list in `heads[levels_count][0]`.
heads: [levels_count + 1][slots_count]u32,
/// Bit `s` of `masks[level]` is set exactly when `heads[level][s]` is not empty.
masks: [levels_count]u64,
due_head: u32,
due_tail: u32,
/// Nodes in the due list.
due_count: u32,
/// Nodes in the wheel proper, the overflow list or the due list.
linked_count: u32,
/// The tick the wheel has advanced to: `expire` brings it to `now_ns >> tick_shift`.
tick_now: u64,

comptime {
    assert(@sizeOf(Node) == 32);
}

const Node = struct {
    deadline_ns: u64,
    /// `deadline_ns` rounded up to a tick; meaningful while linked.
    tick: u64,
    next: u32,
    prev: u32,
    level: u8,
    slot: u8,
};

const tick_shift = 17;
const digit_bits = 6;
const slots_count = 1 << digit_bits;
const levels_count = 4;
const overflow_level: u8 = levels_count;
const due_level: u8 = levels_count + 1;
const unlinked_level: u8 = 0xff;
const none: u32 = std.math.maxInt(u32);

const unlinked_node: Node = .{
    .deadline_ns = 0,
    .tick = 0,
    .next = none,
    .prev = none,
    .level = unlinked_level,
    .slot = 0,
};

/// Fills `target` in place. Precondition: `options.nodes_max > 0`. Allocates `nodes_max` nodes
/// from `gpa`, the only allocation of the wheel's life; on error nothing is left allocated.
pub fn init(target: *Wheel, gpa: std.mem.Allocator, options: Options) error{OutOfMemory}!void {
    assert(options.nodes_max > 0);
    assert(options.nodes_max < none);

    const nodes = try gpa.alloc(Node, options.nodes_max);
    errdefer gpa.free(nodes);

    @memset(nodes, unlinked_node);
    target.* = .{
        .nodes = nodes,
        .heads = @splat(@splat(none)),
        .masks = @splat(0),
        .due_head = none,
        .due_tail = none,
        .due_count = 0,
        .linked_count = 0,
        .tick_now = options.now_ns >> tick_shift,
    };
    target.check_invariants();
}

/// Frees the node array; nodes still linked are dropped. `gpa` must be the one given to `init`.
pub fn deinit(wheel: *Wheel, gpa: std.mem.Allocator) void {
    assert(wheel.nodes.len > 0);
    gpa.free(wheel.nodes);
    wheel.* = undefined;
}

/// Number of linked nodes: waiting in the wheel, or due and not yet popped.
pub fn count(wheel: *const Wheel) u32 {
    assert(wheel.linked_count <= wheel.nodes.len);
    return wheel.linked_count;
}

/// Precondition: `id < nodes_max`.
pub fn is_linked(wheel: *const Wheel, id: u32) bool {
    assert(id < wheel.nodes.len);
    return wheel.nodes[id].level != unlinked_level;
}

/// Links `id` to fire at `deadline_ns`. Preconditions: `id < nodes_max` and not linked. A
/// deadline that is not after the wheel's tick goes straight to the due list.
pub fn insert(wheel: *Wheel, id: u32, deadline_ns: u64) void {
    assert(id < wheel.nodes.len);
    assert(!wheel.is_linked(id));

    const node = &wheel.nodes[id];
    node.deadline_ns = deadline_ns;
    node.tick = (deadline_ns +| (tick_ns - 1)) >> tick_shift;
    wheel.linked_count += 1;
    wheel.place(id);
    assert(wheel.is_linked(id));
}

/// Unlinks `id` wherever it waits, due list included. Precondition: `id` is linked.
pub fn remove(wheel: *Wheel, id: u32) void {
    assert(id < wheel.nodes.len);
    assert(wheel.is_linked(id));

    if (wheel.nodes[id].level == due_level) wheel.due_count -= 1;
    wheel.unlink(id);
    wheel.linked_count -= 1;
    assert(!wheel.is_linked(id));
}

/// Advances the wheel to `now_ns` and moves every node whose rounded deadline has passed to the
/// due list. Returns the length of the due list afterwards, nodes inserted already late included.
/// A `now_ns` earlier than one given before is treated as no time having passed.
pub fn expire(wheel: *Wheel, now_ns: u64) u32 {
    // A clock that steps back (wall time) must not re-base the wheel under occupied slots.
    const target = @max(now_ns >> tick_shift, wheel.tick_now);

    // Each pass empties one occupied slot and moves each of its nodes to a lower level or to the
    // due list, so a node is visited at most once per level and the overflow list.
    const passes_max = (levels_count + 1) * wheel.nodes.len + 1;
    for (0..passes_max) |_| {
        const next = wheel.next_slot() orelse break;
        if (next.start > target) break;
        assert(next.start > wheel.tick_now);
        wheel.tick_now = next.start;
        wheel.cascade(next.level, next.slot);
    } else stdx.assert_always(false);
    wheel.tick_now = target;
    assert(wheel.due_count <= wheel.linked_count);
    return wheel.due_count;
}

/// Unlinks and returns the oldest due node, or null when none is due.
pub fn pop_due(wheel: *Wheel) ?u32 {
    const id = wheel.due_head;
    if (id == none) {
        assert(wheel.due_count == 0);
        return null;
    }
    assert(wheel.due_count > 0);
    wheel.unlink(id);
    wheel.due_count -= 1;
    wheel.linked_count -= 1;
    assert(!wheel.is_linked(id));
    return id;
}

/// The time the earliest linked node fires: its deadline rounded up to a tick, or null when empty.
pub fn next_deadline(wheel: *const Wheel) ?u64 {
    if (wheel.due_count > 0) return wheel.min_fire_ns(wheel.due_head);
    const next = wheel.next_slot() orelse {
        assert(wheel.linked_count == 0);
        return null;
    };
    return wheel.min_fire_ns(wheel.heads[next.level][next.slot]);
}

/// Walks every list and checks the placement rule, link symmetry, masks and counters.
pub fn check_invariants(wheel: *const Wheel) void {
    var linked: u32 = 0;
    for (wheel.heads, 0..) |level_heads, level| {
        for (level_heads, 0..) |head, slot| {
            const walked = wheel.check_list(head, @intCast(level), @intCast(slot));
            if (level < levels_count) {
                assert(((wheel.masks[level] >> @intCast(slot)) & 1 == 1) == (head != none));
            }
            linked += walked;
        }
    }
    const due = wheel.check_list(wheel.due_head, due_level, 0);
    assert(due == wheel.due_count);
    if (wheel.due_head == none) assert(wheel.due_tail == none);
    if (wheel.due_head != none) assert(wheel.nodes[wheel.due_tail].next == none);
    assert(linked + due == wheel.linked_count);
    var unlinked: u32 = 0;
    for (wheel.nodes) |node| unlinked += @intFromBool(node.level == unlinked_level);
    assert(unlinked + wheel.linked_count == wheel.nodes.len);
}

fn check_list(wheel: *const Wheel, head: u32, level: u8, slot: u8) u32 {
    var walked: u32 = 0;
    var prev: u32 = none;
    var id = head;
    for (0..wheel.nodes.len + 1) |_| {
        if (id == none) return walked;
        const node = &wheel.nodes[id];
        assert(node.prev == prev);
        assert(node.level == level);
        assert(node.slot == slot);
        if (level == due_level) assert(node.tick <= wheel.tick_now);
        if (level != due_level) assert(node.tick > wheel.tick_now);
        if (level != due_level) assert(wheel.location(node.tick).level == level);
        if (level < levels_count) assert(wheel.location(node.tick).slot == slot);
        walked += 1;
        prev = id;
        id = node.next;
    }
    stdx.assert_always(false); // A cycle in a list.
    return walked;
}

const Location = struct { level: u8, slot: u8 };

/// Where a node due at `tick` belongs relative to `tick_now`. Precondition: `tick > tick_now`.
fn location(wheel: *const Wheel, tick: u64) Location {
    assert(tick > wheel.tick_now);
    const high_bit: u32 = 63 - @clz(tick ^ wheel.tick_now);
    const level = high_bit / digit_bits;
    if (level >= levels_count) return .{ .level = overflow_level, .slot = 0 };
    const slot = (tick >> @intCast(level * digit_bits)) & (slots_count - 1);
    return .{ .level = @intCast(level), .slot = @intCast(slot) };
}

/// Links a node that is not yet in any list, by its `tick`.
fn place(wheel: *Wheel, id: u32) void {
    const node = &wheel.nodes[id];
    assert(node.level == unlinked_level);
    if (node.tick <= wheel.tick_now) {
        node.level = due_level;
        node.slot = 0;
        node.next = none;
        node.prev = wheel.due_tail;
        if (wheel.due_tail == none) wheel.due_head = id else wheel.nodes[wheel.due_tail].next = id;
        wheel.due_tail = id;
        wheel.due_count += 1;
        return;
    }
    const where = wheel.location(node.tick);
    const head = &wheel.heads[where.level][where.slot];
    node.level = where.level;
    node.slot = where.slot;
    node.prev = none;
    node.next = head.*;
    if (head.* != none) wheel.nodes[head.*].prev = id;
    head.* = id;
    if (where.level < levels_count) wheel.masks[where.level] |= @as(u64, 1) << @intCast(where.slot);
}

/// Takes `id` out of its list and marks it unlinked; the caller adjusts the counters.
fn unlink(wheel: *Wheel, id: u32) void {
    const node = &wheel.nodes[id];
    assert(node.level != unlinked_level);
    if (node.next != none) wheel.nodes[node.next].prev = node.prev;
    if (node.level == due_level) {
        if (node.next == none) wheel.due_tail = node.prev;
        if (node.prev == none) wheel.due_head = node.next;
    } else if (node.prev == none) {
        wheel.heads[node.level][node.slot] = node.next;
        const emptied = node.next == none;
        if (emptied and node.level < levels_count) {
            wheel.masks[node.level] &= ~(@as(u64, 1) << @intCast(node.slot));
        }
    }
    if (node.prev != none) wheel.nodes[node.prev].next = node.next;
    node.* = .{
        .deadline_ns = node.deadline_ns,
        .tick = node.tick,
        .next = none,
        .prev = none,
        .level = unlinked_level,
        .slot = 0,
    };
}

const Slot = struct { level: u8, slot: u8, start: u64 };

/// The occupied slot that starts first, with the tick it starts at; null when only the due list
/// (or nothing) is linked. Occupied slots at a level lie strictly after the current digit. The
/// overflow list counts as one slot starting at the horizon block of its earliest node.
fn next_slot(wheel: *const Wheel) ?Slot {
    for (wheel.masks, 0..) |mask, level| {
        if (mask == 0) continue;
        const shift: u6 = @intCast(level * digit_bits);
        const digit: u6 = @intCast((wheel.tick_now >> shift) & (slots_count - 1));
        assert(mask & ((@as(u64, 2) << digit) -% 1) == 0);
        const slot: u6 = @intCast(@ctz(mask));
        const block = (wheel.tick_now >> (shift + digit_bits)) << (shift + digit_bits);
        const start = block | (@as(u64, slot) << shift);
        return .{ .level = @intCast(level), .slot = slot, .start = start };
    }
    var id = wheel.heads[overflow_level][0];
    if (id == none) return null;
    // Lower levels are empty, so the earliest overflow node decides which horizon block to enter.
    var tick_min: u64 = std.math.maxInt(u64);
    for (0..wheel.nodes.len) |_| {
        if (id == none) break;
        tick_min = @min(tick_min, wheel.nodes[id].tick);
        id = wheel.nodes[id].next;
    }
    const block = tick_min >> (levels_count * digit_bits);
    assert(block > wheel.tick_now >> (levels_count * digit_bits));
    return .{ .level = overflow_level, .slot = 0, .start = block << (levels_count * digit_bits) };
}

/// Re-places every node of one slot against the (already advanced) current tick.
fn cascade(wheel: *Wheel, level: u8, slot: u8) void {
    var id = wheel.heads[level][slot];
    assert(id != none);
    wheel.heads[level][slot] = none;
    if (level < levels_count) wheel.masks[level] &= ~(@as(u64, 1) << @intCast(slot));
    for (0..wheel.nodes.len) |_| {
        if (id == none) return;
        const node = &wheel.nodes[id];
        const next = node.next;
        node.level = unlinked_level;
        wheel.place(id);
        assert(node.level != unlinked_level);
        assert(node.level <= level or node.level == due_level);
        id = next;
    }
    stdx.assert_always(id == none);
}

fn min_fire_ns(wheel: *const Wheel, head: u32) u64 {
    assert(head != none);
    var tick_min: u64 = std.math.maxInt(u64);
    var id = head;
    for (0..wheel.nodes.len) |_| {
        if (id == none) break;
        tick_min = @min(tick_min, wheel.nodes[id].tick);
        id = wheel.nodes[id].next;
    }
    assert(tick_min < std.math.maxInt(u64));
    return tick_min << tick_shift;
}

const testing = std.testing;

fn expect_due(wheel: *Wheel, expected: []const u32) !void {
    var got: [16]u32 = undefined;
    var n: u32 = 0;
    while (wheel.pop_due()) |id| : (n += 1) got[n] = id;
    try testing.expectEqualSlices(u32, expected, got[0..n]);
}

test "tick is at most 250 microseconds" {
    comptime assert(tick_ns <= 250_000);
    comptime assert(std.math.isPowerOfTwo(tick_ns));
}

test "a node expires at its deadline rounded up to a tick, never before" {
    var wheel: Wheel = undefined;
    try wheel.init(testing.allocator, .{ .nodes_max = 4, .now_ns = 1_000_000 });
    defer wheel.deinit(testing.allocator);

    wheel.insert(2, 3_000_000);
    try testing.expectEqual(@as(?u64, 23 * tick_ns), wheel.next_deadline());
    try testing.expectEqual(@as(u32, 0), wheel.expire(23 * tick_ns - 1));
    try testing.expect(wheel.is_linked(2));
    try testing.expectEqual(@as(u32, 1), wheel.expire(23 * tick_ns));
    try expect_due(&wheel, &.{2});
    try testing.expect(!wheel.is_linked(2));
    try testing.expectEqual(@as(u32, 0), wheel.count());
    try testing.expectEqual(@as(?u64, null), wheel.next_deadline());
    wheel.check_invariants();
}

test "a deadline already past is due without waiting for a tick" {
    var wheel: Wheel = undefined;
    try wheel.init(testing.allocator, .{ .nodes_max = 4, .now_ns = 10 * tick_ns });
    defer wheel.deinit(testing.allocator);

    wheel.insert(0, 5 * tick_ns);
    wheel.insert(1, 10 * tick_ns);
    try testing.expectEqual(@as(u32, 2), wheel.expire(10 * tick_ns));
    try expect_due(&wheel, &.{ 0, 1 });
}

test "remove unlinks from the slot, the due list and the overflow list" {
    var wheel: Wheel = undefined;
    try wheel.init(testing.allocator, .{ .nodes_max = 4, .now_ns = 0 });
    defer wheel.deinit(testing.allocator);

    wheel.insert(0, 50 * tick_ns);
    wheel.insert(1, 0);
    wheel.insert(2, (1 << 40) * tick_ns);
    try testing.expectEqual(@as(u32, 3), wheel.count());
    wheel.remove(0);
    wheel.remove(1);
    wheel.remove(2);
    try testing.expectEqual(@as(u32, 0), wheel.count());
    try testing.expectEqual(@as(?u64, null), wheel.next_deadline());
    try testing.expectEqual(@as(u32, 0), wheel.expire(1 << 60));
    try expect_due(&wheel, &.{});
    wheel.check_invariants();
}

test "a node past the wheel horizon waits in overflow and still fires on time" {
    var wheel: Wheel = undefined;
    try wheel.init(testing.allocator, .{ .nodes_max = 2, .now_ns = 0 });
    defer wheel.deinit(testing.allocator);

    const far_ns: u64 = (3 << 24) * tick_ns + 777;
    wheel.insert(1, far_ns);
    wheel.insert(0, 20 * tick_ns);
    try testing.expectEqual(@as(?u64, 20 * tick_ns), wheel.next_deadline());
    try testing.expectEqual(@as(u32, 1), wheel.expire(far_ns - 1));
    try expect_due(&wheel, &.{0});
    try testing.expectEqual(@as(?u64, 3 * (1 << 24) * tick_ns + tick_ns), wheel.next_deadline());
    try testing.expectEqual(@as(u32, 1), wheel.expire(far_ns + tick_ns));
    try expect_due(&wheel, &.{1});
    wheel.check_invariants();
}

test "init fails cleanly under every allocation failure" {
    const run = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var wheel: Wheel = undefined;
            try wheel.init(gpa, .{ .nodes_max = 8, .now_ns = 0 });
            wheel.deinit(gpa);
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, run, .{});
}

const Reference = struct {
    deadline_ns: [nodes_max]u64,
    active: [nodes_max]bool,

    const nodes_max = 64;

    fn due_tick(deadline_ns: u64) u64 {
        return (deadline_ns +| (tick_ns - 1)) >> tick_shift;
    }

    fn min_fire_ns(ref: *const Reference) ?u64 {
        var best: ?u64 = null;
        for (ref.active, ref.deadline_ns) |active, deadline_ns| {
            const tick = due_tick(deadline_ns);
            if (active and (best == null or tick < best.?)) best = tick;
        }
        return if (best) |tick| tick << tick_shift else null;
    }
};

fn model_deadline(prng: *std.Random.DefaultPrng, now_ns: u64) u64 {
    const random = prng.random();
    const kind = random.uintLessThan(u32, 40);
    if (kind == 0) return now_ns -| random.uintLessThan(u64, tick_ns * 8);
    if (kind == 1) return std.math.maxInt(u64) - random.uintLessThan(u64, 4 * tick_ns);
    const span_ns: u64 = switch (kind % 5) {
        0 => tick_ns * 3,
        1 => tick_ns * 64,
        2 => tick_ns * 4096,
        3 => tick_ns * (1 << 20),
        else => tick_ns * (1 << 26),
    };
    return now_ns + random.uintLessThan(u64, span_ns);
}

test "model: 10k random insert, remove and expire ops match a sorted reference" {
    var prng = std.Random.DefaultPrng.init(0x7131_0003);
    const random = prng.random();
    var now_ns: u64 = 12_345_678;
    var wheel: Wheel = undefined;
    try wheel.init(testing.allocator, .{ .nodes_max = Reference.nodes_max, .now_ns = now_ns });
    defer wheel.deinit(testing.allocator);

    var ref: Reference = .{
        .deadline_ns = @splat(0),
        .active = @splat(false),
    };
    for (0..10_000) |_| {
        const id = random.uintLessThan(u32, Reference.nodes_max);
        switch (random.uintLessThan(u32, 3)) {
            0 => if (!ref.active[id]) {
                ref.deadline_ns[id] = model_deadline(&prng, now_ns);
                ref.active[id] = true;
                wheel.insert(id, ref.deadline_ns[id]);
            },
            1 => if (ref.active[id]) {
                ref.active[id] = false;
                wheel.remove(id);
            },
            else => {
                now_ns += random.uintLessThan(u64, tick_ns * 4096);
                if (random.uintLessThan(u32, 50) == 0) now_ns += tick_ns * (1 << 25);
                var expected: [Reference.nodes_max]bool = @splat(false);
                var expected_count: u32 = 0;
                for (ref.active, ref.deadline_ns, 0..) |active, deadline_ns, index| {
                    if (active and Reference.due_tick(deadline_ns) <= now_ns >> tick_shift) {
                        expected[index] = true;
                        expected_count += 1;
                        ref.active[index] = false;
                    }
                }
                try testing.expectEqual(expected_count, wheel.expire(now_ns));
                var seen: u32 = 0;
                var tick_last: u64 = 0;
                while (wheel.pop_due()) |popped| : (seen += 1) {
                    const tick = Reference.due_tick(ref.deadline_ns[popped]);
                    try testing.expect(tick >= tick_last);
                    tick_last = tick;
                    try testing.expect(expected[popped]);
                    expected[popped] = false;
                    try testing.expect(ref.deadline_ns[popped] <= now_ns);
                }
                try testing.expectEqual(expected_count, seen);
            },
        }
        wheel.check_invariants();
        try testing.expectEqual(ref.min_fire_ns(), wheel.next_deadline());
    }
}

test "the latest possible deadline fires on one jump of the clock" {
    var wheel: Wheel = undefined;
    try wheel.init(testing.allocator, .{ .nodes_max = 3, .now_ns = 0 });
    defer wheel.deinit(testing.allocator);

    wheel.insert(0, std.math.maxInt(u64));
    wheel.insert(1, (1 << 30) * tick_ns);
    wheel.insert(2, 1);
    try testing.expectEqual(@as(u32, 1), wheel.expire(tick_ns));
    try expect_due(&wheel, &.{2});
    try testing.expectEqual(@as(u32, 1), wheel.expire((1 << 30) * tick_ns));
    try expect_due(&wheel, &.{1});
    try testing.expectEqual(@as(?u64, ((1 << 47) - 1) * tick_ns), wheel.next_deadline());
    try testing.expectEqual(@as(u32, 1), wheel.expire(std.math.maxInt(u64)));
    try expect_due(&wheel, &.{0});
    wheel.check_invariants();
}

test "a clock that steps back is treated as no time passing" {
    var wheel: Wheel = undefined;
    try wheel.init(testing.allocator, .{ .nodes_max = 2, .now_ns = 100 * tick_ns });
    defer wheel.deinit(testing.allocator);

    wheel.insert(0, 150 * tick_ns);
    try testing.expectEqual(@as(u32, 0), wheel.expire(120 * tick_ns));
    try testing.expectEqual(@as(u32, 0), wheel.expire(10 * tick_ns));
    wheel.insert(1, 125 * tick_ns);
    try testing.expectEqual(@as(u32, 0), wheel.expire(124 * tick_ns));
    try testing.expectEqual(@as(u32, 1), wheel.expire(125 * tick_ns));
    try expect_due(&wheel, &.{1});
    try testing.expectEqual(@as(u32, 1), wheel.expire(150 * tick_ns));
    try expect_due(&wheel, &.{0});
    wheel.check_invariants();
}
