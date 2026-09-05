Run sirocco benchmarks and compare against PRD targets.

Steps:
1. `zig build bench -- $ARGUMENTS` (ReleaseFast is set in build.zig)
2. Compare each result with `docs/PRD.md` §5 targets
3. Append a row to the table in `docs/milestones.md` (date, metric, measured, target)
4. If a metric regressed >10% vs the last recorded value, open an investigation: identify the commit range and likely cause
5. Report a table: metric | measured | target | status
