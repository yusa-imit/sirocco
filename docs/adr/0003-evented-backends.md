# 0003 — evented backends: one poller per scheduler, sockets owned by the `Io` that made them

- Status: proposed — merging the plan 004 item 2 PR accepts it; item 10 may append the
  "Gate 1 on one carrier" section, and a comment on the plan 004 milestone issue reopens it
- Date: 2026-10-13
- Plan: `docs/plans/004-evented-net.md`, items 2 to 6 and 10
- Builds on: ADR 0001 (hybrid vtable), ADR 0002 (offload before multi-carrier)

## Context

On v0.4.0 the carrier never blocks, but every socket call is offloaded: two thread hand-offs,
and a worker held until the call returns. 1000 idle connections need 1000 workers, which is
`Io.Threaded` with extra steps. std 0.16.0's `Io.Kqueue` does not compile (ADR 0001), so
sirocco writes its own readiness layer. ADR 0002 deferred multi-carrier scheduling to this plan
so that placement follows the poller.

The pieces it must fit: one carrier per `Runtime`; `Sched.park`/`unpark` on the carrier and
`Sched.unpark_foreign` (a lock-free inbox plus a futex word) from other threads; a timing wheel
that reports the next deadline; no allocation after init (PRD gate 5); and only `src/backend/*`
touches OS APIs. This ADR decides what the poller is and who owns it, how the carrier idles,
which descriptors may be armed, what kqueue and epoll share, and what happens when one carrier
is not fast enough.

## Decision

### 1. One `Poller` per `Sched`

- A `Sched` built for an evented backend (`.kqueue`, `.epoll`) owns exactly one `Poller`,
  initialised in `Sched.init` and torn down in `Sched.deinit`. Under `.threaded` there is none,
  and the futex idle path is unchanged.
- The carrier idles in `Poller.wait`. `run_loop` drains the inbox and fires the wheel. With no
  fiber ready it waits with `timeout_ns` = the wheel's next deadline minus now, rounded up
  (`null` when no deadline exists). It then unparks the fiber each event names before it
  dispatches again. With fibers always ready, the carrier still calls `wait(0, ...)` at least
  once every `fibers_max` dispatches, so a busy run queue cannot starve sockets.
- `unpark_foreign` pushes onto the inbox and then calls `Poller.wake`. The wake is latched: a
  wake that lands before the carrier enters `wait` makes that `wait` return at once. So no wake
  is lost between the inbox drain and the wait, and the evented path does not need
  `inbox_version`.
- Every `Poller` function except `wake` is carrier-only. One poller per `Sched` also fixes plan
  005's placement rule in advance: a socket is served by the carrier whose poller armed it.

### 2. The `Poller` contract

`src/backend/poller.zig` holds the shared types: `Interest`, `Event`, `Options`, `InitError`,
`ArmError`, `events_max`, `registrations_max_limit`, `key` (the table key of a pair), the
bounded `Table`, and `contract(comptime Poller: type)`.
`kqueue.zig` and `epoll.zig` each declare `const Poller = @This();` and call
`comptime shared.contract(Poller)`. The check requires every public declaration to exist with
exactly the type `poller.zig` spells out (`init`, `deinit`, `arm`, `disarm`, `is_armed`,
`wait`, `wake`), so drift between backends is a compile error on the job that compiles them.

- `deinit` has the precondition that the table is empty (`table.count == 0`): callers disarm
  every pair first, which `netClose` and fiber teardown do anyway.

- `arm(fd, interest, token)` is one-shot (`EV_ONESHOT`, `EPOLLONESHOT`). It delivers at most
  one `Event` for the pair `(fd, interest)`, and then the registration is gone. Read and write
  on one fd are independent registrations with their own tokens. Arming a pair that is already
  armed is a contract breach and is asserted.
- `disarm(fd, interest)` is idempotent. After it returns, no later `wait` returns an event for
  that pair, including one already pending in the kernel.
- `wait(timeout_ns, out)`: `null` blocks until an event or a wake; `0` polls. Otherwise it
  returns no earlier than `timeout_ns`, unless an event or wake arrives first. It may return 0
  spuriously (a wake, `EINTR`), and the caller loops. It never reads a clock: the wheel owns
  time. It returns at most `@min(out.len, events_max)` events: a longer `out` is clamped, not
  rejected (`out.len >= 1` is asserted), and events that do not fit stay pending.
