{
  description = "Native Scion packages and NixOS/nix-darwin modules";

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
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
      upstream = builtins.fromJSON (builtins.readFile ./upstream.json);
      imageManifest = builtins.fromJSON (builtins.readFile ./image-manifest.json);
      _sameRevision = assert imageManifest.upstreamRev == upstream.rev; true;
    in
    assert _sameRevision;
    {
      packages = forSystems (pkgs:
        let
          google-scion-source = pkgs.callPackage ./nix/package.nix {
            src = scion-src;
            version = upstream.version;
            rev = upstream.rev;
          };
          google-scion = import ./nix/published-binaries.nix {
            inherit pkgs;
            version = upstream.version;
          };
          image-puller = import ./nix/pull-images.nix {
            inherit pkgs;
            manifest = imageManifest;
          };
        in
        {
          inherit google-scion google-scion-source image-puller;
          default = google-scion;
        });

      apps = forSystems (pkgs: {
        pull-images = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.image-puller}/bin/scion-pull-images";
          meta.description = "Pull pinned Scion agent images into Podman or Docker";
        };
      });

      nixosModules.default = import ./nix/modules/nixos.nix { inherit self; };
      darwinModules.default = import ./nix/modules/darwin.nix { inherit self; };

      checks = forSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.google-scion;
        source = self.packages.${pkgs.stdenv.hostPlatform.system}.google-scion-source;
        image-puller = self.packages.${pkgs.stdenv.hostPlatform.system}.image-puller;
        image-puller-behavior = import ./nix/tests/image-puller.nix {
          inherit pkgs;
          manifest = imageManifest;
        };
        modules = import ./nix/tests/modules.nix { inherit pkgs nixpkgs nix-darwin self; };
      });
    };
}
