//! The loopback echo benchmark with the carrier's time counters on (plan 005 item 1, ADR 0003
//! 4c). Run: `zig build bench-echo-profile`. The root declares `sirocco_profile`, which switches
//! `sirocco.profile` on; the scenario is `bench/echo.zig`'s, unchanged. The counters add two clock
//! reads to every timed syscall, so the throughput of this build is not a gate figure.

const echo = @import("echo.zig");

pub const sirocco_profile = true;

pub const main = echo.main;
