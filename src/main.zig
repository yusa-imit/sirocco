//! sirocco CLI — minimal diagnostics: `version` and `--help`.
//!
//! Grows subcommands as PRD phases land; see docs/PRD.md.

const std = @import("std");
const sirocco = @import("sirocco");

/// Minimal CLI: `sirocco version` / `sirocco --help`.
/// Diagnostic subcommands are added as modules land (see docs/PRD.md).
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    assert(args.len >= 1); // argv[0] (the program name) is always present.

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    try run(args, out);
    assert(out.end <= stdout_buffer.len); // Postcondition: run() never overflows the fixed buffer.
}

/// Resolves `args` to a CLI command and writes its output to `out`.
/// `args[0]` is the program name; `args[1]`, if present, selects the command.
fn run(args: []const []const u8, out: *std.Io.Writer) !void {
    assert(args.len >= 1);
    maybe(args.len == 1); // Sometimes no subcommand is given — falls back to `--help`.

    const cmd = if (args.len > 1) args[1] else "--help";
    assert(cmd.len > 0);

    if (std.mem.eql(u8, cmd, "version")) {
        try out.print("sirocco {f}\n", .{sirocco.version});
    } else {
        try out.print(
            \\sirocco — The wind that drives the fleet — async I/O runtime and network stack for Zig
            \\
            \\usage: sirocco <command>
            \\  version    print library version
            \\  --help     this text
            \\
        , .{});
    }
    assert(out.end > 0); // Postcondition: run() always writes something to `out`.
}

test "cli: version is exposed" {
    try std.testing.expectEqual(@as(u32, 0), sirocco.version.major);
}

test "run: version command prints the library version" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try run(&.{ "sirocco", "version" }, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "sirocco 0.") != null);
}

test "run: no subcommand falls back to help text" {
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try run(&.{"sirocco"}, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "usage:") != null);
}

test "run: unknown subcommand falls back to help text" {
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try run(&.{ "sirocco", "bogus" }, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "usage:") != null);
}

const assert = sirocco.stdx.assert;
const maybe = sirocco.stdx.maybe;
