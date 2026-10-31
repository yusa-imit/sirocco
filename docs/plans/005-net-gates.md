# Plan 005 — net-gates

## Goal

Close the two PRD §5 gates v0.5.0 missed: gate 1 (echo throughput at 1000 connections) and
gate 4 (memory per idle connection), each fix following a profile. Run sirocco on N carriers
(ADR 0003 rule 1). Land item 8b from plan 004: a waiter node per operation, so an idle batch
parks on the poller instead of polling in wheel slices. Finish plan 004's review leftovers.

## Why now

v0.5.0 ships with gate 1 at 0.83x-0.87x of `Io.Threaded` against a 2.0x target, and gate 4 at
29.2 KB against 24.7 KB per idle task (ADR 0003 sections 4a and 4b). Gate 3 missed in one run
of eight. Section 4a says one carrier is core-bound (28.8 s in the kernel against 3.4 s in user
code), but that is an inference: `sample(1)` hung on the bench. ADR 0003 promised the profile
and then multi-carrier as plan 005. No consumer pins sirocco yet and zoltraak is still on its
`001` migration, so a breaking `Options` change is cheapest now.

## Scope

- [x] 1. Profile `zig build bench-echo` at 1000 connections, ReleaseFast, kqueue. Use
      `xctrace record --template 'Time Profiler'`, or `dtrace -n profile-997` as the fallback.
      Never use `sample(1)`, which hangs the bench. Record the carrier's time share in `kevent`
      (arm and wait), socket syscalls, fiber switches, offload and std's `Io` call chain.
      Why first: items 6-8 rest on section 4a's inference. Verify: ADR 0003 gets a section 4c
      with the table and the trace command. If kernel time is under 60% of the carrier's time,
      4c names the hot spot, and item 2 decides whether to fix it before multi-carrier.
- [x] 2. `docs/adr/0004-multi-carrier.md` (architect, opus). Contents:
      `Options.carriers` and its validation; placement (a fiber stays on the carrier whose
      poller holds its sockets); cross-carrier futex wake, `await`, cancel and close on
      `unpark_foreign`; registry per carrier or shared; work stealing (never-started fibers
      only, or none, with the reason); the 8b `Waiter` node (prev, next, fiber, outcome, pool
      sized at `Runtime.init`) and its changes to `cancel`, `close_on_carrier`,
      `close_off_carrier`, `closing_finish` and `on_event`.
      Why one ADR: both change who owns `src/net_registry.zig`'s waiter lists. Verify: the ADR
      is merged and names one construction path, the item 1 numbers, and a gate-5 argument.
- [x] 3. Bring `src/sched.zig` (695 lines) and `src/concurrency.zig` (725) well under the
      800-line tidy cap, by moving tests or a cohesive helper module the way plan 004 item 1 did.
      Why here: items 4-6 grow both files. Verify: `zig build tidy`; `wc -l src/*.zig` all
      < 650; the `zig build test --summary all` test count is unchanged.
- [x] 4. 8b part 1: the registry's waiter lists hold `Waiter` nodes from the ADR 0004 pool
      instead of `*Fiber`. Behaviour does not change. Verify: the full suite is green under
      `.kqueue` and `.threaded`; `tests/parity/net_close.zig` and the cancel-after-wake test
      from #49 pass; allocations are flat after init (gate 5); the ubuntu CI job (epoll) is
      green. Budget one CI round trip, because epoll is CI-only.
- [ ] 5. 8b part 2: in `src/batch.zig`, an awaiting fiber holds one `Waiter` per op and parks
      on poller + wheel. The 50 us-2 ms wheel slices and their `recvmsg` per slice go away
      (ADR 0003 section 2c is amended). Verify: `tests/parity/batch.zig` still matches. A new
      test shows an idle 64-socket batch makes no `recvmsg` between arming and the first event.
      `zig build bench-echo` gate 2 stays >= 0.9x. ubuntu CI is green.
- [ ] 6. Add `Options.carriers` as ADR 0004 specifies. `Runtime` builds `carriers` `Sched`s,
      each with its own `Poller`, wheel and carrier thread, all allocated in `init`.
      `carriers = 1` behaves as v0.5.0. Verify: `tests/parity/fixtures.zig` runs the suite at
      1 and 2 carriers on `.kqueue` and `.epoll` (CI). Gate 5 holds. Gate 7 is re-run at 2.
- [ ] 7. Cross-carrier correctness: futex wake, `await` and cancel of a fiber on another
      carrier, and a socket closed from another carrier. Verify: a seeded model test at 4
      carriers (style of `tests/parity/futex_model.zig`, fixed seeds in CI), the parity suite at
      4 carriers, and 1000 serial runs of the built test binary with no hang (not looped
      `zig build test`: cached re-runs test nothing).
