# sirocco — Decision Log (ADR)

Format: `## ADR-NNN: Title` / **Date** / **Context** / **Decision** / **Consequences**

## ADR-001: Zero external dependencies

**Date**: 2026-09-05
**Context**: sirocco is a foundation layer of the Zig kingdom; every other component may depend on it.
**Decision**: Depend only on the Zig standard library. Integrations with other kingdom components live under `src/adapters/` and are opt-in.
**Consequences**: No dependency cycles across the kingdom. Some functionality (e.g. compression, event-driven watchers) is deferred until it can be implemented in-tree or provided through an adapter.
