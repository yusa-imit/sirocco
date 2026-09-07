# sirocco — Product Requirements Document

> **sirocco**: 함대를 밀어주는 바람. Zig 왕국의 `std.Io.VTable` 구현체.
> Layer: **Foundation** · Consumers: silica, zoltraak, zr, sailor, synod
> Design decision: `docs/adr/0001-std-io-vtable.md`

---

## 1. 배경과 문제

왕국의 서버 제품(silica, zoltraak)과 도구(zr, sailor)가 각자 TCP 서버, 커넥션 처리, TLS, HTTP 클라이언트를 따로 구현하고 있었다.

Zig 0.16.0은 `std.Io` — 런타임 vtable 값(`Io = struct { userdata: ?*anyopaque, vtable: *const VTable }`, 109개 슬롯)을 도입했다. `std.net`은 삭제되었고, `std.fs`/`std.time`/`std.Thread` 동기화 프리미티브 대부분이 `Io.net`, `Io.Dir`/`Io.File`, `Io.Clock`, `Io.Mutex`/`Io.Group`/`Io.Queue`로 재편되었다. `std.http.Client`와 `std.crypto.tls.Client`도 같은 vtable로 디스패치한다. 왕국의 다섯 소비자(silica, zoltraak, zr, sailor, synod) 모두 `io: std.Io`를 받는 방향으로 이미 마이그레이션 중이다.

즉, sirocco가 원래 만들려던 것(완성 기반 이벤트 루프, 취소 1급 지원, 명시적 데드라인)을 std가 이미 인터페이스로 정의했다. 문제는 남아 있다: 0.16.0 pinned 툴체인 기준으로 std가 제공하는 evented `Io` 구현체 중 네트워킹이 실제로 동작하는 것이 하나도 없다.

| 구현체 | 컴파일 | 네트워킹 | 비고 |
|---|---|---|---|
| `Io.Threaded` | O | 완전 | 스레드풀 기반. 유일하게 출하 가능한 std `Io` |
| `Io.Dispatch` (Darwin `Evented`) | O | 모든 `net*` 슬롯이 `…Unavailable` | GCD 기반 |
| `Io.Uring` (Linux `Evented`) | **X** | 모든 `net*` 슬롯이 `…Unavailable` | 에러셋 불일치, `Uring.zig:2732`, `:3157` |
| `Io.Kqueue` (BSD `Evented`) | **X** | 실제 `net*` 구현 있음 | `fileWriteStreaming` 참조 — 현재 `VTable`엔 없는 슬롯 |

sirocco가 존재하는 이유는 "이벤트 루프를 만드는 것"이 아니라 이 공백 — 어떤 플랫폼에서도 네트워킹이 동작하는 evented `Io`가 pinned 툴체인에 없다는 것 — 을 메우는 것이다.

## 2. 목표 (Goals)

1. **`std.Io.VTable`의 완전한 구현체**: kqueue(macOS/BSD), epoll(Linux), 추후 io_uring(Linux)/IOCP(Windows) 백엔드로 109개 슬롯을 채운다. 공개 API는 `std.Io` 하나뿐이다.
2. **제로 의존성**: Zig std만 사용.
3. **선언된 하이브리드**: 아직 네이티브로 구현하지 않은 슬롯(`dir*`, `process*`/`child*`, `random`/`randomSecure`, `progressParentFile`)은 내장된 `Io.Threaded`로 명시적으로 위임한다 — 숨겨진 미구현이 아니라 `Options.unimplemented`로 드러나는, 테스트되는 위임이다.
4. **명시적 자원 관리**: allocator-first, 모든 소켓/타이머/파이버는 `Runtime.init`에서 상한만큼 할당, 취소는 std의 `Io.Cancelable`/`error.Canceled`(l 하나) 어휘를 그대로 따른다 — sirocco 고유의 취소 타입은 없다.
5. **서버 제품이 요구하는 수준**: 10k 동시 연결, 커넥션당 고정 메모리 상한, 백프레셔, graceful shutdown.
6. **정합성의 오라클**: 109개 슬롯 전부 `Io.Threaded`와의 차등 테스트(differential test)로 검증한다. 하나의 `Runtime`에서 `rt.io()`와 `rt.baselineIo()` 두 값을 얻어 같은 입력에 같은 결과가 나오는지 비교한다.

