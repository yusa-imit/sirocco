Implement a feature for sirocco.

Feature description: $ARGUMENTS

Workflow:
1. **Understand**: Read `docs/PRD.md`, `docs/milestones.md`, `CLAUDE.md`, and `.claude/memory/` files.
2. **Plan**: Interactive session → `EnterPlanMode`. Autonomous session → plan internally (no plan mode). Identify files, public API, error set, and which PRD phase item this closes.
3. **Red**: Call `test-writer` to write failing tests from the PRD contract.
4. **Green**: Call `zig-developer` to implement the minimum that passes.
5. **Refactor**: Clean up with tests green. `zig fmt`.
6. **Review**: Call `code-reviewer`. Fix CRITICAL/WARNING.
7. **Verify**: `zig build test` — 0 failures, 0 leaks.
8. **Milestone**: Tick the checkbox in `docs/milestones.md`.
9. **Memory**: Update `.claude/memory/` with decisions and patterns.
10. **Commit**: Explicit file list, conventional message, push.
11. **Report**: What was implemented, files, tests, next PRD item.

For public interface or file/wire format changes, call `architect` before step 3.
