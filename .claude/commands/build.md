Build the sirocco library and CLI.

Steps:
1. Run `zig fmt --check src build.zig` — report formatting violations
2. Run `zig build` — report success or the first error with file:line
3. If it fails, analyze the error, fix it, and rebuild
4. Report final status
