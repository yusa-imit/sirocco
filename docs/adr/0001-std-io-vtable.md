# 0001 — sirocco is an implementation of `std.Io.VTable`

- Status: accepted
- Date: 2026-09-08
- Plan: `docs/plans/001-zig-0.16-and-tiger-baseline.md`, item 7
- Supersedes: `docs/PRD.md` §4.1 (`Loop` sketch), §4.2–§4.5 as public surface, §5

## Context

sirocco was scoped in 2025 as a hand-rolled completion-based I/O stack: its own `Loop`,
`Completion`, `Op` and `Result` types, kqueue/epoll/io_uring/IOCP backends, and a public
`io` -> `net` -> `tls` -> `http`/`ws` layering that consumers would import directly.

Zig 0.16.0 shipped `std.Io`: a runtime vtable value (`Io = struct { userdata: ?*anyopaque,
vtable: *const VTable }`) with 109 slots. `std.net` was deleted; most of `std.fs`, most of
`std.time`, and every `std.Thread` synchronisation primitive were deleted from their old
namespaces and reborn as `Io.net`, `Io.Dir`/`Io.File`, `Io.Clock`, `Io.Mutex`/`Io.Group`/
`Io.Queue`. `std.http.Client` and `std.crypto.tls.Client` both dispatch through the same
vtable. Every kingdom consumer — silica, zoltraak, sailor, zr, synod — is migrating to take
`io: std.Io` as a parameter, and `main(init: std.process.Init)` hands one out pre-built.

The old design and `std.Io` overlap almost completely, and where they overlap they disagree
on vocabulary: the old PRD spells cancellation `error.Cancelled`; std spells it
`error.Canceled`, one `l`, and rides it in nearly every I/O error set.

std does not, however, make sirocco redundant. Measured against the pinned 0.16.0 toolchain:

| implementation | compiles | networking | notes |
|---|---|---|---|
| `Io.Threaded` | yes | complete | thread-pool backed; the only shippable std `Io` |
| `Io.Dispatch` (Darwin `Evented`) | yes | every `net*` slot is `…Unavailable` | GCD-backed |
| `Io.Uring` (Linux `Evented`) | **no** | every `net*` slot is `…Unavailable` | error-set mismatches at `Uring.zig:2732`, `:3157` |
| `Io.Kqueue` (BSD `Evented`) | **no** | real `net*` implementations | references `fileWriteStreaming`, a slot the shipped `VTable` no longer has |

So on the kingdom's pinned toolchain there is no evented `Io` with working networking on any
platform. That gap — not "an event loop" — is sirocco's reason to exist.

## Decision

**sirocco is an implementation of `std.Io.VTable`. It exposes no parallel I/O API.**

The entire public surface of the library is one runtime object and the `std.Io` it hands out:
`Runtime.init` / `Runtime.deinit` / `Runtime.io()` / `Runtime.Options`. Everything a consumer
does with sirocco, it does through `std.Io`, `std.Io.net`, `std.Io.File`, `std.http`,
`std.crypto.tls` — types it already uses. Nothing new to learn, and a consumer can swap
sirocco in or out at one line in `main`.

Concretely:

1. **Two bases, two purposes.** The runtime vtable is a by-value copy of `Io.Threaded`'s
   vtable with sirocco's slots written over it; `Io.userdata` is the address of an embedded
   `Io.Threaded` field, and sirocco recovers its own state with
   `@fieldParentPtr("threaded", t)`. Forwarded slots therefore cost zero indirection — they
   are Threaded's own function pointers. `Io.failing` is the *test* base: under
   `Options.unimplemented = .fail`, every slot sirocco has not implemented is installed from
   `Io.failing`, so a test that accidentally depends on the fallback fails loudly instead of
   silently passing on Threaded.
