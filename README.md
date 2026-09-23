# scion-nix

Nix packaging and deployment modules for [Scion](https://googlecloudplatform.github.io/scion/overview/).

The flake pins upstream Scion to `v0.3.0-preview.3` and builds the Go CLI with the web dashboard embedded. [PLAN.md](PLAN.md) tracks the release criteria and the remaining live deployment tests.

Install the published native binary without compiling Scion:

```sh
nix build github:phynics/scion-nix#google-scion
./result/bin/scion version
```

`packages.google-scion` downloads a hash-checked GitHub release asset. To rebuild the same pinned source with Nix, use `nix build .#google-scion-source`. CI builds both packages on all four platforms. A public Cachix cache will also provide substitutes for the source-built package when configured.

### NixOS

Add this flake as an input, then import its module:

```nix
{
  inputs.scion-nix.url = "github:phynics/scion-nix";
}
```

```nix
{ inputs, ... }: {
  imports = [ inputs.scion-nix.nixosModules.default ];

  users.users.agents = {
    isNormalUser = true;
    home = "/home/agents";
    createHome = true;
  };

  programs.google-scion.enable = true;
  services.scion.workstation = {
    enable = true;
    user = "agents";
  };
}
```

The workstation process is a native systemd service. It uses the `agents` account's home and rootless container runtime. Initialize Scion under that account once, and set `profiles.local.runtime` to `podman` in its `~/.scion/settings.yaml` if the upstream auto-detection selects another runtime. A standalone native Hub needs no Podman and is configured with `services.scion.hub` instead. Enable `services.scion.broker` only when it will execute containerized agents. The module does not create accounts or overwrite existing Scion settings.

For secrets, set `services.scion.hub.environmentFile` or the corresponding workstation or Broker option to a runtime file path. With sops-nix, pass `config.sops.secrets.scion-hub-env.path`; the decrypted file must use `KEY=value` lines, be readable by the selected service account, and remain outside the Nix store. The Hub needs a stable `SESSION_SECRET` in a hosted deployment.

### nix-darwin

Import `inputs.scion-nix.darwinModules.default`, enable `programs.google-scion`, and set `services.scion.workstation.user` to `system.primaryUser`. Start that user's Podman machine before the launchd agent needs to run. The initial module rejects another account because a launchd user agent cannot switch users.

The [image build workflow](.github/workflows/images.yml) builds Scion's Linux OCI images from the revision in [upstream.json](upstream.json) and pushes them to `ghcr.io/phynics`. The [Nix CI workflow](.github/workflows/nix.yml) builds the four host packages. The [cache publishing workflow](.github/workflows/publish-cache.yml) needs a public Cachix cache, the `CACHIX_NAME` repository variable, and the `CACHIX_AUTH_TOKEN` repository secret before it can publish substitutes. The [native binary release workflow](.github/workflows/release.yml) attaches four platform tarballs to a GitHub release after all builds pass.

Image publication is manual until the runtime checks in the plan pass. The image workflow publishes both the version tag in `upstream.json` and a mutable `latest` compatibility tag. `imageRegistry` changes the registry prefix but does not pin an image tag. A GHCR package must be made public and tested with an anonymous pull before it is listed as a public release. The image workflow produces a digest manifest artifact for the later immutable flake image outputs.
