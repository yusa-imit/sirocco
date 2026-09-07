//! tools/tidy.zig — Tiger Style mechanical checks over source text.
//!
//! Pure, allocator-explicit checks over in-memory source text: `checkSource` never touches the
//! filesystem itself, so callers (a future `zig build tidy` step, or a test) read a file and
//! pass the bytes in. This keeps the checker unit-testable without on-disk fixtures.
//!
//! Ownership contract: `checkSource` returns a `gpa`-allocated `[]Violation`; the caller frees
//! it with `gpa.free(violations)`. Each `Violation.detail` is a *borrowed* static string
//! associated with its `Rule` (never allocated per violation, never freed independently of the
//! returned slice) — this keeps the no-allocation-after-return-value contract simple to test
//! under `std.testing.allocator` without a per-field free loop.
//!
//! See `citadel/core/rules/tiger-style.md` §5 "Mechanical checks" for the rule table this file
//! implements, and `docs/plans/001-zig-0.16-and-tiger-baseline.md` item 2 for the acceptance
//! criteria. Status: red phase — type declarations only, `checkSource` is not implemented.

const std = @import("std");

/// One mechanical rule this checker enforces. See tiger-style.md §5 for the rationale behind
/// each.
pub const Rule = enum {
    line_length,
    function_length,
    catch_unreachable,
    debug_print,
    time_use,
    usize_in_format,
    missing_header,
};

/// A single finding. `line` is 1-indexed; `missing_header` always reports line 1 (the
/// convention this checker uses for a file-level finding with no specific offending line).
pub const Violation = struct {
    line: u32,
    rule: Rule,
    detail: []const u8,
};

/// One entry of the checked-in `tidy_baseline.txt` (tiger-style.md §5.1): a function already
/// over `CheckOptions.function_len_max` on the day `tidy` shipped, recorded so it does not fail
/// the build, but capped so it can never grow past `CheckOptions.function_len_redzone_max`.
pub const BaselineEntry = struct {
    path: []const u8,
    function: []const u8,
    lines_max: u32,
};

/// Options for one `checkSource` call. Every field is spelled out at the call site (Tiger
/// Style §3.15) except the three numeric limits, which default to the kingdom-wide values and
/// exist as fields only so a test can probe the boundary directly.
pub const CheckOptions = struct {
    line_len_max: u32 = 100,
    function_len_max: u32 = 70,
    function_len_redzone_max: u32 = 72,
    enforce_lib_bans: bool,
    is_format_file: bool,
    baseline: []const BaselineEntry,
    path: []const u8,
};

/// Runs every mechanical check in this file over `source` and returns every violation found, in
/// the order encountered, allocated with `gpa`. The caller owns the returned slice and frees it
/// with `gpa.free(violations)` — see the module header for the `.detail` ownership contract.
///
/// Preconditions: `options.function_len_max <= options.function_len_redzone_max`; every
/// `options.baseline` entry's `.path` refers to the same file as `options.path` or is ignored.
pub fn checkSource(
    gpa: std.mem.Allocator,
    source: []const u8,
    options: CheckOptions,
) error{OutOfMemory}![]Violation {
    assert(options.function_len_max <= options.function_len_redzone_max);
    assert(options.path.len > 0);

    var violations: std.ArrayList(Violation) = .empty;
    errdefer violations.deinit(gpa);

    try checkMissingHeader(gpa, &violations, source);

    var scanner = FunctionScanner{};
    var prev_line: []const u8 = "";
    var line_no: u32 = 0;

    // Every source file has at most `source.len + 1` lines (one per byte, plus one for a
    // source with no trailing newline); this bounds the scan without trusting the iterator.
    const lines_max: usize = source.len + 1;
    var iterations: usize = 0;
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iterations < lines_max) : (iterations += 1) {
        const line = iter.next() orelse break;
        line_no += 1;

        try checkLineLength(gpa, &violations, line, line_no, options);
        try checkCatchUnreachable(gpa, &violations, line, prev_line, line_no);
        try checkDebugPrint(gpa, &violations, line, line_no, options);
        try checkTimeUse(gpa, &violations, line, line_no, options);
        try checkUsizeInFormat(gpa, &violations, line, line_no, options);
        try scanner.processLine(gpa, &violations, line, line_no, options);

        prev_line = line;
    }
    assert(iterations <= lines_max);
    // Not asserted: `!scanner.in_function`. This is a text scanner, not a lexer — a string
    // literal containing an escaped brace (`"{{"`) can desync the per-line `{`/`}` count from
    // real scope depth. That is malformed *input* to this naive method, not a caller contract
    // violation, so a dangling open function at EOF is silently unmeasured rather than a crash.

    return violations.toOwnedSlice(gpa);
}

