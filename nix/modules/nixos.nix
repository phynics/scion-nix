{ self }:
{ config, lib, pkgs, ... }:

# Scion run modes (https://googlecloudplatform.github.io/scion/choosing-a-mode/):
#
#   Local               programs.google-scion                      CLI + container runtime, no server
#   Workstation         services.scion.workstation                 combo server (Hub + Broker + Web) on loopback
#   Single-node hosted  services.scion.hub (availability = "single-node")
#                                                                  one networked Hub on SQLite, optional embedded Broker
#   HA hosted           services.scion.hub (availability = "ha")   one Hub replica on Postgres + GCS
#
# services.scion.broker adds a standalone Runtime Broker that executes agents
# for a Hub running elsewhere (either hosted tier). Every service runs the
# native binary under systemd as an existing account; none runs a Scion
# server container. Components that execute agents pull the digest-pinned
# harness images into that account's container store first.

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption optionals optionalAttrs types;
  flakePackages = self.packages.${pkgs.stdenv.hostPlatform.system};
  program = config.programs.google-scion;
  cfg = config.services.scion;
  hub = cfg.hub;
  isHA = hub.availability == "ha";
  hubStateDir = "/var/lib/${hub.stateDirectory}";

  runtimeType = types.enum [ "podman" "docker" ];
  runtimePackage = runtime: if runtime == "podman" then pkgs.podman else pkgs.docker;

  commonOptions = what: {
    user = mkOption {
      type = types.str;
      description = "Existing account that runs ${what}. Scion keeps its settings under this account's home; the module never creates the account.";
    };
    environmentFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/scion.env";
      description = "Runtime path to a KEY=value file readable by the service account, for example a sops-nix secret. Its contents never enter the Nix store.";
    };
  };

  agentOptions = {
    runtime = mkOption {
      type = runtimeType;
      default = program.runtime;
      defaultText = lib.literalExpression "config.programs.google-scion.runtime";
      description = "Container runtime that executes agents.";
    };
    pullImages = mkOption {
      type = types.bool;
      default = true;
      description = "Pull the digest-pinned harness images into the service account's container store before starting.";
    };
    harnesses = mkOption {
      type = types.listOf (types.enum flakePackages.image-puller.harnessNames);
      default = flakePackages.image-puller.harnessNames;
      defaultText = lib.literalMD "every harness in `image-manifest.json`";
      example = [ "claude" "opencode" ];
      description = "Harness images to pull when `pullImages` is enabled.";
    };
    containersStorageConf = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Rootless Podman storage.conf path, when the account uses a non-default graphroot.";
    };
  };

  # Rootless Podman needs the account's lingering user manager, a delegated
  # cgroup, and PODMAN_SYSTEMD_UNIT so conmon lands in this unit's cgroup.
  runtimeUnit = agents: optionalAttrs (agents.runtime == "podman") {
    after = [ "linger-users.service" ];
    wants = [ "linger-users.service" ];
    environment = { PODMAN_SYSTEMD_UNIT = "%n"; }
      // optionalAttrs (agents.containersStorageConf != null) {
        CONTAINERS_STORAGE_CONF = agents.containersStorageConf;
      };
    serviceConfig.Delegate = true;
  } // optionalAttrs (agents.runtime == "docker") {
    after = [ "docker.service" ];
    wants = [ "docker.service" ];
  };

  imagesUnitName = component: "scion-${component}-images";

  imagesService = component: user: agents: mkMerge [ (runtimeUnit agents) {
    description = "Pull pinned Scion harness images for ${user}";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ (runtimePackage agents.runtime) ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = user;
      WorkingDirectory = "~";
      ExecStart = lib.escapeShellArgs ([
        "${flakePackages.image-puller}/bin/scion-pull-images"
        agents.runtime
        program.imageRegistry
      ] ++ agents.harnesses);
    };
  } ];

  scionService = { component, description, user, environmentFile, agents ? null, workingDirectory ? "~", requiredMountsFor ? [ ], exec, extraEnv ? { }, extraServiceConfig ? { } }:
    let
      pullsImages = agents != null && agents.pullImages;
      images = "${imagesUnitName component}.service";
    in
    mkMerge [ (if agents == null then { } else runtimeUnit agents) {
      inherit description;
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ] ++ optionals pullsImages [ images ];
      wants = [ "network-online.target" ];
      requires = optionals pullsImages [ images ];
      path = [ pkgs.git ] ++ optionals (agents != null) [ (runtimePackage agents.runtime) ];
      unitConfig.RequiresMountsFor = requiredMountsFor;
      environment = { SCION_IMAGE_REGISTRY = program.imageRegistry; } // extraEnv;
      serviceConfig = {
        User = user;
        WorkingDirectory = workingDirectory;
        ExecStart = lib.escapeShellArgs exec;
        Restart = "on-failure";
        RestartSec = 5;
      } // optionalAttrs (environmentFile != null) { EnvironmentFile = environmentFile; }
        // extraServiceConfig;
    } ];

  # Link ~/.scion/settings.yaml to a runtime file (for example a sops-nix
  # template). An existing regular file is never overwritten.
  linkSettings = settingsFile: pkgs.writeShellScript "scion-link-settings" ''
    set -eu
    link="$HOME/.scion/settings.yaml"
    ${pkgs.coreutils}/bin/mkdir -p "$HOME/.scion"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      echo "Refusing to replace existing $link; migrate it into ${settingsFile} first." >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/ln -sfn ${lib.escapeShellArg settingsFile} "$link"
  '';

  hubExec = [ "${hub.package}/bin/scion" "server" "start" "--foreground" "--hosted" "--enable-hub" "--host" hub.listenAddress ]
    ++ (if hub.enableWeb
      then [ "--enable-web" "--web-port" (toString hub.port) ]
      else [ "--port" (toString hub.port) ])
    ++ optionals hub.broker.enable ([ "--enable-runtime-broker" "--runtime-broker-port" (toString hub.broker.port) ]
      ++ optionals hub.broker.autoProvide [ "--auto-provide" ])
    ++ optionals (!isHA) [ "--db" (if hub.databasePath != null then hub.databasePath else "${hubStateDir}/hub.db") ]
    ++ (if hub.storageBucket != null
      then [ "--storage-bucket" hub.storageBucket ]
      else [ "--storage-dir" (if hub.storagePath != null then hub.storagePath else "${hubStateDir}/storage") ])
    ++ lib.concatMap (email: [ "--admin-emails" email ]) hub.adminEmails;
