# sirocco — Claude Code Orchestrator

> **sirocco**: The wind that drives the fleet — async I/O runtime and network stack for Zig
> Current Phase: **Bootstrap → Phase 1**
> Kingdom layer: **Foundation** · Consumers: silica, zoltraak, zr, sailor, synod

---

## Project Overview

- **Language**: Zig 0.15.2
- **Type**: Library (consumed via `build.zig.zon`) + small CLI
- **Build**: `zig build` / `zig build test` / `zig build bench`
- **PRD**: `docs/PRD.md` (전체 요구사항 — 반드시 먼저 읽는다)
- **Milestones**: `docs/milestones.md` (진행 상황의 단일 진실)
- **Branch Strategy**: `main` (development)
- **Dependencies**: Zig std만. 왕국의 다른 컴포넌트에 의존하지 않는다 (어댑터는 예외, PRD 참조)
- **Kingdom map**: `citadel` 레포의 `docs/KINGDOM.md`

sirocco는 kqueue/epoll/io_uring/IOCP를 하나의 완성 기반(completion-based) API로 추상화한 이벤트 루프 위에 TCP/UDP/Unix 소켓, DNS, 커넥션 풀, TLS 1.3, HTTP/1.1·HTTP/2, WebSocket을 얇게 쌓은 제로 의존성 네트워크 스택이다. silica·zoltraak 서버, zr의 다운로더·원격 캐시, sailor의 네트워크 위젯, synod의 Transport가 이 위에서 동작한다.

## Repository Structure

```
sirocco/
├── CLAUDE.md                    # THIS FILE — orchestrator
├── docs/PRD.md                  # Product Requirements Document
├── docs/milestones.md           # Phase checklist (single source of truth)
├── .claude/
│   ├── agents/                  # zig-developer, test-writer, code-reviewer, architect, git-manager, ci-cd
│   ├── commands/                # /build /test /implement /fix /review /status /release /bench
│   ├── memory/                  # project-context, architecture, decisions, debugging, patterns
│   └── settings.json
├── .github/workflows/ci.yml     # Build, test, fmt, cross-compile
├── src/
│   ├── root.zig                 # Library root — re-exports all public modules
│   ├── main.zig                 # CLI entry point
│   ├── io.zig                  # Event loop, completions, timers, cancellation
│   │   ├── io/completion.zig
│   │   ├── io/loop.zig
│   │   ├── io/timer.zig
│   │   ├── io/backend/kqueue.zig
│   │   ├── io/backend/epoll.zig
│   │   ├── io/backend/io_uring.zig
│   │   ├── io/backend/iocp.zig
│   ├── net.zig                 # Sockets (tcp, udp, unix), address parsing, DNS resolver, connection pool
│   │   ├── net/address.zig
│   │   ├── net/tcp.zig
│   │   ├── net/udp.zig
│   │   ├── net/unix.zig
│   │   ├── net/dns.zig
│   │   ├── net/pool.zig
│   ├── tls.zig                 # TLS 1
│   │   ├── tls/client.zig
│   │   ├── tls/server.zig
│   │   ├── tls/pem.zig
│   ├── http.zig                # HTTP/1
│   │   ├── http/parser.zig
│   │   ├── http/client.zig
│   │   ├── http/server.zig
│   │   ├── http/h2/hpack.zig
│   │   ├── http/h2/stream.zig
│   ├── ws.zig                  # WebSocket (RFC 6455) client and server framing, ping/pong, close handshake
│   │   ├── ws/frame.zig
│   │   ├── ws/client.zig
│   │   ├── ws/server.zig
│   └── task.zig                # Thread pool, bounded channel, wait group, hierarchical cancellation, multi-loop scheduler
│       ├── task/thread_pool.zig
│       ├── task/channel.zig
│       ├── task/cancel.zig
│       ├── task/scheduler.zig
├── bench/main.zig               # Benchmark harness
├── examples/                    # Runnable examples
└── tests/                       # Integration / property / fuzz tests
```

> **NOTE**: 위 구조와 PRD의 구조는 **참고용**이다. 구현 과정에서 파일명·모듈 구성은 변경될 수 있다. 변경 시 이 파일과 `.claude/memory/architecture.md`를 갱신한다.

---

## Development Workflow

### Autonomous Development Protocol

Claude Code는 이 프로젝트에서 **완전 자율 개발**을 수행한다.

1. **작업 수신** → `docs/milestones.md`에서 다음 미완료 항목 식별 (의존성 순서 준수)
2. **계획 수립** → 대화형 세션: `EnterPlanMode`; 자율 세션(`claude -p`): 내부적으로 계획 후 즉시 구현 (plan mode 도구 사용 금지)
3. **팀 구성** → 복잡도에 따라 서브에이전트 호출
4. **구현** → TDD: test-writer(Red) → zig-developer(Green) → code-reviewer
5. **검증** → `zig build test`, `zig fmt --check src build.zig`
6. **커밋 + 푸시** → 단위별 즉시. `git add <files>` 명시, `git add -A` 금지
7. **메모리 갱신** → `.claude/memory/`, `docs/milestones.md` 체크박스

### Team Orchestration

```
Leader (orchestrator)
├── test-writer     — 실패하는 테스트 먼저 (MUST run before zig-developer)
├── zig-developer   — 테스트를 통과시키는 구현
├── code-reviewer   — 리뷰 & 품질
└── architect       — 설계 검토 (인터페이스/파일 포맷 변경 시 필수)
```

