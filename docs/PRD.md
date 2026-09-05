# sirocco — Product Requirements Document

> **sirocco**: 함대를 밀어주는 바람. Zig 왕국의 비동기 I/O 런타임 & 네트워크 스택.
> Layer: **Foundation** · Consumers: silica, zoltraak, zr, sailor, synod

---

## 1. 배경과 문제

왕국의 서버 제품(silica, zoltraak)과 도구(zr, sailor)가 각자 TCP 서버, 커넥션 처리, TLS, HTTP 클라이언트를 따로 구현하고 있다.

| 프로젝트 | 현재 자체 구현 | sirocco 도입 후 |
|---|---|---|
| silica | `src/server/{server,connection}.zig`, TLS | `sirocco.net.tcp` + `sirocco.tls` 위에 PG wire만 유지 |
| zoltraak | `server.zig`, `network/tls.zig` | 동일 — RESP 프로토콜 계층만 유지 |
| zr | `std.http` 직접 사용 (downloader, remote cache) | `sirocco.http.Client` (재시도, 풀링, 프록시) |
| sailor | `tui/widgets/{httpclient,websocket}.zig` | `sirocco.http` / `sirocco.ws` 에 위임 |
| synod | Transport 인터페이스 | `sirocco` 어댑터로 실 네트워크 구현 |

한 번 잘 만들면 네 곳의 네트워크 품질(타임아웃, 백프레셔, TLS, 관측성)이 동시에 올라간다.

## 2. 목표 (Goals)

1. **완성 기반 I/O (completion-based)**: kqueue(macOS/BSD), epoll(Linux), io_uring(Linux 5.6+, 선택), IOCP(Windows) 백엔드를 하나의 API로 추상화
2. **제로 의존성**: Zig std만 사용. TLS는 `std.crypto.tls` 기반
3. **프로토콜 계층 분리**: `io` → `net` → `tls` → `http`/`ws` 순서로 얇게 쌓아 각 계층을 단독 사용 가능
4. **명시적 자원 관리**: allocator-first, 모든 소켓/타이머는 명시적 close, 취소(cancellation) 1급 지원
5. **서버 제품이 요구하는 수준**: 10k 동시 연결, 커넥션당 고정 메모리 상한, 백프레셔, graceful shutdown
6. **Zig 0.15 `std.Io` 방향과 정합**: 향후 std의 비동기 인터페이스가 안정되면 어댑터로 연결 가능하도록 vtable 기반 `Io` 인터페이스 설계

## 3. 비목표 (Non-Goals)

- 웹 프레임워크(라우팅 DSL, 템플릿) — 상위 레이어 별도 프로젝트
- gRPC / HTTP/3(QUIC) — v2 이후 검토
- 동기 블로킹 API의 완전 호환 — thin wrapper만 제공

## 4. 아키텍처

```
┌─────────────────────────────────────────────┐
│  http (h1 client/server, h2, ws)            │
├─────────────────────────────────────────────┤
│  tls (std.crypto.tls client/server, ALPN)   │
├─────────────────────────────────────────────┤
│  net (tcp, udp, unix, dns, addr, pool)      │
├─────────────────────────────────────────────┤
│  io (Loop, Completion, Timer, Cancel)       │
│    backends: kqueue | epoll | io_uring | iocp│
├─────────────────────────────────────────────┤
│  task (Scheduler, ThreadPool, Channel)      │
└─────────────────────────────────────────────┘
```

### 4.1 `io` — 이벤트 루프

```zig
pub const Loop = struct {
    pub fn init(allocator: Allocator, opts: Options) !Loop;
    pub fn deinit(self: *Loop) void;
    /// 완료 하나를 제출. callback은 루프 스레드에서 호출된다.
    pub fn submit(self: *Loop, c: *Completion) void;
    pub fn cancel(self: *Loop, c: *Completion) void;
    /// 대기 중인 완료가 없을 때까지 실행
    pub fn run(self: *Loop, mode: enum { once, until_done, no_wait }) !void;
    pub fn stop(self: *Loop) void;
};

pub const Completion = struct {
    op: Op,                     // union: accept, connect, read, write, recv, send, close, timeout, ...
    userdata: ?*anyopaque,
    callback: *const fn (*Loop, *Completion, Result) void,
    // intrusive list links (no allocation per op)
};
```

- **인트루시브 설계**: `Completion`은 호출자가 소유. 루프는 per-op 할당을 하지 않는다.
- **백엔드 선택**: comptime `builtin.os.tag` + 런타임 io_uring 가용성 감지.
- **타이머**: 계층형 타이밍 휠(hierarchical timing wheel), O(1) 등록/취소.
- **Wakeup**: eventfd / pipe / kqueue user event로 다른 스레드에서 루프 깨우기.

### 4.2 `net` — 소켓

- `TcpListener`, `TcpStream`, `UdpSocket`, `UnixListener/Stream`
- `Address` 파싱(IPv4/IPv6/Unix), `resolve()` — `/etc/hosts` + DNS(UDP/TCP fallback) 비동기 리졸버
- `Pool(T)` — 커넥션 풀: min/max, idle timeout, health check hook, fairness(FIFO)
- 소켓 옵션: `TCP_NODELAY`, `SO_REUSEPORT`, keepalive, 버퍼 크기

### 4.3 `tls`

- `std.crypto.tls.Client` 래핑 + 비동기 핸드셰이크 상태기계
- 서버 측 TLS 1.3 (std에 없으면 자체 구현 — Phase 3 리스크 항목)
- ALPN, SNI, 인증서 체인 로딩(PEM), 세션 재개(선택)

