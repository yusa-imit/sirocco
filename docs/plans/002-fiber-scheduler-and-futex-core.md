# Plan 002 — fiber-scheduler-and-futex-core

## Goal

Turn sirocco from a stub into a real `std.Io` value: a `Runtime` assembling all 109 `Io.VTable`
slots (forwarding by default), with the P0 concurrency/cancel core (12) and the P1 futex trio
(3) native on its own fibers, each group differential-tested against the embedded `Io.Threaded`.

## Why now

`docs/PRD.md` §4.3 makes P0 the floor: every later group (time, submission, net, file) suspends
on `sched.zig`'s fibers and wakes through the futex table, so nothing after P1 can start until
these 15 slots exist. The six stub modules ADR 0001 retired must go before a consumer reads
`sirocco.net` and believes it. Plan 001 deferred macOS CI and `docs/PRD.md` §9 says the next
plan may not — context switching is per-arch assembly and aarch64-darwin runs every session.

## Scope

- [ ] 1. Enable a native macOS runner in `.github/workflows/ci.yml` (`macos-latest`, aarch64),
      or record the exact link failure and the fallback in `docs/adr/`. Why first: cross-compile
      cannot execute a context switch, and this plan's core is arch-specific assembly.
      Verify: `gh run list` shows a green `Build & Test (macos-latest)` job on the PR.
