//! tools/tidy_test.zig — red-phase tests for `tools/tidy.zig`'s `checkSource`.
//!
//! `checkSource` does not exist yet (its body is `@compileError`), so every test below is
//! expected to fail the *build*, not just an assertion, until the zig-developer implements it.
//! That is the intended TDD red state for this cycle — do not weaken these tests to make them
//! pass; implement `checkSource` against them instead.
//!
//! Convention pinned here, since the design doc leaves it open: a function's line count is
//! measured *inclusively* from the line containing `fn <name>(` (or `pub fn <name>(`) through
//! the line holding its matching closing brace — both endpoints counted. `buildFunctionSource`
//! below constructs exactly that many lines so the boundary tests are exact, not approximate.
//!
//! No test asserts the exact text of `Violation.detail` — only `.rule` and `.line` — because a
//! detail string copied from the implementation is a forbidden test (testing.md) and tells the
//! reader nothing the rule name does not already say.

const std = @import("std");
const tidy = @import("tidy.zig");

/// Full explicit `CheckOptions` for a test that only cares about one rule; every field is set
/// so no test relies on a default it did not name (Tiger Style §3.15's fixture exemption still
/// spells everything out for clarity).
fn baseOptions(path: []const u8) tidy.CheckOptions {
    return .{
        .line_len_max = 100,
        .function_len_max = 70,
        .function_len_redzone_max = 72,
        .enforce_lib_bans = false,
        .is_format_file = false,
        .baseline = &.{},
        .path = path,
    };
}

fn hasRuleAt(violations: []const tidy.Violation, rule: tidy.Rule, line: u32) bool {
    for (violations) |v| {
        if (v.rule == rule and v.line == line) return true;
    }
    return false;
}