## 3. 비목표 (Non-Goals)

- 독립된 `net`/`tls`/`http`/`ws` 공개 API — 이제 이들은 std 타입(`Io.net`, `std.crypto.tls.Client`, `std.http.Client`)이 sirocco의 vtable 위에서 그대로 동작하므로 sirocco가 다시 노출할 필요가 없다.
- WebSocket — std에 없으므로 필요하다면 `Io.Reader`/`Io.Writer` 위의 별도 애드온 모듈로, 별도 ADR을 거쳐 v1 이후 검토.
- 커넥션 풀(`Pool(T)`) — vtable의 관심사가 아니다. vtable이 완성된 뒤 애드온으로 검토.
- 웹 프레임워크(라우팅 DSL, 템플릿) — 상위 레이어 별도 프로젝트.
- gRPC / HTTP/3(QUIC) — v1 이후 검토.

## 4. 아키텍처

sirocco는 소비자가 올라타는 탑이 아니라, std가 이미 만든 탑 아래 꽂는 플러그다.

```
     consumer code (silica · zoltraak · zr · sailor · synod)
     — writes only against std types —
  ┌──────────────────────────────────────────────────────────────┐
  │ std.http.Client/Server · std.crypto.tls.Client · Io.net       │
  │ Io.Dir/Io.File · Io.Clock · Io.Group/Queue/Mutex/Event        │
  └──────────────────────────────────────────────────────────────┘
                    all dispatch through
  ┌──────────────────────────────────────────────────────────────┐
  │                std.Io  { userdata, vtable }                   │
  └──────────────────────────────────────────────────────────────┘
             chosen once, in the consumer's main()
  ┌────────────────────────────┐        ┌────────────────────────┐
  │ sirocco.Runtime.io()       │   or   │ Io.Threaded.io()       │
  │ 69 native + 40 forwarded   │        │ 109 native (baseline)  │
  └────────────────────────────┘        └────────────────────────┘
```

내부 파일 구성 (그룹당 파일 하나, 슬롯 필드를 이름으로 부르는 곳은 `src/runtime.zig` 뿐):

```
  src/runtime.zig    vtable assembly + Options; the ONLY file that names slot fields
       │  base = Threaded's vtable (or Io.failing's, under .unimplemented = .fail)
       │  overrides installed per group
       ├── src/sched.zig   P0: fibers, run queues, park/unpark, cancel state, Group
       ├── src/futex.zig   P1: wait/wake table keyed by address
       ├── src/timer.zig   P2: timing wheel; now/clockResolution/sleep/deadlines
       ├── src/submit.zig  P3: Operation/Batch -> backend submission and completion
       ├── src/net.zig     P4: 16 net* slots (socket setup, accept, connect, vectored rw)
       ├── src/file.zig    P5: 28 file* slots
       ├── src/stderr.zig  P6: lockStderr/tryLockStderr/unlockStderr
       ├── src/hybrid.zig  H:  the forwarded set, named and asserted, one list
       └── src/backend/{kqueue,epoll,uring,iocp}.zig
                          readiness/completion only; the ONLY files touching OS APIs
       and:  threaded: Io.Threaded   embedded; forwarding target, fallback scheduler,
                                     and differential-test oracle, all one field
```

옛 공개 모듈이 어디로 갔는지:

| old public module | now |
|---|---|
| `io` (Loop, Completion, Timer) | internal — `sched`/`timer`/`submit`/`backend`; std owns the op vocabulary (`Io.Operation`, `Io.Batch`) |
| `net` (tcp/udp/unix/addr) | internal — implements the 16 `net*` slots; addresses are `Io.net.IpAddress` |
| `net` (DNS resolver) | internal — implements `netLookup` |
| `net` (`Pool(T)`) | out of v1 scope |
| `tls` | dropped — `std.crypto.tls.Client.init(reader, writer, options)` runs on sirocco's `net*` slots unchanged |
| `http` (h1, h2, client, server) | dropped — `std.http` takes `io: Io` |
| `ws` | dropped from v1 |
| `task` (ThreadPool, Channel, WaitGroup, CancelToken, Scheduler) | dropped — `Io.Group`, `Io.Queue`, `Io.Event`, `swapCancelProtection`, sirocco's own carrier threads cover all five |

