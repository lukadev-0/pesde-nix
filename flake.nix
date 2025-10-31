{
  description = "A package manager for the Luau programming language, supporting multiple runtimes including Roblox and Lune.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
    flake-compat.url = "github:nixos/flake-compat";
    flake-compat.flake = false;
    rust-overlay.url = "github:oxalica/rust-overlay";
    crate2nix.url = "github:nix-community/crate2nix";
    crate2nix.inputs.nixpkgs.follows = "nixpkgs";
    crate2nix.inputs.flake-compat.follows = "flake-compat";
  };

  nixConfig = {
    extra-substituters = [
      "https://pesde.cachix.org"
    ];
    extra-trusted-public-keys = [
      "pesde.cachix.org-1:Tp5MQIJI/ZWprqkV320kOO3Gym9mzHfv7GUYWZdtK8g="
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
      crate2nix,
      rust-overlay,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      eachSystem = lib.genAttrs (import systems);
      rustToolchainFor = pkgs: pkgs.rust-bin.stable.latest.minimal;
    in
    {
      packages = eachSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
          inherit (pkgs) lib pkgsStatic;

          rustToolchain = rustToolchainFor pkgs;
          versionToName = lib.replaceString "." "_";

          versionManifest = import ./versions/manifest.nix;

          readVersionsIn =
            dir:
            let
              version_fileset = lib.fileset.fileFilter (file: file.hasExt "nix") dir;
            in
            lib.genAttrs' (lib.fileset.toList version_fileset) (
              file: lib.nameValuePair (lib.removeSuffix ".nix" (builtins.baseNameOf file)) (import file)
            );

          packageManifests = lib.mapAttrs (name: channels: {
            inherit channels;
            versions = readVersionsIn ./versions/${name};
          }) versionManifest.packages;

          mkPackages =
            manifest: name: f:
            let
              byVersion = lib.mapAttrs (version: info: f (info // { inherit version name; })) manifest.versions;
              byChannel = lib.mapAttrs (_: version: byVersion.${version}) manifest.channels;
            in
            lib.mapAttrs' (
              version: drv:
              let
                pkgName = if version == "latest" then name else "${name}_${versionToName version}";
              in
              lib.nameValuePair pkgName drv
            ) (byVersion // byChannel);

          mkRustPackage =
            pkgs': base: overrides: info:
            let
              src = pkgs'.fetchFromGitHub {
                owner = versionManifest.owner;
                repo = versionManifest.repo;
                rev = info.rev;
                hash = info.hash;
              };

              crate2nixOutput =
                pkgs.runCommand "${info.name}-${info.version}-crate2nix"
                  {
                    buildInputs = [
                      pkgs.cacert
                      crate2nix.packages.${system}.default
                      rustToolchain
                    ];
                    outputHashMode = "nar";
                    outputHash = info.cargoNixHash;
                  }
                  ''
                    mkdir crate
                    ln -s "${src}" source
                    CARGO_HOME=$PWD/.cargo crate2nix generate \
                      --cargo-toml "source/Cargo.toml" \
                      --output "crate/Cargo.nix" \
                      --crate-hashes "crate/crate-hashes.json"
                    cp -r crate "$out"
                  '';

              generated = pkgs.runCommandLocal "${info.name}-${info.version}-cargoNix" { } ''
                mkdir -p "$out"
                ln -s "${crate2nixOutput}" "$out/crate"
                ln -s "${src}" "$out/source"
                echo "import ./crate/Cargo.nix" > "$out/default.nix"
              '';

              buildRustCrateForPkgs =
                pkgs:
                pkgs.buildRustCrate.override {
                  defaultCrateOverrides = pkgs.defaultCrateOverrides // {
                    openssl-sys = attrs: {
                      preConfigure = ''
                        export OPENSSL_LIB_DIR="${pkgs.openssl.out}/lib"
                        export OPENSSL_INCLUDE_DIR="${pkgs.openssl.dev}/include"
                      '';
                    };
                  };
                };
            in
            pkgs'.callPackage base (
              {
                cargoNix = pkgs'.callPackage generated {
                  inherit buildRustCrateForPkgs;
                };
              }
              // overrides
            );

          pesde = (mkPackages packageManifests.pesde "pesde" (mkRustPackage pkgs ./packages/pesde.nix { }));
          pesde-full = (
            mkPackages packageManifests.pesde "pesde-full" (
              mkRustPackage pkgs ./packages/pesde.nix {
                withVersionManagement = true;
              }
            )
          );
          pesde-fhs = (
            mkPackages packageManifests.pesde "pesde-fhs" (
              info:
              pkgs.callPackage ./packages/pesde-fhs.nix {
                pesde = pesde-full.${"pesde-full_" + versionToName info.version};
              }
            )
          );
          pesde-registry = (
            mkPackages packageManifests.pesde-registry "pesde-registry" (
              mkRustPackage pkgs ./packages/pesde-registry.nix { }
            )
          );
          pesde-registry-static = (
            mkPackages packageManifests.pesde-registry "pesde-registry-static" (
              mkRustPackage pkgsStatic ./packages/pesde-registry.nix { }
            )
          );
          pesde-registry-docker = (
            mkPackages packageManifests.pesde-registry "pesde-registry-docker" (
              info:
              pkgsStatic.callPackage ./packages/pesde-registry-docker.nix {
                pesde-registry = pesde-registry-static.${"pesde-registry-static_" + versionToName info.version};
              }
            )
          );
        in
        pesde
        // pesde-full
        // pesde-registry
        // lib.optionalAttrs pkgs.stdenv.isLinux (pesde-fhs)
        // lib.optionalAttrs (system == "x86_64-linux") (pesde-registry-static // pesde-registry-docker)
      );

      checks = eachSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
        in
        with self.packages.${system};
        {
          inherit
            pesde
            pesde-full
            pesde-registry
            ;
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          inherit pesde-fhs;
        }
        // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          inherit pesde-registry-static pesde-registry-docker;
        }
      );

      devShells = eachSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
          rustToolchain = rustToolchainFor pkgs;
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.lune
              pkgs.nix-prefetch-git
              pkgs.nixfmt-rfc-style
              crate2nix.packages.${system}.default
              rustToolchain
            ];
          };
        }
      );

      formatter = eachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
