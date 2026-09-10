# sirocco

> The wind that drives the fleet — an implementation of `std.Io.VTable` for Zig

sirocco는 Zig 0.16의 `std.Io.VTable`을 구현하는 제로 의존성 파운데이션 컴포넌트다. 공개 표면은
`Runtime.io()`가 반환하는 `std.Io` 하나뿐이며, 소비자는 `std.Io`·`Io.net`·`Io.Dir`/`Io.File`·
`std.http.Client`·`std.crypto.tls.Client` 등 이미 알고 있는 std 타입으로 그대로 sirocco 위에서
동작한다. kqueue(macOS/BSD)·epoll(Linux) 백엔드로 109개 vtable 슬롯을 채우며, 아직 네이티브로
구현하지 않은 슬롯(`dir*`, `process*`/`child*`, `random`/`randomSecure`, `progressParentFile`)은
내장된 `Io.Threaded`로 명시적으로 위임한다. silica·zoltraak 서버, zr의 다운로더·원격 캐시,
sailor의 네트워크 위젯, synod의 Transport가 이 위에서 `main()`의 한 줄만 바꿔 동작한다.

[![CI](https://github.com/yusa-imit/sirocco/workflows/CI/badge.svg)](https://github.com/yusa-imit/sirocco/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.x-orange.svg)](https://ziglang.org)

---

## Status

**Bootstrap** — 설계가 `docs/adr/0001-std-io-vtable.md`로 확정되었고, 109개 슬롯 구현은
아직 시작 전이다 (`docs/plans/`가 실제 순서). 안정 릴리즈 전까지 API는 변경될 수 있다.

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
zig fetch --save https://github.com/yusa-imit/sirocco/archive/refs/tags/v0.2.0.tar.gz
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
