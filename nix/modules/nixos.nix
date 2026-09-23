{ self }:
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types optionalAttrs;
  program = config.programs.google-scion;
  services = config.services.scion;
  defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.google-scion;
  envFile = file: optionalAttrs (file != null) { EnvironmentFile = file; };
  runtimePath = runtime: [ pkgs.git ] ++ lib.optionals (runtime == "podman") [ pkgs.podman ]
    ++ lib.optionals (runtime == "docker") [ pkgs.docker ];
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
    };
  };

  config = lib.mkMerge [
    (mkIf program.enable {
      environment.systemPackages = [ program.package pkgs.git ];
      environment.sessionVariables.SCION_IMAGE_REGISTRY = program.imageRegistry;
    })
    {
      assertions = [
        { assertion = !(services.workstation.enable && (services.hub.enable || services.broker.enable)); message = "Scion workstation cannot run beside a standalone Hub or Broker on this host."; }
        { assertion = !services.hub.enable || builtins.match "[a-zA-Z0-9_-]+" services.hub.stateDirectory != null; message = "Scion Hub stateDirectory must be a single relative directory name."; }
      ];
    }
    (mkIf (services.workstation.enable || services.broker.enable) {
      virtualisation.podman.enable = lib.mkDefault (
        (services.workstation.enable && program.runtime == "podman")
        || (services.broker.enable && services.broker.runtime == "podman")
      );
    })
    (mkIf services.workstation.enable {
      systemd.services.scion-workstation = (commonService "workstation" services.workstation) // {
        path = runtimePath program.runtime;
        serviceConfig = (commonService "workstation" services.workstation).serviceConfig // {
          ExecStart = "${program.package}/bin/scion server start --foreground --enable-hub --enable-runtime-broker --enable-web --host ${services.workstation.listenAddress} --web-port ${toString services.workstation.port}";
        };
      };
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
      systemd.services.scion-broker = (commonService "Broker" services.broker) // {
        path = runtimePath services.broker.runtime;
        serviceConfig = (commonService "Broker" services.broker).serviceConfig // {
          ExecStart = "${program.package}/bin/scion server start --foreground --hosted --enable-runtime-broker";
        };
      };
    })
  ];
}
