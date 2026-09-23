{ pkgs, nixpkgs, nix-darwin, self }:

let
  hub = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.default
      ({ ... }: {
        system.stateVersion = "26.05";
        boot.isContainer = true;
        services.scion.hub.enable = true;
        services.scion.hub.user = "agents";
        services.scion.hub.environmentFile = "/run/secrets/scion-hub-env";
      })
    ];
  };
  workstation = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.default
      ({ ... }: {
        system.stateVersion = "26.05";
        boot.isContainer = true;
        programs.google-scion.enable = true;
        services.scion.workstation.enable = true;
        services.scion.workstation.user = "agents";
      })
    ];
  };
  mac = nix-darwin.lib.darwinSystem {
    system = "aarch64-darwin";
    modules = [
      self.darwinModules.default
      ({ ... }: {
        system.stateVersion = 6;
        system.primaryUser = "agents";
        services.scion.workstation.enable = true;
        services.scion.workstation.user = "agents";
        services.scion.workstation.environmentFile = "/run/secrets/scion-workstation-env";
      })
    ];
  };
in
assert !hub.config.virtualisation.podman.enable;
assert hub.config.systemd.services.scion-hub.serviceConfig.User == "agents";
assert hub.config.systemd.services.scion-hub.serviceConfig.EnvironmentFile == "/run/secrets/scion-hub-env";
assert pkgs.lib.hasInfix "--hosted --enable-hub" hub.config.systemd.services.scion-hub.serviceConfig.ExecStart;
assert workstation.config.virtualisation.podman.enable;
assert workstation.config.systemd.services.scion-workstation.serviceConfig.User == "agents";
assert pkgs.lib.hasInfix "ghcr.io/phynics" workstation.config.systemd.services.scion-workstation.environment.SCION_IMAGE_REGISTRY;
assert builtins.length mac.config.launchd.user.agents.scion-workstation.serviceConfig.ProgramArguments == 1;
pkgs.runCommand "scion-module-evaluation" { } ''
  touch "$out"
''