### 4.4 `http`

- `http1`: 파서(incremental, zero-copy 헤더 슬라이스), 청크 인코딩, keep-alive, 파이프라이닝 방어
- `Client`: 재시도(backoff), 리다이렉트, 풀링, 프록시(HTTP_PROXY), 스트리밍 바디, 진행률 콜백 (zr downloader 요구)
- `Server`: 핸들러 인터페이스 `fn (*Request, *Response) anyerror!void`, 라우팅은 하지 않음(최소 prefix 매칭만), graceful shutdown, 커넥션 상한
- `h2`: HPACK, 스트림 멀티플렉싱, 플로우 컨트롤 (Phase 4)
- `ws`: RFC 6455 클라이언트/서버, 프레이밍, ping/pong, 압축(permessage-deflate, 선택)

### 4.5 `task`

- `ThreadPool` — 워크스틸링 없음, 단순 MPMC 큐 + 고정 워커 (블로킹 작업 오프로드용)
- `Channel(T)` — bounded MPSC, 루프 통합(수신 시 wakeup)
- `WaitGroup`, `CancelToken` — 계층적 취소 전파
- `Scheduler` — N개 루프 + SO_REUSEPORT 샤딩 (multi-core 서버 모드)

## 5. 성능 목표

| 지표 | 목표 | 측정 |
|---|---|---|
| echo 서버 처리량 | 1M req/s (8코어, 64B 메시지) | `bench/echo.zig` |
| HTTP/1.1 hello | 500k req/s (8코어) | `bench/http_hello.zig` + wrk |
| p99 지연 (10k conn, 1k rps/conn) | < 1ms | `bench/latency.zig` |
| 커넥션당 메모리 | < 8KB (버퍼 제외) | 측정 후 기록 |
| 콜드 스타트 | < 1ms Loop.init | |

## 6. 마일스톤

### Phase 1 — Loop Core
- 1A `io/completion.zig` — Op union, Result, 인트루시브 큐
- 1B `io/backend/kqueue.zig` — accept/connect/read/write/close/timeout
- 1C `io/backend/epoll.zig` — 동일 op 세트
- 1D `io/timer.zig` — 타이밍 휠
- 1E `io/loop.zig` — 백엔드 디스패치, run 모드, wakeup, cancel
- 1F 테스트: 루프백 echo, 타이머 정확도, 취소 경합, 누수 0

### Phase 2 — Net
- 2A `net/address.zig` — IPv4/IPv6/Unix 파싱·포맷
- 2B `net/tcp.zig`, `net/udp.zig`, `net/unix.zig`
- 2C `net/dns.zig` — 리졸버
- 2D `net/pool.zig` — 커넥션 풀
- 2E `bench/echo.zig` — 1차 성능 측정

### Phase 3 — TLS
- 3A `tls/client.zig` — 비동기 핸드셰이크 + read/write
- 3B `tls/pem.zig` — 인증서/키 로딩
- 3C `tls/server.zig` — TLS 1.3 서버 (리스크: std 미지원 시 자체 구현)
- 3D ALPN/SNI

### Phase 4 — HTTP
- 4A `http/parser.zig` — h1 요청/응답 파서 (fuzz 필수)
- 4B `http/client.zig` — Client + 재시도/리다이렉트/풀링
- 4C `http/server.zig` — Server + graceful shutdown
- 4D `ws/` — WebSocket
- 4E `http/h2/` — HPACK, 스트림

### Phase 5 — Task & Multi-core
- 5A `task/thread_pool.zig`, `task/channel.zig`
- 5B `task/cancel.zig` — 계층적 취소
- 5C `task/scheduler.zig` — SO_REUSEPORT 멀티 루프
- 5D io_uring 백엔드
- 5E Windows IOCP 백엔드

### Phase 6 — Integration
- 6A silica 서버를 sirocco로 이식 (PoC 브랜치)
- 6B zr downloader를 `sirocco.http.Client`로 교체
- 6C sailor httpclient/websocket 위젯 위임
- 6D synod Transport 어댑터

## 7. API 설계 원칙

- **콜백 우선, 코루틴 나중**: v1은 completion 콜백. Zig async가 안정되면 어댑터 추가.
- **에러는 `error.` 유니온으로**: `error.ConnectionReset`, `error.Timeout`, `error.Cancelled`, `error.TlsHandshakeFailed` — 절대 `@panic` 금지.
- **버퍼는 호출자 소유**: 런타임은 사용자 버퍼를 복사하지 않는다.
- **모든 블로킹 지점에 데드라인**: connect/read/write/dns 모두 timeout 파라미터 필수.
- **관측 훅**: `Loop.Options.metrics` 콜백으로 op 수/지연을 외부 메트릭 시스템에 전달 (관측성 컴포넌트가 생기면 연결).

## 8. 테스트 전략

- 루프백 통합 테스트 (매 op 타입)
- 취소/타임아웃 경합 테스트 — `std.testing.fuzz`로 op 시퀀스 생성
- HTTP 파서 fuzz 캠페인 (잘못된 헤더, 청크 경계, 거대 헤더)
- TLS: 실제 `openssl s_server` 대상 인터롭 테스트 (CI에서 선택 실행)
- 누수: 모든 테스트 `std.testing.allocator`

## 9. 리스크

| 리스크 | 완화 |
|---|---|
| std TLS 서버 미지원 | Phase 3C를 별도 트랙으로, 초기엔 클라이언트만으로 zr/sailor 요구 충족 |
| io_uring API 변동 | epoll을 기본으로, io_uring은 opt-in |
| Zig std.Io 변화 | vtable 경계에 격리 |
