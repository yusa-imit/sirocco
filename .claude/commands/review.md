Perform a code review on current changes in sirocco.

Steps:
1. `git diff` (unstaged) and `git diff --cached` (staged); if none, `git diff HEAD~1`
2. Read each changed file in full for context
3. Review against `.claude/agents/code-reviewer.md` checklist:
   - Correctness & invariants, error paths, errdefer cleanup
   - Library safety: allocator-first, no panic, no debug.print, doc comments
   - sirocco-specific rules (see CLAUDE.md)
   - Tests present for new/changed behavior, failure paths covered
4. Report findings as CRITICAL / WARNING / SUGGESTION with file:line

Context: $ARGUMENTS (optional focus)