/// Tracks brace-depth to find top-level `fn`/`pub fn` declarations and measure their inclusive
/// line count (declaration line through matching closing brace, both counted).
const FunctionScanner = struct {
    depth: i64 = 0,
    in_function: bool = false,
    start_line: u32 = 0,
    name: []const u8 = "",

    fn processLine(
        self: *FunctionScanner,
        gpa: std.mem.Allocator,
        violations: *std.ArrayList(Violation),
        line: []const u8,
        line_no: u32,
        options: CheckOptions,
    ) error{OutOfMemory}!void {
        assert(line_no > 0);
        assert(options.function_len_max <= options.function_len_redzone_max);

        if (!self.in_function and self.depth == 0) {
            if (functionNameAt(line)) |name| {
                self.in_function = true;
                self.start_line = line_no;
                self.name = name;
            }
        }

        var opens: i64 = 0;
        var closes: i64 = 0;
        for (line) |c| {
            if (c == '{') opens += 1;
            if (c == '}') closes += 1;
        }
        self.depth += opens - closes;

        if (self.in_function and self.depth == 0) {
            const total_lines = line_no - self.start_line + 1;
            const effective_max = effectiveFunctionMax(options, self.name);
            if (total_lines > effective_max) {
                try violations.append(gpa, .{
                    .line = self.start_line,
                    .rule = .function_length,
                    .detail = "function exceeds the line-count limit",
                });
            }
            self.in_function = false;
        }
    }
};

/// Returns the effective line-count ceiling for `name` in the current file: a baseline entry
/// matching both `options.path` and `name` unlocks up to `function_len_redzone_max` (never
/// beyond it, regardless of the recorded `lines_max`); absent a match, `function_len_max`.
fn effectiveFunctionMax(options: CheckOptions, name: []const u8) u32 {
    assert(options.function_len_max <= options.function_len_redzone_max);
    assert(name.len > 0);
    for (options.baseline) |entry| {
        if (std.mem.eql(u8, entry.path, options.path) and std.mem.eql(u8, entry.function, name)) {
            return @min(entry.lines_max, options.function_len_redzone_max);
        }
    }
    return options.function_len_max;
}

/// Returns the declared function name if `line`, once left-trimmed, starts a top-level `fn` or
/// `pub fn` declaration; null otherwise (nested declarations are excluded by the caller checking
/// `depth == 0` before calling this).
fn functionNameAt(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const rest = if (std.mem.startsWith(u8, trimmed, "pub fn "))
        trimmed["pub fn ".len..]
    else if (std.mem.startsWith(u8, trimmed, "fn "))
        trimmed["fn ".len..]
    else
        return null;
    const paren = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    return std.mem.trim(u8, rest[0..paren], " \t");
}

/// Flags `line` if its length exceeds `options.line_len_max` columns. Columns are counted as
/// Unicode codepoints, not bytes, so a multi-byte character (e.g. an em dash) counts once, not
/// three times — falls back to byte length on invalid UTF-8 (never occurs in a `.zig` source
/// file the compiler already accepted, but keeps this a total function regardless).
fn checkLineLength(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    line: []const u8,
    line_no: u32,
    options: CheckOptions,
) error{OutOfMemory}!void {
    assert(line_no > 0);
    assert(options.line_len_max > 0);
    const col_count = std.unicode.utf8CountCodepoints(line) catch line.len;
    if (col_count > options.line_len_max) {
        try violations.append(gpa, .{
            .line = line_no,
            .rule = .line_length,
            .detail = "line exceeds the column limit",
        });
    }
}