### 4.1 Public API

```zig
//! sirocco — an implementation of `std.Io.VTable` with evented backends.

const std = @import("std");
const Io = std.Io;

pub const version: std.SemanticVersion = .{ .major = 0, .minor = 2, .patch = 0 };

/// Compile-time guard: sirocco's vtable is exhaustive against the pinned std.
comptime {
    std.debug.assert(@typeInfo(Io.VTable).@"struct".fields.len == 109);
}

pub const Runtime = struct {
    /// Forwarding target for the declared hybrid, fallback scheduler, and the
    /// differential-test oracle. Its address is this runtime's `Io.userdata`;
    /// sirocco state is recovered with `@fieldParentPtr("threaded", t)`.
    threaded: Io.Threaded,
    /// Threaded's vtable with sirocco's slots written over it. Never shared.
    vtable: Io.VTable,
    backend: Backend,
    // ... fibers, timer wheel, futex table, backend state; all sized at init.

    pub const Backend = enum { auto, kqueue, epoll, uring, threaded };

    /// What a not-yet-native slot does. `.forward` is the shipping hybrid;
    /// `.fail` installs `Io.failing`'s stub so a test cannot pass by accident.
    pub const Unimplemented = enum { forward, fail };

    pub const Options = struct {
        backend: Backend = .auto,
        unimplemented: Unimplemented = .forward,
        /// 0 selects one carrier thread per CPU.
        carrier_threads: u16 = 0,
        /// Limits are part of the signature. All storage is reserved at init.
        fibers_max: u32 = 4096,
        fiber_stack_bytes: u32 = 64 * 1024,
        pending_ops_max: u32 = 4096,
        sockets_max: u32 = 4096,
        timers_max: u32 = 4096,
    };

    pub const InitError = error{
        OutOfMemory,
        BackendUnavailable,
        FibersUnsupported,
        SystemResources,
        Unexpected,
    };

    /// Allocates every fiber stack, timer slot and op slot here; never after.
    pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Runtime;
    pub fn deinit(rt: *Runtime) void;

    /// The whole public surface. Hand this to the code that does the work.
    pub fn io(rt: *Runtime) Io;

    /// The same runtime's forwarding base, for differential tests and for a
    /// consumer that wants an escape hatch without a second construction path.
    pub fn baselineIo(rt: *Runtime) Io;
};
```

Call site — and the entire acceptance test:

```zig
pub fn main(init: std.process.Init) !void {
    var rt: sirocco.Runtime = try .init(init.gpa, .{ .sockets_max = 16_384 });
    defer rt.deinit();
    try server.run(rt.io(), ...);   // was: init.io
}
```

### 4.2 Invariants

- One construction path: `Runtime.init`. `Options` carries every same-typed scalar limit.
- Zero allocation after `init`. `Io.Operation.Storage` is caller-owned and intrusive by std's
  own design — sirocco never heap-allocates per operation.
- Only `src/backend/*` names an OS API. Every other file sees fibers, ops and completions.
- Only `src/runtime.zig` names a `VTable` field. A std vtable change is one file's edit.
- `error.Canceled`, one `l`. Every `Cancelable` slot is a cancellation point unless
  `CancelProtection.blocked` is in effect; no exhaustive I/O `switch` may `else => unreachable`.
- `async` promises completion, not concurrency; only `concurrent` promises concurrency, and
  refuses with `error.ConcurrencyUnavailable`.
- Buffers are caller-owned; `netRead`/`netWrite`/`fileReadPositional` are vectored
  (`[]const []u8`) and copy nothing.

### 4.3 슬롯 우선순위 (109 슬롯, 구현 순서)

