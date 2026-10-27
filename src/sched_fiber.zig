//! The birth and death of a `Sched` fiber (plan 002 item 4): the first context of a new stack, the
//! naked entry trampoline that turns it into a call of `fiber_main`, the exit path that returns
//! the fiber to the free list, and the stack-base canary. Split out of `src/sched.zig`, which
//! owns the `Fiber` record, the queues and the carrier loop and calls `context_prepare` from
//! `spawn` and `canary_intact` on every switch-out.
//!
//! Layout of a fresh stack, top (high address) down: a `Start` record (scheduler, fiber, entry,
//! argument), one zero word standing for the return address (x86_64 enters `fiber_main` through a
//! `jmp`, so a stack walk ends there; aarch64 zeroes `x30` in `fiber_entry`), then free stack. The
//! first eight bytes at the stack base hold `canary_value`; it catches a linear overflow only.
//!
//! Invariants: `fiber_main` runs only on the fiber's own stack, with `sched.current == fiber`, and
//! never returns: it frees the fiber (state `.free`, argument cleared, `live_count` down) and
//! switches to the carrier for good, so a free fiber's context is never resumed. The canary is
//! checked with `assert_always` at fiber exit.
//!
//! Allocation: none. Everything is written into the stack that `Sched.init` allocated; `Start`
//! lives on that stack and dies with the fiber.

const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx.zig");
const Sched = @import("sched.zig");

const Io = std.Io;
const assert = stdx.assert;
const assert_always = stdx.assert_always;
const Fiber = Sched.Fiber;

const canary_value: u64 = 0x5afe_c0de_0ddf_00d5;
const canary_size = @sizeOf(u64);

/// Lives at the top of a fiber's stack; the entry trampoline hands its address to `fiber_main`.
const Start = struct {
    sched: *Sched,
    fiber: *Fiber,
    entry: Sched.Entry,
    arg: ?*anyopaque,
};

/// Arms `fiber`'s fresh stack (canary, `Start` record, zero return word) and returns the context
/// whose first switch-in runs `entry(arg)` through `fiber_entry`. Precondition: `fiber` was just
/// taken off the free list, so its stack is unused and `Sched.stack_align`-aligned at the top.
pub fn context_prepare(
    sched: *Sched,
    fiber: *Fiber,
    entry: Sched.Entry,
    arg: ?*anyopaque,
) Io.fiber.Context {
    assert(fiber.state == .free);
    assert(fiber.stack.len > @sizeOf(Start) + canary_size);
    const top = @intFromPtr(fiber.stack.ptr) + fiber.stack.len;
    assert(top % Sched.stack_align == 0);
    const start_address = std.mem.alignBackward(usize, top - @sizeOf(Start), Sched.stack_align);
    const start: *Start = @ptrFromInt(start_address);
    start.* = .{ .sched = sched, .fiber = fiber, .entry = entry, .arg = arg };
    std.mem.writeInt(u64, fiber.stack[0..canary_size], canary_value, .little);
    @as(*usize, @ptrFromInt(start_address - @sizeOf(usize))).* = 0;
    return initial_context(start_address);
}

/// True while the canary at the stack base is untouched.
pub fn canary_intact(stack: []const u8) bool {
    assert(stack.len >= canary_size);
    return std.mem.readInt(u64, stack[0..canary_size], .little) == canary_value;
}

/// Runs on the fiber's own stack; never returns, it switches to the carrier for good.
fn fiber_main(start: *Start) callconv(.withStackAlign(.c, @alignOf(Start))) noreturn {
    const sched = start.sched;
    const fiber = start.fiber;
    assert(sched.current == fiber);
    start.entry(start.arg);

    assert_always(canary_intact(fiber.stack));
    assert(fiber.state == .running);
    fiber.state = .free;
    fiber.arg = null;
    fiber.queue_next = sched.free_head;
    sched.free_head = fiber;
    sched.live_count -= 1;
    sched.switch_to_carrier(fiber);
    // A free fiber is never made ready again, so its context is never resumed.
    unreachable;
}

fn initial_context(start_address: usize) Io.fiber.Context {
    return switch (builtin.cpu.arch) {
        .x86_64 => .{
            .rsp = start_address - @sizeOf(usize),
            .rbp = 0,
            .rip = @intFromPtr(&fiber_entry),
        },
        .aarch64 => .{
            .sp = start_address,
            .fp = 0,
            .pc = @intFromPtr(&fiber_entry),
        },
        else => unreachable, // `supported` is false and `init` refused.
    };
}

/// First instruction of a new fiber: turns the stack-top `Start` record into `fiber_main`'s
/// only argument.
fn fiber_entry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ leaq 8(%%rsp), %%rdi
            \\ jmp %[fiber_main:P]
            :
            : [fiber_main] "X" (&fiber_main),
        ),
        .aarch64 => asm volatile (
            \\ mov x0, sp
            \\ mov x30, xzr
            \\ b %[fiber_main]
            :
            : [fiber_main] "X" (&fiber_main),
        ),
        else => unreachable, // `supported` is false and `init` refused.
    }
}

test "canary detects a clobbered stack base" {
    var stack: [64]u8 = @splat(0);
    std.mem.writeInt(u64, stack[0..canary_size], canary_value, .little);
    try std.testing.expect(canary_intact(&stack));
    stack[3] ^= 0x01;
    try std.testing.expect(!canary_intact(&stack));
}
