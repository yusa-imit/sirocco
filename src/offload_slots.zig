//! sirocco's offloaded slots (plan 003 item 8, ADR 0002): the forwarded blocking `dir*`, `file*`
//! and `net*` slots plus `operate` and `childWait`, each replaced by a thunk that runs the
//! baseline `Io.Threaded` function on the offload pool while the calling fiber parks.
//!
//! `operate` is the fallback of `src/submit.zig`: its thunk serves blocking files,
//! `device_io_control` and handles the registry does not know; `submit` serves `net_receive` on
//! a registered socket and non-blocking file streams natively over it.
//!
//! Purpose: a forwarded call blocks its thread in the kernel, and the one carrier runs every
//! fiber, so one call freezes them all. The thunk submits the call to `Offload` and parks; the
//! carrier runs other fibers until the worker finishes.
//!
//! Invariants: this file is the only place that builds thunks, and each is built from the type of
//! its `Io.VTable` field, so a std change to a signature breaks the build, not a caller. A thunk
//! offloads only when called from a fiber of a ready scheduler; off a fiber (or when the
//! scheduler is `.unavailable`) there is no carrier to protect and it calls the baseline slot
//! directly. A pending cancel is delivered before submit when the error set has `Canceled`;
//! once submitted the call completes (ADR 0001), and its cancelation point is the next slot.
//! Slots outside the set (`batch*`, which `src/batch.zig` serves or forwards whole; the stderr
//! lock, `process*`, `child*` but `childWait`, `netLookup`, `now`, `random*`, and the cheap or
//! unblocking calls in `kept_on_carrier`) are in the ADR with their reasons; `netLookup` also
//! fills a queue through the baseline's futexes, which sirocco's native futex table never sees.
//!
//! A started call cannot be interrupted: a `netAccept` or read that never completes holds its
//! worker, and a `cancel` or `Group.cancel` of its task waits for it. The cancel is not lost, it
//! is delivered at the task's next cancelation point. Close or shut down the socket from another
//! fiber to end such a call (those slots stay on the carrier for that reason). A worker re-enters
//! a vtable slot only through a caller's `File.Reader`; that is safe because `carrier_active` is
//! thread-local, so such a thunk sees no fiber and calls the baseline directly.
//!
//! Allocation: none. The request record and the call's arguments live on the parked fiber's
//! stack, so the cost per call is `sizeof(arguments) + sizeof(result)` of stack.

const std = @import("std");
const stdx = @import("stdx.zig");
const Runtime = @import("runtime.zig");
const concurrency = @import("concurrency.zig");
const Sched = @import("sched.zig");

const Io = std.Io;
const assert = stdx.assert;
const assert_always = stdx.assert_always;

// Matched by the prefix rule below but kept on the carrier: none of them blocks for long, two
// hand-offs cost far more than they do, and the ones that wake or release others (`netShutdown`,
// the closes, `fileUnlock`) must never queue behind workers parked in a read or an accept. The
// memory-map create/resize/destroy calls allocate from the runtime's `gpa`, which the carrier
// uses too, and `netWriteFile` is a TODO panic in std.
const kept_on_carrier = [_][]const u8{
    "netLookup",
    "netWriteFile",
    "netShutdown",
    "netClose",
    "netInterfaceNameResolve",
    "netInterfaceName",
    "dirClose",
    "fileClose",
    "fileUnlock",
    "fileSeekBy",
    "fileSeekTo",
    "fileIsTty",
    "fileEnableAnsiEscapeCodes",
    "fileSupportsAnsiEscapeCodes",
    "fileMemoryMapCreate",
    "fileMemoryMapSetLength",
    "fileMemoryMapDestroy",
};

/// True when the slot called `name` runs on the offload pool.
pub fn is_offloaded(comptime name: []const u8) bool {
    inline for (kept_on_carrier) |kept| {
        if (comptime std.mem.eql(u8, name, kept)) return false;
    }
    if (std.mem.eql(u8, name, "operate")) return true;
    if (std.mem.eql(u8, name, "childWait")) return true;
    return std.mem.startsWith(u8, name, "dir") or
        std.mem.startsWith(u8, name, "file") or
        std.mem.startsWith(u8, name, "net");
}

/// Overwrites every offloaded slot of `vtable` with its thunk. Precondition: `Sched.supported`,
/// and `vtable` holds the baseline's functions (the thunks call the baseline directly, so under
/// `.fail` the caller must not install them).
pub fn install(vtable: *Io.VTable) void {
    @setEvalBranchQuota(100_000);
    assert(Sched.supported);
    var installed_count: u32 = 0;
    inline for (@typeInfo(Io.VTable).@"struct".fields) |field| {
        if (comptime is_offloaded(field.name)) {
            @field(vtable, field.name) = Thunk(field.name).call;
            installed_count += 1;
        }
    }
    assert(installed_count > 0);
    assert(installed_count < @typeInfo(Io.VTable).@"struct".fields.len);
}

fn SlotFn(comptime name: []const u8) type {
    return @typeInfo(@FieldType(Io.VTable, name)).pointer.child;
}

pub fn ReturnOf(comptime name: []const u8) type {
    return @typeInfo(SlotFn(name)).@"fn".return_type.?;
}

fn ParamOf(comptime name: []const u8, comptime index: usize) type {
    return @typeInfo(SlotFn(name)).@"fn".params[index].type.?;
}

