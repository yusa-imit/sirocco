Show the current status of sirocco.

Gather and display:
1. **Git**: branch, uncommitted changes, last commit, ahead/behind
2. **CI**: `gh run list --limit 3 --json status,conclusion,name,createdAt`
3. **Issues**: `gh issue list --state open --limit 10`
4. **Build**: `zig build` result
5. **Tests**: `zig build test` pass/fail summary
6. **Milestones**: Read `docs/milestones.md` — completion per phase, next unchecked items (respect dependency order)
7. **Memory**: Key recent decisions and known issues from `.claude/memory/`

Format as a compact dashboard.
