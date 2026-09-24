# Reference

## Flake outputs

| Output | Systems | Description |
|---|---|---|
| `packages.<system>.google-scion` (also `default`) | all four | Prebuilt `scion` from the `binaryRelease` GitHub release, fetched by a fixed SHA-256. No Go or Node build. |
| `packages.<system>.google-scion-source` | all four | Source build of the pinned revision, with the web UI embedded and the Hub fixes applied. |
| `packages.<system>.scion-server-image` | Linux | Server OCI image, as a `docker-archive` tarball. See [images.md](images.md#server-image). |
| `packages.<system>.image-puller` | all four | The `scion-pull-images` script. `passthru.harnessNames` lists the harnesses it can pull. |
| `apps.<system>.pull-images` | all four | Runs the image puller. |
| `nixosModules.default` | — | NixOS module: every mode. |
| `darwinModules.default` | — | nix-darwin module: Local and Workstation. |
| `checks.<system>.*` | all four | Package builds, image-puller behavior, module evaluation tests, and the server image on Linux. |

### Hub fixes in `google-scion-source`

[nix/package.nix](../nix/package.nix) applies two fixes to the pinned source:

- The broker detail handlers check a `broker` read permission. Upstream's pinned code checks a `runtime_broker` resource, and no read grant is registered for that name.
- The embedded default settings drop the `kubernetes` runtime and `remote` profile. Defaults are merged as maps, so otherwise a site could not opt out of them.

## NixOS options

### `programs.google-scion`

This sets up Local mode, and the settings here are shared by every service.

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Install `scion` and Git, export `SCION_IMAGE_REGISTRY`, and enable the container runtime. |
| `package` | package | `google-scion` | Binary for the CLI, the workstation, and the standalone broker. |
| `runtime` | `"podman"` or `"docker"` | `"podman"` | Default agent runtime; enabled with `mkDefault` when the CLI or an agent-running service is on. |
| `imageRegistry` | str | `"ghcr.io/phynics"` | `SCION_IMAGE_REGISTRY` for the CLI and every service. Pulled images are tagged under it. |

### Options shared by services

These are available on `services.scion.workstation`, `services.scion.hub`, and `services.scion.broker`:

| Option | Type | Default | Description |
|---|---|---|---|
| `user` | str | required | Existing account that runs the service. |
| `environmentFile` | null or str | `null` | Runtime `KEY=value` file for systemd `EnvironmentFile`. |

These are available on components that run agents: `workstation`, `hub.broker`, and `broker`:

| Option | Type | Default | Description |
|---|---|---|---|
| `runtime` | `"podman"` or `"docker"` | `programs.google-scion.runtime` | Agent runtime. |
| `pullImages` | bool | `true` | Pull harness images in a `scion-<component>-images` unit before starting. |
| `harnesses` | list of harness names | every harness | Which images to pull. Valid names come from `image-manifest.json`. |
| `containersStorageConf` | null or str | `null` | `CONTAINERS_STORAGE_CONF` for accounts with a non-default Podman graphroot. |

### `services.scion.workstation`

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Run the combo server (`scion server start --foreground`, with workstation defaults). |
| `listenAddress` | str | `"127.0.0.1"` | Bind address. |
| `port` | port | `8080` | Web and Hub API port. |

This service cannot be enabled together with `services.scion.hub` or `services.scion.broker`.

### `services.scion.hub`

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Run `scion server start --hosted --enable-hub`. |
| `availability` | `"single-node"` or `"ha"` | `"single-node"` | Sets `SCION_SERVER_DATABASE_DRIVER` to `sqlite` or `postgres`, and turns on the HA assertions. |
| `package` | package | `google-scion-source` | Hub binary; the default includes the Hub fixes. |
| `listenAddress` | str | `"127.0.0.1"` | `--host`. |
| `port` | port | `8080` | `--web-port`, or `--port` when `enableWeb = false`. |
| `enableWeb` | bool | `true` | `--enable-web`; the Hub API shares the web port. |
| `publicURL` | null or str | `null` | `SCION_SERVER_BASE_URL`; the base for OAuth and OIDC callbacks. |
| `adminEmails` | list of str | `[ ]` | One `--admin-emails` flag per entry. |
| `settingsFile` | null or str | `null` | Runtime `settings.yaml`, symlinked into `~/.scion/settings.yaml` by `ExecStartPre`. |
| `stateDirectory` | str | `"scion-hub"` | systemd `StateDirectory` name (mode `0700`). |
| `databasePath` | null or str | `null` | SQLite path (single-node only). The default is `/var/lib/<stateDirectory>/hub.db`. |
| `hubId` | null or str | `null` | `SCION_SERVER_HUB_HUBID`; required for HA. |
| `storageBucket` | null or str | `null` | `--storage-bucket` (GCS); required for HA. Without it, the Hub uses `--storage-dir /var/lib/<stateDirectory>/storage`. |
| `workingDirectory` | null or str | `null` | The default is the account's home (`~`). |
| `requiredMountsFor` | list of str | `[ ]` | `RequiresMountsFor=` on the Hub and image units. |
| `broker.enable` | bool | `false` | Embedded Runtime Broker (`--enable-runtime-broker`); single-node only. |
| `broker.port` | port | `9800` | `--runtime-broker-port`. |
| `broker.autoProvide` | bool | `true` | `--auto-provide`. |
| `broker.runtime`, `broker.pullImages`, `broker.harnesses`, `broker.containersStorageConf` | | | See the agent options above. |

HA assertions: `hubId`, `storageBucket`, and `environmentFile` must be set; `databasePath` must be unset; `broker.enable` must be off.

### `services.scion.broker`

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Run `scion server start --hosted --enable-runtime-broker`. |
| `port` | port | `9800` | Broker API port, bound to loopback. |

This service cannot be enabled together with `services.scion.hub.broker` on the same host.

### Removed options

- `services.scion.hosted.*` fails evaluation. See [the migration table](operations.md#migrating-from-servicesscionhosted).

## nix-darwin options

| Option | Type | Default | Description |
|---|---|---|---|
| `programs.google-scion.enable` | bool | `false` | Install `scion`, Git, and Podman; export `SCION_IMAGE_REGISTRY`. |
| `programs.google-scion.package` | package | `google-scion` | |
| `programs.google-scion.runtime` | `"podman"` | `"podman"` | Podman is the only supported runtime on macOS. |
| `programs.google-scion.imageRegistry` | str | `"ghcr.io/phynics"` | |
| `services.scion.workstation.enable` | bool | `false` | launchd user agent that runs the combo server. |
| `services.scion.workstation.user` | str | required | Must equal `system.primaryUser`. |
| `services.scion.workstation.listenAddress` | str | `"127.0.0.1"` | |
| `services.scion.workstation.port` | port | `8080` | |
| `services.scion.workstation.environmentFile` | null or str | `null` | Sourced by the launch script (`set -a`). |

## systemd units

| Unit | Created by | Runs as |
|---|---|---|
| `scion-workstation.service` | `services.scion.workstation` | `user` |
| `scion-hub.service` | `services.scion.hub` | `user` |
| `scion-broker.service` | `services.scion.broker` | `user` |
| `scion-<component>-images.service` | components that run agents, when `pullImages` is on | `user` (oneshot, `RemainAfterExit`) |

Units that use Podman set:

- `Delegate=yes`
- `PODMAN_SYSTEMD_UNIT=%n`
- ordering after `linger-users.service`

Units that use Docker are ordered after `docker.service`.

## Files in this repository

| File | Purpose |
|---|---|
| [upstream.json](../upstream.json) | Pinned Scion `version`, `rev`, harness `imageTag`, and native `binaryRelease`. |
| [image-manifest.json](../image-manifest.json) | Per-platform image digests, produced by the images workflow. |
| [patches/](../patches) | Patches the images workflow applies to upstream before it builds the images. |
| [examples/](../examples) | Single-node and HA NixOS configurations; evaluated by the tests. |
