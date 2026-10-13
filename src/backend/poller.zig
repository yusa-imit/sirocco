//! sirocco.backend.poller — the readiness contract shared by the evented backends (ADR 0003).
//!
//! Purpose: one carrier idles in `Poller.wait`; fibers park on `arm(fd, interest, token)` and the
//! event naming their token unparks them. This file holds what kqueue and epoll share: the
//! value types, the limits, the bounded `Table` that remembers armed pairs, and `contract`,
//! which makes drift between backends a compile error.
//!
//! Invariants: `Native` is the one backend compiled for the target (kqueue on Darwin, `void`
//! elsewhere until FreeBSD and epoll land). Registrations are one-shot. At most
//! `registrations_max` pairs are armed, the `Table` is allocated in `init` and never grows.
//! Every `Poller` function except `wake` is carrier-only.

const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("../stdx.zig");

const assert = stdx.assert;
const assert_always = stdx.assert_always;

pub const Interest = enum(u1) { read, write };

/// One readiness notification. `hangup` means the kernel reported EOF or an error; the caller
/// retries its syscall either way and the syscall's result is the truth.
pub const Event = struct {
    token: u64,
    interest: Interest,
    hangup: bool,
};

pub const Options = struct {
    /// Most `(fd, interest)` pairs armed at once; positive, at most `registrations_max_limit`.
    registrations_max: u32,
};

pub const registrations_max_limit: u32 = 1 << 24;

/// Most events one `wait` call moves from the kernel; also the stack buffer size in `wait`.
pub const events_max: u32 = 64;

pub const InitError = error{
    OutOfMemory,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
};

pub const ArmError = error{ SystemResources, Unpollable };

pub const fd_t = std.posix.fd_t;

/// The evented backend of this target, chosen at comptime (ADR 0003: no vtable).
/// kqueue is compiled for Darwin only: FreeBSD lacks `c.EV.EOF` in std, and OpenBSD and NetBSD
/// lack `EVFILT_USER`. Every other target is `void` until its backend lands.
pub const Native = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => @import("kqueue.zig"),
    else => void,
};

/// Compile error unless `Poller` declares the contract with exactly these types.
pub fn contract(comptime Poller: type) void {
    comptime {
        assert(@typeInfo(Poller) == .@"struct");
        const Slice = []Event;
        expect_decl(Poller, "init", fn (*Poller, std.mem.Allocator, Options) InitError!void);
        expect_decl(Poller, "deinit", fn (*Poller, std.mem.Allocator) void);
        expect_decl(Poller, "arm", fn (*Poller, fd_t, Interest, u64) ArmError!void);
        expect_decl(Poller, "disarm", fn (*Poller, fd_t, Interest) void);
        expect_decl(Poller, "is_armed", fn (*const Poller, fd_t, Interest) bool);
        expect_decl(Poller, "wait", fn (*Poller, ?u64, Slice) u32);
        expect_decl(Poller, "wake", fn (*const Poller) void);
    }
}

fn expect_decl(comptime Poller: type, comptime name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(Poller, name)) {
        @compileError("poller contract: missing declaration `" ++ name ++ "`");
    }
    const Actual = @TypeOf(@field(Poller, name));
    if (Actual != Expected) {
        @compileError("poller contract: `" ++ name ++ "` is " ++ @typeName(Actual) ++
            ", expected " ++ @typeName(Expected));
    }
}

/// The table key of an armed pair: the fd shifted left one bit, the interest in bit 0.
pub fn key(fd: fd_t, interest: Interest) u64 {
    assert(fd >= 0);
    const fd_wide: u64 = @intCast(fd);
    assert(fd_wide < (1 << 62));
    return (fd_wide << 1) | @intFromEnum(interest);
}

