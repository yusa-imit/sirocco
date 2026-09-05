Prepare and execute a release for sirocco.

Version: $ARGUMENTS (e.g. "v0.2.0")

**Version safety (CRITICAL)**: The new version must be strictly greater than both `build.zig.zon` and `git tag -l 'v*' --sort=-v:refname | head -1`, and must be the next minor (or patch if only fixes). Abort otherwise.

Workflow:
1. **Pre-flight**:
   - `zig build test` — 0 failures
   - `git status` — clean tree
   - `gh issue list --state open --label bug` — must be empty
   - Cross-compile all 6 targets: x86_64-linux-gnu, aarch64-linux-gnu, x86_64-macos-none, aarch64-macos-none, x86_64-windows-msvc, aarch64-windows-msvc
2. **Bump**: version in `build.zig.zon`
3. **Changelog**: `git log --oneline <last-tag>..HEAD` → `CHANGELOG.md` section
4. **Commit**: `chore: bump version to <version>`
5. **Tag**: `git tag -a <version> -m "Release <version>"`
6. **Push**: `git push && git push origin <version>`
7. **GitHub Release**: `gh release create <version> --title "<version>" --notes "<changelog>"`
8. **Close issues** resolved by this release
9. **Report**