- `wake()` may be called from any thread. It is latched and coalesced.
- `Event.hangup` means the kernel reported EOF or an error. The caller retries the syscall
  either way, and the syscall's result is the truth.
- Limits: at most `registrations_max` pairs are armed. The table is allocated in `init`, and
  `arm` on a full table returns `error.SystemResources` (kernel `ENOMEM` maps to the same
  error, as does `EINTR` after the bounded retries). An fd the kernel will not poll returns `error.Unpollable`, and the caller runs the
  offload thunk. Kernel errors only a caller bug can cause (`EBADF`, `ENOENT` on delete) are
  asserted.

There is no vtable. Only one evented poller compiles per target (kqueue on Darwin, epoll on
Linux; every other target, FreeBSD included, is `void` until its backend lands), and `wait`
is on the carrier's idle path, so `poller.Native` is chosen at comptime. The one runtime
choice, evented or `.threaded`, is a `switch` on `Runtime.backend`. FreeBSD fails to compile
std's `c.EV.EOF`, and OpenBSD and NetBSD lack `EVFILT_USER`, so kqueue is Darwin-only for now.

### 3. Socket ownership, and the registry for foreign fds (item 4)

- A socket that sirocco creates on a fiber (`netListenIp`, `netBindIp`, `netAccept`,
  `netConnectIp`, `netListenUnix`, `netConnectUnix`, `netSocketCreatePair`) is created
  `O_NONBLOCK | O_CLOEXEC`. It is entered in a registry of `Options.sockets_max` fds, a
  `poller.Table` keyed by fd and allocated at init.
- Such a socket is owned by the `Io` that made it (`rt.io()`). Passing it to `rt.baselineIo()`
  or to raw syscalls is a contract breach: Threaded's `net_receive` treats `WouldBlock` as
  `unreachable`. Parity tests never cross handles.
- Dispatch for every `net*` and `operate` slot:

  | handle | on a fiber | off a fiber |
  |---|---|---|
  | registered | syscall; would-block arms and parks; the event or a cancel ends the park | syscall; would-block blocks the calling thread in `poll(2)` on that fd |
  | foreign | v0.4.0 offload thunk | forward to `Io.Threaded` |

  A registered socket is never handed to `Io.Threaded`: Threaded would see `WouldBlock`. Off a
  fiber there is no carrier to protect, so blocking the calling thread is correct.
- At most one registration exists per `(fd, interest)`. The token is the socket's registry
  slot. More fibers waiting on the same pair join that slot's waiter list. The event unparks
  all of them, each retries, and a loser re-arms.
- sirocco never arms a foreign fd and never changes its `O_NONBLOCK` flag. The flag belongs to
  the open file description and is shared with every other holder. The one exception is item
  7: a file opened with `flags.nonblocking` was declared non-blocking by its caller, and may
  be armed on a fiber.
- When the registry is full, or a socket is created off a fiber, the socket is made blocking
  by the forwarded path and stays foreign for life. It works correctly but is offloaded, and
  ADR 0002's sizing rule applies to it.
- `netClose` (item 5) removes the registry entry, disarms both interests and unparks waiters
  with an error, all before `close(2)`. A reused fd number therefore never inherits a
  registration or a stale event.
- Item 4 as built: the registry is slots plus a `poller.Table` of fd -> slot, with a per-interest
  waiter list threaded through `Fiber.wait`. A cancel unlinks the waiter and disarms when the list
  empties; `Sched.events` carries the event handler. `netAccept` on a full registry returns the
  accepted fd switched back to blocking (it is held by nobody else), so it is foreign for life.
  `netClose` is native from item 4 (not 5): without it a closed fd would stay registered and a
  recycled fd number would be mistaken for a non-blocking socket. A registered fd that reappears
  in `register` is a stale entry and is replaced (it must hold no waiters: closing a registered
  fd behind the runtime while fibers wait on it is a caller bug and asserted). One lock guards
  the slots and every waiter list, and the poller is armed under it, so a close cannot slip
  between a lookup and an arm. A close on a fiber disarms, wakes the waiters with
  `error.SocketNotListening` and frees the slot before `close(2)`. A close from any other thread
  cannot touch the poller: it marks the slot closing and hands the waiters to `unpark_foreign`;
  each runs on the carrier, disarms its interest, and the last closes the fd. Option sets the native path does not serve
  (non-TCP listen/connect modes, a connect timeout, IPv6 interface scopes, abstract Unix paths,
  `ip6_only`/`allow_broadcast` binds) take the foreign path. `Socket.createPair` offers only IP
  families, which no kernel serves, so it fails with `Unexpected` on both `Io`s.
