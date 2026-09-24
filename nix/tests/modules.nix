{ pkgs, nixpkgs, nix-darwin, self }:

let
  inherit (pkgs) lib;

  # Minimal stand-in for the sops-nix options the examples use.
  sopsStub = { lib, ... }: {
    options.sops = {
      secrets = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
          options.owner = lib.mkOption { type = lib.types.str; default = "root"; };
          options.path = lib.mkOption { type = lib.types.str; default = "/run/secrets/${name}"; };
        }));
        default = { };
      };
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
  };

  nixos = module: nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.default
      sopsStub
      { system.stateVersion = "26.05"; boot.isContainer = true; }
      module
    ];
  };
  builds = system: builtins.isString system.config.system.build.toplevel.drvPath;
  rejected = module: !(builtins.tryEval (nixos module).config.system.build.toplevel.drvPath).success;
  unit = system: name: system.config.systemd.services.${name};
  has = infix: string: lib.hasInfix infix string;

  local = nixos { programs.google-scion.enable = true; };
  localDocker = nixos { programs.google-scion = { enable = true; runtime = "docker"; }; };

  workstation = nixos {
    programs.google-scion.enable = true;
    services.scion.workstation = { enable = true; user = "scion"; harnesses = [ "claude" ]; };
  };
  ws = unit workstation "scion-workstation";

  hubOnly = nixos {
    services.scion.hub = { enable = true; user = "scion"; environmentFile = "/run/secrets/scion-hub-env"; };
  };
  hubOnlyUnit = unit hubOnly "scion-hub";

  singleNode = nixos ../../examples/single-node.nix;
  singleNodeUnit = unit singleNode "scion-hub";
  singleNodeImages = unit singleNode "scion-hub-images";

  # A Hub migrated from services.scion.hosted keeps the state it wrote under ~/.scion.
  migrated = nixos {
    services.scion.hub = {
      enable = true;
      user = "scion";
      listenAddress = "0.0.0.0";
      databasePath = "/home/scion/.scion/hub.db";
      storagePath = "/home/scion/.scion/storage";
      broker.enable = true;
    };
  };
  migratedUnit = unit migrated "scion-hub";

  ha = nixos ../../examples/ha-hub.nix;
  haUnit = unit ha "scion-hub";

  broker = nixos {
    services.scion.broker = { enable = true; user = "agents"; environmentFile = "/run/secrets/broker-env"; };
  };
  brokerUnit = unit broker "scion-broker";

  mac = nix-darwin.lib.darwinSystem {
    system = "aarch64-darwin";
    modules = [
      self.darwinModules.default
      {
        system.stateVersion = 6;
        system.primaryUser = "scion";
        programs.google-scion.enable = true;
        services.scion.workstation = { enable = true; user = "scion"; environmentFile = "/run/secrets/scion-workstation-env"; };
      }
    ];
  };
  macAgent = mac.config.launchd.user.agents.scion-workstation.serviceConfig;
in
# Local: CLI and a runtime, no services.
assert builds local;
assert local.config.virtualisation.podman.enable;
assert !(local.config.systemd.services ? scion-hub);
assert localDocker.config.virtualisation.docker.enable;
assert !localDocker.config.virtualisation.podman.enable;

# Workstation: combo server with workstation defaults, images pulled first.
assert builds workstation;
assert ws.serviceConfig.User == "scion";
assert !(has "--hosted" ws.serviceConfig.ExecStart);
assert has "server start --foreground --host 127.0.0.1 --web-port 8080" ws.serviceConfig.ExecStart;
assert ws.serviceConfig.Delegate;
assert ws.environment.PODMAN_SYSTEMD_UNIT == "%n";
assert builtins.elem "linger-users.service" ws.after;
assert builtins.elem "scion-workstation-images.service" ws.requires;
assert has "podman ghcr.io/phynics claude" (unit workstation "scion-workstation-images").serviceConfig.ExecStart;

# Single-node Hub without a broker: no container runtime or images.
assert builds hubOnly;
assert !hubOnly.config.virtualisation.podman.enable;
assert !(hubOnly.config.systemd.services ? scion-hub-images);
assert hubOnlyUnit.serviceConfig.EnvironmentFile == "/run/secrets/scion-hub-env";
assert hubOnlyUnit.serviceConfig.StateDirectory == "scion-hub";
assert hubOnlyUnit.environment.SCION_SERVER_DATABASE_DRIVER == "sqlite";
assert has "--hosted --enable-hub --host 127.0.0.1 --enable-web --web-port 8080" hubOnlyUnit.serviceConfig.ExecStart;
assert has "--db /var/lib/scion-hub/hub.db --storage-dir /var/lib/scion-hub/storage" hubOnlyUnit.serviceConfig.ExecStart;
assert !(has "--enable-runtime-broker" hubOnlyUnit.serviceConfig.ExecStart);