이름은 `/Users/fn/.zr/toolchains/zig/0.16.0/lib/std/Io.zig:51-255`에서 그대로 가져왔다.

- **P0 — 동시성/취소 코어 (12)**: 나머지 모든 슬롯이 이 위에서 suspend 한다.
  `crashHandler` · `async` · `concurrent` · `await` · `cancel` · `groupAsync` ·
  `groupConcurrent` · `groupAwait` · `groupCancel` · `recancel` · `swapCancelProtection` ·
  `checkCancel`
- **P1 — futex (3)**: `Io.Mutex`/`Condition`/`Event`/`Semaphore`/`RwLock`/`Queue`가 모두 이
  세 개 위에 세워진다. `futexWait` · `futexWaitUncancelable` · `futexWake`
- **P2 — 시간 (3)**: `now` · `clockResolution` · `sleep` (`Io.Timeout` = `.none | .duration |
  .deadline` 을 받는다; 공개 `io.sleep(duration, clock)`은 별도 2-인자 형태)
- **P3 — 제출 엔진 (4)**: `Io.Operation`이 `file_read_streaming`, `file_write_streaming`,
  `device_io_control`, `net_receive`를 포함한다 — 즉 모든 스트리밍 read/write와 모든
  데이터그램 수신은 `file*`/`net*`가 아니라 여기를 지난다. `operate` · `batchAwaitAsync` ·
  `batchAwaitConcurrent` · `batchCancel`
- **P4 — 네트워킹 (16)**: sirocco를 링크할 가치가 있게 만드는 마일스톤.
  `netListenIp` · `netAccept` · `netBindIp` · `netConnectIp` · `netListenUnix` ·
  `netConnectUnix` · `netSocketCreatePair` · `netSend` · `netRead` · `netWrite` ·
  `netWriteFile` · `netClose` · `netShutdown` · `netInterfaceNameResolve` ·
  `netInterfaceName` · `netLookup`
- **P5 — 파일 (28)**: `fileMemoryMap*` 5개는 그룹 내에서 가장 낮은 우선순위로 분리 가능.
  `fileStat` · `fileLength` · `fileClose` · `fileWritePositional` · `fileWriteFileStreaming` ·
  `fileWriteFilePositional` · `fileReadPositional` · `fileSeekBy` · `fileSeekTo` · `fileSync` ·
  `fileIsTty` · `fileEnableAnsiEscapeCodes` · `fileSupportsAnsiEscapeCodes` · `fileSetLength` ·
  `fileSetOwner` · `fileSetPermissions` · `fileSetTimestamps` · `fileLock` · `fileTryLock` ·
  `fileUnlock` · `fileDowngradeLock` · `fileRealPath` · `fileHardLink` ·
  `fileMemoryMapCreate` · `fileMemoryMapDestroy` · `fileMemoryMapSetLength` ·
  `fileMemoryMapRead` · `fileMemoryMapWrite`
- **P6 — stderr 잠금 (3)**: `std.log`/`std.debug`/`std.Progress`가 모두 경유하므로, 전달된
  버전이 sirocco 자신의 스케줄러와 데드락을 일으키지 않는지가 중요하다.
  `lockStderr` · `tryLockStderr` · `unlockStderr`
- **H — 선언된 하이브리드: 내장 `Io.Threaded`로 위임 (40)**: "미구현"이 아니라 "위임으로
  구현됨"이며 `Options`에 드러나고 나머지와 동일하게 차등 테스트된다.
  - `dir*` (26): `dirCreateDir` · `dirCreateDirPath` · `dirCreateDirPathOpen` · `dirOpenDir` ·
    `dirStat` · `dirStatFile` · `dirAccess` · `dirCreateFile` · `dirCreateFileAtomic` ·
    `dirOpenFile` · `dirClose` · `dirRead` · `dirRealPath` · `dirRealPathFile` ·
    `dirDeleteFile` · `dirDeleteDir` · `dirRename` · `dirRenamePreserve` · `dirSymLink` ·
    `dirReadLink` · `dirSetOwner` · `dirSetFileOwner` · `dirSetPermissions` ·
    `dirSetFilePermissions` · `dirSetTimestamps` · `dirHardLink`
  - `process*`/`child*` (11): `processExecutableOpen` · `processExecutablePath` ·
    `processCurrentPath` · `processSetCurrentDir` · `processSetCurrentPath` ·
    `processReplace` · `processReplacePath` · `processSpawn` · `processSpawnPath` ·
    `childWait` · `childKill`
  - randomness (2): `random` · `randomSecure`
  - progress (1): `progressParentFile`