- [ ] 8. Placement and stealing, as ADR 0004 decides, for `async`, `concurrent` and
      `groupConcurrent`. Verify: 1000 `concurrent` tasks at 4 carriers spread within the ADR's
      imbalance bound (a counting test). If the ADR adopted stealing, a test shows a carrier
      with no work picks up a never-started fiber.
- [ ] 9. Re-measure gates 1, 2 and 3 with `carriers` equal to the core count and with 1. Run
      gate 3 eight times, and explain or reproduce the 422k us p99 tail. Verify: PRD §5 rows and
      an ADR 0004 measurement section. Gate 2 >= 0.9x is fixed in this item. A gate-1 miss is
      recorded with a profile, and the gate is never lowered and N is never cut.
- [ ] 10. Gate 4: measure resident bytes per idle task at 1000, 2000, 5000 and 10000
      connections with `footprint` or `vmmap --summary`. Split the figure into fiber stacks
      (the bench's 128 KB stack, touched pages), registry, poller table and heap. Fix it here if
      the cause is sirocco's. Why: 14.4 KB at 2000 against 29.2 KB at 10000 is not flat in N.
      Verify: ADR 0003 section 4b gets the breakdown and the PRD §5 gate-4 row is re-measured.
      A fix too big for one cycle opens an issue naming the cause, for plan 006.
- [x] 11. Leftovers, each with a test that fails first: a test cancels a parked `concurrent`
      future (`tests/parity/concurrency.zig`); the three `wait_err` switches in
      `src/submit.zig` list every member instead of `else`; `lease_release` checks the slot
      generation `lease` returned, so a release after a foreign close and fd reuse cannot drop
      another file's lease. Already fixed (checked 2026-10-27): the registry `spin_max` bound and
      the `catch unreachable` at `net_registry.zig:160`. Verify: the new tests; `zig build tidy`.
- [ ] 12. Bring README, CHANGELOG `[0.6.0]`, PRD §4.1 (`Options`) and §5 into line with what
      shipped; bump to 0.6.0 and release. Verify: `gh release view v0.6.0`.

`blocked_by`: none.

## Out of scope

- The consumer swap (ADR 0001 rule 5, ROADMAP Phase 2: swap `Io` at zoltraak's `main`).
  zoltraak has not finished its `001` migration, so it is a zoltraak plan.
- io_uring, IOCP and Windows; moving a fiber that holds armed sockets to another carrier.
- Changelist batching of arms, unless item 1 shows arm syscalls dominate.
- A cancel for the overflow worker's `poll(2)` (ADR 0002 lets a submitted call complete) and
  `poll_block`'s infinite timeout (off a fiber only, as in `Io.Threaded`).

## Risks

- Item 1 may show the carrier is not core-bound; then item 2 records it and asks the owner
  on the milestone issue before item 6 starts.
- Cross-carrier races hide behind single-carrier tests. Mitigations: the seeded model test,
  serial stress of the built binary (item 7), the parity suite at several carrier counts.
- Gate 2 has a margin of 0.01: items 4-6 re-run `bench-echo` before they merge.
- epoll is CI-only, and each fix costs a CI round trip. Mitigations: local Linux
  cross-compile, draft PRs.
- Gate 1 may still miss at N carriers if the kernel serializes loopback. Item 9 records it.

## Done when

- `zig build test`, `zig fmt --check` and `zig build tidy` are green on the ubuntu and macOS
  CI jobs, and every `src/` file is under 800 lines.
- ADR 0004 is merged; the parity suite passes at 1, 2 and 4 carriers; `src/batch.zig` has no
  wheel-slice wait loop.
- PRD §5 has multi-carrier rows for gates 1-4. Gates 2, 3 and 5 pass. Gates 1 and 4 pass, or
  ADR 0003/0004 records the profiled cause of the miss.
- There are zero open `bug` issues, the plan 005 milestone issue is closed, and `v0.6.0` is
  released.

## Version impact

**MINOR, v0.5.0 → v0.6.0.** `Options.carriers` is a new field. It follows `sockets_max` and
is required, so the option is passed at the call site (Tiger Style rule 4). That breaks every
`Runtime.init` call site, which `citadel/protocol/VERSIONING.md` allows as MINOR during `0.x`.
No `build.zig.zon` pins sirocco. The Zig pin stays 0.16.0, so the toolchain MAJOR rule does not
apply. The batch wake change is behaviour only: an idle batch now wakes on the event instead
of within 2 ms.
