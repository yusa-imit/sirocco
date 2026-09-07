# sirocco — Milestones

> Inherited roadmap, frozen at the kingdom restructure (2026-09-05). New work is planned in
> docs/plans/NNN-*.md via plan PRs (citadel/protocol/GITHUB.md).

> 마일스톤은 **이름(테마)** 으로 관리한다. 버전 번호는 릴리즈 시점에 `build.zig.zon` 현재 버전 + 1 로 결정한다.
> 상세 요구사항: `docs/PRD.md`. 진행 상황은 이 파일의 체크박스가 단일 진실이다.

## 현재 상태

- **Phase**: Bootstrap 완료 → Phase 1 착수
- **버전**: 0.1.0 (미릴리즈)
- **CI**: 초기 워크플로우 등록

## Phase 1 — Loop Core

- [ ] 1A `io/completion.zig` — Op union, Result, intrusive queue
- [ ] 1B `io/backend/kqueue.zig`
- [ ] 1C `io/backend/epoll.zig`
- [ ] 1D `io/timer.zig` — timing wheel
- [ ] 1E `io/loop.zig` — dispatch, run modes, wakeup, cancel
- [ ] 1F loopback echo / timer / cancel race tests

## Phase 2 — Net

- [ ] 2A `net/address.zig`
- [ ] 2B `net/tcp.zig`, `net/udp.zig`, `net/unix.zig`
- [ ] 2C `net/dns.zig`
- [ ] 2D `net/pool.zig`
- [ ] 2E `bench/echo.zig`

## Phase 3 — TLS

- [ ] 3A `tls/client.zig`
- [ ] 3B `tls/pem.zig`
- [ ] 3C `tls/server.zig`
- [ ] 3D ALPN / SNI

## Phase 4 — HTTP & WS

- [ ] 4A `http/parser.zig` + fuzz
- [ ] 4B `http/client.zig`
- [ ] 4C `http/server.zig`
- [ ] 4D `ws/`
- [ ] 4E `http/h2/`

## Phase 5 — Task & Multi-core

- [ ] 5A `task/thread_pool.zig`, `task/channel.zig`
- [ ] 5B `task/cancel.zig`
- [ ] 5C `task/scheduler.zig` (SO_REUSEPORT)
- [ ] 5D io_uring backend
- [ ] 5E IOCP backend

## Phase 6 — Integration

- [ ] 6A silica server on sirocco (PoC)
- [ ] 6B zr downloader → `sirocco.http.Client`
- [ ] 6C sailor httpclient/websocket widgets delegate
- [ ] 6D synod Transport adapter


## 성능 목표

`docs/PRD.md` §5 참조. 각 Phase 완료 시 `zig build bench` 결과를 아래에 기록한다.

| 날짜 | 지표 | 측정값 | 목표 | 비고 |
|---|---|---|---|---|
| | | | | |

---

## Superseded by ADR 0001 (2026-09-08)

`docs/adr/0001-std-io-vtable.md` re-aimed sirocco at implementing `std.Io.VTable` instead of
exposing a parallel I/O API. This roadmap is frozen history; below is how each phase maps onto
the vtable model, so no later cycle follows a checklist the design has retired.

| item | status under the vtable model |
|---|---|
| **1A** `io/completion.zig` — Op union, Result, intrusive queue | **superseded.** std owns it: `Io.Operation`, `Io.Operation.Result`, `Io.Operation.Storage` (intrusive, caller-owned, no per-op allocation), `Io.Batch`. sirocco implements `operate`/`batchAwaitAsync`/`batchAwaitConcurrent`/`batchCancel` instead of defining these types |
| **1B** `io/backend/kqueue.zig` | **survives, internal.** `src/backend/kqueue.zig`, private; no consumer names it. Note `std.Io.Kqueue` exists but does not compile in 0.16.0 |
| **1C** `io/backend/epoll.zig` | **survives, internal.** Same |
| **1D** `io/timer.zig` — timing wheel | **survives, internal.** Now the implementation of the `now`/`clockResolution`/`sleep` slots and of `Timeout.deadline` in `batchAwaitConcurrent` |
| **1E** `io/loop.zig` — dispatch, run modes, wakeup, cancel | **superseded.** No `Loop`, no `submit`/`run(mode)`/`stop`. Replaced by `src/sched.zig` (fibers, carrier threads) behind the `async`/`concurrent`/`await`/`cancel`/`group*`/`recancel`/`swapCancelProtection`/`checkCancel` slots. Cancellation is std's `Io.Cancelable`/`error.Canceled`, not a sirocco type |
| **1F** loopback echo / timer / cancel race tests | **survives, reframed.** Now differential tests against `Io.Threaded` rather than self-consistency tests |
| **2A** `net/address.zig` | **superseded.** `Io.net.IpAddress` / `Ip4Address` / `Ip6Address` / `UnixAddress` are std types with parsing and formatting |
| **2B** `net/{tcp,udp,unix}.zig` | **survives as slot implementations, internal.** The 16 `net*` slots; UDP is `netSend` + the `net_receive` operation, not a `UdpSocket` type |
| **2C** `net/dns.zig` — resolver | **survives, internal.** Becomes the `netLookup` slot |
| **2D** `net/pool.zig` — connection pool | **out of v1 scope.** Not a vtable concern; revisit as an additive module after the vtable is complete |
| **2E** `bench/echo.zig` | **survives, reframed.** Measures sirocco against `Io.Threaded`, not against an absolute req/s figure |
| **3A–3D** TLS client, PEM, TLS server, ALPN/SNI | **dropped.** `std.crypto.tls.Client.init(reader, writer, options)` runs unmodified on sirocco's `net*` slots. sirocco ships no TLS |
| **4A–4C** HTTP parser, client, server | **dropped.** `std.http` takes `io: Io` and works the moment the `net*` slots land |
| **4D** `ws/` — WebSocket | **out of v1 scope.** std has no WebSocket; if the kingdom needs one it is an additive module over `Io.Reader`/`Io.Writer` with its own ADR |
| **4E** `http/h2/` — HPACK, streams | **dropped.** Not a vtable concern |
| **5A** `task/{thread_pool,channel}.zig` | **superseded.** `Io.Group`, `Io.Queue`, `Io.Event`, and sirocco's own carrier threads |
| **5B** `task/cancel.zig` — hierarchical cancellation | **superseded.** `Io.Cancelable`, `recancel`, `swapCancelProtection`, `checkCancel`, `Group.cancel` |
| **5C** `task/scheduler.zig` — SO_REUSEPORT multi-loop | **survives, internal.** Multi-carrier-thread scheduling inside `src/sched.zig`; `SO_REUSEPORT` becomes a `netListenIp` option detail |
| **5D** io_uring backend | **survives, internal.** `src/backend/uring.zig`. Note `std.Io.Uring` exists but does not compile in 0.16.0 |
| **5E** IOCP backend | **survives, internal, post-v1** |
| **6A–6D** Integration (silica, zr, sailor, synod) | **reframed and promoted.** No longer porting consumers onto a sirocco API — swapping `init.io` for `rt.io()` at one `main` and running the consumer's existing suite unchanged. This is the acceptance criterion, not the last phase |

The 성능 목표 table above points at `docs/PRD.md` §5, which was rewritten: absolute
throughput targets are deleted in favour of ratio gates against `Io.Threaded`.
