//! Coverage table for the 109 `std.Io.VTable` slots (PRD §8, plan 002 item 3).
//!
//! Every slot name appears in exactly one of three lists: `native` (sirocco's own implementation,
//! with a parity test), `delegated` (forwarded to `Io.Threaded`; trivially passes today, so the
//! test that catches the regression already exists the day the slot turns native), or `divergent`
//! (a native slot whose observable behaviour may differ from `Io.Threaded`, each entry citing the
//! std doc comment that permits it). A slot in none of them, in two of them, or a name that is
//! not a slot at all is a `@compileError`, so a std bump or a half-finished migration fails the
//! build instead of the review.
//!
//! Each later plan-002 item moves names from `delegated` to `native`; `audit` is pure so its
//! negative cases run as ordinary tests. Allocation: none (comptime only).

const std = @import("std");
const Io = std.Io;
const Runtime = @import("sirocco").Runtime;
const fixtures = @import("fixtures.zig");

const assert = std.debug.assert;

/// A slot allowed to behave differently from `Io.Threaded`.
pub const Divergence = struct {
    name: []const u8,
    /// The std doc comment or error-set declaration that permits the difference. Never empty.
    contract: []const u8,
};

/// Slots implemented on sirocco's own fibers (where `Runtime.fibers_supported`; elsewhere they
/// are forwarded, and `tests/parity/concurrency.zig` checks that too). Parity tests:
/// `tests/parity/concurrency.zig`.
pub const native: []const []const u8 = &.{ "async", "await", "cancel" };

/// Slots still forwarded to the embedded `Io.Threaded`.
pub const delegated: []const []const u8 = &.{
    "crashHandler",
    "groupAsync",
    "groupConcurrent",
    "groupAwait",
    "groupCancel",
    "recancel",
    "swapCancelProtection",
    "checkCancel",
    "futexWait",
    "futexWaitUncancelable",
    "futexWake",
    "operate",
    "batchAwaitAsync",
    "batchAwaitConcurrent",
    "batchCancel",
    "dirCreateDir",
    "dirCreateDirPath",
    "dirCreateDirPathOpen",
    "dirOpenDir",
    "dirStat",
    "dirStatFile",
    "dirAccess",
    "dirCreateFile",
    "dirCreateFileAtomic",
    "dirOpenFile",
    "dirClose",
    "dirRead",
    "dirRealPath",
    "dirRealPathFile",
    "dirDeleteFile",
    "dirDeleteDir",
    "dirRename",
    "dirRenamePreserve",
    "dirSymLink",
    "dirReadLink",
    "dirSetOwner",
    "dirSetFileOwner",
    "dirSetPermissions",
    "dirSetFilePermissions",
    "dirSetTimestamps",
    "dirHardLink",
    "fileStat",
    "fileLength",
    "fileClose",
    "fileWritePositional",
    "fileWriteFileStreaming",
    "fileWriteFilePositional",
    "fileReadPositional",
    "fileSeekBy",
    "fileSeekTo",
    "fileSync",
    "fileIsTty",
    "fileEnableAnsiEscapeCodes",
    "fileSupportsAnsiEscapeCodes",
    "fileSetLength",
    "fileSetOwner",
    "fileSetPermissions",
    "fileSetTimestamps",
    "fileLock",
    "fileTryLock",
    "fileUnlock",
    "fileDowngradeLock",
    "fileRealPath",
    "fileHardLink",
    "fileMemoryMapCreate",
    "fileMemoryMapDestroy",
    "fileMemoryMapSetLength",
    "fileMemoryMapRead",
    "fileMemoryMapWrite",
    "processExecutableOpen",
    "processExecutablePath",
    "lockStderr",
    "tryLockStderr",
    "unlockStderr",
    "processCurrentPath",
    "processSetCurrentDir",
    "processSetCurrentPath",
    "processReplace",
    "processReplacePath",
    "processSpawn",
    "processSpawnPath",
    "childWait",
    "childKill",
    "progressParentFile",
    "now",
    "clockResolution",
    "sleep",
    "random",
    "randomSecure",
    "netListenIp",
    "netAccept",
    "netBindIp",
    "netConnectIp",
    "netListenUnix",
    "netConnectUnix",
    "netSocketCreatePair",
    "netSend",
    "netRead",
    "netWrite",
    "netWriteFile",
    "netClose",
    "netShutdown",
    "netInterfaceNameResolve",
    "netInterfaceName",
    "netLookup",
};

/// Native slots that may legitimately differ from `Io.Threaded`; each cites the std text that
/// permits the difference.
pub const divergent: []const Divergence = &.{
    .{
        .name = "concurrent",
        .contract = "Io.ConcurrentError.ConcurrencyUnavailable doc comment: \"May occur due " ++
            "to a temporary condition such as resource exhaustion, or to the Io implementation " ++
            "not supporting concurrency.\" sirocco is single-carrier until plan 003, so it " ++
            "always returns it where Io.Threaded succeeds.",
    },
};

comptime {
    if (audit(native, delegated, divergent)) |problem| @compileError(problem);
}

