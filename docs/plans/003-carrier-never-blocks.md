# Plan 003 — carrier-never-blocks

## Goal

No `rt.io()` slot called from a fiber may block the single carrier thread. `sleep` goes native
on a timer wheel (P2, gate 7), every forwarded blocking slot runs on a bounded offload pool while
its fiber parks, and the two P0 debts v0.3.0 shipped with are closed: `groupAwait` ignoring a
cancel that arrives while it is parked, and PRD §5 gate 6 failing at 1000 tasks in flight.

## Why now

Plan 002's Risks bound this plan to remove the single-carrier limitation. On v0.3.0 one fiber in
`sleep`, `dirOpenFile` or `netAccept` freezes every fiber, so a server that accepts on one fiber
and connects or serves on another deadlocks. Removing the *stall* needs neither a backend nor a
second carrier: the wheel covers the one slot that is pure waiting, and offload covers the rest
until P3/P4 make them evented. Multi-carrier scheduling is a throughput feature that gate 1
(2.0x echo at 1000 connections) will demand, so it belongs with the kqueue/epoll plan, where each
carrier owns one poller; item 7's ADR records that choice for the human to approve here.

## Scope

- [x] 1. `groupAwait` propagates a cancel that arrives while it is already parked: the awaiter is
      unparked, cancels every member, waits for them all, then returns `error.Canceled`; under
      `.blocked` it keeps waiting. Why first: `Io.Group.await` documents this ("cancelation
      requests propagate to all members"), so the gap is a shipped contract bug, and bugs go
      before features. Verify: `tests/parity/group.zig` — members parked on a futex, the
      awaiter parked, then `cancel`: `Canceled` after all members were canceled, plus the
      `.blocked` case and the cancel racing the last member (asserted on `rt.io()` alone, as
      the other cancel-timing facts: the baseline has no fiber to park).
- [x] 2. Eager task start: `async` switches into the new fiber at once and re-queues the caller
      (off-fiber, it runs until the task first parks or ends). `Io.async` permits running the
      task before returning. Why: lazy start is the measured cause of gate 6 failing at 1000
      (86056 ns vs 599 ns). Verify: a `concurrency.zig` test that the body has run when `async`
      returns; `zig build bench-spawn -Doptimize=ReleaseFast` passes at 1 and 1000, rows in PRD §5.
- [x] 3. `src/timer.zig`: a timing wheel whose nodes are a bounded array, one per fiber
      index, allocated once in `init` (bounded by `fibers_max`, no allocation after, no `timers_max`
      option), with `insert`/`remove`/
      `expire(now_ns)`/`next_deadline`, tick <= 250 µs so a 1 ms sleep cannot round past gate 7.
      The wheel never reads a clock; `now_ns` is passed in (determinism). Verify: seeded model
      test (10k random insert/remove/expire ops) against a sorted-array reference compares the
      expiry trace; the allocation counter stays flat after init.
- [x] 4. Native `sleep` on the wheel for `.duration`/`.deadline` on `real`/`awake`/`boot`, a
      cancelation point a cancel unparks; CPU-time clocks and off-fiber callers forward (a wall
      wheel cannot measure CPU time). Move futex timeouts onto the wheel and delete the
      `Sched.timers` hook plan 002 item 8 called temporary. Verify: `tests/parity/time.zig` sleep
      ordering and cancel parity (in flight -> `Canceled` on both, `.blocked` -> neither); 16
      fibers sleeping 50 ms finish in < 400 ms (a stall takes 800 ms); `futex*.zig` stay green.
- [x] 5. `bench/timer.zig` + `zig build bench-timer`: 1 ms sleep wake error p50/p99 on `rt.io()`
      vs `rt.baselineIo()`. Verify: PRD §5 gate 7 row recorded (p99 < 2 ms and <= Threaded); a
      failing row is fixed in this item if the tick is the cause, else recorded with the cause.
- [x] 6. Parity harness in-fiber mode: `expectSameResultInFiber` runs the `rt.io()` side inside an
      `async` task. Why before 7-8: every parity call today runs off-fiber, where offload never
      engages, so item 8 would otherwise be verified by nothing. Verify: `zig build test` runs
      the `dir.zig`, `time.zig` and `futex.zig` tables in both modes.
- [ ] 7. `docs/adr/0002-offload-before-multi-carrier.md` and `src/offload.zig`: `offload_threads`
      workers (new required `Options` field) spawned in `init`, an intrusive request queue whose
      records live on the parked fiber's stack (bounded by `fibers_max`), completion through
      `Sched.unpark_foreign`, join in `deinit`. The ADR also records why `now`/`clockResolution`
      stay delegated (they never block; native buys nothing until a backend owns a clock).
      Verify: `src/offload.zig` tests — `fibers_max` fibers each offload a 20 ms blocking job and
      overlap; allocation counter flat after init (gate 5); `deinit` joins idle workers.
- [ ] 8. Offload the declared blocking set — `dir*`, `file*`, `net*`, `operate`, `childWait` —
      through comptime thunks built from each `VTable` field type in `src/runtime.zig`, still the
      only file naming slots. A pending cancel is checked before submit when the error set has
      `Canceled`; once submitted the call completes, as ADR 0001 allows. Excluded, reasons in
      ADR 0002: `batch*` (Threaded's own concurrency), `*Stderr` (thread-owned lock), `process*`
      (process-global state). Verify: fiber A `netAccept`s while fiber B `netConnectIp`s on one
      `rt.io()` over loopback (deadlocks on v0.3.0); `dir.zig` in-fiber parity; a comptime test
      that each thunk's type equals its field type.
- [ ] 9. Reconcile README (drop "stalls every fiber"), CHANGELOG, PRD §4.1/§4.3/§5 with what
      shipped, bump `build.zig.zon` to 0.4.0 and release. Verify: `gh release view v0.4.0`.

`blocked_by`: none — zero-dependency foundation, and no kingdom repo pins sirocco yet.

## Out of scope

- Multi-carrier scheduling, work stealing, a truthful `concurrent`/`groupConcurrent` (both stay
  `ConcurrencyUnavailable`): with the kqueue/epoll plan, per ADR 0002.
- `src/backend/*` and native P3/P4/P5/P6. Offload is the hybrid's transport, not their
  implementation; each slot still leaves the offload set when it turns native.
- Interrupting an offloaded call mid-syscall: Threaded's cancel state is per Threaded task and
  knows nothing of fibers. Native `now`/`clockResolution`. Fibers beyond aarch64/x86_64.

## Risks

- Eager start changes observable order; tests that encode lazy FIFO start encode a detail std
  does not promise and are rewritten to assert the contract, not deleted.
- A bounded pool can deadlock where Threaded would spawn a thread: with `offload_threads = 1`,
  an accept holds the only worker while its connect waits behind it. Mitigation: ADR 0002 and
  the `Options` doc state the sizing rule; item 8 includes a test that names this case.
- Offload workers call Threaded's function with Threaded's userdata and never `rt.io()`, so
  `carrier_active` stays false on them; `offload.zig` asserts it, as plan 002 item 6 learned.
- `src/sched.zig` is 757 lines against the 800-line tidy limit: wheel and pool get their own
  files and item 4 deletes the timers hook. Timing tests use >= 2x bounds under gate 9's limit;
  bench numbers come from the aarch64 dev box in ReleaseFast, as gate 6's did.

## Done when

- `zig build test` and `zig fmt --check src bench build.zig tools tests` are green on the Linux
  and macOS CI jobs, and `zig build tidy` reports zero violations with every `src/` file < 800.
- `tests/parity/slots.zig` lists 16 names as `native` (P0 + P1 + `sleep`), and the suite passes
  again under `.unimplemented = .fail`.
- PRD §5 holds passing gate 6 rows at 1 and 1000 in flight and a gate 7 row; gates 8 and 9 hold.
- The loopback accept/connect test from item 8 is green on both CI runners.
- Zero open `bug` issues; milestone issue for plan 003 closed; `v0.4.0` tagged and released.

## Version impact

**MINOR — v0.3.0 → v0.4.0.** `Options.offload_threads` is a new required field, so every
`Runtime.init` call site breaks, and `async` start order changes observably. Per
`citadel/protocol/VERSIONING.md` foundation repos stay `0.x` until two consumers depend on them,
and MINOR may break during `0.x`; no `build.zig.zon` in the kingdom pins sirocco, so MAJOR would
be noise. Zig stays pinned at 0.16.0, so the toolchain MAJOR rule does not apply.
