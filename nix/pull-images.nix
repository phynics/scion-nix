{ pkgs, manifest, sourceRegistry ? "ghcr.io/phynics" }:

# scion-pull-images RUNTIME [TARGET_REGISTRY] [HARNESS...]
#
# Pulls the agent harness images for this host's Linux architecture by their
# immutable digest, then tags each one as TARGET_REGISTRY/scion-<harness>:latest,
# which is the name Scion derives from its image_registry setting. With no
# HARNESS arguments every harness in image-manifest.json is pulled.

let
  inherit (pkgs) lib;
  arch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  # Build layers and server images are not agent harnesses.
  nonHarness = [ "core-base" "scion-base" "scion-hub" ];
  images = builtins.filter
    (image: image.platform == "linux/${arch}" && !(builtins.elem image.name nonHarness))
    manifest.images;
  harnessNames = map (image: lib.removePrefix "scion-" image.name) images;
  pullCase = lib.concatMapStringsSep "\n" (image:
    let
      reference = "${sourceRegistry}/${image.name}@${image.digest}";
    in
    ''
      ${lib.removePrefix "scion-" image.name})
        "$runtime" pull ${lib.escapeShellArg reference}
        "$runtime" tag ${lib.escapeShellArg reference} "$target_registry/${image.name}:latest"
        ;;
    '') images;
in
pkgs.writeShellApplication {
  name = "scion-pull-images";
  passthru = { inherit harnessNames; };
  text = ''
    runtime="''${1:-podman}"
    target_registry="''${2:-${sourceRegistry}}"
    shift "$(( $# < 2 ? $# : 2 ))"
    case "$runtime" in
      podman|docker) ;;
      *) echo "usage: scion-pull-images podman|docker [TARGET_REGISTRY] [HARNESS...]" >&2; exit 2 ;;
    esac
    case "$target_registry" in
      *[!a-zA-Z0-9./:_-]*|"") echo "Invalid target registry: $target_registry" >&2; exit 2 ;;
    esac
    command -v "$runtime" > /dev/null || { echo "$runtime is not installed" >&2; exit 1; }
    if [ "$#" -eq 0 ]; then
      set -- ${lib.escapeShellArgs harnessNames}
    fi
    for harness in "$@"; do
      case "''${harness#scion-}" in
    ${pullCase}
        *)
          echo "Unknown harness '$harness'. Available: ${lib.concatStringsSep " " harnessNames}" >&2
          exit 2
          ;;
      esac
    done
  '';
}
