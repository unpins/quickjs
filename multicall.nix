# QuickJS ships two real programs — `qjs` (the interpreter) and `qjsc` (the
# bytecode compiler) — built from the same source tree. We fold them into one
# multicall binary at $out/bin/quickjs (named after the package, as the CI gate
# requires), with `qjs` and `qjsc` as argv[0]-dispatch UNPIN_META aliases.
#
# Both mains pull in the same six library objects (quickjs/dtoa/libregexp/
# libunicode/cutils/quickjs-libc), and `nm` confirms qjs.c and qjsc.c each
# define exactly TWO clashing globals (`main` and `help`). So we compile the
# library objects ONCE, compile the two mains, rename `main`/`help` →
# `qjs_*`/`qjsc_*`, and link everything (shared objects linked a single time)
# with the canonical dispatcher.
#
# The interpreter embeds the REPL as QuickJS bytecode: `qjsc -s -c -o repl.c -m
# repl.js` emits a `qjsc_repl[]` byte array that qjs.c links against. That
# bytecode is version-specific but architecture-independent (the same trick
# upstream's Makefile uses with `host-qjsc` for cross builds), so we generate
# repl.c ONCE on the build platform (pkgsBuildBuild) and compile it for every
# target — native, cross, mingw and darwin alike.
#
# Store-path hygiene: qjsc bakes CONFIG_CC (the compiler it shells out to in its
# default executable-output mode) and CONFIG_PREFIX (where it looks for
# quickjs.h/libquickjs.a) into the binary. nixpkgs would set these to store
# paths; we pin them to bare `cc` / `/usr/local` so the binary carries no
# /nix/store reference. (qjsc's `-c`/`-e` C-emitting modes work standalone; its
# executable-output mode then needs a `cc` on PATH plus the quickjs dev files,
# which a single static binary does not ship — an inherent, documented limit.)
{ lib }:
{ pkgs, quickjs }:
let
  hostPlat = quickjs.stdenv.hostPlatform;
  isWindows = hostPlat.isWindows or false;
  isDarwin = hostPlat.isDarwin or false;

  ver = quickjs.version;

  # The six objects that make up libquickjs + the libc bindings (QJS_LIB_OBJS in
  # upstream's Makefile).
  libObjs = "quickjs dtoa libregexp libunicode cutils quickjs-libc";

  # Per-OS link libraries (catalog "ship every feature"):
  #  - Linux:  -lm -ldl -lpthread (loadlib via dlopen, worker threads).
  #  - Darwin: -lm -lpthread       (dlopen + pthread live in libSystem; no -ldl).
  #  - Windows: -lm -lpthread      (winpthreads; no dlfcn — module loader stubbed).
  syslibs =
    if isWindows then "-lm -lpthread"
    else if isDarwin then "-lm -lpthread"
    else "-lm -ldl -lpthread";

  # Quoted -D defines must stay inline in each compile command — stashing them
  # in a shell variable would lose the quotes (quote-removal doesn't apply to
  # variable-expanded text), mangling CONFIG_VERSION into a multi-char literal.
  verDef = "-DCONFIG_VERSION='\"${ver}\"'";
  # qjsc's neutralized executable-output knobs (see header).
  qjscDefines = "-DCONFIG_CC='\"cc\"' -DCONFIG_PREFIX='\"/usr/local\"'";

  # repl.c — generated once on the build platform. QuickJS bytecode is
  # endian/word-size independent, so the array is valid for every target.
  buildHostDarwin = pkgs.pkgsBuildBuild.stdenv.hostPlatform.isDarwin or false;
  replHostLibs = if buildHostDarwin then "-lm -lpthread" else "-lm -ldl -lpthread";
  replC = pkgs.pkgsBuildBuild.stdenv.mkDerivation {
    pname = "quickjs-repl-c";
    version = ver;
    inherit (quickjs) src;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      for s in ${libObjs} qjsc; do
        $CC -O2 -D_GNU_SOURCE ${verDef} ${qjscDefines} -c "$s.c" -o "$s.o"
      done
      $CC *.o -o host-qjsc ${replHostLibs}
      ./host-qjsc -s -c -o repl.c -m repl.js
      runHook postBuild
    '';
    installPhase = "cp repl.c $out";
  };

  multicall = quickjs.overrideAttrs (old: {
    pname = "quickjs-multi";
    outputs = [ "out" ];
    # No docs/install-check from the stock derivation; we drive our own build.
    nativeBuildInputs = lib.filter (x: (x.pname or "") != "texinfo") (old.nativeBuildInputs or [ ]);
    doInstallCheck = false;

    buildPhase = ''
      runHook preBuild
      set -e
      mkdir -p multicall/obj

      CF="-O2 -D_GNU_SOURCE"
      for s in ${libObjs}; do
        $CC $CF ${verDef} -c "$s.c" -o "multicall/obj/$s.o"
      done
      $CC $CF ${verDef} -c qjs.c  -o multicall/obj/qjs.o
      $CC $CF ${verDef} ${qjscDefines} -c qjsc.c -o multicall/obj/qjsc.o
      # The embedded REPL bytecode (generated on the build host; arch-neutral).
      # The store path has no .c suffix, so force the C language (before input).
      $CC $CF -x c -c ${replC} -o multicall/obj/repl.o

      # Mach-O leads C symbols with '_'; detect once from qjs.o's `main`.
      if $NM --defined-only multicall/obj/qjs.o 2>/dev/null \
           | awk '$3=="_main"{f=1} END{exit !f}'; then up=_; else up=""; fi

      # qjs.o and qjsc.o each define exactly two clashing globals (nm-verified):
      # `main` and `help`. Rename both per interpreter; objcopy rewrites the
      # definition and the in-object references together, so each program's
      # `main`→…_main lands in the dispatcher and its `help` stays self-consistent.
      for sym in main help; do
        printf '%s%s %sqjs_%s\n'  "$up" "$sym" "$up" "$sym" >> multicall/qjs.redef
        printf '%s%s %sqjsc_%s\n' "$up" "$sym" "$up" "$sym" >> multicall/qjsc.redef
      done
      $OBJCOPY --redefine-syms=multicall/qjs.redef  multicall/obj/qjs.o
      $OBJCOPY --redefine-syms=multicall/qjsc.redef multicall/obj/qjsc.o

      # Dispatcher (shared canonical generator). The canonical binary is named
      # after the package (`quickjs`) — the action-build gate inspects
      # `result/bin/<manifest.name>`, so the primary on-disk binary MUST be
      # `quickjs`, with `qjs`/`qjsc` as embedded argv[0] aliases (the
      # coreutils/busybox model). `quickjs` is not itself an applet, so
      # defaultApplet=qjs makes a bare `quickjs script.js` run the interpreter;
      # an argv[0] of `qjs` does the same and `qjsc` runs the compiler.
      printf '%s\n' qjs qjsc > multicall/apps.list
${lib.multicallDispatcherC { name = "quickjs"; defaultApplet = "qjs"; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Final link. On mingw, force a fully static exe (-static folds libc,
      # libwinpthread and libgcc in — otherwise -lpthread pulls libwinpthread-1.dll
      # as a runtime dependency, failing both wine and the no-companion-DLL gate).
      # gc-sections on native only (on windows `pkgs` is the x86_64-linux root, so
      # its lld flags would be wrong here). Library objects linked once; both
      # *_main present.
      $CC multicall/obj/*.o multicall/dispatcher.o \
        ${if isWindows then "-static -static-libgcc" else (lib.gcSectionsFlag pkgs)} \
        ${syslibs} \
        -o multicall/qjs
      [ -f multicall/qjs ] || mv multicall/qjs.exe multicall/qjs
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 multicall/qjs "$out/bin/quickjs"
      ln -s quickjs "$out/bin/qjs"
      ln -s quickjs "$out/bin/qjsc"
      runHook postInstall
    '';

    # nixpkgs' postBuild/postInstall build texi docs + a lib/include tree we
    # don't ship.
    postBuild = "";
    postInstall = "";
  });

  aliased = lib.withAliases pkgs
    {
      primary = "quickjs";
      aliasesFromSymlinksIn = "bin";
    }
    multicall;
in
if isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/quickjs" ] && mv "$out/bin/quickjs" "$out/bin/quickjs.exe"
  '';
})
else aliased
