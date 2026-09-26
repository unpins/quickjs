# Changelog

## [Unreleased]

## [2026-06-04-1] - 2026-09-26

Initial release — QuickJS `2026-06-04` as a single self-contained binary, built
natively for Linux, macOS, and Windows.

### Added

- Builds for Linux (x86_64, aarch64, armv7l, i686, ppc64le, riscv64), macOS
  (x86_64, aarch64), and Windows.
- The `qjs` interpreter and the `qjsc` bytecode compiler in the one binary —
  `unpin install quickjs` creates both commands.
- The interactive REPL is built in; there is no companion script file.
- Built from upstream git rather than the older release nixpkgs pins, which
  carries three open CVEs in its memory handling.

### Removed

- `qjsc`'s default mode, which produces an executable, needs a C compiler and
  the QuickJS headers on the machine, so it cannot work from a single binary.
  `qjsc -c` and `qjsc -e`, which emit C source, work as usual.
