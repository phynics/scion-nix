{ self }:
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  program = config.programs.google-scion;
  service = config.services.scion.workstation;
  defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.google-scion;
  command = pkgs.writeShellScript "scion-workstation" ''
    set -eu
    export SCION_IMAGE_REGISTRY=${lib.escapeShellArg program.imageRegistry}
    ${lib.optionalString (service.environmentFile != null) ''
      set -a
      . ${lib.escapeShellArg (toString service.environmentFile)}
      set +a
    ''}
    exec ${program.package}/bin/scion server start --foreground --enable-hub --enable-runtime-broker --enable-web --host ${lib.escapeShellArg service.listenAddress} --web-port ${toString service.port}
  '';
in
{
  options = {
    programs.google-scion = {
      enable = mkEnableOption "the Scion command line interface";
      package = mkOption { type = types.package; default = defaultPackage; };
      runtime = mkOption { type = types.enum [ "podman" ]; default = "podman"; description = "Scion agent runtime on macOS."; };
      imageRegistry = mkOption { type = types.str; default = "ghcr.io/phynics"; };
    };
    services.scion.workstation = {
      enable = mkEnableOption "the native Scion workstation server";
      user = mkOption { type = types.str; description = "Login account that owns the Podman machine."; };
      listenAddress = mkOption { type = types.str; default = "127.0.0.1"; };
      port = mkOption { type = types.port; default = 8080; };
      environmentFile = mkOption { type = types.nullOr types.str; default = null; description = "Runtime path to a shell-compatible environment file."; };
    };
  };

  config = lib.mkMerge [
    (mkIf program.enable {
      environment.systemPackages = [ program.package pkgs.git pkgs.podman ];
      environment.variables.SCION_IMAGE_REGISTRY = program.imageRegistry;
    })
    {
      assertions = [
        { assertion = !service.enable || service.user == config.system.primaryUser; message = "The Scion launchd agent must run as the nix-darwin primaryUser who owns its Podman machine."; }
      ];
    }
    (mkIf service.enable {
      launchd.user.agents.scion-workstation.serviceConfig = {
        ProgramArguments = [ "${command}" ];
        RunAtLoad = true;
        KeepAlive = true;
      };
    })
  ];
}
