# quickjs

[QuickJS](https://bellard.org/quickjs/) — Fabrice Bellard's small, fast,
spec-compliant JavaScript engine. A single self-contained binary (`qjs` +
`qjsc`), built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/quickjs/actions/workflows/quickjs.yml/badge.svg)](https://github.com/unpins/quickjs/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install quickjs`.

## Usage

Run the `qjs` interpreter with [unpin](https://github.com/unpins/unpin):

```bash
unpin qjs script.js              # run a script
unpin qjs -e 'console.log(1+1)'  # run a one-liner
unpin qjs -i                     # interactive REPL
```

To install it onto your PATH:

```bash
unpin install quickjs
```

Installing also creates the `qjsc` command (the bytecode compiler) alongside
`qjs`:

```bash
qjsc -c -o out.c -m script.js    # compile to a C bytecode array
```

## Build locally

```bash
nix build github:unpins/quickjs
./result/bin/qjs -e 'console.log("hi")'
```

Or run directly:

```bash
nix run github:unpins/quickjs -- -e 'console.log("hi")'
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/quickjs/releases) page has standalone binaries for manual download.

## Build notes

- **Upstream source, not nixpkgs.** We build from Fabrice Bellard's upstream
  git (`2026-06-04`). nixpkgs pins the older `2025-09-13` release, which carries
  three open CVEs (`knownVulnerabilities`); the version we ship lands after those
  memory-handling fixes.
- **Single multicall binary.** `qjs` (interpreter) and `qjsc` (bytecode
  compiler) are folded into one binary at `$out/bin/qjs`, with `qjsc` an
  `argv[0]`-dispatch alias. The bare/canonical `qjs` runs the interpreter
  (`defaultApplet`); `qjs --unpin-program=qjsc …` reaches the compiler from the
  bare binary. Both share the whole QuickJS library, so we don't prefix-rename
  every global; `nm` confirms `qjs.c`/`qjsc.c` each define only `main` and
  `help`, which are renamed per program. See `multicall.nix`.
- **REPL embedded as bytecode.** The interactive REPL (`repl.js`) is compiled to
  QuickJS bytecode (`qjsc -c`) and linked into the binary — there is no external
  `.js` file to ship. That bytecode is architecture-independent (the same trick
  upstream uses for cross builds), so it is generated once on the build host and
  compiled for every target.
- **No VFS / embedded data needed.** QuickJS's standard library is C, and the
  REPL is the only bundled script (embedded as above). `import` of external
  *JS* modules still works from the filesystem; loading external *native* (`.so`)
  modules does not, as expected for one static binary (and is stubbed on
  Windows upstream).
- **Static linking, per target.** Linux/macOS link fully static (musl) /
  libSystem-only; on Windows `-static` folds libc, libwinpthread and libgcc in,
  so the `.exe` imports only system DLLs.
- **`qjsc` executable output.** `qjsc -c` / `qjsc -e` (emit a C bytecode array /
  a standalone-`main` C file) work out of the box. `qjsc`'s default
  *executable* output mode shells out to a C compiler and needs the QuickJS dev
  headers/library, which a single static binary does not carry — so use it with
  an explicit `-c`/`-e`, or compile the emitted C yourself. The baked compiler
  path is neutralized to a bare `cc` (no `/nix/store` reference).
