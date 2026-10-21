# Plan 004 — evented-net

## Goal

`rt.io()` serves sockets from an event loop. A kqueue poller (macOS/BSD) and an epoll poller
(Linux) live in `src/backend/`, one per `Sched`, and the carrier idles in it. The 12 socket
`net*` slots and P3 (`operate`, `batch*`) go native on non-blocking sockets, `concurrent` tells
the truth, and PRD §5 gates 1-4 get their first rows.

## Why now

v0.4.0 never stalls the carrier, but each socket call costs two thread hand-offs and holds an
offload worker until it returns: 1000 idle connections would need 1000 workers, which is
`Io.Threaded` with extra steps. Evented networking is ADR 0001's reason for sirocco. ADR 0002 moved
multi-carrier here so placement follows the poller; item 10 measures gate 1 on one carrier and
lets that number decide. kqueue first: the dev box is macOS arm64; epoll is CI-only (x86_64).

## Scope

- [x] 1. Move the tests of `src/sched.zig` (823 lines) to `src/sched_test.zig`, adding `pub`
      accessors that `root.zig` does not re-export. Why first: tidy caps files at 800 lines, and
      item 3 grows this file. Verify: `zig build tidy`; `wc -l src/*.zig` all < 800; the
      `zig build test --summary all` test count is unchanged.
- [x] 2. `docs/adr/0003-evented-backends.md` + `src/backend/kqueue.zig`: a `Poller` with `init(gpa,
      registrations_max)`, `arm(fd, .read|.write, token)` (`EV_ONESHOT`), `disarm`, `wait(deadline,
      out)` and a thread-safe `wake` (`EVFILT_USER`), its table allocated in `init`. ADR rules:
      one poller per `Sched`; sockets are `O_NONBLOCK`, owned by the `Io` that made them; item
      10's gate-1 rule. Verify: `src/backend/poller_test.zig`, generic over the backend, on a
      socketpair: armed read + a written byte -> token; `wake` from a thread unblocks `wait`; a
      deadline -> empty; a full table -> `SystemResources`; allocations flat after `init` (gate 5).
- [x] 3. Add `Options.sockets_max` (required), and make `.auto` resolve to `.kqueue` where kqueue
      and fibers exist. `Sched.idle_wait` blocks in `Poller.wait` until the wheel's next
      deadline, and `unpark_foreign` calls `Poller.wake`; `.threaded` keeps the futex path.
      Why: offload completions and foreign futex wakes must reach a carrier asleep in kqueue.
      Verify: the full suite is green under `.kqueue` and `.threaded` (`tests/parity/fixtures.zig`);
      gate 7 is re-run on kqueue.
- [x] 4. `src/backend/sys.zig`: non-blocking POSIX socket calls returning `error.WouldBlock`, shared
      by both backends. `src/net.zig` goes native for `netListenIp`, `netBindIp`, `netAccept`,
      `netConnectIp` (`EINPROGRESS` -> arm write -> `SO_ERROR`), `netListenUnix`, `netConnectUnix`,
      `netSocketCreatePair`: a would-block parks the fiber on the poller, a cancel unparks it. Off
      a fiber, or on a handle not in the `sockets_max` registry, the v0.4.0 offload thunk runs.
      Verify: `tests/parity/net.zig` in-fiber parity (incl. `ConnectionRefused`, `AddressInUse`);
      64 accept/connect pairs with `offload_threads = 1` (hangs if offloaded); parked-accept cancel.
- [x] 5. Data-path slots in `src/net.zig`: `netRead`/`netWrite` (`readv`/`writev`, with `header` and
      `splat` not copied), `netSend` (`sendmsg`, partial count), `netShutdown`, `netClose`. A close
      disarms and unparks waiters before `close(2)`, so a reused fd never sees a stale event.
      Verify: a 1 MiB vectored and splat echo matches the baseline; read-cancel parity in flight
      and under `.blocked`; when fiber B closes the socket fiber A is reading, A gets an error and
      does not hang (checked on `rt.io()` only, since Threaded defines no outcome for it).
- [x] 6. `src/backend/epoll.zig`: the same `Poller` on epoll (`EPOLLONESHOT`, an `eventfd` for
      `wake`), with `.auto` resolving to `.epoll` on Linux and a comptime check that both pollers
      export the same declarations. Why here: items 7-9 then land on both backends at once.
      Verify: the ubuntu CI job runs `poller_test.zig` and `tests/parity/net.zig` on epoll, and
      `zig build -Dtarget=x86_64-linux` compiles locally.
- [x] 7. `operate` in `src/submit.zig`: `net_receive` (`recvmsg`) and `file_read_streaming`/
      `file_write_streaming` on `flags.nonblocking` files go through the poller. Blocking files
      and `device_io_control` keep the offload thunk. Verify: `tests/parity/operate.zig` covers
      UDP `net_receive` parity and a non-blocking pipe read that parks until the peer writes,
      with cancel parity.
