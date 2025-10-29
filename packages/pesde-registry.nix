{
  lib,
  stdenvNoCC,
  cargoNix,
  llhttp,
}:

let
  drv = cargoNix.workspaceMembers.pesde-registry.build.overrideAttrs (prevAttrs: {
    buildInputs = prevAttrs.buildInputs ++ lib.optional stdenvNoCC.hostPlatform.isStatic llhttp;
  });
in
stdenvNoCC.mkDerivation {
  pname = "pesde-registry";
  version = drv.version;

  src = drv;

  installPhase = ''
    mkdir -p $out/bin
    cp -r $src/bin/pesde-registry $out/bin
  '';

  meta = {
    description = "Registry backend for pesde.";
    mainProgram = "pesde-registry";
    license = lib.licenses.mit;
  };
}
