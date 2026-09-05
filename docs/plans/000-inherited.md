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