in
{
  imports = [
    (lib.mkRemovedOptionModule [ "services" "scion" "hosted" ] ''
      services.scion.hosted was folded into services.scion.hub. For the same
      single-process Hub + Web + Broker, set services.scion.hub.enable,
      services.scion.hub.broker.enable, and move user, listenAddress, port,
      publicURL, settingsFile, environmentFile, databasePath, workingDirectory
      and requiredMountsFor under services.scion.hub; brokerPort becomes
      hub.broker.port, pullImages and containersStorageConf move under
      hub.broker, and imageRegistry is programs.google-scion.imageRegistry.
      Set hub.databasePath and hub.storagePath (~/.scion/hub.db and
      ~/.scion/storage) to keep an existing Hub's data; the new
      default lives in /var/lib/<stateDirectory>.
    '')
  ];

  options = {
    programs.google-scion = {
      enable = mkEnableOption "the Scion CLI for Local mode (agents started directly with `scion start`, no server)";
      package = mkOption {
        type = types.package;
        default = flakePackages.google-scion;
        defaultText = lib.literalExpression "scion-nix.packages.\${system}.google-scion";
        description = "Scion binary for the CLI, the workstation, and the standalone Broker.";
      };
      runtime = mkOption {
        type = runtimeType;
        default = "podman";
        description = "Container runtime for agents. Enabling the CLI also enables this runtime on the host.";
      };
      imageRegistry = mkOption {
        type = types.str;
        default = "ghcr.io/phynics";
        example = "localhost/scion";
        description = "Registry prefix Scion uses for standard harness images (SCION_IMAGE_REGISTRY). Pulled images are tagged under it.";
      };
    };

    services.scion = {
      workstation = commonOptions "the workstation combo server" // agentOptions // {
        enable = mkEnableOption "Workstation mode: Hub, Runtime Broker and Web in one loopback server";
        listenAddress = mkOption { type = types.str; default = "127.0.0.1"; };
        port = mkOption { type = types.port; default = 8080; description = "Web dashboard and Hub API port."; };
      };

      hub = commonOptions "the Hub" // {
        enable = mkEnableOption "a hosted Scion Hub (Single-node or HA hosted mode)";
        availability = mkOption {
          type = types.enum [ "single-node" "ha" ];
          default = "single-node";
          description = ''
            Availability tier. `single-node` keeps state in SQLite and local
            storage under the systemd StateDirectory. `ha` runs one replica of a
            load-balanced Hub on Postgres and GCS: put SCION_SERVER_DATABASE_URL
            and SCION_SERVER_SESSION_SECRET in `environmentFile`, and set
            `hubId` and `storageBucket` identically on every replica.
          '';
        };
        package = mkOption {
          type = types.package;
          default = flakePackages.google-scion-source;
          defaultText = lib.literalExpression "scion-nix.packages.\${system}.google-scion-source";
          description = "Scion build for the Hub. The default source build carries the Hub fixes in nix/package.nix.";
        };
        listenAddress = mkOption { type = types.str; default = "127.0.0.1"; };
        port = mkOption { type = types.port; default = 8080; description = "Web port, or the Hub API port when `enableWeb` is off."; };
        enableWeb = mkOption { type = types.bool; default = true; description = "Serve the web dashboard; the Hub API shares its port."; };
        publicURL = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "https://scion.example.com";
          description = "Browser-visible URL (SCION_SERVER_BASE_URL). OAuth and OIDC callbacks use it.";
        };
        adminEmails = mkOption { type = types.listOf types.str; default = [ ]; description = "Accounts promoted to Hub admin on login."; };
        settingsFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Runtime settings.yaml (for example a sops-nix template) linked to ~/.scion/settings.yaml. Use it for OAuth/OIDC client secrets.";
        };
        stateDirectory = mkOption { type = types.str; default = "scion-hub"; description = "systemd StateDirectory name, under /var/lib."; };
        databasePath = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Single-node SQLite database path. Defaults to hub.db in the state directory.";
        };
        storagePath = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "/home/scion/.scion/storage";
          description = "Local template and artifact storage when `storageBucket` is unset. Defaults to storage in the state directory; set it to ~/.scion/storage to keep what a Hub started without --storage-dir wrote.";
        };
        hubId = mkOption { type = types.nullOr types.str; default = null; description = "Stable Hub ID shared by every HA replica."; };
        storageBucket = mkOption { type = types.nullOr types.str; default = null; description = "GCS bucket for templates and artifacts; required for HA, optional for single-node (default: local storage in the state directory)."; };
        workingDirectory = mkOption { type = types.nullOr types.str; default = null; description = "Process working directory; defaults to the account's home."; };
        requiredMountsFor = mkOption { type = types.listOf types.str; default = [ ]; description = "Paths that must be mounted before the Hub and image pulling start."; };
        broker = agentOptions // {
          enable = mkEnableOption "a Runtime Broker inside the Hub process, so this node also runs agents (Single-node only)";
          port = mkOption { type = types.port; default = 9800; };
          autoProvide = mkOption { type = types.bool; default = true; description = "Offer this broker to new projects automatically."; };
        };
      };

      broker = commonOptions "the Runtime Broker" // agentOptions // {
        enable = mkEnableOption "a standalone Runtime Broker that runs agents for a Hub elsewhere";
        port = mkOption { type = types.port; default = 9800; description = "Broker API port. A standalone hosted broker binds to loopback and dials the Hub itself."; };
      };
    };
  };

  config = mkMerge [
    {
      assertions = [
        { assertion = !(cfg.workstation.enable && (hub.enable || cfg.broker.enable)); message = "services.scion.workstation already runs a Hub and Broker; do not enable services.scion.hub or services.scion.broker beside it."; }
        { assertion = !(hub.enable && hub.broker.enable && cfg.broker.enable); message = "Enable either services.scion.hub.broker or services.scion.broker on one host, not both."; }
        { assertion = builtins.match "[a-zA-Z0-9_-]+" hub.stateDirectory != null; message = "services.scion.hub.stateDirectory must be a single relative directory name."; }
        { assertion = !(hub.enable && isHA) || (hub.hubId != null && hub.storageBucket != null); message = "HA hosted mode needs services.scion.hub.hubId and services.scion.hub.storageBucket."; }
        { assertion = !(hub.enable && isHA) || hub.environmentFile != null; message = "HA hosted mode needs services.scion.hub.environmentFile with SCION_SERVER_DATABASE_URL and SCION_SERVER_SESSION_SECRET."; }
        { assertion = !(hub.enable && isHA) || !hub.broker.enable; message = "HA Hub replicas do not embed a Runtime Broker; run services.scion.broker on separate nodes."; }
        { assertion = hub.storagePath == null || hub.storageBucket == null; message = "Set either services.scion.hub.storagePath (local) or services.scion.hub.storageBucket (GCS), not both."; }
        { assertion = !(hub.enable && isHA) || hub.databasePath == null; message = "services.scion.hub.databasePath applies to SQLite; set SCION_SERVER_DATABASE_URL in the environment file for HA."; }
      ];
    }

    # Local mode: CLI plus the container runtime its agents need.
    (mkIf program.enable {
      environment.systemPackages = [ program.package pkgs.git ];
      environment.sessionVariables.SCION_IMAGE_REGISTRY = program.imageRegistry;
      virtualisation.podman.enable = lib.mkIf (program.runtime == "podman") (lib.mkDefault true);
      virtualisation.docker.enable = lib.mkIf (program.runtime == "docker") (lib.mkDefault true);
    })

    # Any component that executes agents needs its runtime on the host.
    (let
      runtimes = optionals cfg.workstation.enable [ cfg.workstation.runtime ]
        ++ optionals (hub.enable && hub.broker.enable) [ hub.broker.runtime ]
        ++ optionals cfg.broker.enable [ cfg.broker.runtime ];
    in {
      virtualisation.podman.enable = mkIf (builtins.elem "podman" runtimes) (lib.mkDefault true);
      virtualisation.docker.enable = mkIf (builtins.elem "docker" runtimes) (lib.mkDefault true);
    })

    (mkIf cfg.workstation.enable (let ws = cfg.workstation; in {
      systemd.services.scion-workstation = scionService {
        component = "workstation";
        description = "Scion workstation (Hub, Runtime Broker and Web)";
        inherit (ws) user environmentFile;
        agents = ws;
        # No --hosted: workstation defaults enable every component, dev auth
        # and auto-provide.
        exec = [ "${program.package}/bin/scion" "server" "start" "--foreground" "--host" ws.listenAddress "--web-port" (toString ws.port) ];
      };
      systemd.services.${imagesUnitName "workstation"} = mkIf ws.pullImages (imagesService "workstation" ws.user ws);
    }))

    (mkIf hub.enable {
      systemd.services.scion-hub = scionService {
        component = "hub";
        description = "Scion Hub (${hub.availability} hosted)";
        inherit (hub) user environmentFile requiredMountsFor;
        agents = if hub.broker.enable then hub.broker else null;
        workingDirectory = if hub.workingDirectory == null then "~" else hub.workingDirectory;
        exec = hubExec;
        extraEnv = {
          SCION_SERVER_DATABASE_DRIVER = if isHA then "postgres" else "sqlite";
        } // optionalAttrs (hub.publicURL != null) {
          SCION_SERVER_BASE_URL = hub.publicURL;
        } // optionalAttrs (hub.hubId != null) {
          SCION_SERVER_HUB_HUBID = hub.hubId;
        };
        extraServiceConfig = {
          StateDirectory = hub.stateDirectory;
          StateDirectoryMode = "0700";
        } // optionalAttrs (hub.settingsFile != null) {
          ExecStartPre = linkSettings hub.settingsFile;
        };
      };
      systemd.services.${imagesUnitName "hub"} = mkIf (hub.broker.enable && hub.broker.pullImages)
        (mkMerge [ (imagesService "hub" hub.user hub.broker) { unitConfig.RequiresMountsFor = hub.requiredMountsFor; } ]);
    })

    (mkIf cfg.broker.enable (let broker = cfg.broker; in {
      systemd.services.scion-broker = scionService {
        component = "broker";
        description = "Scion Runtime Broker";
        inherit (broker) user environmentFile;
        agents = broker;
        exec = [ "${program.package}/bin/scion" "server" "start" "--foreground" "--hosted" "--enable-runtime-broker" "--runtime-broker-port" (toString broker.port) ];
      };
      systemd.services.${imagesUnitName "broker"} = mkIf broker.pullImages (imagesService "broker" broker.user broker);
    }))
  ];
}
