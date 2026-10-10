# 0002 — blocking slots go to an offload pool before sirocco gets more carriers

- Status: proposed — the deferral of multi-carrier scheduling is the human's call; a comment on
  the plan 003 milestone issue rejecting it reopens the question
- Date: 2026-10-11
- Plan: `docs/plans/003-carrier-never-blocks.md`, items 7 and 8
- Builds on: ADR 0001 (hybrid vtable), plan 002 (single-carrier fibers)

## Context

On v0.3.0 every fiber runs on one carrier thread, and every slot sirocco has not made native
still forwards to `Io.Threaded`, which blocks the calling thread inside the kernel. A fiber in
`dirOpenFile`, `fileReadStreaming` or `netAccept` therefore freezes every other fiber, and a
server that accepts on one fiber and connects or serves on another deadlocks. Plan 003 removes
the stall in steps: `sleep` and futex timeouts are native on a timing wheel (items 3 to 5);
this ADR covers the rest.

Two ways to stop a blocking call from freezing the carrier:

1. **More carriers.** Run `N` scheduler threads; a blocked call freezes one of `N`.
2. **Offload.** Keep one carrier; run the blocking call on a worker thread while its fiber
   parks, and wake the fiber when the call returns.

## Decision

**Offload first. Multi-carrier scheduling is deferred to the plan that adds the kqueue/epoll
backends.**

- `src/offload.zig` is a bounded pool: `Options.offload_threads` workers (required, positive)
  spawned in the first `io()` and joined in `deinit`. A request record lives on the parked
  fiber's stack, so the queue is bounded by `fibers_max` and nothing allocates after init.
  Completion is `Sched.unpark_foreign`, which plan 002 built for exactly this.
- Item 8 routes the declared blocking set (`dir*`, `file*`, `net*`, `operate`, `childWait`)
  through it with comptime thunks built from each `VTable` field type in `src/runtime.zig`.
  Called off a fiber (no scheduler running), a slot still forwards directly: there is no
  carrier to protect.
- A started call completes. `Io.Threaded`'s cancel state is per `Threaded` task and knows
  nothing of fibers, so sirocco checks a pending cancel before submitting and cannot interrupt
  a call already on a worker. ADR 0001 allows a started call to complete.
- **Sizing rule.** A job holds its worker until it returns. Calls that wait on each other (an
  `accept` on a `connect`) deadlock when `offload_threads` is smaller than the number of such
  calls in flight; `Options` and the `//!` header of `offload.zig` say so, and item 8 tests the
  loopback pair with the smallest sufficient pool.

### Why not multiple carriers now

Multiple carriers are a throughput feature (PRD gate 1: 2.0x `Io.Threaded` echo at 1000
connections), not a correctness one. They also need work stealing or per-carrier run queues,
cross-carrier futex and cancel protocols, and a decision on which carrier owns a socket. The
right owner of that decision is the backend plan: with kqueue/epoll each carrier owns one
poller and a fiber stays on the carrier whose poller holds its descriptors. Building the
carriers first would fix a placement policy before the thing it places exists.

### Slots that stay out of the offload set

| Slots | Reason |
|---|---|
| `batch*` | Threaded's own batch machinery already runs its operations concurrently. |
| `lockStderr`, `tryLockStderr`, `unlockStderr` | The lock is owned by a thread; locking on a worker and unlocking on the carrier would unlock a lock the carrier never held. |
| `process*`, `child*` except `childWait` | Process-global state (signal handlers, the environ block) with no blocking wait. `childWait` blocks and is offloaded. |
| `now`, `clockResolution` | They never block. A native version buys nothing until a backend owns a clock. They stay delegated. |
| `random`, `randomSecure` | They never block for a meaningful time. |

## Consequences

- No fiber stalls on a forwarded blocking slot once item 8 lands, with no backend and no
  second carrier.
- Offload costs two thread hand-offs per call (about 10 to 50 microseconds), acceptable for
  calls that block for milliseconds and the reason P3/P4 still make `net*` and `file*` native.
- `Options` gains a required field, so `Runtime.init` call sites break: MINOR in `0.x`.
- Each slot leaves the offload set when it turns native.
- Observed during item 7 (cause not investigated): 16 concurrent `Io.sleep` calls of 20 ms on
  `Io.Threaded` took 160 ms on the aarch64 dev box, so its sleep does not overlap well; this
  may relate to the slow Threaded row of PRD gate 7. Tests that need concurrent blocking jobs
  use a futex timeout as the timer.
