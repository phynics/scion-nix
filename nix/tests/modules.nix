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
        services.scion.hub.user = "scion";
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
        services.scion.workstation.user = "scion";
      })
    ];
  };
  hosted = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.default
      ({ ... }: {
        system.stateVersion = "26.05";
        boot.isContainer = true;
        services.scion.hosted = {
          enable = true;
          user = "scion";
          home = "/home/scion";
          listenAddress = "0.0.0.0";
          imageRegistry = "localhost/scion";
          settingsFile = "/run/secrets-rendered/scion-settings.yaml";
          environmentFile = "/run/secrets/scion-session-env";
          containersStorageConf = "/etc/containers/storage-scion.conf";
        };
      })
    ];
  };
  hostedExample = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.default
      ../../examples/hosted-single-node.nix
      ({ lib, ... }: {
        config = {
          system.stateVersion = "26.05";
          boot.isContainer = true;
        };
        options.sops = {
          secrets = lib.mkOption { type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything); default = { }; };
          placeholder = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {
              scion-oidc-client-secret = "test-oidc-placeholder";
              scion-session-secret = "test-session-placeholder";
            };
          };
          templates = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
              options = {
                owner = lib.mkOption { type = lib.types.str; };
                mode = lib.mkOption { type = lib.types.str; };
                content = lib.mkOption { type = lib.types.str; };
                path = lib.mkOption { type = lib.types.str; default = "/run/secrets/rendered/${name}"; };
              };
            }));
            default = { };
          };
        };
      })
    ];
  };
  mac = nix-darwin.lib.darwinSystem {
    system = "aarch64-darwin";
    modules = [
      self.darwinModules.default
      ({ ... }: {
        system.stateVersion = 6;
        system.primaryUser = "scion";
        services.scion.workstation.enable = true;
        services.scion.workstation.user = "scion";
        services.scion.workstation.environmentFile = "/run/secrets/scion-workstation-env";
      })
    ];
  };
in
assert !hub.config.virtualisation.podman.enable;
assert hub.config.systemd.services.scion-hub.serviceConfig.User == "scion";
assert hub.config.systemd.services.scion-hub.serviceConfig.EnvironmentFile == "/run/secrets/scion-hub-env";
assert pkgs.lib.hasInfix "--hosted --enable-hub" hub.config.systemd.services.scion-hub.serviceConfig.ExecStart;
assert workstation.config.virtualisation.podman.enable;
assert workstation.config.systemd.services.scion-workstation.serviceConfig.User == "scion";
assert hosted.config.virtualisation.podman.enable;
assert builtins.isString hosted.config.system.build.toplevel.drvPath;
assert hosted.config.systemd.services.scion-hosted.serviceConfig.User == "scion";
assert hosted.config.systemd.services.scion-hosted.serviceConfig.Delegate;
assert hosted.config.systemd.services.scion-hosted.serviceConfig.EnvironmentFile == "/run/secrets/scion-session-env";
assert hosted.config.systemd.services.scion-hosted.environment.CONTAINERS_STORAGE_CONF == "/etc/containers/storage-scion.conf";
assert hosted.config.systemd.services.scion-hosted.environment.SCION_IMAGE_REGISTRY == "localhost/scion";
assert !(hosted.config.systemd.services.scion-hosted.environment ? XDG_RUNTIME_DIR);
assert pkgs.lib.hasInfix "--hosted --enable-hub --enable-web --enable-runtime-broker" hosted.config.systemd.services.scion-hosted.serviceConfig.ExecStart;
assert hosted.config.systemd.services.scion-images.serviceConfig.User == "scion";
assert pkgs.lib.hasInfix "podman localhost/scion" hosted.config.systemd.services.scion-images.serviceConfig.ExecStart;
assert builtins.isString hostedExample.config.system.build.toplevel.drvPath;
assert hostedExample.config.systemd.services.scion-hosted.serviceConfig.WorkingDirectory == "/home/scion";
assert hostedExample.config.systemd.services.scion-hosted.environment.SCION_SERVER_BASE_URL == "http://hub.example.test:8080";
assert pkgs.lib.hasInfix "client_secret: test-oidc-placeholder" hostedExample.config.sops.templates."scion-settings.yaml".content;
assert pkgs.lib.hasInfix "ghcr.io/phynics" workstation.config.systemd.services.scion-workstation.environment.SCION_IMAGE_REGISTRY;
assert builtins.length mac.config.launchd.user.agents.scion-workstation.serviceConfig.ProgramArguments == 1;
pkgs.runCommand "scion-module-evaluation" { } ''
  touch "$out"
''
