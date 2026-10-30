# 0004 — multi-carrier: N schedulers, a shared registry with per-carrier arms, one waiter per op

- Status: proposed. Merging the plan 005 item 2 PR accepts it. Item 9 fills the measurement
  section, and a comment on the plan 005 milestone issue reopens it.
- Date: 2026-10-31
- Plan: `docs/plans/005-net-gates.md`, items 2 and 4 to 9
- Builds on: ADR 0001 (hybrid vtable), ADR 0002 (offload), ADR 0003 (rule 1, sections 2c, 3,
  4a-4c)
- Amends: ADR 0003 sections 1 ("one carrier per `Runtime`"), 2c (batches) and 3 ("one lock")

## Context

v0.5.0 runs every fiber on one carrier: the thread that calls `async` or `await` outside a
fiber drives `Sched.run_loop` (`src/concurrency.zig` `task_finish`, `Sched.run_until`). Gate 1
misses at 0.83x-0.87x of `Io.Threaded` (ADR 0003 section 4a). Section 4c profiled the carrier
in process. 78% of its CPU time is in the kernel and 90% of its wall time is inside five
syscalls. Each echo costs 4 reads (2 of them `EAGAIN`), 2 writes and 2 one-shot `kevent` arms.
The untimed rest (fiber switches, scheduler, std's `Io` chain, user code) is 8.7%-9.4%. That is
above the plan's 60% line, so no user-space hot spot needs fixing first, and plan risk 1 (ask
the owner) is not triggered. Removing the two `EAGAIN` reads and the two arms would bring one
carrier to about 1.3x, still short of 2.0x. Throughput has to come from more cores.

Five pieces of code assume one carrier. `Sched` keeps a threadlocal `carrier_active: bool`.
`Runtime` embeds a single `sched: Sched`. `futex.Table.wake` picks direct `unpark` when
`sched.in_fiber()`. `Registry` (`src/net_registry.zig`) links `*Fiber` through
`Fiber.wait.prev/next` under one `std.atomic.Mutex`, with the arm made under that lock.
`task_request_cancel` calls `sched.unpark` on whatever fiber `task.waiting` names. And
`src/batch.zig` cannot park on N sockets because a fiber has one `Wait`, so it sleeps in wheel
slices (50 us doubling to 2 ms) and calls `recvmsg` on every op in every slice. Changing any of
these changes who owns the registry's waiter lists, so this ADR decides all of them together.

## Decision

### 1. `Options.carriers`, and construction in `Runtime.init`

- `carriers: u32` is required and has no default (Tiger Style rule 15, like `sockets_max`).
  `Runtime.init` asserts `1 <= carriers <= carriers_max`. `pub const carriers_max: u32 = 64` is
  public so that a caller who derives the count from `std.Thread.getCpuCount` can clamp it
  first. 64 is the width of `Slot.armed` (section 4), which is the reason for the bound.
  Options are the programmer's constants, so a bad value is a contract breach, asserted like
  `sockets_max`. It is not a returned error.
- `fibers_max` becomes **per carrier**. Each `Sched` is one unit with its own fiber table, so a
  divisibility rule or a rounding policy is never needed. The memory cost is written once in
  the `Options` doc: `carriers * fibers_max * fiber_stack_size` bytes of stack.
  `sockets_max` stays a **runtime total**, because the registry is shared (section 4).
- `batch_ops_max: u32` is new and required. It counts `Waiter` nodes per carrier beyond the one
  each fiber owns (section 6). 0 is valid and serves no batch natively.
- Every allocation moves into `Runtime.init`. Each `Sched` lives in a heap block
  (`carriers: []Carrier`, `Carrier = struct { sched: Sched, thread: ?std.Thread }`), so fibers
  point at stable memory, and the reason v0.5.0 built the scheduler lazily at the first `io()`
  goes away. Per carrier, `init` allocates the fiber table, the stack arena, the wheel nodes,
  the poller table (evented only) and the waiter pool. Once per runtime it allocates the
  carrier array, the offload handles and the registry's slots and table. That is
  `5 * carriers + 4` blocks evented and `3 * carriers + 2` under `.threaded`.
  `Sched.Options.now_ns` is read from `Io.Threaded.global_single_threaded.io()`, which needs no
  pinned `Runtime`.
