# sirocco

> The wind that drives the fleet — async I/O runtime and network stack for Zig

sirocco는 kqueue/epoll/io_uring/IOCP를 하나의 완성 기반(completion-based) API로 추상화한 이벤트 루프 위에 TCP/UDP/Unix 소켓, DNS, 커넥션 풀, TLS 1.3, HTTP/1.1·HTTP/2, WebSocket을 얇게 쌓은 제로 의존성 네트워크 스택이다. silica·zoltraak 서버, zr의 다운로더·원격 캐시, sailor의 네트워크 위젯, synod의 Transport가 이 위에서 동작한다.

[![CI](https://github.com/yusa-imit/sirocco/workflows/CI/badge.svg)](https://github.com/yusa-imit/sirocco/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.x-orange.svg)](https://ziglang.org)

---

## Status

**Bootstrap** — API 설계 및 Phase 1 구현 중. 안정 릴리즈 전까지 API는 변경될 수 있다.

## Modules

| Module | Purpose |
|---|---|
| `sirocco.io` | Event loop, completions, timers, cancellation. Backends: kqueue, epoll, io_uring, iocp. |
| `sirocco.net` | Sockets (tcp, udp, unix), address parsing, DNS resolver, connection pool. |
| `sirocco.tls` | TLS 1.3 client/server on std.crypto.tls with async handshake, ALPN, SNI, PEM loading. |
| `sirocco.http` | HTTP/1.1 parser, client (retry/redirect/pool/proxy), server (graceful shutdown), HTTP/2 (HPACK, streams). |
| `sirocco.ws` | WebSocket (RFC 6455) client and server framing, ping/pong, close handshake. |
| `sirocco.task` | Thread pool, bounded channel, wait group, hierarchical cancellation, multi-loop scheduler. |

## Install

```bash
zig fetch --save https://github.com/yusa-imit/sirocco/archive/refs/tags/v0.1.0.tar.gz
```

```zig
// build.zig
const sirocco = b.dependency("sirocco", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("sirocco", sirocco.module("sirocco"));
```

## Build

```bash
zig build            # library + CLI
zig build test       # unit tests
zig build bench      # benchmarks
zig build docs       # API docs → zig-out/docs
```

## Part of the Zig Kingdom

sirocco is a foundation component consumed by: silica, zoltraak, zr, sailor, synod.
See [citadel](https://github.com/yusa-imit/citadel) for the full map.

## License

MIT — see [LICENSE](LICENSE).
