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
    in
    ''
      "$runtime" pull ${lib.escapeShellArg reference}
      "$runtime" tag ${lib.escapeShellArg reference} "$target_registry/${image.name}:latest"
    '') images;
in
pkgs.writeShellApplication {
  name = "scion-pull-images";
  text = ''
    runtime="''${1:-podman}"
    target_registry="''${2:-ghcr.io/phynics}"
    case "$runtime" in
      podman|docker) ;;
      *) echo "Use podman or docker" >&2; exit 2 ;;
    esac
    case "$target_registry" in
      *[!a-zA-Z0-9./:_-]*|"") echo "Invalid target registry" >&2; exit 2 ;;
    esac
    command -v "$runtime" > /dev/null || { echo "$runtime is not installed" >&2; exit 1; }
    ${pullCommands}
  '';
}