/// Checks that every `Io.VTable` slot is listed exactly once. Returns a diagnostic naming the first
/// offender, or null when the table is complete. Comptime-only so the same code powers the build
/// guard and the negative tests.
pub fn audit(
    comptime native_names: []const []const u8,
    comptime delegated_names: []const []const u8,
    comptime divergent_entries: []const Divergence,
) ?[]const u8 {
    @setEvalBranchQuota(1_000_000);
    const fields = @typeInfo(Io.VTable).@"struct".fields;
    comptime assert(fields.len == 109);
    inline for (fields) |field| {
        const listed = occurrences(field.name, native_names, delegated_names, divergent_entries);
        if (listed == 0) return "slot `" ++ field.name ++ "` is in no list";
        if (listed > 1) return "slot `" ++ field.name ++ "` is listed more than once";
    }
    for (native_names) |name| {
        if (!@hasField(Io.VTable, name)) return "native list names a non-slot: " ++ name;
    }
    for (delegated_names) |name| {
        if (!@hasField(Io.VTable, name)) return "delegated list names a non-slot: " ++ name;
    }
    for (divergent_entries) |entry| {
        if (!@hasField(Io.VTable, entry.name)) {
            return "divergent list names a non-slot: " ++ entry.name;
        }
        if (entry.contract.len == 0) {
            return "divergent slot `" ++ entry.name ++ "` cites no contract";
        }
    }
    return null;
}

fn occurrences(
    comptime name: []const u8,
    comptime native_names: []const []const u8,
    comptime delegated_names: []const []const u8,
    comptime divergent_entries: []const Divergence,
) u32 {
    var count: u32 = 0;
    for (native_names) |listed| {
        if (std.mem.eql(u8, name, listed)) count += 1;
    }
    for (delegated_names) |listed| {
        if (std.mem.eql(u8, name, listed)) count += 1;
    }
    for (divergent_entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) count += 1;
    }
    return count;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.find(u8, haystack, needle) != null;
}

test "the shipped table accounts for all 109 slots" {
    comptime assert(audit(native, delegated, divergent) == null);
    try std.testing.expectEqual(@as(usize, 109), native.len + delegated.len + divergent.len);
}

test "removing a name from the table is reported" {
    const problem = comptime audit(native, delegated[1..], divergent) orelse "";
    try std.testing.expect(contains(problem, "crashHandler"));
    try std.testing.expect(contains(problem, "no list"));
}

test "an empty table is reported" {
    const problem = comptime audit(&.{}, &.{}, &.{}) orelse "";
    try std.testing.expect(contains(problem, "no list"));
}

test "a name in two lists is reported" {
    const problem = comptime audit(&.{"crashHandler"}, delegated, divergent) orelse "";
    try std.testing.expect(contains(problem, "`crashHandler`"));
    try std.testing.expect(contains(problem, "more than once"));
}

test "a name repeated inside one list is reported" {
    const problem = comptime audit(native, delegated ++ &[_][]const u8{"crashHandler"}, divergent);
    try std.testing.expect(contains(problem orelse "", "`crashHandler`"));
}

test "delegated slots are the baseline's own function, native ones are not" {
    var rt = try fixtures.init_runtime(.forward);
    defer rt.deinit();

    const vtable = rt.io().vtable;
    const baseline = rt.baselineIo().vtable;
    inline for (delegated) |name| {
        try std.testing.expect(@field(vtable, name) == @field(baseline, name));
    }
    // Native slots exist only where the fiber switch does; elsewhere they stay forwarded.
    const expect_native = Runtime.fibers_supported;
    inline for (native) |name| {
        try std.testing.expectEqual(expect_native, @field(vtable, name) != @field(baseline, name));
    }
    inline for (divergent) |entry| {
        const differs = @field(vtable, entry.name) != @field(baseline, entry.name);
        try std.testing.expectEqual(expect_native, differs);
    }
}

test "a non-slot name is reported in each list" {
    const native_nope = native ++ &[_][]const u8{"nope"};
    const native_problem = comptime audit(native_nope, delegated, divergent) orelse "";
    try std.testing.expect(contains(native_problem, "native list names a non-slot: nope"));
    const delegated_problem = comptime audit(native, delegated ++ .{"nope"}, divergent) orelse "";
    try std.testing.expect(contains(delegated_problem, "delegated list names a non-slot: nope"));
    const divergent_problem = comptime audit(
        native,
        delegated,
        divergent ++ &[_]Divergence{.{ .name = "nope", .contract = "x" }},
    ) orelse "";
    try std.testing.expect(contains(divergent_problem, "divergent list names a non-slot: nope"));
}

test "a divergence must cite its contract, and a cited one moves the slot out of delegated" {
    const uncited = comptime audit(
        native,
        delegated[1..],
        divergent ++ &[_]Divergence{.{ .name = "crashHandler", .contract = "" }},
    ) orelse "";
    try std.testing.expect(contains(uncited, "cites no contract"));

    const cited = comptime audit(
        native,
        delegated[1..],
        divergent ++ &[_]Divergence{
            .{ .name = "crashHandler", .contract = "Io.VTable.crashHandler doc comment" },
        },
    );
    try std.testing.expect(cited == null);
}
