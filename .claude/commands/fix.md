Fix a bug in sirocco.

Bug description: $ARGUMENTS

Workflow:
1. **Reproduce**: Call `test-writer` to write a failing test that reproduces the bug. No fix without a reproducing test.
2. **Locate**: Grep/Read relevant code. Check `.claude/memory/debugging.md` for similar past issues.
3. **Analyze**: Root cause, not symptom. Check invariants (`validate()`), checksums, error paths.
4. **Fix**: Minimal change. Do not refactor unrelated code.
5. **Verify**: `zig build test` — the new test passes, nothing else broke.
6. **Memory**: Record root cause and fix in `.claude/memory/debugging.md`.
7. **Commit**: `fix: <summary>` with explicit files. If it closes a GitHub issue: `gh issue close <n> --comment "Fixed in <hash>"`.
8. **Report**: Root cause, fix, regression test.
