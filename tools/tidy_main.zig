//! tools/tidy_main.zig — CLI entry point wired to `zig build tidy`.
//!
//! Walks each directory given on the command line (default `src`, `bench`, `tests`) for `.zig`
//! files, runs `tidy.checkSource` over each, prints every violation to stderr as
//! `path:line: rule — detail`, and exits non-zero if any file had a violation. Loads
//! `tidy_baseline.txt` from the current working directory if present — both `zig build tidy`
//! and a bare `zig test tools/tidy.zig` are documented (REALM.md) to run from the repo root, so
//! this relative path resolves the same way either invocation is used.
//!
//! Allocation contract: this binary allocates per file scanned (source bytes, the violations
//! slice); it is a short-lived CLI process, not a library, so the `init`-only no-allocation
//! contract in `tidy.zig`'s own header does not apply here.

const std = @import("std");
const tidy = @import("tidy.zig");

const dirs_default = [_][]const u8{ "src", "bench", "tests" };
const dirs_max = 64;
const files_max = 4096;
const source_bytes_max = 64 * 1024;
const baseline_entries_max = 256;
const baseline_bytes_max = 64 * 1024;
const header_probe_bytes_max = 256;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    assert(args.len >= 1);

    var dirs_buf: [dirs_max][]const u8 = undefined;
    const dirs: []const []const u8 = if (args.len > 1) blk: {
        assert(args.len - 1 <= dirs_max);
        for (args[1..], 0..) |arg, i| dirs_buf[i] = arg;
        break :blk dirs_buf[0 .. args.len - 1];
    } else &dirs_default;
    assert(dirs.len > 0);
    assert(dirs.len <= dirs_max);

    var baseline = try loadBaseline(gpa);
    defer baseline.deinit(gpa);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const err_out = &stderr_writer.interface;
    defer err_out.flush() catch {};

    var violations_total: usize = 0;
    for (dirs) |dir_path| {
        violations_total += try checkDir(gpa, dir_path, baseline.entries, err_out);
    }

    if (violations_total > 0) {
        try err_out.flush();
        std.process.exit(1);
    }
}

/// A parsed `tidy_baseline.txt`: `entries` borrows every `.path`/`.function` slice from
/// `contents`, so `contents` must outlive `entries` — `deinit` frees both together.
const Baseline = struct {
    contents: []const u8,
    entries: []tidy.BaselineEntry,

    fn deinit(self: *Baseline, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        gpa.free(self.contents);
    }
};

/// Loads and parses `tidy_baseline.txt` from the working directory. A missing file is not an
/// error: it means no function is baselined yet. Format: `path:function:lines_max` one entry
/// per line; blank lines and lines starting with `#` are ignored.
fn loadBaseline(gpa: std.mem.Allocator) !Baseline {
    const baseline_path = "tidy_baseline.txt";
    const contents = std.fs.cwd().readFileAlloc(gpa, baseline_path, baseline_bytes_max) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return err,
    };
    errdefer gpa.free(contents);
    assert(contents.len <= baseline_bytes_max);

    var entries: std.ArrayList(tidy.BaselineEntry) = .empty;
    errdefer entries.deinit(gpa);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var iterations: usize = 0;
    while (iterations < baseline_entries_max) : (iterations += 1) {
        const line = lines.next() orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, trimmed, ':');
        const path = fields.next() orelse continue;
        const function = fields.next() orelse continue;
        const lines_max_str = fields.next() orelse continue;
        const lines_max = std.fmt.parseInt(u32, lines_max_str, 10) catch continue;

        try entries.append(gpa, .{ .path = path, .function = function, .lines_max = lines_max });
    }
    assert(iterations <= baseline_entries_max);
    assert(entries.items.len <= baseline_entries_max);

    return .{ .contents = contents, .entries = try entries.toOwnedSlice(gpa) };
}

/// Recursively scans `dir_path` for `.zig` files and returns the total violation count across
/// all of them (0 if `dir_path` does not exist — `bench`/`tests` are optional in some repos).
fn checkDir(
    gpa: std.mem.Allocator,
    dir_path: []const u8,
    baseline: []const tidy.BaselineEntry,
    err_out: *std.Io.Writer,
) !usize {
    assert(dir_path.len > 0);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var violations_total: usize = 0;
    var iterations: usize = 0;
    while (iterations < files_max) : (iterations += 1) {
        const entry = (try walker.next()) orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const rel_path = try std.fs.path.join(gpa, &.{ dir_path, entry.path });
        defer gpa.free(rel_path);

        violations_total += try checkFile(gpa, rel_path, baseline, err_out);
    }
    assert(iterations <= files_max);

    return violations_total;
}

/// Reads, checks, and reports one `.zig` file; returns its violation count.
fn checkFile(
    gpa: std.mem.Allocator,
    path: []const u8,
    baseline: []const tidy.BaselineEntry,
    err_out: *std.Io.Writer,
) !usize {
    assert(path.len > 0);
    assert(std.mem.endsWith(u8, path, ".zig"));

    const source = try std.fs.cwd().readFileAlloc(gpa, path, source_bytes_max);
    defer gpa.free(source);

    const src_prefix = "src" ++ std.fs.path.sep_str;
    const options = tidy.CheckOptions{
        .enforce_lib_bans = std.mem.startsWith(u8, path, src_prefix),
        .is_format_file = isFormatFile(source),
        .baseline = baseline,
        .path = path,
    };
    const violations = try tidy.checkSource(gpa, source, options);
    defer gpa.free(violations);

    for (violations) |v| {
        try err_out.print("{s}:{d}: {s} — {s}\n", .{ path, v.line, @tagName(v.rule), v.detail });
    }
    return violations.len;
}

/// True if `source`'s first line, lowercased, mentions "wire format" or "on-disk format" —
/// the convention this repo uses to opt a file into the `usize_in_format` check.
fn isFormatFile(source: []const u8) bool {
    const newline = std.mem.indexOfScalar(u8, source, '\n');
    const first_line = if (newline) |n| source[0..n] else source;
    assert(first_line.len <= source.len);

    var buf: [header_probe_bytes_max]u8 = undefined;
    const probe_len = @min(first_line.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..probe_len], first_line[0..probe_len]);
    return std.mem.indexOf(u8, lower, "wire format") != null or
        std.mem.indexOf(u8, lower, "on-disk format") != null;
}

const assert = std.debug.assert;