/// Fixed-capacity open-addressing map `u64 -> u64`: linear probing, Fibonacci hash,
/// backward-shift delete (no tombstones). Capacity is the power of two at least twice
/// `count_max`, allocated once in `init`, so a probe always ends at an empty slot.
pub const Table = struct {
    keys: []u64,
    values: []u64,
    count: u32,
    count_max: u32,

    /// Marks an empty slot; not a valid key (`key` never produces it).
    pub const key_empty: u64 = std.math.maxInt(u64);

    pub fn init(target: *Table, gpa: std.mem.Allocator, count_max: u32) error{OutOfMemory}!void {
        assert(count_max > 0);
        assert(count_max <= registrations_max_limit);
        const capacity: u32 = std.math.ceilPowerOfTwoAssert(u32, 2 * count_max);
        const slots = try gpa.alloc(u64, 2 * @as(usize, capacity));
        @memset(slots[0..capacity], key_empty);
        target.* = .{
            .keys = slots[0..capacity],
            .values = slots[capacity..],
            .count = 0,
            .count_max = count_max,
        };
        assert(target.keys.len == target.values.len);
        assert(std.math.isPowerOfTwo(target.keys.len));
    }

    pub fn deinit(table: *Table, gpa: std.mem.Allocator) void {
        assert(table.keys.len == table.values.len);
        assert(table.count <= table.count_max);
        gpa.free(table.keys.ptr[0 .. 2 * table.keys.len]);
        table.* = undefined;
    }

    /// Precondition: `k` is absent and not `key_empty`. A full table returns
    /// `error.SystemResources` and stays unchanged.
    pub fn insert(table: *Table, k: u64, value: u64) error{SystemResources}!void {
        assert(k != key_empty);
        assert_always(table.get(k) == null);
        if (table.count == table.count_max) return error.SystemResources;
        const mask = table.keys.len - 1;
        var slot = table.home(k);
        // The load factor is at most 1/2, so an empty slot lies within `keys.len` steps.
        for (0..table.keys.len) |_| {
            if (table.keys[slot] == key_empty) {
                table.keys[slot] = k;
                table.values[slot] = value;
                table.count += 1;
                return;
            }
            slot = (slot + 1) & mask;
        }
        unreachable; // proof: count < count_max <= keys.len / 2, so an empty slot exists.
    }

    pub fn remove(table: *Table, k: u64) ?u64 {
        assert(k != key_empty);
        assert(table.count <= table.count_max);
        const found = table.find(k) orelse return null;
        const value = table.values[found];
        table.keys[found] = key_empty;
        table.count -= 1;
        table.shift_back(found);
        return value;
    }

    pub fn get(table: *const Table, k: u64) ?u64 {
        assert(k != key_empty);
        assert(table.count <= table.count_max);
        const found = table.find(k) orelse return null;
        return table.values[found];
    }

    fn home(table: *const Table, k: u64) usize {
        const shift: u6 = @intCast(64 - @ctz(@as(u64, table.keys.len)));
        return @intCast((k *% 0x9E3779B97F4A7C15) >> shift);
    }

    fn find(table: *const Table, k: u64) ?usize {
        const mask = table.keys.len - 1;
        var slot = table.home(k);
        for (0..table.keys.len) |_| {
            if (table.keys[slot] == k) return slot;
            if (table.keys[slot] == key_empty) return null;
            slot = (slot + 1) & mask;
        }
        return null;
    }

    /// Backward-shift delete: refill the hole at `hole_start` from the probe chain after it, so
    /// no lookup ever crosses a gap it did not cross before.
    fn shift_back(table: *Table, hole_start: usize) void {
        const mask = table.keys.len - 1;
        var hole = hole_start;
        var scan = hole;
        for (0..table.keys.len) |_| {
            scan = (scan + 1) & mask;
            if (table.keys[scan] == key_empty) return;
            const wanted = table.home(table.keys[scan]);
            // Movable unless `wanted` lies cyclically in (hole, scan].
            const stays = if (hole <= scan)
                hole < wanted and wanted <= scan
            else
                hole < wanted or wanted <= scan;
            if (stays) continue;
            table.keys[hole] = table.keys[scan];
            table.values[hole] = table.values[scan];
            table.keys[scan] = key_empty;
            hole = scan;
        }
    }
};

const testing = std.testing;

