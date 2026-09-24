# Container images

Scion uses two kinds of container image, and scion-nix delivers both:

| Image | Used by | Built by | Published as |
|---|---|---|---|
| Agent harness images (`scion-claude`, `scion-opencode`, …) | Every mode: each agent runs in one | Upstream Dockerfiles, in [images.yml](../.github/workflows/images.yml) | `ghcr.io/phynics/scion-<harness>`, pinned by digest in [image-manifest.json](../image-manifest.json) |
| Server image (`scion-server`) | Hosted modes, when you run the Hub in a container | Nix: [nix/server-image.nix](../nix/server-image.nix) | `ghcr.io/phynics/scion-server`, via [server-image.yml](../.github/workflows/server-image.yml) |

## Agent harness images

Harness images are Linux images for `linux/amd64` and `linux/arm64`. macOS runs them through its Podman machine.

Scion looks up each image as `<image_registry>/scion-<harness>:latest`, where `image_registry` comes from `SCION_IMAGE_REGISTRY` or `settings.yaml`. That name is a mutable tag, so scion-nix pins the images another way:

1. The images workflow builds every harness in upstream's `harnesses/*/Dockerfile` from the commit pinned in [upstream.json](../upstream.json), then records each platform's digest.
2. The pull app pulls `ghcr.io/phynics/scion-<harness>@<digest>` for the host's architecture, then tags it as `<registry>/scion-<harness>:latest` in the local container store.

That way, the `:latest` tag Scion resolves always points at the image built from the pinned commit.

### Pull the images yourself

```sh
nix run github:phynics/scion-nix#pull-images -- RUNTIME [TARGET_REGISTRY] [HARNESS...]

nix run github:phynics/scion-nix#pull-images -- podman                                 # every harness, tagged under ghcr.io/phynics
nix run github:phynics/scion-nix#pull-images -- podman localhost/scion                 # tagged under a local prefix
nix run github:phynics/scion-nix#pull-images -- docker ghcr.io/phynics claude opencode  # only these harnesses
```

- `RUNTIME` is `podman` or `docker`.
- `TARGET_REGISTRY` must match your `image_registry`.
- You can name a harness with or without the `scion-` prefix.
- The app pulls only harness images; it never pulls `core-base`, `scion-base`, or `scion-hub`.

### Pulling from NixOS services

`services.scion.workstation`, `services.scion.hub` (with `broker.enable`), and `services.scion.broker` each have a oneshot unit that pulls images before the service starts. The unit is named `scion-workstation-images`, `scion-hub-images`, or `scion-broker-images`.

The unit runs as the service account, so the images land in that account's own rootless store. Three options control it:

- `harnesses` selects which images to pull.
- `pullImages = false` turns the unit off.
- `programs.google-scion.imageRegistry` sets the tag prefix, and is also exported to Scion as `SCION_IMAGE_REGISTRY`.

If a `settings.yaml` sets `image_registry`, it must use the same prefix.

### Custom images

A template or agent that names an explicit image overrides `image_registry`. You are responsible for pinning such images yourself.

## Server image

`packages.<linux-system>.scion-server-image` is a layered OCI image. Nix builds it from `google-scion-source`, the Scion binary with the web dashboard embedded. Upstream's `scion-hub` image omits the web assets, so `--enable-web` serves the UI only with this image.

| Property | Value |
|---|---|
| Entrypoint | `tini --` |
| Default command | `scion server start --foreground --hosted --enable-hub --enable-web --host 0.0.0.0 --web-port 8080` |
| User | `scion` (UID/GID 1000), home `/home/scion` |
| Volume | `/home/scion/.scion` (SQLite and templates in single-node use) |
| Ports | 8080 (Web + Hub API), 9800 (Runtime Broker, if enabled) |
| Contents | `scion`, `git`, `ssh`, `bash`, coreutils, CA certificates; no harnesses, no container engine |

### Build and run locally

```sh
nix build github:phynics/scion-nix#scion-server-image
podman load < result

# Single-node hosted
podman run -d --name scion -p 8080:8080 -v scion-state:/home/scion/.scion \
  -e SCION_SERVER_SESSION_SECRET="$(openssl rand -hex 32)" \
  -e SCION_SERVER_BASE_URL=https://scion.example.com \
  scion-server:scion-v0.3.0-preview.3
curl localhost:8080/healthz
```

### HA hosted

Pass the same configuration the HA module uses:

```sh
SCION_SERVER_DATABASE_DRIVER=postgres
SCION_SERVER_DATABASE_URL=postgres://...
SCION_SERVER_HUB_HUBID=scion-prod
SCION_SERVER_STORAGE_BUCKET=my-scion-bucket
SCION_SERVER_SESSION_SECRET=...
```

On Cloud Run, the presence of `K_SERVICE` switches on Scion's HA preflight checks.

### Running a broker in the image

To run a Runtime Broker in the image, override the command and add `--enable-runtime-broker`. The image contains no container engine, so such a broker is only useful with a Kubernetes runtime profile.

### Publishing

Run the **Build Scion server image** workflow manually. It builds on an amd64 and an arm64 runner and pushes `scion-server:<imageTag>-<arch>`. It then creates the multi-arch tags `scion-server:<imageTag>` and `scion-server:latest`.

## Upstream images the modules do not use

Upstream also publishes `scion-hub` and `scion-omni`; the modules use neither.

- `scion-hub` is a Hub without web assets. Its digests from this pin are listed in the manifest for reference.
- `scion-omni` combines a Hub and harnesses, is amd64-only, and targets Cloud Run Instances. This repository does not build it.