/// Flags an unproven `catch unreachable` unless a `proof` comment appears on the same line or
/// the immediately preceding line.
fn checkCatchUnreachable(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    line: []const u8,
    prev_line: []const u8,
    line_no: u32,
) error{OutOfMemory}!void {
    assert(line_no > 0);
    const len_before = violations.items.len;

    const found = std.mem.indexOf(u8, line, "catch unreachable") != null;
    const proof_same_line = std.mem.indexOf(u8, line, "proof") != null;
    const proof_prev_line = std.mem.indexOf(u8, prev_line, "proof") != null;
    if (found and !proof_same_line and !proof_prev_line) {
        try violations.append(gpa, .{
            .line = line_no,
            .rule = .catch_unreachable,
            .detail = "catch unreachable without a proof comment",
        });
    }

    assert(violations.items.len == len_before or violations.items.len == len_before + 1);
}

/// Flags `std.debug.print` when `options.enforce_lib_bans` is set (banned in library code,
/// fine in `bench`/`tests`).
fn checkDebugPrint(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    line: []const u8,
    line_no: u32,
    options: CheckOptions,
) error{OutOfMemory}!void {
    assert(line_no > 0);
    const len_before = violations.items.len;

    if (options.enforce_lib_bans and std.mem.indexOf(u8, line, "std.debug.print") != null) {
        try violations.append(gpa, .{
            .line = line_no,
            .rule = .debug_print,
            .detail = "std.debug.print left in library code",
        });
    }

    assert(violations.items.len == len_before or violations.items.len == len_before + 1);
}

/// Flags `std.time.` when `options.enforce_lib_bans` is set (hidden non-determinism; libraries
/// take an injected clock instead). Does not false-positive on `Io.Timestamp` / `std.Io.Clock`.
fn checkTimeUse(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    line: []const u8,
    line_no: u32,
    options: CheckOptions,
) error{OutOfMemory}!void {
    assert(line_no > 0);
    const len_before = violations.items.len;

    if (options.enforce_lib_bans and std.mem.indexOf(u8, line, "std.time.") != null) {
        try violations.append(gpa, .{
            .line = line_no,
            .rule = .time_use,
            .detail = "std.time. used instead of an injected clock",
        });
    }

    assert(violations.items.len == len_before or violations.items.len == len_before + 1);
}

/// Flags `: usize` when `options.is_format_file` is set (width varies across targets in a
/// wire/on-disk format).
fn checkUsizeInFormat(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    line: []const u8,
    line_no: u32,
    options: CheckOptions,
) error{OutOfMemory}!void {
    assert(line_no > 0);
    const len_before = violations.items.len;

    if (options.is_format_file and std.mem.indexOf(u8, line, ": usize") != null) {
        try violations.append(gpa, .{
            .line = line_no,
            .rule = .usize_in_format,
            .detail = "usize in a wire/on-disk format",
        });
    }

    assert(violations.items.len == len_before or violations.items.len == len_before + 1);
}

/// Flags a source whose first line is not a `//!` module doc comment.
fn checkMissingHeader(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    source: []const u8,
) error{OutOfMemory}!void {
    const len_before = violations.items.len;
    const newline = std.mem.indexOfScalar(u8, source, '\n');
    const first_line = if (newline) |n| source[0..n] else source;
    assert(first_line.len <= source.len);

    if (!std.mem.startsWith(u8, first_line, "//!")) {
        try violations.append(gpa, .{
            .line = 1,
            .rule = .missing_header,
            .detail = "first line is not a //! module doc comment",
        });
    }

    assert(violations.items.len == len_before or violations.items.len == len_before + 1);
}

const assert = std.debug.assert;

test {
    _ = @import("tidy_test.zig");
}
