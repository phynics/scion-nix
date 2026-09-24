{ self }:
{ config, lib, pkgs, ... }:

# macOS supports the two single-user modes:
#
#   Local        programs.google-scion         CLI + Podman, no server
#   Workstation  services.scion.workstation    combo server as a launchd user agent
#
# Agents run in Linux containers inside the account's Podman machine, which
# must already exist and be running. Hosted Hubs belong on Linux (see the
# NixOS module or the scion-server-image package).

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  program = config.programs.google-scion;
  service = config.services.scion.workstation;
  defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.google-scion;
  # launchd agents start with a minimal PATH; Scion shells out to git and podman.
  path = lib.makeBinPath [ program.package pkgs.git pkgs.podman ];
  command = pkgs.writeShellScript "scion-workstation" ''
    set -eu
    export PATH=${lib.escapeShellArg path}:/usr/bin:/bin:/usr/sbin:/sbin
    export SCION_IMAGE_REGISTRY=${lib.escapeShellArg program.imageRegistry}
    ${lib.optionalString (service.environmentFile != null) ''
      set -a
      . ${lib.escapeShellArg service.environmentFile}
      set +a
    ''}
    exec ${program.package}/bin/scion server start --foreground --host ${lib.escapeShellArg service.listenAddress} --web-port ${toString service.port}
  '';
in
{
  options = {
    programs.google-scion = {
      enable = mkEnableOption "the Scion CLI for Local mode (agents started directly with `scion start`, no server)";
      package = mkOption { type = types.package; default = defaultPackage; defaultText = lib.literalExpression "scion-nix.packages.\${system}.google-scion"; };
      runtime = mkOption { type = types.enum [ "podman" ]; default = "podman"; description = "Agent runtime on macOS."; };
      imageRegistry = mkOption { type = types.str; default = "ghcr.io/phynics"; description = "Registry prefix for standard harness images (SCION_IMAGE_REGISTRY)."; };
    };
    services.scion.workstation = {
      enable = mkEnableOption "Workstation mode: Hub, Runtime Broker and Web in one loopback server";
      user = mkOption { type = types.str; description = "Login account that owns the Podman machine; must be system.primaryUser."; };
      listenAddress = mkOption { type = types.str; default = "127.0.0.1"; };
      port = mkOption { type = types.port; default = 8080; };
      environmentFile = mkOption { type = types.nullOr types.str; default = null; description = "Runtime path to a shell-compatible KEY=value file, sourced at start."; };
    };
  };

  config = lib.mkMerge [
    (mkIf program.enable {
      environment.systemPackages = [ program.package pkgs.git pkgs.podman ];
      environment.variables.SCION_IMAGE_REGISTRY = program.imageRegistry;
    })
    {
      assertions = [
        { assertion = !service.enable || service.user == config.system.primaryUser; message = "The Scion launchd agent runs as system.primaryUser, who must own the Podman machine."; }
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
