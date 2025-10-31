{
  lib,
  callPackage,
  stdenvNoCC,
  cargoNix,
  runCommandLocal,
  defaultCrateOverrides,
  withVersionManagement ? false,
  features ? [ ],
}:

let
  drv = (
    cargoNix.workspaceMembers.pesde.build.override {
      features = [
        "bin"
        "wally-compat"
        "patches"
      ]
      ++ features
      ++ lib.optional withVersionManagement "version-management";
    }
  );
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pesde";
  version = drv.version;

  src = drv;

  installPhase = ''
    mkdir -p $out/bin
    cp -r $src/bin/pesde $out/bin
  '';

  passthru.withExtraBins = callPackage ./with-extra-bins.nix { } finalAttrs.finalPackage;

  meta = {
    description = "A package manager for the Luau programming language, supporting multiple runtimes including Roblox and Lune.";
    mainProgram = "pesde";
    license = lib.licenses.mit;
  };
})
