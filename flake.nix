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
    in
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
        in
        {
          inherit google-scion google-scion-source;
          default = google-scion;
        });

      nixosModules.default = import ./nix/modules/nixos.nix { inherit self; };
      darwinModules.default = import ./nix/modules/darwin.nix { inherit self; };

      checks = forSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.google-scion;
        source = self.packages.${pkgs.stdenv.hostPlatform.system}.google-scion-source;
        modules = import ./nix/tests/modules.nix { inherit pkgs nixpkgs nix-darwin self; };
      });
    };
}