**TDD 규칙**: 모든 구현은 실패하는 테스트가 먼저 존재해야 한다. 테스트 수정은 test-writer가 한다.
**팀 생성 기준**: 3개 이상 파일 수정 → 팀 구성. 공개 인터페이스/포맷 변경 → architect 포함.

### Automated Session Execution

자동화 세션(citadel의 cron 잡)은 다음 순서로 실행한다.

**컨텍스트 복원**: `.claude/memory/project-context.md` → `architecture.md` → `decisions.md` → `debugging.md` → `patterns.md` → `docs/milestones.md`

**실행 사이클**:

| Phase | 내용 |
|---|---|
| 1. 상태 파악 | `git log -5`, `zig build test`, `gh run list --limit 3` |
| 1.5. 이슈 확인 | `gh issue list --state open --limit 10` — bug 라벨은 항상 최우선 |
| 2. 계획 | 내부 계획 (plan mode 금지) |
| 3. 구현 루프 | Red → Green → Refactor → 커밋+푸시, 단위별 반복 |
| 4. 리뷰 | `/review` |
| 5. 릴리즈 판단 | 마일스톤 완료 시 자동 (아래 규칙) |
| 6. 메모리 갱신 | `chore: update session memory` 별도 커밋 |
| 7. 세션 요약 | 템플릿 출력 |

### 버전 안전 규칙 (CRITICAL)

- 버전은 **단조 증가**. 릴리즈 전 `grep version build.zig.zon`과 `git tag -l 'v*' --sort=-v:refname | head -1` 확인
- 새 버전은 현재 버전의 **다음 마이너** (또는 fix만 있으면 패치). 건너뛰기·다운그레이드 금지
- **MAJOR**는 사용자 지시 시에만
- 릴리즈 조건: `zig build test` 0 failures · 6개 크로스 타겟 빌드 성공 · open `bug` 이슈 0개

**세션 요약 템플릿**:

    ## Session Summary
    ### Completed
    ### Files Changed
    ### Tests
    ### Benchmarks
    ### Next Priority
    ### Issues / Blockers

### Available Custom Agents

| Agent | Model | Purpose |
|---|---|---|
| zig-developer | sonnet | Zig 구현, 빌드 오류 해결 |
| code-reviewer | sonnet | 리뷰, 안전성/성능 검사 |
| test-writer | sonnet | 유닛/프로퍼티/fuzz/크래시 테스트 |
| architect | opus | 인터페이스·포맷·모듈 설계 |
| git-manager | haiku | Git 운영 |
| ci-cd | haiku | GitHub Actions |

### Available Slash Commands

`/build` `/test` `/implement <feature>` `/fix <bug>` `/review` `/status` `/release <version>` `/bench`

---

## Coding Standards

### Zig Conventions

- **Naming**: camelCase 함수/변수, PascalCase 타입, SCREAMING_SNAKE 상수
- **Errors**: 명시적 에러 유니온. 라이브러리 코드에서 `catch unreachable`, `@panic` 금지
- **Memory**: allocator-first. 전역 allocator 금지. 핫 패스에서 per-op 할당 금지
- **Output**: `std.debug.print` 금지 — writer 기반
- **Docs**: 모든 공개 함수에 doc comment (계약, 에러, 복잡도/비용)
- **Files**: 800줄 이하, 파일 하나에 개념 하나. 테스트는 파일 하단 `test` 블록
- **Format**: `zig fmt` 통과 필수 (CI에서 검사)

### Zig 0.15.x Guidelines

- `std.ArrayList(T)`는 unmanaged — `.empty`로 초기화, 모든 변경 메서드에 allocator 전달
- `child.wait()`는 stdout을 닫는다 — wait 전에 읽는다
- `callconv(.c)` 소문자
- 버퍼드 writer는 `std.process.exit()` 전에 flush
- 파일 스코프 `const X = expr;` (`comptime` 키워드 불필요)

### sirocco-Specific Rules

- **Completion은 호출자 소유, 인트루시브** — 루프는 op당 힙 할당을 하지 않는다
- **모든 블로킹 지점에 데드라인** — connect/read/write/dns 모두 timeout 파라미터 필수
- **버퍼는 호출자 소유** — 런타임은 사용자 버퍼를 복사하지 않는다
- **취소는 1급** — 모든 op는 `cancel()` 가능하고 `error.Cancelled`로 완료된다
- **백엔드 격리** — `io/backend/*`만 OS API를 안다. 상위 계층은 `Completion`/`Result`만 본다
- **파서는 입력을 신뢰하지 않는다** — HTTP/WS 파서는 크기 제한, 상태기계, fuzz 필수
- **graceful shutdown** — 서버는 listen 중단 → in-flight 완료 대기 → 강제 종료 순서를 지킨다

---

## Git Workflow

- `main` 직접 커밋 (자율 세션). 사람 작업은 `feat/<name>`, `fix/<name>`
- Conventional Commits: `feat:`, `fix:`, `perf:`, `refactor:`, `test:`, `docs:`, `chore:`
- 커밋 전 `zig build test` 통과 필수. 깨진 코드 푸시 금지
- 커밋 트레일러: `Co-Authored-By: Claude <noreply@anthropic.com>`

## Shared Scratchpad Protocol

`.claude/scratchpad.md`는 한 TDD 사이클 동안 에이전트 간 컨텍스트 전달용이다. 사이클 시작 시 초기화하고, 각 에이전트는 작업 후 자기 섹션을 append한다 (다른 에이전트 기록 삭제 금지).
