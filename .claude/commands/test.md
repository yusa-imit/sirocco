Run the sirocco test suite.

Steps:
1. Run `zig build test 2>&1`
2. If failures: list each failing test name, the assertion, and the file:line
3. For each failure, decide: implementation bug or wrong test expectation — check `docs/PRD.md`
4. Fix and re-run until green
5. Report: total tests, pass/fail, any leaks reported by std.testing.allocator

Focus: $ARGUMENTS (optional test name filter or module)