2. **The hybrid is declared, not hidden.** `dir*` (26 slots), `process*`/`child*` (11),
   `random`/`randomSecure` (2), `progressParentFile` (1) forward to the embedded `Threaded`
   until sirocco implements them. `Options.unimplemented` is in the public API precisely so
   the forwarding set is visible at the call site and testable.
3. **Cancellation vocabulary is std's.** `Io.Cancelable`, `error.Canceled` (one `l`),
   `recancel`, `swapCancelProtection`, `checkCancel`, `CancelProtection.{unblocked, blocked}`.
   sirocco defines no cancellation type of its own. `error.Cancelled` is a defect wherever it
   still appears.
4. **Backends are internal.** kqueue, epoll and (later) io_uring/IOCP are private modules
   under `src/backend/`; no consumer names them. `Options.backend` selects one by enum, with
   `.threaded` always available as a correctness fallback.
5. **Acceptance is a swap, not a demo.** sirocco "works" when one real kingdom service's
   `main` changes `init.io` to `rt.io()` and its existing test suite passes unchanged.
6. **Every slot is differential-tested** against `Io.Threaded`. Both `Io` values come from the
   same `Runtime` object (`rt.io()` and `rt.baselineIo()`), so the harness has one
   construction path.

## What this obsoletes

- **PRD §4.1, the `Loop` sketch** — `pub fn submit(*Completion)` / `cancel` / `run(mode)` /
  `stop`, and the caller-owned intrusive `Completion` with a callback field. Deleted. std
  already owns this shape: `Io.Operation` is the op union, `Io.Operation.Storage` is the
  caller-owned intrusive node (no per-op allocation), `Io.Batch` is the submission set, and
  `batchAwaitAsync` / `batchAwaitConcurrent` / `batchCancel` are submit/run/cancel. sirocco
  implements those slots; it does not define a competing vocabulary for them.
- **PRD §4.2–§4.5 as a public surface.** `sirocco.net`, `sirocco.tls`, `sirocco.http`,
  `sirocco.ws`, `sirocco.task` are removed from `src/root.zig`. Consumers reach the same
  functionality through `Io.net.IpAddress.listen(io, .{})`, `std.crypto.tls.Client.init`,
  `std.http.Client{ .io = io }`, `Io.Group`, `Io.Queue` — all of which run on sirocco's vtable
  for free. The *internal* layering survives as file organisation: `src/net.zig` implements
  the 16 `net*` slots, `src/file.zig` the 28 `file*` slots, and so on. Layering as
  organisation, yes; layering as API, no.
- **PRD §5, the absolute performance table.** 1M req/s echo, 500k req/s HTTP, p99 < 1ms,
  < 8KB/conn, < 1ms cold start. Deleted, not re-targeted at the same numbers: two of the five
  measured a stack sirocco no longer ships, and none was ever measured. Replaced by ratio
  gates against `Io.Threaded` on the same machine and the same benchmark, because that is the
  only comparison that decides whether sirocco is worth linking. See the rewritten §5.
- **`error.Cancelled`** everywhere in `docs/` and `citadel/realms/sirocco/REALM.md`.
- **PRD §7's "callback first, coroutine later"** — the concurrency model is `io.async` /
  `io.concurrent` / `Io.Future` / `Io.Group`, decided by std.

## Alternatives considered

**A. Keep the old design; write a `std.Io` adapter later.** Rejected. Every operation would be
implemented twice — once behind `Loop.submit`, once again in the vtable slot that must map
`Io.Operation` onto it — and the seam between the two op vocabularies is where the
cancellation and deadline bugs would live. The PRD would describe an API no consumer speaks:
all five consumers already take `io: std.Io`, so adopting sirocco would mean *un*-migrating
them off std types. sirocco would also have to re-implement `http`, `tls`, DNS and address
parsing that it gets for free by filling in slots, and it would fork the cancellation
vocabulary (`Cancelled` vs `Canceled`) — a divergence already present in today's docs.

