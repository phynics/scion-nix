# Run modes

Scion has four [run modes](https://googlecloudplatform.github.io/scion/choosing-a-mode/). Each one runs more infrastructure than the one before it. This page shows how to deploy each mode with scion-nix. For every option and its default, see the [option reference](reference.md).

| Scion mode | What runs | scion-nix interface | Platforms |
|---|---|---|---|
| [Local](#local) | CLI only; you start agents with `scion start` | `programs.google-scion` | NixOS, nix-darwin |
| [Workstation](#workstation) | Combo server: Hub, Runtime Broker, and Web on loopback | `services.scion.workstation` | NixOS, nix-darwin |
| [Single-node hosted](#single-node-hosted) | One networked Hub on SQLite, optionally with an embedded Broker | `services.scion.hub`, or the [server image](images.md#server-image) | NixOS, containers |
| [HA hosted](#ha-hosted) | Hub replicas on Postgres and GCS; agents run on separate Brokers | `services.scion.hub` with `availability = "ha"`, or the server image | NixOS, containers |
| [Standalone Broker](#standalone-runtime-broker) | Agent execution for a Hub that runs elsewhere | `services.scion.broker` | NixOS |

**Choosing a mode.** First decide whether you need a networked control plane at all. If not, use Local. If you want the dashboard on your own machine only, use Workstation. If you do need a networked control plane, decide whether it must survive restarts and node loss. If it must, use HA hosted; if not, use Single-node hosted.

## What every service has in common

- **Native binary.** Services run the native `scion` binary under systemd (NixOS) or launchd (macOS). None of them runs a Scion server container.
- **Existing account.** `user` must name an account that already exists. The modules never create accounts. Scion keeps its settings under that account's home.
- **Settings are left alone.** An existing `~/.scion/settings.yaml` is never overwritten. If you set `settingsFile`, a regular file already at that path stops startup until you migrate it.
- **Agent images.** Components that run agents pull the digest-pinned [harness images](images.md#agent-harness-images) into the account's container store before they start.
- **Secrets.** Secrets reach services only through `environmentFile` or `settingsFile`, which are runtime paths. See [Secrets](operations.md#secrets).

## Import the modules

```nix
# flake.nix
{
  inputs.scion-nix.url = "github:phynics/scion-nix";
}
```

```nix
# NixOS configuration
{ inputs, ... }: { imports = [ inputs.scion-nix.nixosModules.default ]; }

# nix-darwin configuration
{ inputs, ... }: { imports = [ inputs.scion-nix.darwinModules.default ]; }
```

## Account prerequisites for rootless Podman (NixOS)

Every service that runs agents with rootless Podman needs these settings on its account:

```nix
users.users.scion = {
  isNormalUser = true;
  linger = true;   # the user manager must run without a login session
  subUidRanges = [{ startUid = 100000; count = 65536; }];
  subGidRanges = [{ startGid = 100000; count = 65536; }];
};
```

To use Docker instead, set `programs.google-scion.runtime = "docker"` (or the per-service `runtime`), and add the account to the `docker` group.

## Local

```nix
{
  programs.google-scion.enable = true;   # runtime = "podman" (default) or "docker" on NixOS
}
```

This installs `scion` and Git, and exports `SCION_IMAGE_REGISTRY`. On NixOS it also enables the container runtime. On macOS it installs Podman, but you must run `podman machine init` and `podman machine start` yourself.

Then pull the agent images and start an agent:

```sh
nix run github:phynics/scion-nix#pull-images -- podman
cd my-repo && scion start my-agent
```

## Workstation

```nix
# NixOS
{
  programs.google-scion.enable = true;
  services.scion.workstation = {
    enable = true;
    user = "scion";
    harnesses = [ "claude" "opencode" ];   # optional; default is every harness
  };
}
```

```nix
# nix-darwin
{ config, ... }: {
  programs.google-scion.enable = true;
  services.scion.workstation = {
    enable = true;
    user = config.system.primaryUser;   # must own the Podman machine
  };
}
```

The service runs `scion server start --foreground` with upstream's workstation defaults: every component, dev auth, and auto-provide, bound to `127.0.0.1:8080`. Open <http://localhost:8080>.

- **NixOS.** A `scion-workstation-images` unit pulls the images first. Scion runs with a delegated cgroup under the account's lingering user manager.
- **macOS.** The service is a launchd user agent, so it can only run as `system.primaryUser`. Pull the images yourself once the Podman machine is running.

## Single-node hosted

A single Hub on one node, with SQLite state. It accepts downtime during restarts and redeploys.

```nix
{ config, ... }: {
  services.scion.hub = {
    enable = true;
    user = "scion";
    listenAddress = "0.0.0.0";
    publicURL = "https://scion.example.com";                          # OAuth/OIDC callback base
    adminEmails = [ "me@example.com" ];
    environmentFile = config.sops.secrets.scion-hub-env.path;         # SCION_SERVER_SESSION_SECRET=...
    settingsFile = config.sops.templates."scion-settings.yaml".path;  # optional: OAuth/OIDC config
    broker.enable = true;                                             # optional: run agents here too
  };
}
```

- **State.** SQLite (`hub.db`) and template storage live in `/var/lib/scion-hub`, the systemd `StateDirectory`, which systemd owns. To reuse an existing database or template store, set `databasePath` and `storagePath`. To store templates in GCS instead, set `storageBucket`.
- **Without a broker**, the Hub needs no container runtime and pulls no images.
- **With `broker.enable`**, the Hub process also runs a Runtime Broker on port 9800. The `scion-hub-images` unit pulls the harness images before startup.

[examples/single-node.nix](../examples/single-node.nix) is a complete configuration with sops-nix, OIDC login, and an embedded broker.

## HA hosted

Deploy the same Hub configuration on every replica behind a load balancer:

```nix
{ config, ... }: {
  services.scion.hub = {
    enable = true;
    availability = "ha";
    user = "scion";
    listenAddress = "0.0.0.0";
    publicURL = "https://scion.example.com";
    hubId = "scion-prod";               # identical on every replica
    storageBucket = "my-scion-bucket";  # GCS
    environmentFile = config.sops.secrets.scion-hub-env.path;
  };
}
```

The environment file must contain:

```sh
SCION_SERVER_DATABASE_URL=postgres://user:pass@host:5432/scion?sslmode=require
SCION_SERVER_SESSION_SECRET=...
# GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json   # unless the VM has an attached service account
```

Evaluation fails if `hubId`, `storageBucket`, or `environmentFile` is missing, if `databasePath` is set, or if `broker.enable` is set. HA replicas never embed a broker: run agents on [standalone brokers](#standalone-runtime-broker).

Upstream's HA preflight, which runs when the Hub starts, also requires Postgres, GCS, a hub ID, and a session secret.

See [examples/ha-hub.nix](../examples/ha-hub.nix). On Cloud Run or Kubernetes, use the [server image](images.md#server-image) with the same variables.

## Standalone Runtime Broker

```nix
{
  services.scion.broker = {
    enable = true;
    user = "agents";
  };
}
```

This runs `scion server start --hosted --enable-runtime-broker`. The broker listens on loopback port 9800 and dials out to the Hub. Register it once, as the service account:

```sh
sudo -iu agents
scion hub auth login --hub-url https://scion.example.com --no-browser
scion broker register
cd /path/to/project && scion broker provide
```

A host can run either `services.scion.broker` or `services.scion.hub.broker`, not both. The workstation already includes a broker.
