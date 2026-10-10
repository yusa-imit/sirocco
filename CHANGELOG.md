# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) with the `0.x` MINOR-may-break
exemption recorded in `citadel/protocol/VERSIONING.md`.

## [Unreleased]

### Added

- `src/offload.zig`: a bounded worker-thread pool that runs a blocking call for a parked fiber
  and wakes it through `Sched.unpark_foreign` (plan `003` item 7, ADR 0002). `Runtime.Options`
  gains the required field `offload_threads`; the pool is built with the scheduler at the first
  `io()`. No slot uses it yet (item 8). Internal.
- `src/timer.zig`: a hierarchical timing wheel (131 us tick, bounded node array, no allocation
  after `init`, clock passed in) that native `sleep` and futex timeouts run on (plan `003`
  item 3). Internal.

### Changed

- **Breaking (0.x MINOR):** `Runtime.Options` gains the required field `offload_threads`.
- `sleep` is native: a fiber in `rt.io().sleep` parks on the scheduler's timing wheel instead of
  blocking the carrier thread, so other fibers keep running; a cancel wakes it with
  `error.Canceled`. CPU-time clocks and calls from outside a fiber still forward to `Io.Threaded`.
  Futex timeouts moved onto the same wheel and the temporary `Sched.timers` hook is gone (plan
  `003` item 4).
- `async` starts the task at once: the body runs inside the call until it first parks, yields or ends
  (a caller on a fiber yields; off-fiber the carrier loop runs it). Gate 6 now passes at 1000 in
  flight (plan `003` item 2).

### Fixed

- `groupAwait` honors a cancel that arrives while it is parked: the awaiter is woken, cancels every
  member, waits for them all and returns `error.Canceled`; a protected awaiter keeps waiting
  (plan `003` item 1).

## [0.3.0] - 2026-10-06

Plan `002` (fiber scheduler and futex core). An internal milestone: the runtime has a single
carrier thread, so any forwarded blocking slot (file, dir, net, `sleep`) stalls every fiber, and
`groupAwait` does not yet propagate a cancel that arrives while it is parked. It is not ready for
silica or zoltraak; plan 003 removes the limitation. PRD §5 gate 6 passes at 1 task in flight and
fails at 1000 (tasks start lazily).

### Added

- Native `futexWait`, `futexWaitUncancelable` and `futexWake` on fibers (`src/futex.zig`): an
  address-keyed FIFO wait table bounded by `fibers_max` (the wait record lives in each fiber, no
  allocation), timeouts read through the baseline clock and expired by a `Sched` timer hook,
  `futexWait` as a cancelation point that a cancel unparks, and a spinlock so `futexWake` from any
  thread is safe (off-carrier wakes go through `Sched.unpark_foreign`). std's `Mutex`, `Condition`,
  `Event`, `Semaphore` and `Queue` now block fibers instead of the carrier. The context-switch
  assembly moved from `src/sched.zig` to `src/fiber_switch.zig`. Tests: `tests/parity/futex*.zig`.
- Native group slots `groupAsync`, `groupAwait`, `groupCancel` and `groupConcurrent`
  (`ConcurrencyUnavailable`, like `concurrent`), plus `crashHandler`, closing the P0 set of 12.
  `Io.Group.token` points at a record holding the live members; `groupCancel` (and a canceled
  awaiter) requests cancelation on every member, and a member that gets no fiber or record runs
  inline. Tests: `tests/parity/group.zig`.
- Native `checkCancel`, `recancel` and `swapCancelProtection` on fibers: each task record holds
  its cancel request (`none`/`requested`/`acknowledged`) and protection; `cancel` sets the request
  and the task's first unprotected `checkCancel` returns `error.Canceled`, once, until
  `recancel`. Outside a task (the carrier, or a forwarded group worker thread) they forward to the
  embedded `Io.Threaded`. `Sched.run_until` lets `await` outside a fiber run only up to the
  awaited task instead of draining every live fiber.
- `bench/spawn.zig` (`zig build bench-spawn`): `io.async` -> body-entered latency of `rt.io()`
  against `rt.baselineIo()` at 1 and 1000 in flight (PRD §5 gate 6); first numbers recorded.
- `sirocco.Runtime` (`src/runtime.zig`): walking skeleton of the `std.Io` implementation. Every
  one of the 109 `Io.VTable` slots is forwarded from an embedded `Io.Threaded`
  (`Options.unimplemented = .forward`) or taken from `Io.failing` (`.fail`); `io()` and
  `baselineIo()` hand out the runtime's vtable and the untouched `Io.Threaded` oracle.
