{
  description = "QuickJS (qjs + qjsc) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Every target builds via the unpin-llvm engine + emits a bitcode multicall
  # module. The standalone self-folds qjs (the interpreter, with the REPL
  # bytecode embedded) + qjsc (the bytecode compiler) into ONE dispatcher binary
  # at $out/bin/quickjs from the captured module.bc; `qjs`/`qjsc` are embedded
  # as UNPIN_META aliases; `quickjs` itself is not a program, so a bare
  # invocation lists the two.
  #
  # We take the source straight from Fabrice Bellard's upstream git rather than
  # nixpkgs: nixpkgs pins the older 2025-09-13 release, which carries three open
  # CVEs (knownVulnerabilities, fix pending upstream). The 2026-06-04 HEAD lands
  # after those memory-handling fixes, so we fetch it directly and clear the
  # (now-stale) knownVulnerabilities marker.
  #
  # QuickJS needs none of the VFS machinery perl (@INC) / python (stdlib zip)
  # require — the REPL is compiled to bytecode and linked in, the stdlib is C —
  # and unlike lua there is no readline/terminfo leak (qjs line-edits in JS via
  # raw tty). The one store-path leak is qjsc's baked-in CONFIG_CC / CONFIG_PREFIX
  # (the compiler + install prefix qjsc shells out to in its executable-output
  # mode); both are neutralized to bare `cc` / `/usr/local` in `retarget`.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # Bellard upstream HEAD ("new release", VERSION 2026-06-04) — newer than
      # nixpkgs' 2025-09-13 and past the memory-buffer CVE fixes.
      qjsSrc = rev: hash: builtins.fetchTarball {
        url = "https://github.com/bellard/quickjs/archive/${rev}.tar.gz";
        sha256 = hash;
      };
      srcHEAD = qjsSrc "3d5e064e9" "0zvigrq2synxhkx9qradgja8saskf9ipfjvb48yls2s7jr6g8hgq";

      # Drop the example programs from the Makefile's PROGS. Upstream's `all`
      # (which `install` depends on) also builds examples, including PIC shared
      # objects (examples/*.so) that can't link against the static-musl crt on
      # i686 (`R_386_PC32 against _start_c/_init/_fini without -fPIC`); we never
      # ship them. Shared by the real build and the repl.c host bootstrap below.
      dropExamples = ''
        substituteInPlace Makefile \
          --replace-fail 'PROGS+=examples/hello examples/test_fib' "" \
          --replace-fail 'PROGS+=examples/hello_module' "" \
          --replace-fail 'PROGS+=examples/fib.so examples/point.so' ""
      '';

      # repl.c is QuickJS bytecode the interpreter embeds; upstream generates it
      # at build time with `qjsc -s -c -o repl.c -m repl.js`. In a cross build
      # that runs the TARGET qjsc — fine under qemu for the linux crosses, but on
      # the Intel Mac builder the arm64 qjsc is "Bad CPU type in executable", and
      # the engine cross-compiles via `clang -target` with no CROSS_PREFIX, so
      # upstream's own host-qjsc fallback never trips. The bytecode is endian /
      # word-size independent, so generate repl.c ONCE on the build host (a native
      # qjsc, the same trick upstream's Makefile uses for cross) and inject it —
      # no target qjsc ever runs, identical bytes on every arch.
      preGenRepl = pkgs: pkgs.pkgsBuildBuild.stdenv.mkDerivation {
        pname = "quickjs-repl-c";
        version = "2026-06-04";
        src = srcHEAD;
        dontConfigure = true;
        postPatch = dropExamples;
        buildPhase = ''
          runHook preBuild
          for s in quickjs dtoa libregexp libunicode cutils quickjs-libc qjsc; do
            $CC -O2 -D_GNU_SOURCE -DCONFIG_VERSION='"2026-06-04"' \
              -DCONFIG_CC='"cc"' -DCONFIG_PREFIX='"/usr/local"' -c "$s.c" -o "$s.o"
          done
          $CC *.o -o host-qjsc -lm -ldl -lpthread
          ./host-qjsc -s -c -o repl.c -m repl.js
          runHook postBuild
        '';
        installPhase = "cp repl.c $out";
      };

      # Repoint pkgsStatic.quickjs at upstream HEAD, drop the stale
      # knownVulnerabilities (they describe the old release we no longer build),
      # strip the examples, and inject the host-generated repl.c (neutralising its
      # Makefile rule so the target qjsc never runs).
      retarget = pkgs: drv: drv.overrideAttrs (old: {
        version = "2026-06-04";
        src = srcHEAD;
        meta = (old.meta or { }) // { knownVulnerabilities = [ ]; };
        postPatch = (old.postPatch or "") + dropExamples + ''
          cp ${preGenRepl pkgs} repl.c
          chmod +w repl.c
          substituteInPlace Makefile \
            --replace-fail 'repl.c: $(QJSC) repl.js' 'repl.c: repl.js' \
            --replace-fail '$(QJSC) -s -c -o $@ -m repl.js' 'touch -c $@'
          # Neutralise the store paths qjsc bakes for its executable-output mode
          # (the cc it shells out to + the prefix it looks for quickjs.h/.a in).
          # With PREFIX=$(out) the engine build would bake a /nix/store/…-quickjs
          # path into the folded binary as dead rodata (nix registers no reference
          # — the closure stays empty — but it's an ugly leak the published
          # multicall.nix already scrubbed). Pin both to bare cc / /usr/local.
          substituteInPlace Makefile \
            --replace-fail 'QJSC_DEFINES:=-DCONFIG_CC=\"$(QJSC_CC)\" -DCONFIG_PREFIX=\"$(PREFIX)\"' \
                           'QJSC_DEFINES:=-DCONFIG_CC=\"cc\" -DCONFIG_PREFIX=\"/usr/local\"' \
            --replace-fail 'QJSC_HOST_DEFINES:=-DCONFIG_CC=\"$(HOST_CC)\" -DCONFIG_PREFIX=\"$(PREFIX)\"' \
                           'QJSC_HOST_DEFINES:=-DCONFIG_CC=\"cc\" -DCONFIG_PREFIX=\"/usr/local\"'
        '';
      });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "quickjs";
      pkgsAttr = "quickjs";
      # QuickJS ships no man pages (docs are texi → pdf/html only), so there is
      # nothing to embed. Disabling embedMan also avoids the windows man-graft,
      # which would otherwise reference the stock nixpkgs `quickjs` (the older
      # 2025-09-13 release with open CVEs → knownVulnerabilities eval error).
      embedMan = false;
      # qjs has no `--version` flag (its banner only prints via `-h`, which
      # exits 1), so smoke by evaluating a computed marker — proves the
      # interpreter actually runs JS (a shell ignoring `-e` wouldn't emit it)
      # and exits 0.
      smoke = [ "--unpin-program=qjs" "-e" "console.log('quickjs ' + 6 * 7)" ];
      smokePattern = "quickjs 42";
      engine = "unpin-llvm";
      multicall = {
        windows = true;
        programs = [ { name = "qjs"; } { name = "qjsc"; } ];
      };
      build = pkgs: retarget pkgs pkgs.pkgsStatic.quickjs;
      windowsBuild = pkgs:
        let cross = ulib.mingwStaticCross pkgs; in
        (retarget pkgs cross.quickjs).overrideAttrs (o: {
          # QuickJS includes <pthread.h> and links -lpthread (worker threads,
          # JS atomics) on every platform; mingw needs winpthreads for the
          # header + static lib (same as aom/vim's windows builds).
          buildInputs = (o.buildInputs or [ ]) ++ [ cross.windows.pthreads ];
          # Upstream's Makefile only takes its Windows branch when told to:
          # without CONFIG_WIN32 it appends -ldl to LIBS, passes -rdynamic and
          # names the targets with no .exe. CROSS_PREFIX is forced empty because
          # CONFIG_WIN32 otherwise defaults it to `x86_64-w64-mingw32-`, which
          # switches the build onto a host-qjsc bootstrap it doesn't need (the
          # repl.c `retarget` injects is already host-generated) and looks for a
          # build-host gcc that isn't on PATH.
          makeFlags = (o.makeFlags or [ ]) ++ [ "CONFIG_WIN32=y" "CROSS_PREFIX=" ];
          # run-test262 sits in PROGS unconditionally and #includes <ftw.h>,
          # which mingw doesn't ship. It's a test driver we never ship, so drop
          # it the same way dropExamples drops the examples.
          postPatch = (o.postPatch or "") + ''
            substituteInPlace Makefile \
              --replace-fail 'PROGS=qjs$(EXE) qjsc$(EXE) run-test262$(EXE)' \
                             'PROGS=qjs$(EXE) qjsc$(EXE)'
          '';
        });
    };
}
