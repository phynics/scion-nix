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

## Updating Scion

New Scion versions arrive as pull requests, the way the nixpkgs update bot works. Every value tied to the Scion version lives in one file, [sources.json](../sources.json), and a script rewrites it.

### How an update happens

1. **Detection.** [update.yml](../.github/workflows/update.yml) runs every day (and on demand). [scripts/update.py](../scripts/update.py) lists upstream's tags and picks the newest release on the channel set in `sources.json`:

   | Channel | Follows |
   |---|---|
   | `preview` | `vX.Y.Z-preview.N`, `vX.Y.Z-rc.N`, and `vX.Y.Z` |
   | `stable` | `vX.Y.Z` only |

   Three rules apply:
   - Nightly tags are ignored.
   - The pin never moves to an older version.
   - A release is only taken once upstream has published its binaries for all four platforms. Until then, the run waits and retries the next day.
2. **Pinning.** The script resolves the tag to a commit and rewrites `sources.json`:
   - It prefetches the source (`hash`) and the four release tarballs (`binaries`).
   - It recomputes `npmDepsHash` and `vendorHash` by building each dependency derivation with a fake hash and reading the real one from the error.
   - The workflow then builds `google-scion-source` and `google-scion`. This catches Hub fixes in `nix/package.nix` that no longer apply.
3. **Images.** The workflow calls [images.yml](../.github/workflows/images.yml) for the new commit. It builds and pushes the harness images as `:scion-<version>` (never `:latest`) and produces `image-manifest.json`. Build patches that upstream has since adopted are skipped.
4. **Pull request.** The workflow runs `nix flake check` with the new files, then opens `Update Scion to <version>` from the branch `update/scion-<version>`. While that branch exists, later runs do not rebuild the same release.
5. **Publishing.** After you merge, [publish.yml](../.github/workflows/publish.yml) does three things:
   - moves the harness images' `:latest` tags to the pinned images;
   - publishes the `scion-server` image;
   - tags this repository `<version>-nix.<N>`, with a GitHub release.

### One-time repository setup

- **Settings → Actions → General:** allow GitHub Actions to create and approve pull requests.
- **Optional:** a secret named `UPDATE_TOKEN`, holding a fine-grained token with *Contents* and *Pull requests* write access to this repository. Pull requests opened with the default `GITHUB_TOKEN` do not start other workflows, so without this token CI does not run on update PRs. The update workflow's own `nix flake check` still gates them.
- **Optional:** a repository variable `AUTO_MERGE=true` turns on auto-merge (squash) for update PRs. For it to wait for CI, enable auto-merge in the repository settings and mark `nix.yml`'s jobs as required checks.

### Updating by hand

Run the workflow manually. Leave *version* empty to take the newest release on the channel, or give an exact tag. You can also pick a different channel for that run.

The script also works locally. It needs `git` and `nix`:

```sh
scripts/update.py --check                    # what would change; writes nothing
scripts/update.py                            # rewrite sources.json for the newest release
scripts/update.py --version v0.3.0-preview.4
scripts/update.py --channel stable           # also switches the channel stored in sources.json
```

A local run does not build images. `image-manifest.json` has to come from the images workflow, whose `image-manifest` artifact you commit alongside `sources.json`. Until both describe the same commit, the flake refuses to evaluate the image puller and the modules. The packages still evaluate, so the script can keep working.

### When an update fails

| Symptom | Cause and fix |
|---|---|
| `could not determine the hash of …` | A dependency build failed for another reason; its log is printed above the message. `sources.json` is left holding placeholder hashes. |
| The `substituteInPlace` / `--replace-fail` step fails | Upstream changed or fixed code that a Hub fix in `nix/package.nix` patches. Drop the fix if upstream now includes it; otherwise update it. |
| A patch in `patches/` fails in the images job | Upstream changed that Dockerfile. Update or remove the patch. |
| A harness image fails to build | Rerun **Build Scion images** for that single step. Then run it with `target: verify` to regenerate the manifest, and push the result to the update branch. |

### Pinning and rolling back

Users choose how closely to follow new versions:
- `github:phynics/scion-nix` follows `main`.
- `github:phynics/scion-nix/v0.3.0-preview.3-nix.1` pins one release.

To roll back, pin an older tag. Its image digests and binary hashes remain valid, because images are never overwritten and binaries are fetched from upstream's immutable release assets.

## CI workflows

| Workflow | Trigger | What it does |
|---|---|---|
| [nix.yml](../.github/workflows/nix.yml) | PRs, pushes to `main` | Runs `nix flake check`: module tests, image-puller tests, and update-script tests, plus the server image on Linux. Also builds both packages on all four platforms. |
| [update.yml](../.github/workflows/update.yml) | Daily, manual | Detects a new upstream release, rewrites `sources.json`, builds the images, and opens an update PR. |
| [images.yml](../.github/workflows/images.yml) | Manual, called by `update.yml` | Builds and pushes the upstream harness images for both architectures, then emits `image-manifest.json`. |
| [publish.yml](../.github/workflows/publish.yml) | Push to `main` that changes the pin, manual | Moves the `:latest` image tags, publishes the server image, and tags `<version>-nix.<N>`. |
| [server-image.yml](../.github/workflows/server-image.yml) | Manual, called by `publish.yml` | Builds and pushes the multi-arch Nix server image. |
| [publish-cache.yml](../.github/workflows/publish-cache.yml) | Manual | Pushes build outputs to Cachix. Needs the `CACHIX_NAME` variable and the `CACHIX_AUTH_TOKEN` secret. |

## Known gaps

The following have passed evaluation tests only; none has been verified on a live host:

- the HA tier against real Postgres and GCS
- the standalone broker registration flow
- the server image on Cloud Run or Kubernetes
- the macOS launchd agent

The Hub, running with the server image's command, has been started and checked. It serves `/healthz`, `/readyz`, and its embedded assets.

The update workflows have been linted, and their scripts were tested locally. Their first real run happens on GitHub.

`google-scion` is upstream's release binary, so it lacks the Hub fixes in `nix/package.nix`. That is why `services.scion.hub.package` defaults to the source build. Upstream v0.3.0-preview.3's binary reports its version as `v0.3.0-preview.1`, but it was built from the tagged commit.
