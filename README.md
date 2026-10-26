# sirocco

> The wind that drives the fleet — an implementation of `std.Io.VTable` for Zig

sirocco는 Zig 0.16의 `std.Io.VTable`을 구현하는 것을 목표로 하는 제로 의존성 파운데이션
컴포넌트다. 목표 공개 표면은 `Runtime.io()`가 반환하는 `std.Io` 하나뿐이며, 소비자는
`std.Io`·`Io.net`·`Io.Dir`/`Io.File`·`std.http.Client`·`std.crypto.tls.Client` 등 이미 알고
있는 std 타입으로 그대로 sirocco 위에서 동작하게 될 예정이다. 설계상 kqueue(macOS/BSD)·
epoll(Linux) 백엔드로 109개 vtable 슬롯을 채우고, 아직 네이티브로 구현하지 않은 슬롯
(`dir*`, `process*`/`child*`, `random`/`randomSecure`, `progressParentFile`)은 내장된
`Io.Threaded`로 명시적으로 위임하도록 되어 있다 (아래 Status 참고 — 현재는 파이버 기반
동시성·futex·`sleep`·소켓 슬롯이 네이티브다). 완성되면 silica·zoltraak 서버, zr의
다운로더·원격 캐시, sailor의 네트워크 위젯, synod의 Transport가 이 위에서 `main()`의 한
줄만 바꿔 동작하는 것이 목표다.

[![CI](https://github.com/yusa-imit/sirocco/workflows/CI/badge.svg)](https://github.com/yusa-imit/sirocco/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.x-orange.svg)](https://ziglang.org)

---

## Status

**v0.5.0 — 내부 마일스톤, 소비자용 아님.** 설계는 `docs/adr/0001-std-io-vtable.md`로
확정되었고, 109개 슬롯 중 `Runtime`이 네이티브로 구현한 것은 32개다: 파이버 위의
동시성·취소(`async`/`concurrent`/`await`/`cancel`, `group*`, `checkCancel`/`recancel`/
`swapCancelProtection`, `crashHandler`), `futexWait`/`futexWake`, `sleep`, 소켓(`netListenIp`,
`netAccept`, `netBindIp`, `netConnectIp`, `netListenUnix`, `netConnectUnix`,
`netSocketCreatePair`, `netRead`, `netWrite`, `netSend`, `netShutdown`, `netClose`), 그리고
제출 엔진(`operate`, `batchAwaitAsync`, `batchAwaitConcurrent`, `batchCancel`)이다.
`Options.backend = .auto`는 macOS에서 `.kqueue`, Linux에서 `.epoll`(캐리어가 폴러에서
대기, `docs/adr/0003-evented-backends.md`), 그 외에서는 `.threaded`로 해석되며
`Options.sockets_max`는 필수다. 폴러에 등록된 소켓(`sockets_max`개까지)과 논블로킹 파일
스트림은 호출한 파이버만 멈추고, 등록 한도를 넘거나 외부 핸들이거나 파이버 밖에서 만든
소켓은 오프로드 풀(`Options.offload_threads`)로 간다. 나머지 슬롯은 내장 `Io.Threaded`로
위임된다(`Options.unimplemented`). `concurrent`는 빈 파이버가 있으면 그 위에서 실행하고
`async`가 인라인으로 돌 상황(스케줄러 없음, `fibers_max` 소진)에서만
`error.ConcurrencyUnavailable`을 반환한다. 캐리어는 아직 하나다. 유휴 `batchAwait*`는 폴러
이벤트가 아니라 최대 2 ms의 휠 슬라이스로 깨어난다(`docs/adr/0003-evented-backends.md`
2c). 성능 게이트(PRD §5, macOS kqueue): 2·3은 통과(0.91x, p99 127 ms 대 162 ms; 3은 8회
중 7회), 1(1000 연결 0.83x–0.87x, 목표 2.0x)과 4(유휴 태스크당 29.2 KB 대 24.7 KB)는 미달이며
다음 플랜(멀티 캐리어)이 다룬다. silica/zoltraak에 쓸 준비는 아직 되지 않았다. 파이버
스케줄러는 aarch64/x86_64에서만 동작하며(`Runtime.fibers_supported`), 그 외 타깃에서는 슬롯이
위임 상태로 남는다. 작업 순서는 `docs/plans/`가 기준이다. 안정 릴리즈 전까지 API는 변경될 수
있다.

## Design

sirocco는 소비자가 올라타는 새 API가 아니라, std가 이미 정의한 `std.Io.VTable` 아래 꽂는
플러그다 — 별도의 `io`/`net`/`tls`/`http`/`ws`/`task` 공개 모듈은 없다. 전체 설계는
`docs/PRD.md`, 그 근거는 `docs/adr/0001-std-io-vtable.md` 참고.

```zig
pub const Runtime = struct {
    pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Runtime;
    pub fn deinit(rt: *Runtime) void;

    /// The whole public surface. Hand this to the code that does the work.
    pub fn io(rt: *Runtime) std.Io;

    /// Io.Threaded, for differential tests and as an escape hatch.
    pub fn baselineIo(rt: *Runtime) std.Io;
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

## Install

```
zig fetch --save https://github.com/yusa-imit/sirocco/archive/refs/tags/v0.5.0.tar.gz
```

```zig
// build.zig
const sirocco = b.dependency("sirocco", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("sirocco", sirocco.module("sirocco"));
```

During development against an unreleased change, point `build.zig.zon` at a local checkout
instead:

```zig
// build.zig.zon
.dependencies = .{
    .sirocco = .{ .path = "../sirocco" },
},
```

See `CHANGELOG.md` for what shipped in each release.

## Build

```bash
zig build            # library + CLI
zig build test       # unit tests
zig build tidy       # Tiger Style mechanical checks (line/function length, ban list, headers)
zig build bench      # benchmarks
zig build docs       # API docs → zig-out/docs
```

## Part of the Zig Kingdom

sirocco is a foundation component consumed by: silica, zoltraak, zr, sailor, synod.
See [citadel](https://github.com/yusa-imit/citadel) for the full map.

## License

MIT — see [LICENSE](LICENSE).
