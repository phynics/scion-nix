{
  description = "Scion packages, container images, and NixOS/nix-darwin modules for every Scion run mode";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nix-darwin }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forSystems = f: lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
      # The single Scion pin: version, commit, and every hash derived from it.
      # scripts/update.py rewrites it; image-manifest.json follows the same rev.
      sources = builtins.fromJSON (builtins.readFile ./sources.json);
      # Checked where the digests are used, not at the top level, so the source
      # packages still evaluate mid-update while the new images are building.
      imageManifest =
        let manifest = builtins.fromJSON (builtins.readFile ./image-manifest.json);
        in assert lib.assertMsg (manifest.upstreamRev == sources.rev && manifest.tag == sources.imageTag)
          "image-manifest.json must describe the images built from sources.json (same rev and imageTag)";
          manifest;
    in
    {
      packages = forSystems (pkgs:
        let
          # Built from the pinned source with the Hub fixes in nix/package.nix.
          google-scion-source = pkgs.callPackage ./nix/package.nix { inherit sources; };
          # Upstream's release binary, hash-checked; no local Go or Node build.
          google-scion = import ./nix/upstream-binaries.nix { inherit pkgs sources; };
          image-puller = import ./nix/pull-images.nix {
            inherit pkgs;
            manifest = imageManifest;
          };
        in
        {
          inherit google-scion google-scion-source image-puller;
          default = google-scion;
        } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # OCI image that runs the Scion server (Hub + Web, optionally a
          # Runtime Broker) inside a container. Linux only.
          scion-server-image = import ./nix/server-image.nix {
            inherit pkgs;
            scion = google-scion-source;
            tag = sources.imageTag;
          };
        });

      apps = forSystems (pkgs: {
        pull-images = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.image-puller}/bin/scion-pull-images";
          meta.description = "Pull digest-pinned Scion agent images into Podman or Docker";
        };
      });

      nixosModules.default = import ./nix/modules/nixos.nix { inherit self; };
      darwinModules.default = import ./nix/modules/darwin.nix { inherit self; };

      checks = forSystems (pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          packages = self.packages.${system};
        in
        {
          package = packages.google-scion;
          source = packages.google-scion-source;
          image-puller = packages.image-puller;
          image-puller-behavior = import ./nix/tests/image-puller.nix {
            inherit pkgs;
            manifest = imageManifest;
          };
          modules = import ./nix/tests/modules.nix { inherit pkgs nixpkgs nix-darwin self; };
          update-script = pkgs.runCommand "scion-update-script-tests" {
            nativeBuildInputs = [ pkgs.python3 ];
            PYTHONDONTWRITEBYTECODE = "1";
          } ''
            cd ${./scripts}
            python3 -m unittest -q test_update
            touch "$out"
          '';
        } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          server-image = packages.scion-server-image;
        });
    };
}