- Differential test suite (`tests/parity/`, part of `zig build test`): `expectSameResult` runs one
  call on `rt.io()` and on `rt.baselineIo()` and compares tag, payload and error name;
  `slots.zig` lists all 109 slots as `native`, `delegated` or `divergent` and fails the build if
  a slot is in none of them, in two, or misnamed; first parity tests for `clockResolution`,
  `dirAccess` and `dirStatFile`.
- CI builds and tests on a native `macos-latest` runner as well as `ubuntu-latest`.
- Internal fiber substrate (`src/sched.zig`, not public): `fibers_max` stacks allocated once in
  `init`, a FIFO ready queue, `spawn`/`yield`/`park`/`unpark`, a stack canary checked at fiber
  exit, and a lock-free `unpark_foreign` inbox that wakes a carrier blocked in the baseline
  futex. aarch64 and x86_64 only (`Sched.supported`).
- Native `async`, `await`, `cancel` slots on the fiber scheduler (`src/concurrency.zig`): a task
  is a fiber that runs lazily, FIFO, once an `await` outside any fiber drives the scheduler;
  `await` inside a fiber parks. With no free fiber or a failed allocation `async` runs the task
  inline and returns no future. `cancel` sets a flag and awaits (observable from item 6 on).
  `Runtime.fibers_supported` tells whether the slots are native (elsewhere they stay forwarded).
- `Sched.in_fiber`, `Sched.has_free_fiber`; parity tests in `tests/parity/concurrency.zig`.
- `stdx.assert_always`: an invariant check that stays on in ReleaseFast and ReleaseSmall.

### Changed

- `Runtime.Options` gained required `fibers_max` and `fiber_stack_size` (stacks are allocated at
  the first `io()`).
- `concurrent` now always returns `error.ConcurrencyUnavailable` (allowed by
  `Io.ConcurrentError`; recorded as a divergence in `tests/parity/slots.zig`) while the runtime
  has a single carrier; before, the forwarded Threaded slot succeeded.

### Removed

- The six stub modules `sirocco.io`, `.net`, `.tls`, `.http`, `.ws`, `.task` (they only raised
  `error.NotImplemented`; ADR 0001 retired their API).

### Fixed

- Fibers now end their stack with a zero return address, so std's stack unwinder (run by the
  debug allocator on every allocation) stops at the fiber base instead of segfaulting.
- Fiber switch no longer uses std's inline-asm `Io.fiber.contextSwitch`: LLVM miscompiled it in
  x86_64 ReleaseSmall (the message pointer never reached `rsi`), crashing every `sched` test.
  `src/sched.zig` now has its own naked per-arch switch that saves the callee-saved registers,
  and CI runs ReleaseSmall on Linux again.

## [0.2.0] - 2026-09-11

Plan `001` (Zig 0.16 migration and Tiger Style baseline).

### Added

- `zig build tidy`: mechanical Tiger Style checker (line/function length ratchet, ban list,
  missing `//!` header), wired as a dependency of `zig build test`.
- `src/stdx.zig`: shared `assert`/`maybe` helpers, re-exported as `sirocco.stdx`.
- Pre/postcondition assertions on `src/main.zig`'s `run()` and `bench/main.zig`'s
  `matchesFilter()`/`rates()`.
- `docs/adr/0001-std-io-vtable.md`: sirocco's public surface is an implementation of
  `std.Io.VTable` (`Runtime.io()`), not a parallel `io`/`net`/`tls`/`http`/`ws`/`task` API.

### Changed

- Migrated `src/main.zig`, `bench/main.zig`, and `tools/tidy_main.zig`/`tidy_test.zig` to Zig
  0.16.0 (`std.process.Init`, `std.Io.Dir`/`File`, `Io.Clock`).
- `build.zig.zon` `.minimum_zig_version` bumped to `0.16.0`; CI resolves the toolchain from the
  manifest instead of a hardcoded version pin.
- `docs/PRD.md` rewritten against `std.Io.VTable` per ADR 0001.
- README reconciled with the `std.Io.VTable` design (module table replaced by the `Runtime.io()`
  surface, Status and Design sections added, install snippet no longer names an uncut tag).

### Fixed

- `ci.yml` `paths-ignore` no longer references the removed `.claude/memory/**`; format gate
  widened to `zig fmt --check src bench build.zig`; `bench` added to `build.zig.zon` `.paths`
  (`build.zig` references `bench/main.zig`, previously absent from the package tarball).