- Per carrier, `Sched.Options.idle` becomes `.poller` with
  `registrations_max = @min(2 * sockets_max, fibers_max + batch_ops_max)`. A carrier holds a
  registration only while one of its own nodes waits on that pair (section 4), so its node
  count bounds it.
- The first `io()` allocates nothing. It pins the runtime, installs the handlers that point
  into the `Runtime` (`Sched.events = &rt.sockets`, `Sched.expiry = &rt.waits`, as
  `sched_ensure` does today), spawns the offload workers, and spawns threads for carriers
  `1..carriers-1`. Each such thread runs `Sched.run_until(io, &rt.stop)`. Carrier 0 has no
  thread: the driver (the thread that calls `async`/`await` outside a fiber) runs it, exactly
  as in v0.5.0. If a thread fails to spawn, the threads already started are joined and the
  runtime is left `.unavailable`, as an offload spawn failure does today.
- `InitError` gains `OutOfMemory`, `ProcessFdQuotaExceeded`, `SystemFdQuotaExceeded` and
  `SystemResources`. An out-of-memory scheduler build used to fall back to `.unavailable`. It
  now fails `init`.
- `deinit` precondition: every future was awaited and every carrier has `live_count == 0`. It
  stores `rt.stop` (`.release`), calls `notify` on carriers 1..N-1, joins them, and then runs
  each `Sched.deinit`.
- `carriers = 1` schedules exactly as v0.5.0 did. No thread is spawned, placement always picks
  carrier 0, `spawn_first` still starts work eagerly, nothing is ever mailed, `Slot.armed` has
  one bit, and every futex wake takes the direct path. Two things differ from v0.5.0 even at 1:
  the block count and `InitError`.

### 2. Placement

A fiber runs only on its home carrier, from birth to exit. A socket pair is held by the poller
of the carrier whose waiter armed it (section 4), so the rule "a fiber stays on the carrier
whose poller holds its sockets" holds by construction. No fiber ever migrates.

| slot | carrier chosen | start |
|---|---|---|
| `async`, `groupAsync` | creator-local: `Sched.here()`, or carrier 0 off a fiber | `async` eager (`spawn_first`), `groupAsync` lazy, as today |
| `concurrent`, `groupConcurrent` | round robin: `ticket = rt.placement.fetchAdd(1, .monotonic)`, then carrier `(ticket + probe) % carriers` for the first `probe < carriers` whose `reserve()` succeeds | eager when the chosen carrier is the creator's, otherwise posted as a birth (below) |

- `async` stays local. ADR 0001 lets it run inline and promises no concurrency. Its children
  share the creator's sockets, and keeping it local preserves the deterministic single-carrier
  interleaving that the parity suite relies on.
- `Sched.reserve() bool` replaces `has_free_fiber`. It is a CAS loop on the new
  `reserved: std.atomic.Value(u32)` that stops at `fibers_max` (`.monotonic`) and may run on
  any thread. `fiber_main` decrements it at exit. Invariant:
  `live_count <= reserved <= fibers_max`. If every probe fails, `concurrent` returns
  `ConcurrencyUnavailable` and `async` runs inline, as today.
- A birth on a foreign carrier uses the task's `birth: Sched.Mail` node, pushed by
  `Sched.post` (section 3). The home carrier drains its mailbox in `run_loop`, next to
  `inbox_drain`, and runs `spawn`. The reservation proves a free fiber exists at that point.
- Imbalance bound: T tasks placed while no carrier is full leave every carrier with
  `floor(T/N)` or `ceil(T/N)` of them, whatever the number of creator threads, because every
  `fetchAdd` returns a distinct ticket. For 1000 `concurrent` tasks at 4 carriers, that is
  exactly 250 per carrier. The item 8 counting test asserts it.
- The bench case: `acceptor` hands each accepted stream to `servers.concurrent`
  (`bench/echo.zig`), so the connections spread across carriers, and each handler's first
  `waiter_enter` arms on its own carrier.

### 3. Cross-carrier wake, `await`, cancel and close

