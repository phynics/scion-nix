# Operations

This page covers what you do after the modules are in place: secrets, deployment checks, migration, upgrades, and release publishing.

## Secrets

Never put secret values in Nix option strings. Anything in a Nix string ends up world-readable in `/nix/store`. Every service instead reads secrets from runtime paths.

| Mechanism | Format | Use it for |
|---|---|---|
| `environmentFile` | `KEY=value` lines, loaded by systemd (by the launch script on macOS) | `SCION_SERVER_SESSION_SECRET`, `SCION_SERVER_DATABASE_URL`, provider API keys for the service |
| `services.scion.hub.settingsFile` | Scion `settings.yaml`, symlinked into `~/.scion/settings.yaml` before each start | OAuth and OIDC client configuration, including `server.oidc_login.client_secret` (the pinned revision does not read that secret from the environment) |

Both work with sops-nix without the flake depending on it:

- **Environment file.** Pass `config.sops.secrets.<name>.path` or `config.sops.templates.<name>.path`.
- **Ownership.** The rendered file must be owned by, or readable by, the service `user`.
- **Ordering.** Order the unit after `sops-nix.service`:

  ```nix
  systemd.services.scion-hub = {
    after = [ "sops-nix.service" ];
    requires = [ "sops-nix.service" ];
  };
  ```

Hosted Hubs need a stable `SCION_SERVER_SESSION_SECRET`. Without one, sessions do not survive a restart, and the HA preflight refuses to start.

Credentials that agents use (for example `ANTHROPIC_API_KEY` for a harness) belong in the Hub's secrets UI or the agent's configuration, not in the service environment.

## Deployment checklist

After a `nixos-rebuild switch`, check the pieces in this order.

1. **Units:**

   ```sh
   systemctl status scion-hub scion-hub-images   # or scion-workstation / scion-broker
   journalctl -u scion-hub -e
   ```

2. **Health:**

   ```sh
   curl -s localhost:8080/healthz; curl -s localhost:8080/readyz
   ```

3. **Container runtime, from the service account's context:**

   ```sh
   sudo -iu scion podman info
   sudo -iu scion podman images | grep scion-
   ```

   The harness tags should be under `programs.google-scion.imageRegistry`.

4. **Cgroup delegation:**

   ```sh
   systemctl show scion-hub -p Delegate -p ControlGroup
   ```

   For rootless Podman, `Delegate=yes`.

5. **End to end:** log in through the browser, start an agent, and confirm it runs and that its workspace is owned by the service account. A browser terminal session proves the PTY WebSocket path works. A direct `podman exec` does not test that path.

## Migrating from `services.scion.hosted`

`services.scion.hosted` has been removed. A configuration that still uses it fails evaluation with a message that points here.

| Old | New |
|---|---|
| `services.scion.hosted.enable` | `services.scion.hub.enable` + `services.scion.hub.broker.enable` |
| `user`, `listenAddress`, `port`, `publicURL`, `settingsFile`, `environmentFile`, `databasePath`, `workingDirectory`, `requiredMountsFor` | same names under `services.scion.hub` |
| `brokerPort` | `services.scion.hub.broker.port` |
| `pullImages`, `containersStorageConf` | `services.scion.hub.broker.*` |
| `imageRegistry` | `programs.google-scion.imageRegistry` |
| `home` | removed; systemd supplies the account's home |
| `package` | `services.scion.hub.package` |
| unit `scion-hosted` / `scion-images` | `scion-hub` / `scion-hub-images` |

The default SQLite path has moved to `/var/lib/scion-hub/hub.db`. To keep your existing data, set `databasePath` to the old file (previously `~/.scion/hub.db`, unless you had set it), or move the file into the state directory while the service is stopped.

## Upgrading Scion

The pinned Scion revision appears in several places, and they must stay in sync. The flake enforces part of this: evaluation fails if `image-manifest.json` and `upstream.json` pin different revisions.

1. **Pick an exact upstream commit.** Never follow a branch or a moving tag.
2. **Update the source pin.** Set `inputs.scion-src.url` in `flake.nix`, then run `nix flake lock --update-input scion-src`.
3. **Update `upstream.json`.** Set `version`, `rev`, `imageTag` (`scion-<version>`), and a new `binaryRelease` (e.g. `<version>-nix.1`).
4. **Refresh the build hashes.** Set `vendorHash` and `npmDepsHash` in `nix/package.nix` to `lib.fakeHash`, build `.#google-scion-source`, and copy in the hashes Nix reports. Check that the `substituteInPlace` patches still apply; the build fails if they don't.
5. **Rebuild the agent images.** Run **Build Scion images** with `target: all`. Download its `image-manifest` artifact and commit it as `image-manifest.json`. You can rebuild a failed harness on its own, then rerun with `target: verify` to regenerate the manifest.
6. **Publish the native binaries.** Merge to `main`, then run **Release native binaries**. Put each tarball's SHA-256 (from its `.sha256` asset) into `nix/published-binaries.nix`.
7. **Publish the server image.** Run **Build Scion server image**.
8. **Check the result:**

   ```sh
   nix flake check
   nix build .#google-scion && ./result/bin/scion version
   ```

To roll back, pin the previous revision of this flake. Its image digests and binary hashes still resolve.

## CI workflows

| Workflow | Trigger | What it does |
|---|---|---|
| [nix.yml](../.github/workflows/nix.yml) | PRs, pushes to `main` | `nix flake check`, which runs the module tests and the image-puller tests, and on Linux also builds the server image. Also builds both packages on all four platforms. |
| [images.yml](../.github/workflows/images.yml) | Manual | Builds and pushes the upstream harness images for both architectures, then emits `image-manifest.json` |
| [server-image.yml](../.github/workflows/server-image.yml) | Manual | Builds and pushes the multi-arch Nix server image |
| [release.yml](../.github/workflows/release.yml) | Manual, on `main` | Builds the four native tarballs and creates the `binaryRelease` GitHub release |
| [publish-cache.yml](../.github/workflows/publish-cache.yml) | Manual | Pushes build outputs to Cachix; needs the `CACHIX_NAME` variable and the `CACHIX_AUTH_TOKEN` secret |

## Known gaps

The following have passed evaluation tests only; none has been verified on a live host:

- the HA tier against real Postgres and GCS
- the standalone broker registration flow
- the server image on Cloud Run or Kubernetes
- the macOS launchd agent

The Hub, running with the server image's command, has been started and checked. It serves `/healthz`, `/readyz`, and its embedded assets.

The prebuilt `google-scion` release (`v0.3.0-preview.3-nix.1`) predates the Hub fixes in `nix/package.nix`. That is why `services.scion.hub.package` defaults to the source build. Cut a new `binaryRelease` so that the prebuilt binary carries those fixes too.