- `registrations_max` = 2 x `sockets_max`. `Runtime` derives it, and no `Options` field is
  added. Arms from items 7 and 8 share this table: when it is full, `batchAwaitConcurrent`
  returns `ConcurrencyUnavailable` and `batchAwaitAsync` works in rounds.

### 4. Gate 1 on one carrier (item 10)

Item 10 measures gate 1 (echo at 1000 connections, >= 2.0x `Io.Threaded`) and gate 2 (>= 0.9x
at 1) on one carrier. Both `Io`s come from one `Runtime`, built ReleaseFast on the dev box.

- **Pass:** the PRD §5 rows are recorded, and multi-carrier stays off the roadmap until a gate
  asks for it.
- **Gate-2 miss:** fixed inside plan 004, before v0.5.0.
- **Gate-1 miss:** not fixed in plan 004. The measured ratio and a profile go into a "Gate 1
  on one carrier" section of this ADR. The profile records the carrier's time share in
  `kevent`, in fiber switches, in offload and in std's `Io` call chain. The PRD row records
  the failure, v0.5.0 still ships, and plan 005 is multi-carrier: N carriers, each with its
  own `Sched` and `Poller` (rule 1). Work stealing and cross-carrier wake are designed there.
  The gate is never lowered, and N is never cut to make a number pass.

## Rejected alternatives

- **A `Poller` vtable for runtime backend choice.** Only one evented backend compiles per
  target, and an indirection on the idle path buys nothing. Revisit when io_uring sits beside
  epoll on Linux, which makes the choice a runtime one.
- **Persistent or edge-triggered registrations** (`EV_CLEAR` without one-shot, `EPOLLET`). A
  registration would outlive the parked fiber and need generation counters to filter stale
  events. One-shot plus disarm-before-close makes stale events impossible by construction. The
  cost is one `kevent` change per park, and gate 1 measures it.
- **Batching arms into the next `wait`'s changelist.** This saves a syscall per park but moves
  arm errors into `wait` and splits error ownership. It is deferred to plan 005, and only if
  the gate-1 profile shows arm syscalls dominate.
- **A wake pipe, or keeping the futex word for evented wakes.** `EVFILT_USER` and `eventfd`
  cost one syscall and do not need an fd pair.
- **Setting `O_NONBLOCK` on foreign fds.** It changes behaviour for every other holder of the
  open file description.
- **A growable registration map.** It breaks gate 5.
- **One poller per `Runtime`, shared by future carriers.** That needs locking in `arm` and a
  dispatcher thread. A per-`Sched` poller pins placement for free.
- **An absolute deadline in `wait`.** The poller would have to read a clock that the wheel
  already owns. The plan text's `wait(deadline, out)` becomes `wait(timeout_ns, out)`, and
  `init(gpa, registrations_max)` becomes `init(target, gpa, options)` (in-place init).

## Consequences

- `Options.sockets_max` becomes required (item 3). Every `Runtime.init` call site breaks:
  MINOR during `0.x`.
- An idle connection costs one fiber stack plus about 64 bytes of poller table and a registry
  entry. It holds no worker thread.
- A sirocco socket must not be passed to `baselineIo()` or to raw syscalls. The `Options` doc
  and the README say so.
- Sockets created off a fiber, or beyond `sockets_max`, are foreign: correct, offloaded, slow.
- Each park costs one extra syscall (the arm). The fairness poll costs one non-blocking
  `wait` per `fibers_max` dispatches.
- epoll lands in item 6 against the same contract and `poller_test.zig`, and drift is a
  compile error.
- Nothing changes under `.threaded`.
- Item 10's numbers, not this ADR, decide whether multi-carrier comes next.
- Plan 004 item 4's "off a fiber ... the v0.4.0 offload thunk runs" is superseded by the
  dispatch table in section 3.
