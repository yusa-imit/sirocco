# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) with the `0.x` MINOR-may-break
exemption recorded in `citadel/protocol/VERSIONING.md`.

## [Unreleased]

Plan `001` (Zig 0.16 migration and Tiger Style baseline). No tag cut yet.

### Added

- `zig build tidy`: mechanical Tiger Style checker (line/function length ratchet, ban list,
  missing `//!` header), wired as a dependency of `zig build test`.
- `src/stdx.zig`: shared `assert`/`maybe` helpers, re-exported as `sirocco.stdx`.
- Pre/postcondition assertions on `src/main.zig`'s `run()` and `bench/main.zig`'s
  `matchesFilter()`/`rates()`.
- `docs/adr/0001-std-io-vtable.md`: sirocco's public surface is an implementation of
  `std.Io.VTable` (`Runtime.io()`), not a parallel `io`/`net`/`tls`/`http`/`ws`/`task` API.

### Changed

- Migrated `src/main.zig`, `bench/main.zig`, and `tools/tidy_main.zig`/`tidy_test.zig` to Zig
  0.16.0 (`std.process.Init`, `std.Io.Dir`/`File`, `Io.Clock`).
- `build.zig.zon` `.minimum_zig_version` bumped to `0.16.0`; CI resolves the toolchain from the
  manifest instead of a hardcoded version pin.
- `docs/PRD.md` rewritten against `std.Io.VTable` per ADR 0001.
- README reconciled with the `std.Io.VTable` design (module table replaced by the `Runtime.io()`
  surface, Status and Design sections added, install snippet no longer names an uncut tag).

### Fixed

- `ci.yml` `paths-ignore` no longer references the removed `.claude/memory/**`; format gate
  widened to `zig fmt --check src bench build.zig`; `bench` added to `build.zig.zon` `.paths`
  (`build.zig` references `bench/main.zig`, previously absent from the package tarball).