fn has_canceled(comptime Return: type) bool {
    const set = switch (@typeInfo(Return)) {
        .error_union => |union_info| union_info.error_set,
        else => return false,
    };
    const errors = @typeInfo(set).error_set orelse return false;
    for (errors) |err| {
        if (std.mem.eql(u8, err.name, "Canceled")) return true;
    }
    return false;
}

/// The function installed in the `name` slot; `call` has exactly the slot's type. One arity per
/// case because Zig cannot declare a function body over a computed parameter list.
pub fn Thunk(comptime name: []const u8) type {
    const arity = @typeInfo(SlotFn(name)).@"fn".params.len;
    const Return = ReturnOf(name);
    return switch (arity) {
        2 => struct {
            pub fn call(u: ?*anyopaque, a: ParamOf(name, 1)) Return {
                return run(name, u, .{a});
            }
        },
        3 => struct {
            pub fn call(u: ?*anyopaque, a: ParamOf(name, 1), b: ParamOf(name, 2)) Return {
                return run(name, u, .{ a, b });
            }
        },
        4 => struct {
            pub fn call(
                u: ?*anyopaque,
                a: ParamOf(name, 1),
                b: ParamOf(name, 2),
                c: ParamOf(name, 3),
            ) Return {
                return run(name, u, .{ a, b, c });
            }
        },
        5 => struct {
            pub fn call(
                u: ?*anyopaque,
                a: ParamOf(name, 1),
                b: ParamOf(name, 2),
                c: ParamOf(name, 3),
                d: ParamOf(name, 4),
            ) Return {
                return run(name, u, .{ a, b, c, d });
            }
        },
        6 => struct {
            pub fn call(
                u: ?*anyopaque,
                a: ParamOf(name, 1),
                b: ParamOf(name, 2),
                c: ParamOf(name, 3),
                d: ParamOf(name, 4),
                e: ParamOf(name, 5),
            ) Return {
                return run(name, u, .{ a, b, c, d, e });
            }
        },
        else => @compileError("offloaded slot `" ++ name ++ "` has an unsupported arity"),
    };
}

/// One call in flight; lives on the stack of the parked fiber, the worker fills `result`.
fn CallType(comptime name: []const u8, comptime Args: type) type {
    return struct {
        userdata: ?*anyopaque,
        args: Args,
        target: *const SlotFn(name),
        result: ?ReturnOf(name),

        fn job(context: ?*anyopaque) void {
            const call: *@This() = @ptrCast(@alignCast(context.?));
            assert(call.result == null);
            call.result = @call(.auto, call.target, .{call.userdata} ++ call.args);
        }
    };
}

fn run(comptime name: []const u8, userdata: ?*anyopaque, args: anytype) ReturnOf(name) {
    const rt = concurrency.runtime_of(userdata);
    const target = @field(rt.baselineIo().vtable.*, name);
    const task = concurrency.current_task(rt) orelse {
        return @call(.auto, target, .{userdata} ++ args);
    };
    assert(rt.sched_state == .ready);
    if (comptime has_canceled(ReturnOf(name))) {
        if (concurrency.task_acknowledge_cancel(task)) return error.Canceled;
    }
    const Call = CallType(name, @TypeOf(args));
    var call: Call = .{ .userdata = userdata, .args = args, .target = target, .result = null };
    rt.offload.call(Call.job, &call);
    assert_always(call.result != null); // The fiber woke without the worker's result.
    return call.result.?;
}

test "every offloaded slot's thunk has exactly the slot's type" {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(Io.VTable).@"struct".fields) |field| {
        if (comptime is_offloaded(field.name)) {
            try std.testing.expect(@TypeOf(&Thunk(field.name).call) == field.type);
        }
    }
}

test "the offloaded set is the blocking set and nothing else" {
    const offloaded = [_][]const u8{
        "operate",
        "childWait",
        "dirOpenFile",
        "dirRead",
        "fileReadPositional",
        "fileWriteFilePositional",
        "netAccept",
        "netConnectIp",
        "netRead",
        "netWrite",
        "netSend",
    };
    inline for (offloaded) |name| try std.testing.expect(is_offloaded(name));

    const kept = [_][]const u8{
        "netLookup",
        "netWriteFile",
        "netShutdown",
        "netClose",
        "dirClose",
        "fileClose",
        "fileSeekBy",
        "fileMemoryMapCreate",
        "batchAwaitAsync",
        "batchAwaitConcurrent",
        "batchCancel",
        "lockStderr",
        "tryLockStderr",
        "unlockStderr",
        "processSpawn",
        "childKill",
        "now",
        "clockResolution",
        "random",
        "randomSecure",
        "sleep",
        "async",
        "futexWait",
        "progressParentFile",
        "processCurrentPath",
    };
    inline for (kept) |name| try std.testing.expect(!is_offloaded(name));
}

test "only error sets that carry Canceled get a pre-submit cancel check" {
    try std.testing.expect(has_canceled(ReturnOf("dirAccess")));
    try std.testing.expect(has_canceled(ReturnOf("operate")));
    try std.testing.expect(has_canceled(ReturnOf("netAccept")));
    try std.testing.expect(!has_canceled(ReturnOf("dirClose")));
    // `netSend` returns `struct { ?SendError, usize }`, not an error union, and `SendError` has
    // no `Canceled`: there is nothing to deliver before submit.
    try std.testing.expect(!has_canceled(ReturnOf("netSend")));
}
