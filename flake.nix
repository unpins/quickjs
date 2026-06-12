{
  description = "QuickJS (qjs + qjsc) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # qjs (the interpreter, with the REPL bytecode embedded) + qjsc (the bytecode
  # compiler) folded into one multicall binary at $out/bin/qjs, with `qjsc` as
  # an argv[0]-dispatch UNPIN_META alias. See ./multicall.nix.
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
  # mode); both are neutralized to bare `cc` / `/usr/local` in ./multicall.nix.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # Bellard upstream HEAD ("new release", VERSION 2026-06-04) — newer than
      # nixpkgs' 2025-09-13 and past the memory-buffer CVE fixes.
      qjsSrc = rev: hash: builtins.fetchTarball {
        url = "https://github.com/bellard/quickjs/archive/${rev}.tar.gz";
        sha256 = hash;
      };

      # Repoint pkgsStatic.quickjs at upstream HEAD and drop the stale
      # knownVulnerabilities (they describe the old release we no longer build).
      retarget = drv: drv.overrideAttrs (old: {
        version = "2026-06-04";
        src = qjsSrc "3d5e064e9" "0zvigrq2synxhkx9qradgja8saskf9ipfjvb48yls2s7jr6g8hgq";
        meta = (old.meta or { }) // { knownVulnerabilities = [ ]; };
      });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "quickjs";
      binName = "qjs";
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
      smoke = [ "-e" "console.log('quickjs ' + 6 * 7)" ];
      smokePattern = "quickjs 42";
      build = pkgs:
        let base = retarget pkgs.pkgsStatic.quickjs; in
        import ./multicall.nix { lib = pkgs.lib // ulib; } { inherit pkgs; quickjs = base; };
      windowsBuild = pkgs:
        let
          cross = ulib.mingwStaticCross pkgs;
          # QuickJS includes <pthread.h> and links -lpthread (worker threads,
          # JS atomics) on every platform; mingw needs winpthreads for the
          # header + static lib (same as aom/vim's windows builds).
          base = (retarget cross.quickjs).overrideAttrs (o: {
            buildInputs = (o.buildInputs or [ ]) ++ [ cross.windows.pthreads ];
          });
        in
        import ./multicall.nix { lib = pkgs.lib // ulib; } { inherit pkgs; quickjs = base; };
    };
}
