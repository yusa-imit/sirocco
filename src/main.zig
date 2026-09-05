const std = @import("std");
const sirocco = @import("sirocco");

/// Minimal CLI: `sirocco version` / `sirocco --help`.
/// Diagnostic subcommands are added as modules land (see docs/PRD.md).
pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const cmd = if (args.len > 1) args[1] else "--help";
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
}

test "cli: version is exposed" {
    try std.testing.expectEqual(@as(u32, 0), sirocco.version.major);
}
