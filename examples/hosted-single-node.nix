# Import this alongside the scion-nix and sops-nix NixOS modules.
# Supply sops.defaultSopsFile and replace the example OIDC values.
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
          admin_emails:
            - admin@example.test
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

  programs.google-scion = {
    enable = true;
    package = config.services.scion.hosted.package;
    imageRegistry = "localhost/scion";
  };

  services.scion.hosted = {
    enable = true;
    user = "scion";
    home = "/home/scion";
    listenAddress = "0.0.0.0";
    port = 8080;
    brokerPort = 9800;
    publicURL = "http://hub.example.test:8080";
    imageRegistry = "localhost/scion";
    settingsFile = config.sops.templates."scion-settings.yaml".path;
    environmentFile = config.sops.templates."scion-session.env".path;
  };

  systemd.services.scion-hosted = {
    after = [ "sops-nix.service" ];
    requires = [ "sops-nix.service" ];
  };

  # Define the service account, firewall rules, and any custom storage or
  # workspace mounts in the host configuration.
}
