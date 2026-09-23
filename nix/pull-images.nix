{ pkgs, manifest }:

let
  inherit (pkgs) lib;
  arch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  images = builtins.filter
    (image:
      image.platform == "linux/${arch}"
      && lib.hasPrefix "scion-" image.name
      && image.name != "scion-base"
      && image.name != "scion-hub")
    manifest.images;
  pullCommands = lib.concatMapStringsSep "\n" (image:
    let
      reference = "ghcr.io/phynics/${image.name}@${image.digest}";
      tag = "ghcr.io/phynics/${image.name}:latest";
    in
    ''
      "$runtime" pull ${lib.escapeShellArg reference}
      "$runtime" tag ${lib.escapeShellArg reference} ${lib.escapeShellArg tag}
    '') images;
in
pkgs.writeShellApplication {
  name = "scion-pull-images";
  text = ''
    runtime="''${1:-podman}"
    case "$runtime" in
      podman|docker) ;;
      *) echo "Use podman or docker" >&2; exit 2 ;;
    esac
    command -v "$runtime" > /dev/null || { echo "$runtime is not installed" >&2; exit 1; }
    ${pullCommands}
  '';
}
