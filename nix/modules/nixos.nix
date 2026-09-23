{ self }:
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types optionalAttrs;
  program = config.programs.google-scion;
  services = config.services.scion;
  defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.google-scion;
  patchedPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.google-scion-source;
  envFile = file: optionalAttrs (file != null) { EnvironmentFile = file; };
  runtimePath = runtime: [ pkgs.git ] ++ lib.optionals (runtime == "podman") [ pkgs.podman ]
    ++ lib.optionals (runtime == "docker") [ pkgs.docker ];
  podmanService = {
    after = [ "network-online.target" "linger-users.service" ];
    wants = [ "network-online.target" "linger-users.service" ];
    serviceConfig = { Delegate = true; Environment = "PODMAN_SYSTEMD_UNIT=%n"; };
  };
  commonService = component: extra: {
    description = "Scion ${component}";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment.SCION_IMAGE_REGISTRY = program.imageRegistry;
    serviceConfig = {
      User = extra.user;
      Restart = "on-failure";
      RestartSec = 5;
    } // envFile extra.environmentFile;
  };
in
{
  options = {
    programs.google-scion = {
      enable = mkEnableOption "the Scion command line interface";
      package = mkOption { type = types.package; default = defaultPackage; description = "Native Scion binary used by the CLI and services."; };
      runtime = mkOption { type = types.enum [ "podman" "docker" ]; default = "podman"; description = "Container runtime used by a workstation or broker."; };
      imageRegistry = mkOption { type = types.str; default = "ghcr.io/phynics"; description = "Registry prefix for standard Scion agent images."; };
    };
    services.scion = {
      workstation = {
        enable = mkEnableOption "the native Scion workstation server";
        user = mkOption { type = types.str; description = "Existing account that owns Scion state and the container runtime."; };
        listenAddress = mkOption { type = types.str; default = "127.0.0.1"; };
        port = mkOption { type = types.port; default = 8080; };
        environmentFile = mkOption { type = types.nullOr types.str; default = null; description = "Runtime path to a service-readable environment file."; };
      };
      hub = {
        enable = mkEnableOption "the native Scion Hub and web server";
        user = mkOption { type = types.str; description = "Existing account that runs the Hub."; };
        stateDirectory = mkOption { type = types.str; default = "scion-hub"; description = "Relative systemd StateDirectory name for Hub data."; };
        listenAddress = mkOption { type = types.str; default = "127.0.0.1"; };
        port = mkOption { type = types.port; default = 8080; };
        environmentFile = mkOption { type = types.nullOr types.str; default = null; };
      };
      broker = {
        enable = mkEnableOption "the native Scion Runtime Broker";
        user = mkOption { type = types.str; description = "Existing account that owns Broker state and the container runtime."; };
        runtime = mkOption { type = types.enum [ "podman" "docker" ]; default = program.runtime; };
        environmentFile = mkOption { type = types.nullOr types.str; default = null; };
      };
      hosted = {
        enable = mkEnableOption "a hosted Hub, Web, and embedded Runtime Broker in one native process";
        user = mkOption { type = types.str; description = "Existing account that owns Scion state and rootless Podman."; };
        home = mkOption { type = types.str; description = "Home directory of the existing account."; };
        package = mkOption { type = types.package; default = patchedPackage; description = "Scion build with broker read and default profile fixes."; };
        listenAddress = mkOption { type = types.str; default = "127.0.0.1"; };
        port = mkOption { type = types.port; default = 8080; };
        publicURL = mkOption { type = types.nullOr types.str; default = null; description = "Browser-visible Hub URL used for OIDC callbacks."; };
        brokerPort = mkOption { type = types.port; default = 9800; };
        databasePath = mkOption { type = types.nullOr types.str; default = null; description = "Existing or new SQLite Hub database path."; };
        workingDirectory = mkOption { type = types.nullOr types.str; default = null; description = "Working directory for the Scion process."; };
        requiredMountsFor = mkOption { type = types.listOf types.str; default = [ ]; description = "Paths that must be mounted before Scion and image pulling start."; };
        imageRegistry = mkOption { type = types.str; default = "ghcr.io/phynics"; description = "Tag prefix for pulled harness images and Scion's image_registry."; };
        pullImages = mkOption { type = types.bool; default = true; description = "Pull digest-pinned harness images into the service account's Podman store before starting."; };
        settingsFile = mkOption { type = types.str; description = "Runtime YAML settings path, usually a sops-nix template path. Must include OIDC client_secret."; };
        environmentFile = mkOption { type = types.str; description = "Runtime environment file containing SCION_SERVER_SESSION_SECRET."; };
        containersStorageConf = mkOption { type = types.nullOr types.str; default = null; description = "Rootless containers storage.conf path."; };
      };
    };
  };

  config = lib.mkMerge [
    (mkIf program.enable {
      environment.systemPackages = [ program.package pkgs.git ];
      environment.sessionVariables.SCION_IMAGE_REGISTRY = program.imageRegistry;
    })
    {
      assertions = [
        { assertion = !(services.workstation.enable && (services.hub.enable || services.broker.enable || services.hosted.enable)); message = "Scion workstation cannot run beside another Scion service on this host."; }
        { assertion = !services.hosted.enable || !(services.hub.enable || services.broker.enable); message = "Scion hosted combined service cannot run beside a standalone Hub or Broker."; }
        { assertion = !services.hub.enable || builtins.match "[a-zA-Z0-9_-]+" services.hub.stateDirectory != null; message = "Scion Hub stateDirectory must be a single relative directory name."; }
      ];
    }
    (mkIf (services.workstation.enable || services.broker.enable || services.hosted.enable) {
      virtualisation.podman.enable = lib.mkDefault (
        (services.workstation.enable && program.runtime == "podman")
        || (services.broker.enable && services.broker.runtime == "podman")
        || services.hosted.enable
      );
    })
    (mkIf services.workstation.enable {
      systemd.services.scion-workstation = lib.recursiveUpdate ((commonService "workstation" services.workstation) // {
        path = runtimePath program.runtime;
        serviceConfig = (commonService "workstation" services.workstation).serviceConfig // {
          ExecStart = "${program.package}/bin/scion server start --foreground --enable-hub --enable-runtime-broker --enable-web --host ${services.workstation.listenAddress} --web-port ${toString services.workstation.port}";
        };
      }) (lib.optionalAttrs (program.runtime == "podman") podmanService);
    })
    (mkIf services.hub.enable {
      systemd.services.scion-hub = (commonService "Hub" services.hub) // {
        path = [ pkgs.git ];
        environment = (commonService "Hub" services.hub).environment // {
          SCION_SERVER_DATABASE_URL = "/var/lib/${services.hub.stateDirectory}/hub.db";
          SCION_SERVER_STORAGE_LOCAL_PATH = "/var/lib/${services.hub.stateDirectory}/storage";
        };
        serviceConfig = (commonService "Hub" services.hub).serviceConfig // {
          StateDirectory = services.hub.stateDirectory;
          ExecStart = "${program.package}/bin/scion server start --foreground --hosted --enable-hub --enable-web --host ${services.hub.listenAddress} --web-port ${toString services.hub.port}";
        };
      };
    })
    (mkIf services.broker.enable {
      systemd.services.scion-broker = lib.recursiveUpdate ((commonService "Broker" services.broker) // {
        path = runtimePath services.broker.runtime;
        serviceConfig = (commonService "Broker" services.broker).serviceConfig // {
          ExecStart = "${program.package}/bin/scion server start --foreground --hosted --enable-runtime-broker";
        };
      }) (lib.optionalAttrs (services.broker.runtime == "podman") podmanService);
    })
    (mkIf services.hosted.enable (
      let
        hosted = services.hosted;
        settingsLink = "${hosted.home}/.scion/settings.yaml";
        storageEnv = optionalAttrs (hosted.containersStorageConf != null) {
          CONTAINERS_STORAGE_CONF = hosted.containersStorageConf;
        };
        prepareSettings = pkgs.writeShellScript "scion-prepare-settings" ''
          set -eu
          ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg "${hosted.home}/.scion"}
          if [ -e ${lib.escapeShellArg settingsLink} ] && [ ! -L ${lib.escapeShellArg settingsLink} ]; then
            echo "Existing Scion settings must be migrated before enabling hosted mode: ${settingsLink}" >&2
            exit 1
          fi
          ${pkgs.coreutils}/bin/ln -sfn ${lib.escapeShellArg hosted.settingsFile} ${lib.escapeShellArg settingsLink}
        '';
      in {
        systemd.services.scion-images = mkIf hosted.pullImages {
          description = "Pull pinned Scion images for ${hosted.user}";
          after = [ "network-online.target" "linger-users.service" ];
          wants = [ "network-online.target" "linger-users.service" ];
          path = [ pkgs.podman ];
          unitConfig.RequiresMountsFor = hosted.requiredMountsFor;
          environment = { HOME = hosted.home; } // storageEnv;
          serviceConfig = {
            Type = "oneshot";
            User = hosted.user;
            Delegate = true;
            Environment = "PODMAN_SYSTEMD_UNIT=%n";
            RemainAfterExit = true;
            ExecStart = "${self.packages.${pkgs.stdenv.hostPlatform.system}.image-puller}/bin/scion-pull-images podman ${lib.escapeShellArg hosted.imageRegistry}";
          };
        };
        systemd.services.scion-hosted = {
          description = "Scion hosted Hub, Web, and Runtime Broker";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" "linger-users.service" ] ++ lib.optionals hosted.pullImages [ "scion-images.service" ];
          wants = [ "network-online.target" "linger-users.service" ];
          requires = lib.optionals hosted.pullImages [ "scion-images.service" ];
          path = runtimePath "podman";
          unitConfig.RequiresMountsFor = hosted.requiredMountsFor;
          environment = {
            HOME = hosted.home;
            SCION_IMAGE_REGISTRY = hosted.imageRegistry;
          } // storageEnv // optionalAttrs (hosted.publicURL != null) {
            SCION_SERVER_BASE_URL = hosted.publicURL;
          };
          serviceConfig = {
            User = hosted.user;
            WorkingDirectory = if hosted.workingDirectory == null then hosted.home else hosted.workingDirectory;
            Delegate = true;
            Environment = "PODMAN_SYSTEMD_UNIT=%n";
            EnvironmentFile = hosted.environmentFile;
            ExecStartPre = prepareSettings;
            ExecStart = "${hosted.package}/bin/scion server start --foreground --hosted --enable-hub --enable-web --enable-runtime-broker --host ${lib.escapeShellArg hosted.listenAddress} --web-port ${toString hosted.port} --runtime-broker-port ${toString hosted.brokerPort}${lib.optionalString (hosted.databasePath != null) " --db ${lib.escapeShellArg hosted.databasePath}"}";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };
      }
    ))
  ];
}