- [ ] 2. Delete `src/{io,net,tls,http,ws,task}.zig` and their `root.zig` re-exports; land
      `src/runtime.zig` with `Runtime`, `Options`, `Backend`, `Unimplemented`, `init`/`deinit`/
      `io()`/`baselineIo()`, every slot copied from the embedded `Io.Threaded` (`.fail` installs
      `Io.failing`'s stub), the `@typeInfo(Io.VTable).@"struct".fields.len == 109` comptime guard,
      and the invariant that no `Runtime` field points into `Runtime` — state is recovered with
      `@fieldParentPtr("threaded", t)`, so `io()` is the only place taking its address.
      Verify: `zig build test` — `rt.io().vtable != rt.baselineIo().vtable`, forwarded call works.
- [ ] 3. `tests/parity/` harness: `expectSameResult(rt, call, args)` runs one call on `rt.io()`
      and on `rt.baselineIo()` and compares tag, payload and error name; `tests/parity/slots.zig`
      holds a comptime table of all 109 slot names in `native`, `delegated` and `divergent` lists
      and fails the build if a name is in none. Why before any slot lands: it is the mechanism
      every later item verifies itself with, and the `divergent` list (contract-permitted
      differences, each citing the std doc comment that permits it) must exist before the first
      divergence is written. Verify: `zig build test` plus a negative test that removing a name
      from the table is a comptime error.
- [ ] 4. `src/sched.zig` fiber substrate, no slots installed yet: all `fibers_max` stacks
      allocated once in `init`, an intrusive ready queue, `park`/`unpark`, switching via
      `Io.fiber.contextSwitch`, a stack canary checked at fiber exit, and `.auto` resolving to
      `.threaded` when `!Io.fiber.supported`. The carrier thread blocks through the baseline's
      `futexWaitUncancelable` when the queue drains, so no `src/backend/*` file is needed yet.
      Verify: internal tests spawn `fibers_max` fibers round-robin, assert each ran with its
      canary intact and that `std.testing.allocator` counts no allocation after `init` (gate 5).
- [ ] 5. Install the four future-producing slots as one set: `async`, `concurrent`, `await`,
      `cancel`. Why together: `await`/`cancel` receive the `*AnyFuture` that `async`/`concurrent`
      produced, so a half-native vtable would hand a sirocco future to Threaded's `await`.
      `concurrent` returns `error.ConcurrencyUnavailable` (permitted by `Io.ConcurrentError`)
      while the runtime is single-carrier; `cancel` is request-flag + await until item 6 makes
      the flag observable. Verify: `tests/parity/concurrency.zig`; `bench/spawn.zig` records
      PRD §5 gate 6 at 1 and 1000 in flight.
- [ ] 6. Cancel state: `checkCancel`, `recancel`, `swapCancelProtection`, with per-fiber cancel
      flags and protection depth, and `cancel` from item 5 now unparking its target with
      `error.Canceled`. Verify: cancel-parity tests per PRD §8 — cancel in flight returns
      `error.Canceled` on both `Io`s, and neither returns it under `.blocked`.
- [ ] 7. Group slots as one set: `groupAsync`, `groupConcurrent`, `groupAwait`, `groupCancel`
      (same token-ownership argument as item 5), plus `crashHandler`, which closes P0's 12.
      Verify: `tests/parity/group.zig` (wait-all, cancel-all, error propagation); `slots.zig`
      shows 12 P0 names in `native`.
- [ ] 8. `src/futex.zig`: address-keyed wait table with `futexWait`, `futexWaitUncancelable`,
      `futexWake`, bounded by `fibers_max` waiters. `Timeout.deadline`/`.duration` read the
      clock through the still-forwarded `now` slot — a stated temporary until P2's timer wheel
      lands. Why it must be in this plan: `Io.Mutex`/`Condition`/`Event`/`Semaphore`/`RwLock`/
      `Queue` are all built on these three, so no std synchronization primitive works on
      sirocco without them. Verify: `tests/parity/futex.zig` plus a seeded model test that
      replays a random wait/wake sequence on both `Io`s and compares the wake trace.
- [ ] 9. Reconcile `README.md`, `CHANGELOG.md` and PRD §5's measurement table with what shipped
      (including the single-carrier limitation), bump `build.zig.zon` to 0.3.0 and release.
      Verify: `gh release view v0.3.0`.

`blocked_by`: none — sirocco is zero-dependency foundation and no kingdom repo pins it yet.

## Out of scope

- P2 time (`now`/`clockResolution`/`sleep` stay forwarded), P3 submission, P4 net, P5 file,
  P6 stderr locking — the next plans, each needing P0/P1 underneath it.
- `src/backend/*` — P0 and P1 make no OS call; kqueue/epoll arrive with P3/P4.
- Multi-carrier-thread scheduling, work stealing and a truthful `concurrent`. Plan 003.
- Anything ADR 0001 already dropped: TLS, HTTP, WebSocket, `Pool(T)`, a sirocco cancel type.

## Risks

- `Io.fiber.supported` is false outside aarch64/riscv64/x86_64, and every CI target is
  supported, so the fallback is never exercised by accident. Mitigation: item 4 tests
  `.backend = .threaded` explicitly on every target, which is the same path `.auto` selects.
- 64 KiB `fiber_stack_bytes` may be far too small: std's own `Io.Kqueue` reserves a 4 MiB
  minimum per fiber (`Io/Kqueue.zig:90`) because std code runs on those stacks. Item 4's canary
  turns an overflow into a failed assertion instead of memory corruption; raise the default if
  it trips.
- A single carrier thread means any forwarded blocking slot (file, dir, net, `sleep`) stalls
  every fiber. v0.3.0 is therefore an internal milestone: item 9's README must say it is not
  yet ready for silica/zoltraak, and plan 003 must remove the limitation.
- The `divergent` list in `slots.zig` can become a hiding place for real bugs. Mitigation: an
  entry without a quoted std doc comment permitting it fails review.
- `crashHandler` runs after a panic on a switched stack: keep it a forward plus a fiber-state
  dump or a test failure becomes an unreadable trace. The macOS runner may still fail to link
  as on 0.15; item 1 may end in an ADR rather than a green job, but not in silence.

## Done when

- `zig build test` and `zig fmt --check src bench build.zig tools tests` are green on Linux and
  on the macOS runner (or the ADR from item 1 is merged), and `zig build tidy` reports zero
  violations with `src/sched.zig`, `src/futex.zig`, `src/runtime.zig` all under 800 lines.
- `tests/parity/slots.zig` accounts for all 109 slots and lists the 15 P0+P1 names as `native`.
- The suite passes a second time with `.unimplemented = .fail`: no native test passes by
  falling through to `Io.Threaded`.
- `zig build test` wall clock stays under 60s in CI (PRD §5 gate 8) with no test exempted from
  `Step.Run.unit_test_timeout_ns` (gate 9); gates 5 and 6 are recorded in PRD §5's table.
- No `src/io.zig`, `src/net.zig`, `src/tls.zig`, `src/http.zig`, `src/ws.zig`, `src/task.zig`.
- Zero open `bug` issues; milestone issue for plan 002 closed; `v0.3.0` tagged and released.

## Version impact

**MINOR — v0.2.0 → v0.3.0.** Additive by intent (`Runtime` is the first real public surface) but
it also deletes six exported stub modules, which is breaking. Per
`citadel/protocol/VERSIONING.md`, foundation repos stay `0.x` until two consumers depend on
them and MINOR may break during `0.x`; no `build.zig.zon` in the kingdom pins sirocco today
(STATE.md, 2026-09-11), so no consumer can break and MAJOR would be noise. Not PATCH: this is a
milestone with features, and `CHANGELOG.md` plus the `build.zig.zon` bump ship in item 9's PR.
Zig stays pinned at 0.16.0, so the toolchain MAJOR rule does not apply.