(12 + 3 + 3 + 4 + 16 + 28 + 3 + 40 = 109)

## 5. 성능 목표 (targets are gates, not predictions)

sirocco가 알려줘야 하는 유일하게 의미 있는 수치는 **같은 머신, 같은 벤치마크, 같은
`Runtime`에서 `Io.Threaded` 대비 비율**이다. 절대 req/s 수치는 러닝타임보다 박스에 대해
더 많은 것을 말해준다. 아래 다섯 항목(1M req/s echo, 500k req/s HTTP, p99 < 1ms, 8KB/conn,
Loop.init < 1ms)은 측정된 적이 없고 그중 둘은 더 이상 출하하지 않는 스택(HTTP 서버, echo
서버)을 측정하던 것이었으므로 전부 삭제한다. 각 행은 예측이 아니라 해당 마일스톤이
닫히기 위해 통과해야 하는 게이트다.

| # | gate | measured by | milestone |
|---|---|---|---|
| 1 | loopback echo throughput at 1000 concurrent connections: **>= 2.0x** `Io.Threaded` | `bench/echo.zig`, both `Io`s from one `Runtime` | net |
| 2 | loopback echo throughput at concurrency 1: **>= 0.9x** `Io.Threaded` (no regression on the trivial case) | same | net |
| 3 | accept->first-byte p99 at 1000 connections: **<=** `Io.Threaded` p99 | `bench/latency.zig` | net |
| 4 | resident bytes per idle connection: **<=** one `Io.Threaded` task, recorded absolutely | RSS delta over 10k connections / 10k | net |
| 5 | `Runtime.init` allocation count: **constant in connection count**, 0 allocations after init | `std.testing.allocator` counting harness | core |
| 6 | `io.async` -> body-entered latency: **<=** `Io.Threaded` at 1 and at 1000 in flight | `bench/spawn.zig` | core |
| 7 | timer wake error, 1ms sleep: p99 **< 2ms**, and **<=** `Io.Threaded` | `bench/timer.zig` | time |
| 8 | full differential suite wall clock under `zig build test`: **< 60s** on CI | `zig build test` timing | every |
| 9 | `zig build test` stays under `Step.Run.unit_test_timeout_ns` with no test exempted | build output | every |

| date | backend | machine | gate | measured |
|---|---|---|---|---|
| | | | | |

v1에서 명시적으로 타겟하지 않음: HTTP req/s(std가 파서를 소유), TLS 핸드셰이크 속도(std가
암호화를 소유), `zig build bench`로 kingdom CI 머신에서 재현 불가능한 수치.

## 6. 마일스톤

Phase 1–6 체크리스트는 `docs/plans/000-inherited.md`에 있다. `docs/adr/0001-std-io-vtable.md`
말미의 표가 각 항목이 vtable 모델에서 어떻게 재해석되는지(그대로 내부 구현으로 남음 /
std가 대체함 / v1 범위 밖) 정리한다. 다음 플랜(002)이 실제 슬롯 구현 순서(§4.3)를 기준으로
새 체크리스트를 연다.

## 7. API 설계 원칙

- **공개 표면은 std 타입 하나**: `Runtime.io()`가 반환하는 `std.Io`. 별도의 콜백/코루틴
  선택은 없다 — 동시성 모델은 `io.async`/`io.concurrent`/`Io.Future`/`Io.Group`으로 std가
  결정했고, sirocco는 그 계약(`async`는 완료만 보장, `concurrent`만 동시 실행을 보장하며
  실패 시 `error.ConcurrencyUnavailable`)을 그대로 지킨다.
