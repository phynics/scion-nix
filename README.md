# scion-nix

Nix packages, container images, and NixOS/nix-darwin modules for [Scion](https://googlecloudplatform.github.io/scion/overview/), covering each of its [run modes](https://googlecloudplatform.github.io/scion/choosing-a-mode/).

The flake pins upstream Scion `v0.3.0-preview.3` (commit `253ba544`) in [upstream.json](upstream.json). The agent image digests in [image-manifest.json](image-manifest.json) were built from the same commit.

## Choosing a mode

| Scion mode | What runs | Nix interface | Container images needed |
|---|---|---|---|
| **Local** | CLI only; agents started with `scion start` | `programs.google-scion` (NixOS, nix-darwin) | Harness images |
| **Workstation** | Combo server (Hub + Broker + Web) on loopback | `services.scion.workstation` (NixOS, nix-darwin) | Harness images |
| **Single-node hosted** | One networked Hub on SQLite, optionally with an embedded Broker | `services.scion.hub` on NixOS, or the `scion-server` image | Harness images only if the node runs agents |
| **HA hosted** | Hub replicas on Postgres and GCS; agents on separate Brokers | `services.scion.hub` with `availability = "ha"` on each replica, or the `scion-server` image | Harness images on the Broker nodes |
| (any hosted) | A Runtime Broker that runs agents for a remote Hub | `services.scion.broker` (NixOS) | Harness images |

Every module runs the native `scion` binary under systemd or launchd, as an account you already have. The modules never create accounts, and they never overwrite an existing `~/.scion/settings.yaml`.

## Flake outputs

| Output | Description |
|---|---|
| `packages.<system>.google-scion` (default) | Prebuilt release binary for all four platforms, fetched by a fixed hash. No local compilation. |
| `packages.<system>.google-scion-source` | The same revision built from source (Go + embedded web UI), with the Hub fixes in [nix/package.nix](nix/package.nix). Hub services use this by default. |
| `packages.<linux>.scion-server-image` | OCI image that runs the Scion server in a container. See [Running Scion in a container](#running-scion-in-a-container). |
| `packages.<system>.image-puller`, `apps.<system>.pull-images` | Pulls the harness images by digest and tags them for Scion. |
| `nixosModules.default`, `darwinModules.default` | The modules described below. |

## Container images

Scion needs two kinds of image:

- **Agent (harness) images** such as `scion-claude` and `scion-opencode`. Every agent runs in one of these, in every mode. [images.yml](.github/workflows/images.yml) builds them with upstream's Dockerfiles for `linux/amd64` and `linux/arm64` and pushes them to `ghcr.io/phynics`. The manifest records the digest for each platform.
- **The server image** `scion-server`, for running the Hub, Web, and optionally a Broker inside a container. It is built by Nix; see below.

Pull the harness images by their immutable digests and tag them with the names Scion expects (`<image_registry>/scion-<harness>:latest`):

```sh
nix run github:phynics/scion-nix#pull-images -- podman                        # all harnesses, tagged ghcr.io/phynics/...
nix run github:phynics/scion-nix#pull-images -- podman localhost/scion         # tagged under another image_registry
nix run github:phynics/scion-nix#pull-images -- docker ghcr.io/phynics claude opencode   # only some harnesses
```

The NixOS services that run agents do this themselves: a `scion-<component>-images` oneshot unit pulls the images into the service account's store before Scion starts. `harnesses` selects which images to pull and `pullImages = false` disables it. The tag prefix is `programs.google-scion.imageRegistry`, which is also exported to Scion as `SCION_IMAGE_REGISTRY`. If a `settings.yaml` sets `image_registry`, it must use the same prefix.

On macOS, run the pull app yourself once the Podman machine is up. macOS pulls the Linux image for its architecture.

## Local mode

```nix
{ inputs, ... }: {
  imports = [ inputs.scion-nix.nixosModules.default ];   # or darwinModules.default
  programs.google-scion.enable = true;                    # runtime = "podman" (default) or "docker" on NixOS
}
```

This installs `scion` and Git and enables the selected container runtime on NixOS. On macOS, Podman is installed, but you must create and start `podman machine` yourself. Then run `nix run github:phynics/scion-nix#pull-images -- podman` and use `scion start` in a Git repository.

To try the CLI without a module, run `nix run github:phynics/scion-nix -- version`.

## Workstation mode

```nix
# NixOS
{
  users.users.scion = {
    isNormalUser = true;
    linger = true;
    subUidRanges = [{ startUid = 100000; count = 65536; }];
    subGidRanges = [{ startGid = 100000; count = 65536; }];
  };
  programs.google-scion.enable = true;
  services.scion.workstation = {
    enable = true;
    user = "scion";
    harnesses = [ "claude" "opencode" ];   # default: all
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

The service runs `scion server start --foreground` with workstation defaults: Hub, Broker, and Web in one process on `127.0.0.1:8080`, with dev auth and auto-provide. On NixOS it runs as a system unit with `User=`, rootless Podman (`Delegate=yes`, `PODMAN_SYSTEMD_UNIT`), and the account's lingering user manager. On macOS it is a launchd user agent. It can only run as `system.primaryUser`, because a user agent cannot switch accounts.

## Single-node hosted

`services.scion.hub` runs `scion server start --hosted --enable-hub --enable-web`. SQLite and local template storage live in `/var/lib/<stateDirectory>` (default `scion-hub`), which systemd owns. Set `broker.enable` to run the Runtime Broker in the same process, so the node also runs agents. A Hub without a broker needs no container runtime and no images.

```nix
{ config, ... }: {
  services.scion.hub = {
    enable = true;
    user = "scion";
    listenAddress = "0.0.0.0";
    publicURL = "https://scion.example.com";         # sets SCION_SERVER_BASE_URL (OAuth/OIDC callbacks)
    adminEmails = [ "me@example.com" ];
    environmentFile = config.sops.secrets.scion-hub-env.path;    # SCION_SERVER_SESSION_SECRET=...
    settingsFile = config.sops.templates."scion-settings.yaml".path;  # optional; OAuth/OIDC client secrets
    broker.enable = true;                            # optional: run agents on this node too
  };
}
```

[examples/single-node.nix](examples/single-node.nix) is a complete sops-nix setup with OIDC login and an embedded broker.

- `settingsFile` is symlinked to `~/.scion/settings.yaml` before each start. If a regular file already exists there, startup stops so that you can migrate it deliberately. The pinned revision does not read the OIDC client secret from the environment, so put `server.oidc_login.client_secret` in this file.
- `environmentFile` is loaded by systemd. Keep secrets such as `SCION_SERVER_SESSION_SECRET` there, never in Nix strings.
- To keep an existing SQLite database, set `databasePath`.

After deploying, check `systemctl status scion-hub scion-hub-images` and `curl localhost:8080/healthz`. Then complete a login and start an agent.

## HA hosted

Deploy the same Hub configuration on every replica behind a load balancer, with `availability = "ha"`. Each replica then runs with `SCION_SERVER_DATABASE_DRIVER=postgres`, a shared `hubId`, and GCS storage (`storageBucket`). The environment file must provide `SCION_SERVER_DATABASE_URL` and `SCION_SERVER_SESSION_SECRET`. HA replicas do not embed a broker; run agents on `services.scion.broker` nodes. See [examples/ha-hub.nix](examples/ha-hub.nix).

For Cloud Run or Kubernetes, use the server image with the same `SCION_SERVER_*` variables.

## Standalone Runtime Broker

```nix
{
  services.scion.broker = {
    enable = true;
    user = "agents";   # existing account with rootless Podman (or runtime = "docker")
  };
}
```

This runs `scion server start --hosted --enable-runtime-broker` on port 9800, bound to loopback. The broker dials the Hub itself. Register it once as the service account: `scion hub auth login --hub-url <hub-url> --no-browser`, then `scion broker register`, then `scion broker provide` in each project it should serve.

## Running Scion in a container

`packages.<linux>.scion-server-image` is a layered OCI image built by Nix from `google-scion-source`. [server-image.yml](.github/workflows/server-image.yml) publishes it as `ghcr.io/phynics/scion-server`. Unlike upstream's `scion-hub` image, it contains the embedded web dashboard. It runs as UID 1000 under `tini`, and by default runs `scion server start --foreground --hosted --enable-hub --enable-web --host 0.0.0.0 --web-port 8080`.

```sh
nix build .#scion-server-image && podman load < result
# Single-node hosted: SQLite in a volume
podman run -d -p 8080:8080 -v scion-state:/home/scion/.scion \
  -e SCION_SERVER_SESSION_SECRET=... -e SCION_SERVER_BASE_URL=https://scion.example.com \
  scion-server:scion-v0.3.0-preview.3
```

For HA, pass `SCION_SERVER_DATABASE_DRIVER=postgres`, `SCION_SERVER_DATABASE_URL`, `SCION_SERVER_HUB_HUBID`, `SCION_SERVER_STORAGE_BUCKET`, and `SCION_SERVER_SESSION_SECRET`. The image contains no harnesses and no container engine, so agents run on Brokers elsewhere. For a Kubernetes-runtime Broker, override the command with `--enable-runtime-broker`.

Upstream also publishes `scion-hub`, which has no web assets, and `scion-omni` (amd64 only). Their digests from this pin are in the manifest for reference. The modules do not use them.

## Secrets

Every service takes `environmentFile`, a runtime path such as `config.sops.secrets.<name>.path`. The file must contain `KEY=value` lines, be readable by the service account, and stay outside the Nix store. sops-nix is not a flake input. Order your units after `sops-nix.service`, as the examples do.

## Migrating from `services.scion.hosted`

`services.scion.hosted` has been removed, and using it fails evaluation with instructions. The same Hub + Web + Broker process is now `services.scion.hub` with `broker.enable = true`. The fields map as follows:

- `brokerPort`, `pullImages`, and `containersStorageConf` move to `hub.broker.*`.
- `imageRegistry` becomes `programs.google-scion.imageRegistry`.
- `home` is no longer needed; systemd provides the account's home.
- The pull unit is renamed from `scion-images` to `scion-hub-images`, and the service from `scion-hosted` to `scion-hub`.
- Set `hub.databasePath` to the old database (by default `~/.scion/hub.db`) to keep your data.

## CI and releases

- [nix.yml](.github/workflows/nix.yml) runs `nix flake check` and builds both packages on all four platforms. On Linux the check also builds the server image.
- [release.yml](.github/workflows/release.yml) attaches the four native tarballs to the GitHub release named by `binaryRelease` in `upstream.json`.
- [images.yml](.github/workflows/images.yml) builds and verifies the upstream harness images and uploads a new `image-manifest.json`.
- [server-image.yml](.github/workflows/server-image.yml) publishes the Nix-built server image.
- [publish-cache.yml](.github/workflows/publish-cache.yml) pushes to Cachix once the `CACHIX_NAME` variable and the `CACHIX_AUTH_TOKEN` secret exist.

To bump Scion, update the `scion-src` input, then `upstream.json`, then the vendor and npm hashes. Next, run the images workflow and commit its manifest. Finally, cut a release and update the hashes in `nix/published-binaries.nix`.

## Not yet verified on real hosts

Module behavior is covered by evaluation tests in [nix/tests/modules.nix](nix/tests/modules.nix). Live deployments are the remaining gap:

- the HA tier against Postgres and GCS
- the standalone broker registration flow
- the server image on Cloud Run or Kubernetes
- the macOS launchd agent

The prebuilt `google-scion` release binary predates the Hub fixes in `nix/package.nix`. Cut a new `binaryRelease` so that it carries them.
