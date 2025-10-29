{
  lib,
  callPackage,
  buildFHSEnv,
  pesde,
  additionalPkgs ? pkgs: [ ],
}:

let
  fhs = buildFHSEnv {
    pname = pesde.pname;
    version = pesde.version;

    targetPkgs =
      pkgs:
      (with pkgs; [
        # These are the same packages added by `vscode-fhs`
        glibc
        curl
        icu
        libunwind
        libuuid
        lttng-ust
        openssl
        zlib
        krb5

        # Used by pesde
        dbus
      ])
      ++ additionalPkgs pkgs;

    runScript = "${lib.getExe pesde}";
  };
in
fhs
// {
  withExtraBins = callPackage ./with-extra-bins.nix { } fhs;
}