- **에러는 std의 어휘를 따른다**: `error.Canceled`(l 하나), `error.ConnectionResetByPeer`,
  `error.Timeout` 등 `Io`가 이미 정의한 에러셋. sirocco가 새 에러 이름을 만들지 않는다.
  `@panic` 금지.
- **버퍼는 호출자 소유**: 런타임은 사용자 버퍼를 복사하지 않는다. `net*`/`file*`의
  read/write는 벡터화(`[]const []u8`)되어 있다.
- **모든 블로킹 지점에 데드라인**: `Io.Timeout`(`.none | .duration | .deadline`)이
  `batchAwaitConcurrent`를 통해 모든 op에 적용된다.
- **관측 훅**: 백엔드별 op 수/지연 카운터를 `Runtime.Options`에 노출 (관측성 컴포넌트가
  생기면 연결).

## 8. 테스트 전략

- **차등 테스트**: `tests/parity/<group>.zig`, 슬롯 그룹당 파일 하나.
  `fn expectSameResult(rt: *Runtime, comptime call: anytype, args: anytype) !void`가
  `rt.io()`와 `rt.baselineIo()` 양쪽으로 같은 호출을 실행하고 결과 태그, 페이로드,
  에러 이름을 비교한다.
- **커버리지 단언**: `tests/parity/slots.zig`에 109개 슬롯 이름의 comptime 표를 두고,
  "네이티브+차등테스트 있음" 목록과 "위임됨" 목록 어느 쪽에도 없는 슬롯이 있으면 빌드
  실패. 위임된 슬롯도 테스트한다(오늘은 자명하게 통과 — 그래서 나중에 네이티브로
  바뀌는 날 회귀를 잡는 테스트가 이미 존재한다).
- **취소 패리티**: `Cancelable` 슬롯마다 비행 중 취소해서 양쪽 구현이 같은 지점에서
  `error.Canceled`를 반환하는지, `swapCancelProtection(.blocked)` 하에서는 둘 다
  반환하지 않는지 확인.
- **모델 테스트**: 시드된 op 시퀀스(`std.testing.Smith`, 0.16 fuzz 형태)를 양쪽 `Io`에
  재생하며 completion trace를 비교.
- **`Io.failing` 정합성**: `.unimplemented = .fail`로 전체 스위트를 한 번 더 실행 —
  Threaded로 폴백해서만 통과하던 테스트를 여기서 잡는다.
- **누수 패리티**: 양쪽 모두 `std.testing.allocator`; 테스트 자신의 I/O는
  `std.testing.io`에서만 가져온다.
- **스왑 테스트(인수 조건)**: 실제 소비자의 테스트 스위트를 `init.io`와 `rt.io()` 양쪽으로
  두 번 실행해 바이트 단위로 동일한 결과를 확인.

## 9. 리스크

| 리스크 | 완화 |
|---|---|
| std `Io.VTable`이 0.17에서 변경됨 | 슬롯 필드를 이름으로 부르는 곳은 `src/runtime.zig` 하나뿐; `@typeInfo(Io.VTable).@"struct".fields.len == 109` comptime 단언으로 std 버전 변경을 빌드 타임에 크게 실패시킨다; 툴체인은 0.16.0에 정확히 고정 |
| 위임된 슬롯이 캐리어 스레드를 블록하고 sirocco의 취소를 무시함 | 슬롯별로 문서화된 한계 — 해당 슬롯이 네이티브로 바뀌는 시점에 종료됨 |
| 파이버가 모든 타겟에서 지원되지 않음(`Io.fiber.supported`는 aarch64/riscv64/x86_64에서만 true) | `.backend = .auto`는 미지원 타겟에서 `.threaded`로 해석되어야 하며, `Io.Evented`에 대한 무조건적 참조는 금지 |
| macOS CI 공백 (kqueue가 첫 백엔드, cross-compile은 런타임 백엔드 버그를 못 잡음) | 플랜 001은 미룸; 다음 플랜은 미룰 수 없음 |
| io_uring API 변동 | epoll을 기본으로, io_uring은 opt-in |
