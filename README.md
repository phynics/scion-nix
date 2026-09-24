# scion-nix

Nix packages, container images, and NixOS/nix-darwin modules for [Scion](https://googlecloudplatform.github.io/scion/overview/). The modules cover each of Scion's [run modes](https://googlecloudplatform.github.io/scion/choosing-a-mode/).

The flake pins Scion `v0.3.0-preview.3` (commit `253ba544`) in [sources.json](sources.json). The agent images in [image-manifest.json](image-manifest.json) are built from the same commit and pinned by digest.

New upstream releases arrive automatically. A daily workflow rewrites the pin, builds the new images, and opens an update PR. Each merged pin is tagged `<version>-nix.<N>`, so you can pin or roll back with `github:phynics/scion-nix/<tag>`. See [Updating Scion](docs/operations.md#updating-scion).

## Modes at a glance

| Scion mode | Nix interface | Guide |
|---|---|---|
| Local: CLI only | `programs.google-scion` (NixOS, nix-darwin) | [Local](docs/modes.md#local) |
| Workstation: Hub + Broker + Web on loopback | `services.scion.workstation` (NixOS, nix-darwin) | [Workstation](docs/modes.md#workstation) |
| Single-node hosted: one Hub on SQLite | `services.scion.hub`, or the server image | [Single-node hosted](docs/modes.md#single-node-hosted) |
| HA hosted: Hub replicas on Postgres + GCS | `services.scion.hub` with `availability = "ha"`, or the server image | [HA hosted](docs/modes.md#ha-hosted) |
| Agent compute for a remote Hub | `services.scion.broker` | [Standalone broker](docs/modes.md#standalone-runtime-broker) |

## Quick start

```sh
# The CLI, prebuilt (no local compilation)
nix run github:phynics/scion-nix -- version

# Agent images for Podman or Docker, pulled by digest
nix run github:phynics/scion-nix#pull-images -- podman

# The Scion server as a container image (Linux)
nix build github:phynics/scion-nix#scion-server-image && podman load < result
```

To use the modules, add `inputs.scion-nix.url = "github:phynics/scion-nix"` to your flake. Then import one of the modules:

- `inputs.scion-nix.nixosModules.default`
- `inputs.scion-nix.darwinModules.default`

For example, a NixOS workstation:

```nix
{
  imports = [ inputs.scion-nix.nixosModules.default ];
  programs.google-scion.enable = true;
  services.scion.workstation = { enable = true; user = "scion"; };
}
```

## What the flake provides

- **`google-scion`** (the default package): upstream's release binary for x86_64/aarch64 Linux and macOS.
- **`google-scion-source`**: the same binary built from source, including the Hub fixes.
- **Agent harness images**: built from upstream's Dockerfiles for amd64 and arm64. They are pulled by digest, either by the `pull-images` app or by the services that run agents.
- **`scion-server-image`**: a Nix-built OCI image that runs the Hub and web dashboard in a container.
- **NixOS and nix-darwin modules** for the modes above, with evaluation tests for each mode.

## Documentation

| For | Read |
|---|---|
| Choosing and deploying a mode | [docs/modes.md](docs/modes.md) |
| Agent images, the pull app, the server image | [docs/images.md](docs/images.md) |
| Secrets, deployment checks, migrating from `services.scion.hosted`, updating Scion, CI | [docs/operations.md](docs/operations.md) |
| Every option, output, and systemd unit | [docs/reference.md](docs/reference.md) |
| Contributors and coding agents | [AGENTS.md](AGENTS.md) |
| Complete configurations | [examples/single-node.nix](examples/single-node.nix), [examples/ha-hub.nix](examples/ha-hub.nix) |

## Status

The module tests evaluate every mode, and CI builds the packages on all four platforms. The server image's Hub has been started and serves its dashboard. The following have not yet been verified on live hosts:

- HA hosted
- standalone broker registration
- the server image on Cloud Run or Kubernetes
- the macOS launchd agent

[Known gaps](docs/operations.md#known-gaps) has the details.


## License

The Nix packaging, modules, workflows, and documentation in this repository are licensed under the [MIT License](LICENSE). Scion itself, and the images and binaries built from it, are licensed under [Apache-2.0](https://github.com/GoogleCloudPlatform/scion/blob/main/LICENSE).