fn hasRule(violations: []const tidy.Violation, rule: tidy.Rule) bool {
    for (violations) |v| {
        if (v.rule == rule) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// line_length
// ---------------------------------------------------------------------------------------------

test "tidy: line_length flags a line over 100 columns" {
    const gpa = std.testing.allocator;
    const long_line = "a" ** 101;
    const source = try std.fmt.allocPrint(gpa, "//! header\n{s}\n", .{long_line});
    defer gpa.free(source);

    var options = baseOptions("src/example.zig");
    options.enforce_lib_bans = false;
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(hasRuleAt(violations, .line_length, 2));
}

test "tidy: line_length does not flag a line at exactly 100 columns (boundary)" {
    const gpa = std.testing.allocator;
    const max_line = "a" ** 100;
    const source = try std.fmt.allocPrint(gpa, "//! header\n{s}\n", .{max_line});
    defer gpa.free(source);

    const options = baseOptions("src/example.zig");
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(!hasRule(violations, .line_length));
}

// ---------------------------------------------------------------------------------------------
// function_length
// ---------------------------------------------------------------------------------------------

/// Builds a fixture module containing exactly one function, `total_lines` long by the
/// convention documented at the top of this file (fn line and closing brace both counted).
fn buildFunctionSource(gpa: std.mem.Allocator, name: []const u8, total_lines: u32) ![]u8 {
    std.debug.assert(total_lines >= 2);
    const body_lines = total_lines - 2;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "//! fixture module for tidy function_length tests.\n\n");

    const decl = try std.fmt.allocPrint(gpa, "fn {s}() void {{\n", .{name});
    defer gpa.free(decl);
    try out.appendSlice(gpa, decl);

    var i: u32 = 0;
    while (i < body_lines) : (i += 1) {
        try out.appendSlice(gpa, "    const filler = 0;\n");
    }
    try out.appendSlice(gpa, "}\n");

    return out.toOwnedSlice(gpa);
}

test "tidy: function_length passes a function at exactly 70 lines" {
    const gpa = std.testing.allocator;
    const source = try buildFunctionSource(gpa, "at_max", 70);
    defer gpa.free(source);

    const options = baseOptions("src/example.zig");
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(!hasRule(violations, .function_length));
}

test "tidy: function_length flags a 71-line non-baselined function" {
    const gpa = std.testing.allocator;
    const source = try buildFunctionSource(gpa, "over_max", 71);
    defer gpa.free(source);

    const options = baseOptions("src/example.zig");
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(hasRule(violations, .function_length));
}

test "tidy: function_length passes a 71-line function matching a baseline entry at lines_max 71" {
    const gpa = std.testing.allocator;
    const source = try buildFunctionSource(gpa, "baselined_fn", 71);
    defer gpa.free(source);

    var options = baseOptions("src/example.zig");
    const baseline = [_]tidy.BaselineEntry{
        .{ .path = "src/example.zig", .function = "baselined_fn", .lines_max = 71 },
    };
    options.baseline = &baseline;
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(!hasRule(violations, .function_length));
}

test "tidy: function_length flags a 73-line function even with a generous baseline (ratchet ceiling)" {
    const gpa = std.testing.allocator;
    const source = try buildFunctionSource(gpa, "grew_past_redzone", 73);
    defer gpa.free(source);

    var options = baseOptions("src/example.zig");
    const baseline = [_]tidy.BaselineEntry{
        .{ .path = "src/example.zig", .function = "grew_past_redzone", .lines_max = 80 },
    };
    options.baseline = &baseline;
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    // A baseline entry unlocks 71-72 only; 73 exceeds function_len_redzone_max regardless of
    // how generous the recorded lines_max is.
    try std.testing.expect(hasRule(violations, .function_length));
}

test "tidy: function_length passes a baselined function that shrank below its recorded lines_max" {
    const gpa = std.testing.allocator;
    // Recorded at 72 lines in the baseline; the function has since shrunk to 71.
    const source = try buildFunctionSource(gpa, "shrunk_fn", 71);
    defer gpa.free(source);

    var options = baseOptions("src/example.zig");
    const baseline = [_]tidy.BaselineEntry{
        .{ .path = "src/example.zig", .function = "shrunk_fn", .lines_max = 72 },
    };
    options.baseline = &baseline;
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    // Shrinking below the recorded ceiling is never itself a violation.
    try std.testing.expect(!hasRule(violations, .function_length));
}

// ---------------------------------------------------------------------------------------------
// catch_unreachable
// ---------------------------------------------------------------------------------------------

test "tidy: catch_unreachable flags an unproven catch unreachable" {
    const gpa = std.testing.allocator;
    const source =
        \\//! header
        \\const b = x catch unreachable;
        \\
    ;
    const options = baseOptions("src/example.zig");
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(hasRuleAt(violations, .catch_unreachable, 2));
}

test "tidy: catch_unreachable passes when the proof comment is on the same line" {
    const gpa = std.testing.allocator;
    const source =
        \\//! header
        \\const b = x catch unreachable; // proof: bar cannot fail because baz holds an invariant
        \\
    ;
    const options = baseOptions("src/example.zig");
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(!hasRule(violations, .catch_unreachable));
}

test "tidy: catch_unreachable passes when the proof comment is on the immediately preceding line" {
    const gpa = std.testing.allocator;
    const source =
        \\//! header
        \\// proof: bar cannot fail because baz holds an invariant
        \\const b = x catch unreachable;
        \\
    ;
    const options = baseOptions("src/example.zig");
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(!hasRule(violations, .catch_unreachable));
}

test "tidy: catch_unreachable still flags when the proof comment is two lines above" {
    const gpa = std.testing.allocator;
    const source =
        \\//! header
        \\// proof: bar cannot fail because baz holds an invariant
        \\const unrelated = 1;
        \\const b = x catch unreachable;
        \\
    ;
    const options = baseOptions("src/example.zig");
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(hasRuleAt(violations, .catch_unreachable, 4));
}

// ---------------------------------------------------------------------------------------------
// debug_print
// ---------------------------------------------------------------------------------------------

test "tidy: debug_print flags std.debug.print when lib bans are enforced" {
    const gpa = std.testing.allocator;
    const source =
        \\//! header
        \\std.debug.print("oops\n", .{});
        \\
    ;
    var options = baseOptions("src/example.zig");
    options.enforce_lib_bans = true;
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(hasRuleAt(violations, .debug_print, 2));
}

test "tidy: debug_print passes std.debug.print when lib bans are not enforced" {
    const gpa = std.testing.allocator;
    const source =
        \\//! header
        \\std.debug.print("fine in bench/tests\n", .{});
        \\
    ;
    var options = baseOptions("bench/example.zig");
    options.enforce_lib_bans = false;
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(!hasRule(violations, .debug_print));
}

// ---------------------------------------------------------------------------------------------
// time_use
// ---------------------------------------------------------------------------------------------

test "tidy: time_use flags std.time. when lib bans are enforced" {
    const gpa = std.testing.allocator;
    const source =
        \\//! header
        \\const now = std.time.milliTimestamp();
        \\
    ;
    var options = baseOptions("src/example.zig");
    options.enforce_lib_bans = true;
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(hasRuleAt(violations, .time_use, 2));
}

test "tidy: time_use passes std.time. when lib bans are not enforced" {
    const gpa = std.testing.allocator;
    const source =
        \\//! header
        \\const now = std.time.milliTimestamp();
        \\
    ;
    var options = baseOptions("bench/example.zig");
    options.enforce_lib_bans = false;
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(!hasRule(violations, .time_use));
}

test "tidy: time_use does not false-positive on std.Io.Clock or Io.Timestamp under lib bans" {
    const gpa = std.testing.allocator;
    const source =
        \\//! header
        \\const now: Io.Timestamp = clock.now();
        \\const c: std.Io.Clock = clock;
        \\
    ;
    var options = baseOptions("src/example.zig");
    options.enforce_lib_bans = true;
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(!hasRule(violations, .time_use));
}

// ---------------------------------------------------------------------------------------------
// usize_in_format
// ---------------------------------------------------------------------------------------------

test "tidy: usize_in_format flags `: usize` in a declared wire/on-disk format file" {
    const gpa = std.testing.allocator;
    const source =
        \\//! header — on-disk format.
        \\pub const Header = struct {
        \\    count: usize,
        \\};
        \\
    ;
    var options = baseOptions("src/format.zig");
    options.is_format_file = true;
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(hasRuleAt(violations, .usize_in_format, 3));
}

test "tidy: usize_in_format passes `: usize` outside a declared format file" {
    const gpa = std.testing.allocator;
    const source =
        \\//! header — not a wire format.
        \\pub const Header = struct {
        \\    count: usize,
        \\};
        \\
    ;
    var options = baseOptions("src/plain.zig");
    options.is_format_file = false;
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(!hasRule(violations, .usize_in_format));
}

// ---------------------------------------------------------------------------------------------
// missing_header
// ---------------------------------------------------------------------------------------------

test "tidy: missing_header passes a source whose first line is a //! doc comment" {
    const gpa = std.testing.allocator;
    const source = "//! this module states its contract.\nconst x = 1;\n";
    const options = baseOptions("src/example.zig");
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(!hasRule(violations, .missing_header));
}

test "tidy: missing_header flags a source whose first line is a plain comment" {
    const gpa = std.testing.allocator;
    const source = "// not a module doc comment\nconst x = 1;\n";
    const options = baseOptions("src/example.zig");
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(hasRuleAt(violations, .missing_header, 1));
}

test "tidy: missing_header flags a source whose first line is code" {
    const gpa = std.testing.allocator;
    const source = "const std = @import(\"std\");\n";
    const options = baseOptions("src/example.zig");
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    try std.testing.expect(hasRuleAt(violations, .missing_header, 1));
}

// ---------------------------------------------------------------------------------------------
// Integration: the real repo, today, under enforce_lib_bans
// ---------------------------------------------------------------------------------------------

// Read at test time via `std.fs`, rather than `@embedFile`, deliberately: `@embedFile("../..")`
// escapes the package path of a bare `zig test tools/tidy.zig` invocation (there is no
// build.zig-declared module root to widen the boundary), and reading live also means this test
// checks today's actual file contents rather than a frozen copy. `zig build test` and
// `zig test tools/tidy.zig` are both documented (REALM.md) to run from the repo root, so these
// relative paths resolve the same way either invocation is used.
const real_paths = [_][]const u8{
    "src/root.zig",
    "src/main.zig",
    "src/io.zig",
    "src/net.zig",
    "src/tls.zig",
    "src/http.zig",
    "src/ws.zig",
    "src/task.zig",
};

test "tidy: every real src/ file today produces zero violations under lib bans" {
    const gpa = std.testing.allocator;
    const source_bytes_max = 64 * 1024;

    for (real_paths) |path| {
        const source = try std.fs.cwd().readFileAlloc(gpa, path, source_bytes_max);
        defer gpa.free(source);

        var options = baseOptions(path);
        options.enforce_lib_bans = true;
        options.is_format_file = false;
        const violations = try tidy.checkSource(gpa, source, options);
        defer gpa.free(violations);

        for (violations) |v| {
            std.debug.print(
                "tidy violation left in {s}: rule={s} line={d}\n",
                .{ path, @tagName(v.rule), v.line },
            );
        }
        try std.testing.expectEqual(@as(usize, 0), violations.len);
    }
}
