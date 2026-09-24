# Single-node hosted: one networked Hub on SQLite, with an embedded Runtime
# Broker that runs agents in the service account's rootless Podman.
#
# Import this alongside the scion-nix and sops-nix NixOS modules, supply
# sops.defaultSopsFile, and replace the example OIDC values. Define the
# `scion` account (with a home, subuid/subgid ranges, and linger) and the
# firewall rules in the host configuration.
{ config, ... }:
{
  sops.secrets.scion-oidc-client-secret = { };
  sops.secrets.scion-session-secret = { };

  sops.templates."scion-settings.yaml" = {
    owner = "scion";
    mode = "0600";
    content = ''
      schema_version: "1"
      image_registry: localhost/scion
      active_profile: local
      default_harness_config: opencode
      runtimes:
        podman:
          type: podman
      profiles:
        local:
          runtime: podman
      server:
        mode: hosted
        hub:
          public_url: http://hub.example.test:8080
        broker:
          host: 127.0.0.1
          port: 9800
          auto_provide: true
        oidc_login:
          enabled: true
          display_name: OIDC
          issuer_url: https://id.example.test
          client_id: REPLACE_WITH_OIDC_CLIENT_ID
          client_secret: ${config.sops.placeholder.scion-oidc-client-secret}
    '';
  };
  sops.templates."scion-session.env" = {
    owner = "scion";
    mode = "0600";
    content = ''
      SCION_SERVER_SESSION_SECRET=${config.sops.placeholder.scion-session-secret}
    '';
  };

  # image_registry above must match the prefix the harness images are tagged with.
  programs.google-scion = {
    enable = true;
    package = config.services.scion.hub.package;
    imageRegistry = "localhost/scion";
  };

  services.scion.hub = {
    enable = true;
    availability = "single-node";
    user = "scion";
    listenAddress = "0.0.0.0";
    port = 8080;
    publicURL = "http://hub.example.test:8080";
    adminEmails = [ "admin@example.test" ];
    settingsFile = config.sops.templates."scion-settings.yaml".path;
    environmentFile = config.sops.templates."scion-session.env".path;
    broker = {
      enable = true;
      port = 9800;
      harnesses = [ "opencode" "claude" ];
    };
  };

  systemd.services.scion-hub = {
    after = [ "sops-nix.service" ];
    requires = [ "sops-nix.service" ];
  };
}