**The claim.** `fiber.wait.outcome` is the claim word. Every transition out of `.waiting` is
`@cmpxchgStrong(.waiting, X, .acq_rel, .acquire)`. Exactly one winner calls `unpark` (when the
fiber's home is `Sched.here()`) or `fiber.home.unpark_foreign`. This replaces the precondition
of `unpark_foreign` ("named by at most one waker") with a mechanism. A loser only detaches its
node (section 6). New: `Fiber.home: *Sched`, set in `Sched.init`; `Sched.index: u32`; and a
threadlocal `Sched.here() ?*Sched`, which replaces `carrier_active: bool` so that `in_fiber`
names the carrier.

**`unpark_foreign` and `post`** keep the v0.5.0 protocol, now per carrier:

| step | thread | operation | order |
|---|---|---|---|
| claim | waker | CAS on `fiber.wait.outcome` | `.acq_rel` |
| push | waker | Treiber push of `fiber.queue_next` onto `home.inbox` (or a `Mail` onto `home.mailbox`) | CAS `.release`, fail `.monotonic` |
| notify | waker | `.poller`: `home.idle.poller.wake()` (`EVFILT_USER` ident 0 `NOTE_TRIGGER`, latched by `EV_CLEAR`; an `eventfd` write on epoll). `.futex`: `inbox_version` add `.release`, then `futexWake` | syscall |
| drain | home carrier | `@atomicRmw(.Xchg, null)` on `inbox`, then on `mailbox` | `.acquire` |

- The drain runs only between dispatches, on the home carrier. A fiber that is still running
  toward `park` is that carrier's current fiber, so it cannot be drained early. The latch
  means a wake that lands between the drain and `Poller.wait` makes the wait return at once.
- `Sched.notify(io)` is new. It is the wake step without a push, used by `stop` and by the
  join word below.
- The echo path makes no foreign wakes: each fiber is woken by its own poller's socket event.
  So no idle-flag shortcut is added before item 9 measures one.

**Futex: one shared table.** `Runtime.waits` stays a single `futex.Table` with
`waiters_max = carriers * fibers_max`. `Table.wake(table, here: ?*Sched, io, addr, max)` routes
each removed waiter by `fiber.home`: direct `unpark` when it equals `here` and the caller is a
fiber, otherwise the hand-off list, released after the lock, then `unpark_foreign`. `timeout`
and `cancel_wait` always run on the fiber's home carrier, because the wheel and the cancel mail
are local there. FIFO per address survives because every waiter of an address sits in one list.

**`await`.** `Task.done` and `Task.waiter` merge into `join: std.atomic.Value(usize)`, with the
values `0` running, `1` done, `2` the off-fiber driver waiting, or a `*Fiber`. The awaiter does
`cmpxchg(0, self, .acq_rel)`. If it sees `1`, it does not park. The finisher writes the result,
then `swap(1, .acq_rel)`. If it gets a fiber back, it wakes that fiber by its home. If it gets
`2`, it calls `rt.carriers[0].notify`. The off-fiber driver runs
`carriers[0].run_until(io, stop)`, where `stop` is now `*const std.atomic.Value(bool)` read
`.acquire`. When `live_count == 0` and stop is false, the loop idles instead of returning.
`GroupRec` uses the same join word for its awaiter.

**Cancel** is mailed to the home carrier, so the v0.5.0 cancel bodies run unchanged and stay
local there:

1. The canceller does `cmpxchg(.none, .requested, .release)` on
   `Task.cancel: std.atomic.Value(CancelState)`. `task_acknowledge_cancel` becomes
   `cmpxchg(.requested, .acknowledged, .acquire)` on the task's own fiber.
2. If `task.home == Sched.here()`, the canceller runs `task_request_cancel` as today. Otherwise
   it does `mail_state.cmpxchg(.idle, .posted, .acq_rel)`. On success it calls
   `home.post(io, &task.cancel_mail)`. On failure the task has already finished, and `await`
   will see `join == 1`.
3. The mail handler runs on the home carrier. If `cancel` is still `.requested` and
   `task.waiting`/`task.awaiting` names a parked fiber, it runs today's body
   (`futex.cancel_wait`, `net.cancel`, `sleep.cancel`, or the group wake). If the fiber
   already acknowledged, it does nothing.
4. Use-after-free guard. At the end of `task_entry`, the finisher does
   `mail_state.cmpxchg(.idle, .finished)`. If that fails because the state is `.posted`, the
   completion step (the join swap for a future; unlink and `task_free` for a member) moves to
   the mail handler. If the state is `.handled`, the finisher completes as usual. Both of these
   paths run on the home carrier, so the record is freed only after its mail has been consumed.

`GroupRec` gains `lock: std.atomic.Mutex` over `head`, `pending`, `waiter` and `canceling`, and
`idle` becomes atomic. `member_finish` unlinks under the lock. `group_request_cancel` walks the
members under the lock and mails each foreign one.

**Close from another carrier** follows section 6. Lock order: `Registry.table_lock`, then
`Slot.lock`. A thread never holds two slot locks. The futex `Table.lock` and `GroupRec.lock`
are leaves. `arm`/`disarm` run under a slot lock and only on the caller's own poller.
`unpark_foreign`, `post` and `notify` take no lock and may run under any lock (v0.5.0's
`close_off_carrier` already wakes under the lock).

### 4. `net_registry`: shared, one lock per slot, an armed mask per interest

- There is **one shared `Registry`**. An fd is process-global, `netClose` must find it from any
  thread, and the server pattern accepts on one carrier and serves on another. A per-carrier
  registry would pin a socket to its acceptor's carrier.
- The registry's `mutex` splits in two. `table_lock` guards the fd-to-slot `Table`, the free
  list and slot insert/release (`lookup`, `register`, `unregister`, `lease`, `lease_release`).
  `Slot.lock` guards the waiter lists, `armed`, `closing`, `closing_pending` and the poller
  calls made for that slot. The reason is in the numbers: 2 arms per echo at 0.29 us under one
  global lock would serialize 0.21 s of every second at the 2.0x target (368k echoes/s),
  before any lookup is counted.
- `Slot.waiters: [2]?*Sched.Waiter` holds nodes, not fibers. `Slot.armed: [2]u64` has bit `k`
  set exactly while carrier `k` holds the one-shot registration of that pair. Invariant
  (outside closing): bit `k` is set exactly when at least one node of a fiber homed on `k` is
  linked in that list. A pair can be armed on several pollers at once, which kqueue and epoll
  both allow across instances (each epoll instance keeps its own per-fd entry, ADR 0003
  section 2a). An event on carrier `k` wakes only `k`'s nodes. So several acceptors on
  different carriers each get an event, and the losers re-arm (the herd rule of ADR 0003
  section 3, per carrier).
- **Who owns the lists:** the registry owns the links and `Slot.lock` serializes them. Each
  node belongs to the fiber that took it, and only that fiber returns it to its carrier's pool.
  `on_event`, `close_*` and `leave` may unlink a node. Only the owner's home carrier arms or
  disarms that carrier's bit.

### 5. Work stealing: none

Stealing never-started fibers is rejected:

- Round robin already places within one task of perfect balance at birth (section 2). A birth
  waits in the target's mailbox for at most one loop turn, so the steal window is microseconds.
- Gate 1 is long-lived fibers. In `bench/echo.zig`, 1000 connection fibers live for the whole
  window, and 90% of the wall time is socket syscalls that belong to whichever carrier armed
  them (4c). Once started, a fiber cannot be stolen, so stealing cannot fix an imbalance that
  only appears after start (hot and cold connections).
- The scheduler's whole share is 8.7%-9.4% (4c), which bounds anything stealing could buy
  back. Its costs: popping single nodes from a mailbox that today is drained only by exchange
  needs an ABA guard; reservations would have to move between carriers; and the item 8 count
  would stop being exact.
- Trigger to revisit: item 9 shows a carrier idle while births queue on another.

### 6. The 8b `Waiter` node, and the changes it makes

```zig
// src/sched.zig
pub const Waiter = struct {
    prev: ?*Waiter,
    next: ?*Waiter,
    fiber: *Fiber, // its `home` names the carrier
    outcome: Outcome, // written under the slot's lock
    interest: evented.Interest,
    slot: u32,
    generation: u32, // the slot's generation at `waiter_enter`; replaces `generation_of`
    pub const Outcome = enum(u8) { idle, waiting, ready, closed, closing };
};
```

- Each carrier has a pool `waiters: []Waiter` of `fibers_max + batch_ops_max` nodes, allocated
  in `Sched.init`. Node `i < fibers_max` is fiber `i`'s own node, so a single-op wait cannot
  fail for want of a node. The spares sit on a free list touched only by that carrier.
  `Wait.prev/next/addr` stay, but only for the futex table. `Wait.sleeping` and `Wait.socket`
  become `Wait.kind: enum { none, futex, sleep, socket }`. `sleep.fire` dispatches `.socket` to
  a new `Expiry.socket_timeout`, which claims `.timed_out`.
- `waiter_enter(registry, sched, fd, node) Enter` takes `table_lock` to find the slot, then
  `Slot.lock`. It returns `.gone` when the slot is closing. It links the node and records
  `slot`, `generation` and `interest`. If bit `sched.index` is clear, it arms on `sched`'s
  poller with the slot index as the token, and sets the bit. If the arm fails, it unlinks the
  node and returns `.resources`.
- `on_event(ctx, sched, event)` takes `Slot.lock` only (the token is the slot index). A closing
  slot clears its bit and drops the event. Otherwise it asserts the bit, clears it, and walks
  the list (bounded by `carriers * (fibers_max + batch_ops_max)`). For each node whose
  `fiber.home == sched` it unlinks the node, sets `.ready`, and claims `.woken`, calling
  `unpark` if the claim wins. Nodes of other carriers are left alone.
- `cancel(fiber)` becomes the claim alone: `.waiting` to `.canceled`, then `unpark`. It takes
  no lock, unlinks nothing and disarms nothing. It runs on the home carrier, mailed there if
  needed (section 3).
- `leave(registry, sched, node) Waiter.Outcome` is new. The resumed fiber runs it for each of
  its nodes, under that slot's lock. A node still `.waiting` is unlinked. If `sched` has no
  other node left in that list, it disarms and clears the bit. `.ready` is downgraded to
  `.closed` when `generation` moved or the slot is closing. This replaces `still_open`, so a
  single-op park holds a lock 4 times (table, slot, event, leave), the same as v0.5.0's
  `waiter_enter`, `generation_of`, `on_event` and `still_open`.
- `close_on_carrier(registry, here: *Sched, io, fd) bool` and
  `close_off_carrier(registry, io, fd) bool` share `close_locked(here: ?*Sched)`.
  `close_off_carrier` loses its `sched` parameter. If the slot is already closing, the result
  is false. `here`'s own nodes are unlinked and set `.closed`, the fiber is claimed `.woken`,
  and `here`'s bits are disarmed. Foreign nodes are unlinked and set `.closing`, the fiber is
  claimed `.woken` and woken through `unpark_foreign`, and each such node adds one to
  `closing_pending` even when its claim loses. If nothing is pending, the slot is released and
  the result is true (the caller closes the fd). Otherwise the slot is marked closing and the
  result is false: the fd stays open until every foreign registration is gone.
- `closing_finish(registry, sched, node) bool` disarms `sched`'s registration for
  `node.interest` if its bit is still set (idempotent), clears the bit and decrements
  `closing_pending`. The last one releases the slot and returns true. A resumed fiber processes
  every node before it reports its own outcome, so a `.closing` node always reaches
  `closing_finish`, even when a cancel won the claim.
- `net.park` switches on the node's outcome: `.ready` retries, `.closed` returns `Closed`, and
  `.closing` runs `closing_finish` and then returns `Closed`. The fiber-level outcome only
  distinguishes `.woken`, `.canceled` and `.timed_out`.

**Batches (ADR 0003 section 2c amended).**

1. `served_task` also requires `submitted <= free spare nodes + 1` and takes those nodes. A
   batch that does not fit goes whole to `Io.Threaded`, like any other unserved batch. That
   check happens before any syscall.
2. `wait` sweeps once with `try_once`, as today.
3. If nothing completed, it sets `.waiting` and calls `waiter_enter` with one node per pending
   op. `.gone` completes that op with `SocketUnconnected` and claims the fiber itself.
   `.resources` completes the op with `SystemResources`, as `submit.receive` does.
4. It calls `sleep.arm` with the batch deadline (one wheel node per fiber, as today), sets
   `Wait.kind = .socket`, and parks.
5. On resume it calls `sleep.disarm` and `leave` on every node. It retries only the `.ready`
   ops, completes `.closed` and `.closing` ops with `SocketUnconnected` (after
   `closing_finish`), and returns the nodes to the pool.
6. Result: `.canceled` returns `Canceled`. `.timed_out` with nothing completed returns
   `Timeout`. Any other wake with nothing completed loops, bounded by `rounds_max`.

`slice_ns_min`, `slice_ns_max` and the per-slice `recvmsg` are deleted. An idle batch makes no
syscall between arming and its first event.

### 7. One construction path, gate 5, gate 1

- **Construction.** `Runtime.init` is the only constructor. `tests/parity/fixtures.zig` gains a
  `carriers` argument on `init_runtime_sockets`, which every other helper threads through.
  `build.zig` runs the suite at 1, 2 and 4 carriers per backend. `.epoll` runs on CI.
- **Gate 5.** Every block in section 1 is allocated in `init`, and the count does not depend on
  the number of connections. After init this ADR adds no allocation site:
  - `Waiter` nodes come from the per-carrier pool;
  - `Mail` nodes are embedded in the task record;
  - the inbox and mailbox are links inside existing records;
  - `armed`, `reserved`, `join` and `mail_state` are fields;
  - carrier threads use `std.Thread.spawn`, which takes no allocator on POSIX.

  The per-task record of `async`/`groupAsync` (`task_create`) is the plan 002 exception, and
  this ADR does not change it. The parity test's expected count becomes `5 * carriers + 4`
  evented and `3 * carriers + 2` threaded.
- **Gate 1.** The target is >= 2.0x of 184k, so >= 368k echoes/s. One carrier does 152k-161k,
  and its kernel work per echo is fixed by its syscalls (78% of its CPU). Trimming the 4c waste
  (2 `EAGAIN` reads and 2 arms, about 31% of the wall time) caps one carrier near 1.3x. So
  carriers are the only lever, and at linear scaling the bench needs at least
  `ceil(368/152) = 3`. The dev box has 10 cores. What stands between 3 and 10 is the shared
  locks (section 4) and kernel loopback serialization (plan risk), and item 9 measures both.
  The persistent `EV_CLEAR` registration and the changelist of arms (4c) are deferred to plan
  006, after item 9. Both rewrite the waiter bookkeeping that items 4-7 are changing, and their
  combined gain stays within the 1.3x ceiling.

### 8. API sketch (new unless marked)

```zig
// src/runtime.zig
pub const carriers_max: u32 = 64;
// Options: `carriers: u32` and `batch_ops_max: u32` added; `fibers_max` is now per carrier.
carriers: []Carrier, // replaces `sched: Sched`
stop: std.atomic.Value(bool),
placement: std.atomic.Value(u32),
// src/sched.zig
pub const Mail = struct { next: ?*Mail, run: *const fn (*Mail, *Sched) void };
pub fn here() ?*Sched; // threadlocal
pub fn reserve(sched: *Sched) bool; // any thread
pub fn post(sched: *Sched, io: Io, mail: *Mail) void; // any thread
pub fn notify(sched: *Sched, io: Io) void; // any thread
pub fn run_until(sched: *Sched, io: Io, stop: *const std.atomic.Value(bool)) void; // changed
// src/net_registry.zig
pub fn waiter_enter(r: *Registry, sched: *Sched, fd: fd_t, node: *Waiter) Enter; // changed
pub fn leave(r: *Registry, sched: *Sched, node: *Waiter) Waiter.Outcome;
pub fn close_on_carrier(r: *Registry, here: *Sched, io: Io, fd: fd_t) bool; // changed
pub fn close_off_carrier(r: *Registry, io: Io, fd: fd_t) bool; // changed
pub fn closing_finish(r: *Registry, sched: *Sched, node: *Waiter) bool; // changed
// src/futex.zig
pub fn wake(t: *Table, here: ?*Sched, io: Io, addr: usize, max: u32) u32; // changed
```

`generation_of`, `still_open` and `Sched.has_free_fiber` are removed. `Offload` completes to
`fiber.home` instead of its single `sched` field.

## Rejected alternatives

- **All N carriers as dedicated threads.** At `carriers = 1` this adds a thread, and
  `spawn_first` from the driver stops being eager, so the parity suite's single-thread
  interleaving changes.
- **Per-carrier registries, or a fixed socket home (the creator's carrier).** Accept and hand
  off would put every connection's I/O on the acceptor's carrier, and `netClose` would have to
  search N tables.
- **One registry lock.** See section 4: arms are made under it, and at the target rate they
  alone serialize about 21% of a core.
- **A per-carrier waiter count per slot** instead of walking the list. At `sockets_max = 10000`
  that is 2.5 MB, against lists that almost always hold one node.
- **Per-carrier futex tables.** A wake would visit N locks, and FIFO per address would need a
  global sequence number.
- **Cancel done by the canceller in place.** The poller is carrier-only, and once a fiber
  leaves a wait and starts an uncancelable one, a stale `task.waiting` pointer would cancel the
  wrong wait (ABA).
- **Least-loaded placement.** It reads N counters racily, the placement is not reproducible,
  and the counting test would become probabilistic. Creator-local `concurrent` defeats the
  acceptor pattern.
- **Work stealing** (section 5). **Fiber migration** (out of plan scope).
- **Keeping the wheel-slice batch.** It costs up to 2 ms of latency and a syscall per op per
  slice, and the node pool removes the reason for it.

## Consequences

- `Runtime.init` breaks at every call site (two new fields) and `fibers_max` changes meaning.
  `0.x` allows this as MINOR (v0.6.0).
- `Io` becomes multi-threaded for fibers on carriers 1..N-1. `async`, `concurrent`, `await`,
  `cancel` and `group*` called off a fiber are still allowed only from the driver thread.
  `futexWake` and `netClose` are allowed from any thread, as before.
- Memory grows by `carriers - 1` stack arenas, poller tables and pools. Each fiber gains a
  40-byte node, which item 10 counts in gate 4.
- The profile build (`src/profile.zig`) is single-carrier until its counters are per thread.
  Item 9 decides.
- Risks:
  - lost wakes or use-after-free in the join and mail state machines (covered by the item 7
    model test);
  - contention on `table_lock` from `lookup` on every data call (item 9 profiles it);
  - an epoll fd armed in two instances during a herd (one CI round trip per fix);
  - gate 2 at 0.91x with no margin (items 4-6 re-run `bench-echo`).

## Test plan

| decision | item | verified by |
|---|---|---|
| nodes in the lists, unchanged behaviour, `leave` replaces `still_open` | 4 | full suite on `.kqueue`/`.threaded`, `net_close.zig`, the #49 cancel-after-wake test, ubuntu (epoll) |
| batch parks on poller + wheel | 5 | `batch.zig` parity; an idle 64-socket batch makes no `recvmsg` before its first event; gate 2 >= 0.9x |
| `carriers`, `init` allocates everything, `5N + 4` blocks, carrier threads | 6 | suite at 1 and 2 carriers on both backends; allocation count flat after init; gate 7 at 2 |
| claim CAS, futex routing, join word, cancel mail, `close_locked`, armed mask | 7 | seeded 4-carrier model (spawn, futex wake, await, cancel, close from random carriers, fixed CI seeds); suite at 4; 1000 serial runs of the built test binary |
| round robin and reservation; no stealing | 8 | 1000 `concurrent` tasks at 4 carriers parked on one `Io.Event`: each carrier's `reserved` is 250; no stealing test |
| gate 1 argument | 9 | the measurement section, at `carriers` = 1 and = core count |

## Measurement

Plan 005 item 9 fills this table with `zig build bench-echo` and `zig build bench-latency`,
ReleaseFast, on the 4a machine, and runs gate 3 eight times.

| date | gate | carriers | connections | `Io.Threaded` | sirocco | ratio | result |
|---|---|---|---|---|---|---|---|
| | 1 | 1 | 1000 | | | | |
| | 1 | core count | 1000 | | | | |
| | 2 | 1 | 1 | | | | |
| | 2 | core count | 1 | | | | |
| | 3 (p99) | 1 | 1000 | | | | |
| | 3 (p99) | core count | 1000 | | | | |
