//! The context switch under `Sched` (plan 002 item 4): one naked per-arch function that saves the
//! callee-saved registers of the running fiber (or carrier) on its own stack and resumes another.
//!
//! Invariants: `Io.fiber.Context` has the `sp`/`fp`/`pc` (`rsp`/`rbp`/`rip` on x86_64) layout the
//! assembly hard-codes, checked at compile time below. Allocation: none. Only aarch64 and x86_64
//! have a body; `Sched.supported` keeps every other target from reaching `switch_context`.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const assert = @import("stdx.zig").assert;

// Naked on purpose. std's `Io.fiber.contextSwitch` is inline asm that LLVM miscompiles in
// ReleaseSmall on x86_64 (the message pointer never reaches `rsi`, so the asm reads the wrong
// context) and that clobbers the frame registers on aarch64. Here the switch is a whole function:
// it pushes the callee-saved registers on the old stack, stores `sp`/`fp`/resume `pc` in `old`,
// loads them from `new` and jumps. Resuming `old` later pops the registers and returns to the
// caller of `switch_context`. It declares no Zig parameters (the self-hosted x86_64 backend
// rejects unused arguments of a naked function); the C-convention pointer type in
// `switch_context` carries `old` in rdi/x0 and `new` in rsi/x1. A fresh fiber's `Context` is
// jumped to, never returned into.
fn switch_context_asm() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ pushq %%rbx
            \\ pushq %%r12
            \\ pushq %%r13
            \\ pushq %%r14
            \\ pushq %%r15
            \\ leaq 0f(%%rip), %%rax
            \\ movq %%rsp, 0(%%rdi)
            \\ movq %%rbp, 8(%%rdi)
            \\ movq %%rax, 16(%%rdi)
            \\ movq 0(%%rsi), %%rsp
            \\ movq 8(%%rsi), %%rbp
            \\ jmpq *16(%%rsi)
            \\0:
            \\ popq %%r15
            \\ popq %%r14
            \\ popq %%r13
            \\ popq %%r12
            \\ popq %%rbx
            \\ retq
        ),
        .aarch64 => asm volatile (
            \\ sub sp, sp, #160
            \\ stp x19, x20, [sp, #0]
            \\ stp x21, x22, [sp, #16]
            \\ stp x23, x24, [sp, #32]
            \\ stp x25, x26, [sp, #48]
            \\ stp x27, x28, [sp, #64]
            \\ stp d8, d9, [sp, #80]
            \\ stp d10, d11, [sp, #96]
            \\ stp d12, d13, [sp, #112]
            \\ stp d14, d15, [sp, #128]
            \\ str x30, [sp, #144]
            \\ mov x2, sp
            \\ adr x3, 0f
            \\ stp x2, x29, [x0]
            \\ str x3, [x0, #16]
            \\ ldp x2, x29, [x1]
            \\ ldr x3, [x1, #16]
            \\ mov sp, x2
            \\ br x3
            \\0:
            \\ ldp x19, x20, [sp, #0]
            \\ ldp x21, x22, [sp, #16]
            \\ ldp x23, x24, [sp, #32]
            \\ ldp x25, x26, [sp, #48]
            \\ ldp x27, x28, [sp, #64]
            \\ ldp d8, d9, [sp, #80]
            \\ ldp d10, d11, [sp, #96]
            \\ ldp d12, d13, [sp, #112]
            \\ ldp d14, d15, [sp, #128]
            \\ ldr x30, [sp, #144]
            \\ add sp, sp, #160
            \\ ret
        ),
        else => unreachable, // `Sched.supported` is false and `init` refused.
    }
}

// The assembly above hard-codes this layout (offsets 0, 8, 16).
comptime {
    if (Io.fiber.supported and (builtin.cpu.arch == .x86_64 or
        builtin.cpu.arch == .aarch64))
    {
        const names = switch (builtin.cpu.arch) {
            .x86_64 => .{ "rsp", "rbp", "rip" },
            else => .{ "sp", "fp", "pc" },
        };
        assert(@sizeOf(Io.fiber.Context) == 24);
        assert(@offsetOf(Io.fiber.Context, names[0]) == 0);
        assert(@offsetOf(Io.fiber.Context, names[1]) == 8);
        assert(@offsetOf(Io.fiber.Context, names[2]) == 16);
    }
}

// Zig refuses a direct call to a naked function; calling it through a C-convention pointer gives
// the compiler an ordinary call, whose caller-saved registers it already treats as clobbered.
// `never_inline` keeps LLVM from splicing the asm body into a caller that has no clobber list.
pub fn switch_context(old: *Io.fiber.Context, new: *Io.fiber.Context) void {
    const switch_c: *const fn (*Io.fiber.Context, *Io.fiber.Context) callconv(.c) void =
        @ptrCast(&switch_context_asm);
    @call(.never_inline, switch_c, .{ old, new });
}
