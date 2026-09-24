{
  description = "Scion packages, container images, and NixOS/nix-darwin modules for every Scion run mode";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    scion-src = {
      url = "github:GoogleCloudPlatform/scion/253ba544c21255121d4059638c9b5c74b56ee42e";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, scion-src, nix-darwin }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forSystems = f: lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
      upstream = builtins.fromJSON (builtins.readFile ./upstream.json);
      imageManifest = builtins.fromJSON (builtins.readFile ./image-manifest.json);
    in
    assert lib.assertMsg (imageManifest.upstreamRev == upstream.rev)
      "image-manifest.json and upstream.json must pin the same Scion revision";
    {
      packages = forSystems (pkgs:
        let
          # Built from the pinned source with the Hub fixes in nix/package.nix.
          google-scion-source = pkgs.callPackage ./nix/package.nix {
            src = scion-src;
            inherit (upstream) version rev;
          };
          # Hash-checked release binary; no local Go or Node build.
          google-scion = import ./nix/published-binaries.nix {
            inherit pkgs;
            inherit (upstream) version binaryRelease;
          };
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
            tag = upstream.imageTag;
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
        } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          server-image = packages.scion-server-image;
        });
    };
}