# Single-node example: Hub + Web + embedded broker, sops-rendered settings.
assert builds singleNode;
assert singleNode.config.virtualisation.podman.enable;
assert has "--enable-runtime-broker --runtime-broker-port 9800 --auto-provide" singleNodeUnit.serviceConfig.ExecStart;
assert has "--admin-emails admin@example.test" singleNodeUnit.serviceConfig.ExecStart;
assert singleNodeUnit.environment.SCION_SERVER_BASE_URL == "http://hub.example.test:8080";
assert singleNodeUnit.environment.SCION_IMAGE_REGISTRY == "localhost/scion";
assert singleNodeUnit.serviceConfig.WorkingDirectory == "~";
assert singleNodeUnit.serviceConfig ? ExecStartPre;
assert builtins.elem "sops-nix.service" singleNodeUnit.requires;
assert builtins.elem "scion-hub-images.service" singleNodeUnit.requires;
assert singleNodeImages.serviceConfig.User == "scion";
assert lib.hasSuffix "podman localhost/scion opencode claude" singleNodeImages.serviceConfig.ExecStart;
assert has "client_secret: test-oidc-placeholder" singleNode.config.sops.templates."scion-settings.yaml".content;

# Migrated single-node Hub: existing SQLite database and template storage.
assert builds migrated;
assert has "--db /home/scion/.scion/hub.db --storage-dir /home/scion/.scion/storage" migratedUnit.serviceConfig.ExecStart;
assert has "--hosted --enable-hub --host 0.0.0.0" migratedUnit.serviceConfig.ExecStart;

# HA example: Postgres driver, shared hub ID, GCS storage, no local state flags.
assert builds ha;
assert !ha.config.virtualisation.podman.enable;
assert haUnit.environment.SCION_SERVER_DATABASE_DRIVER == "postgres";
assert haUnit.environment.SCION_SERVER_HUB_HUBID == "scion-example";
assert haUnit.serviceConfig.EnvironmentFile == "/run/secrets/scion-hub-env";
assert has "--storage-bucket example-scion-hub" haUnit.serviceConfig.ExecStart;
assert !(has "--db" haUnit.serviceConfig.ExecStart);

# Standalone broker for a remote Hub.
assert builds broker;
assert broker.config.virtualisation.podman.enable;
assert brokerUnit.serviceConfig.User == "agents";
assert has "--hosted --enable-runtime-broker --runtime-broker-port 9800" brokerUnit.serviceConfig.ExecStart;
assert !(has "--enable-hub" brokerUnit.serviceConfig.ExecStart);
assert (unit broker "scion-broker-images").serviceConfig.User == "agents";

# Invalid combinations fail evaluation.
assert rejected { services.scion.workstation = { enable = true; user = "a"; }; services.scion.hub = { enable = true; user = "a"; }; };
assert rejected { services.scion.hub = { enable = true; user = "a"; broker.enable = true; }; services.scion.broker = { enable = true; user = "a"; }; };
assert rejected { services.scion.hub = { enable = true; user = "a"; availability = "ha"; environmentFile = "/run/e"; }; };
assert rejected { services.scion.hub = { enable = true; user = "a"; availability = "ha"; environmentFile = "/run/e"; hubId = "h"; storageBucket = "b"; broker.enable = true; }; };
assert rejected { services.scion.hub = { enable = true; user = "a"; stateDirectory = "/var/lib/x"; }; };
assert rejected { services.scion.hub = { enable = true; user = "a"; storagePath = "/srv/s"; storageBucket = "b"; }; };
assert rejected { services.scion.hosted.enable = true; };

# nix-darwin: Local + Workstation as a launchd user agent.
assert builtins.length macAgent.ProgramArguments == 1;
assert macAgent.KeepAlive;
assert mac.config.environment.variables.SCION_IMAGE_REGISTRY == "ghcr.io/phynics";
pkgs.runCommand "scion-module-evaluation" { } ''
  touch "$out"
''
