# HA hosted: one replica of a load-balanced Hub. Deploy the same
# configuration on every replica node behind the load balancer; state lives
# in Cloud SQL Postgres and a GCS bucket, so replicas are interchangeable.
# Agents run on separate nodes with services.scion.broker.
#
# The environment file must contain, for example:
#   SCION_SERVER_DATABASE_URL=postgres://scion:...@10.0.0.5:5432/scion?sslmode=require
#   SCION_SERVER_SESSION_SECRET=...
#   GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/scion-gcp.json   (unless the VM has an attached service account)
{ config, ... }:
{
  sops.secrets.scion-hub-env = { owner = "scion"; };

  services.scion.hub = {
    enable = true;
    availability = "ha";
    user = "scion";
    listenAddress = "0.0.0.0";
    publicURL = "https://scion.example.test";
    hubId = "scion-example";
    storageBucket = "example-scion-hub";
    adminEmails = [ "admin@example.test" ];
    environmentFile = config.sops.secrets.scion-hub-env.path;
  };

  systemd.services.scion-hub = {
    after = [ "sops-nix.service" ];
    requires = [ "sops-nix.service" ];
  };
}
