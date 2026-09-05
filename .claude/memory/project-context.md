# sirocco — Project Context

## Current State (2026-09-05)

- **Phase**: Bootstrap complete. Next: Phase 1 (see `docs/milestones.md`)
- **Version**: 0.1.0 (unreleased)
- **Build**: `zig build test` green on skeleton
- **CI**: workflow registered, first run pending

## Immediate Next Steps

- 1A: `Completion`/`Op`/`Result` 타입과 인트루시브 큐 — 테스트: 큐 push/pop/remove, Op 태그 커버리지
- 1B: kqueue 백엔드 — 테스트: 루프백 TCP accept/connect/read/write/close
- 1D: 타이밍 휠 — 테스트: 등록/취소/만료 순서, 대량 타이머(100k) 성능

## Session Log

**Session 0 (2026-09-05) — Bootstrap**
- Repository scaffolded from `citadel/templates/repo` by `citadel/scripts/scaffold.py`
- PRD written (`docs/PRD.md`), milestones enumerated, agent/command definitions installed
- Module stubs compile; each module has a placeholder test