test "Table: insert, get, remove" {
    var table: Table = undefined;
    try Table.init(&table, testing.allocator, 4);
    defer table.deinit(testing.allocator);

    try table.insert(10, 100);
    try table.insert(11, 110);
    try testing.expectEqual(@as(u32, 2), table.count);
    try testing.expectEqual(@as(?u64, 100), table.get(10));
    try testing.expectEqual(@as(?u64, 110), table.get(11));
    try testing.expectEqual(@as(?u64, null), table.get(12));
    try testing.expectEqual(@as(?u64, 100), table.remove(10));
    try testing.expectEqual(@as(?u64, null), table.remove(10));
    try testing.expectEqual(@as(?u64, null), table.get(10));
    try testing.expectEqual(@as(?u64, 110), table.get(11));
    try testing.expectEqual(@as(u32, 1), table.count);
    try testing.expectEqual(@as(?u64, 110), table.remove(11));
    try testing.expectEqual(@as(u32, 0), table.count);
}

test "Table: full insert fails and leaves the table unchanged" {
    var table: Table = undefined;
    try Table.init(&table, testing.allocator, 3);
    defer table.deinit(testing.allocator);

    try table.insert(1, 1);
    try table.insert(2, 2);
    try table.insert(3, 3);
    try testing.expectError(error.SystemResources, table.insert(4, 4));
    try testing.expectEqual(@as(u32, 3), table.count);
    try testing.expectEqual(@as(?u64, null), table.get(4));
    try testing.expectEqual(@as(?u64, 2), table.get(2));
    // Freeing a slot makes room again.
    try testing.expectEqual(@as(?u64, 2), table.remove(2));
    try table.insert(4, 40);
    try testing.expectEqual(@as(?u64, 40), table.get(4));
}

test "Table: capacity is a power of two at least twice count_max" {
    var table: Table = undefined;
    try Table.init(&table, testing.allocator, 5);
    defer table.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 16), table.keys.len);
    try testing.expectEqual(table.keys.len, table.values.len);
    for (table.keys) |slot| try testing.expectEqual(Table.key_empty, slot);
}

test "Table: init surfaces OutOfMemory and keeps nothing" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var table: Table = undefined;
    try testing.expectError(error.OutOfMemory, Table.init(&table, failing.allocator(), 8));
    try testing.expectEqual(@as(usize, 0), failing.allocated_bytes - failing.freed_bytes);
}

test "Table: model test against std.AutoHashMap through backward-shift deletes" {
    const ops_max: u32 = 20_000;
    const count_max: u32 = 32;
    const key_space: u64 = 48; // above count_max so inserts also hit the full path
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();

    var table: Table = undefined;
    try Table.init(&table, testing.allocator, count_max);
    defer table.deinit(testing.allocator);

    var model = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer model.deinit();

    for (0..ops_max) |op_index| {
        const k = random.uintLessThan(u64, key_space);
        const value: u64 = op_index;
        switch (random.uintLessThan(u8, 3)) {
            0 => if (!model.contains(k)) {
                if (model.count() < count_max) {
                    try table.insert(k, value);
                    try model.put(k, value);
                } else {
                    try testing.expectError(error.SystemResources, table.insert(k, value));
                }
            },
            1 => try testing.expectEqual(model.fetchRemove(k), removed(&table, k)),
            else => try testing.expectEqual(model.get(k), table.get(k)),
        }
        try testing.expectEqual(model.count(), table.count);
    }
    var it = model.iterator();
    while (it.next()) |entry| {
        try testing.expectEqual(@as(?u64, entry.value_ptr.*), table.get(entry.key_ptr.*));
    }
}

/// Shapes `Table.remove` like `HashMap.fetchRemove` so the model test can compare directly.
fn removed(table: *Table, k: u64) ?std.AutoHashMap(u64, u64).KV {
    const value = table.remove(k) orelse return null;
    return .{ .key = k, .value = value };
}

test "key: distinct per interest, never the empty marker" {
    try testing.expect(key(5, .read) != key(5, .write));
    try testing.expectEqual(@as(u64, 10), key(5, .read));
    try testing.expectEqual(@as(u64, 11), key(5, .write));
    try testing.expect(key(0, .read) != Table.key_empty);
}