- [x] 8. `batchAwaitAsync`, `batchAwaitConcurrent`, `batchCancel` in `src/submit.zig`, installed
      together (they share the batch's lists). Ops are tried and armed on a would-block, and the
      fiber parks on poller + wheel (`Io.Timeout`). No allocation: out of registrations,
      `batchAwaitConcurrent` returns `ConcurrencyUnavailable` (Threaded would allocate) and
      `batchAwaitAsync` works in rounds. Verify: `tests/parity/batch.zig` (64 sockets give the
      same completion set; 10 ms idle -> `Timeout` on both; cancel mid-wait); allocations flat.
      Landed as `src/batch.zig` (ADR 0003 section 2c): native for batches of one-message
      registered-socket `net_receive`s and non-blocking file streams awaited on a fiber, whole
      batch to `Io.Threaded` otherwise; the wait is wheel slices (50 us to 2 ms), not a poller
      park, because a fiber sits on one waiter list only. It never needs a registration, so it
      never returns `ConcurrencyUnavailable`.
- [ ] 8b. Replace the wheel slices of item 8 with a per-operation waiter node in the registry, so
      an idle batch wakes on the poller event (no 2 ms latency, no `recvmsg` per slice). Verify:
      `tests/parity/batch.zig` idle-wake latency below one wheel tick; allocations flat.
- [x] 9. `concurrent`/`groupConcurrent` in `src/concurrency.zig` run on a free fiber once the
      scheduler is ready, and return `ConcurrencyUnavailable` when none is free. Why: plan 003
      deferred this to the backend plan, and the echo bench needs one server task per connection
      on both `Io`s. Verify: two `concurrent` tasks ping-pong over a socketpair in
      `tests/parity/concurrency.zig` (hangs if inline); refusal at `fibers_max`; group parity.
- [x] 10. `bench/echo.zig` + `zig build bench-echo`: clients echo 64-byte messages through one
      loopback server, on `rt.io()` and `rt.baselineIo()` of one `Runtime`, 5 s each. Verify: PRD
      §5 rows, ReleaseFast on the dev box, for gate 1 (1000 connections, >= 2.0x) and gate 2 (1,
      >= 0.9x). A gate-2 miss is fixed here. A gate-1 miss and its profile go into ADR 0003, and
      multi-carrier becomes plan 005.
      Landed: gate 2 passes at 0.91x, gate 1 misses at 0.83x-0.87x (ADR 0003 section 4a,
      PRD §5 rows); plan 005 is multi-carrier and starts with a profile.
- [ ] 11. `bench/latency.zig` + `zig build bench-latency`: accept-to-first-byte p99 at 1000
      connections (gate 3), then RSS delta / 10k over 10k idle connections (gate 4). It raises
      `RLIMIT_NOFILE` (macOS: 256) and records a refusal, never a smaller N. Verify: PRD §5 rows.
- [ ] 12. Bring README, CHANGELOG `[0.5.0]`, PRD §4.1/§4.3/§5 and the `Options` docs in line with
      what shipped; bump to 0.5.0 and release. Verify: `gh release view v0.5.0`.

`blocked_by`: none. Zero-dependency foundation, and no kingdom repo pins sirocco yet.

## Out of scope

- Multi-carrier and work stealing (plan 005, if item 10 shows one carrier misses gate 1);
  io_uring, IOCP, Windows. Forwarded as today: `netLookup` (queue fills through baseline futexes),
  `netWriteFile` (TODO panic in Threaded), `netInterfaceName*` (cheap ioctls). `file*`/`dir*`
  stay offloaded except non-blocking streams. The consumer swap (ADR 0001 rule 5) follows v0.5.0.

## Risks

- epoll and x86_64 are CI-only, so each epoll fix costs a CI round trip. Mitigations: one
  `Poller` contract and one test file, local cross-compiles, epoll placed before P3.
- `Io.Batch` keeps `submitted`/`pending`/`completed` lists and a `Storage` union that only the
  `Io` edits. sirocco mirrors `Threaded.zig` 0.16.0; the pin and the 109-slot guard catch
  drift, and the item-8 parity table is the oracle.
- Mixed handles: Threaded's `net_receive` treats `WouldBlock` as `unreachable`, so a sirocco
  socket passed to `baselineIo()` can trap. A foreign blocking fd would freeze the carrier
  without item 4's registry fallback. ADR 0003 states socket ownership; parity never crosses.
- `concurrent` on fibers is not parallel. A fiber in a forwarded call that stays on the
  carrier (`netLookup`, CPU-clock `sleep`) delays the others, and the `Options` doc says so.

## Done when

- `zig build test`, `zig fmt --check src bench build.zig tools tests` and `zig build tidy` are
  green on the ubuntu and macOS CI jobs, with every `src/` file < 800 lines.
- `tests/parity/slots.zig` lists 32 `native` names under `.auto` on both jobs (P0, P1, `sleep`,
  12 `net*`, 4 P3), and the suite passes under `.unimplemented = .fail`.
- PRD §5 has kqueue rows for gates 1-4. Gates 2-4 pass, and gate 1 passes or ADR 0003 records
  the miss and names plan 005. Gates 5, 8 and 9 hold.
- Zero open `bug` issues; the plan 004 milestone issue is closed; `v0.5.0` is released.

## Version impact

**MINOR, v0.4.0 → v0.5.0.** The new required `Options.sockets_max` breaks every `Runtime.init`
call site. `.auto` now picks kqueue/epoll, and `concurrent` stops refusing. Per
`citadel/protocol/VERSIONING.md`, MINOR may break during `0.x`, and no `build.zig.zon` pins
sirocco. The Zig pin stays 0.16.0, so the toolchain MAJOR rule does not apply.