**B. Fix `std.Io.Uring`/`std.Io.Kqueue` upstream instead of shipping sirocco.** Rejected as
the primary answer: the kingdom is pinned to 0.16.0 and cannot gate a foundation realm on
upstream review latency, and upstream's `Evented` has no networking on any platform even once
it compiles. Adopted as a secondary output — defects found while implementing a slot are worth
an upstream report — with the hard constraint that sirocco vendors no patched copy of std.

**C. Ship a thin wrapper over `Io.Threaded` with tuned options.** Rejected as the product; it
adds nothing over std. Retained as `Options.backend = .threaded`, so sirocco always has a
correct configuration to fall back to and to differential-test against.

**D. Implement all 109 slots natively before shipping anything.** Rejected. The declared
hybrid reaches a usable networking runtime in ~70 slots; `dir*`/`process*` gain little from an
evented backend and would delay the acceptance swap by a milestone or more.

## Consequences

**Good.**
- Consumers learn nothing new. The migration diff at a service is one line in `main`.
- `std.http.Client`, `std.crypto.tls.Client`, `Io.net`, `Io.Dir`/`Io.File`, `Io.Group`,
  `Io.Queue` all start working on sirocco the moment the slots underneath them land.
- Correctness has an oracle. `Io.Threaded` is a complete, independent implementation of the
  same contract, so "same input, same result" is a mechanically checkable specification for
  all 109 slots — not a specification sirocco wrote for itself.
- sirocco is never all-or-nothing: partial slot coverage still produces a working runtime.

**Bad, and accepted.**
- **The public API is a std type.** A `VTable` change in 0.17 is a forced rewrite, and this is
  not hypothetical — it is exactly what broke `Io.Kqueue` and `Io.Uring` inside 0.16.0.
  Mitigation: one slot per function, grouped one concern per file, assembled in a single
  `src/runtime.zig`; the toolchain is pinned to 0.16.0 exactly; a slot-count assertion
  (`@typeInfo(Io.VTable).@"struct".fields.len == 109`) fails the build loudly on any std bump.
- **Forwarded slots block a carrier thread and ignore sirocco's cancellation.** A fiber that
  calls `dirOpenFile` occupies its carrier until the syscall returns, and Threaded's per-task
  cancel state does not know about sirocco's fibers, so cancelling such a call is best-effort:
  the call runs to completion and its result is discarded. This is a documented limitation of
  the hybrid with a defined exit — it ends per slot, when that slot goes native.
- **`io.async` may run inline.** sirocco must honour the std contract that `async` promises
  completion and only `concurrent` promises concurrency; sirocco may not "helpfully" make
  `async` always concurrent, because consumers written against std may rely on either.
- **sirocco constructs an `Io`, which library code is otherwise forbidden to do.** The rule's
  intent survives: sirocco provides the *type*, and only the consumer's `main` constructs it.
- **Fibers are not universal.** `std.Io.fiber.supported` is true only for aarch64, riscv64 and
  x86_64. Elsewhere `Options.backend = .auto` must resolve to `.threaded` and still compile —
  an unconditional reference to `Io.Evented` fails to build on unsupported targets.
- **The macOS CI gap becomes blocking.** kqueue is the first backend and cross-compiling
  catches no runtime backend bug. Plan 001 deferred this; the next plan cannot.
- **The acceptance target is not ready yet.** silica and zoltraak are last in the kingdom's
  0.16 migration order, so the swap-at-`main` test lands after they do; synod is 0.16-shaped
  today but exercises no networking.

## Reference

Slot names and line numbers verified against the pinned toolchain:
`/Users/fn/.zr/toolchains/zig/0.16.0/lib/std/Io.zig` (`VTable` at line 51, `Batch` 474,
`Cancelable` 704, `Clock` 721, `Timeout` 1132, `Group` 1218, `CancelProtection` 1322,
`failing` 2512), `Io/Threaded.zig` (`init` 1607, `io` 1806), `Io/fiber.zig` (`supported`
line 1). The slot grouping and priority order live in `docs/PRD.md` §4.
