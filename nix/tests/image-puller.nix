{ pkgs, manifest }:

let
  arch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  platform = "linux/${arch}";
  claude = builtins.head (builtins.filter
    (image: image.name == "scion-claude" && image.platform == platform)
    manifest.images);
  runtime = pkgs.writeShellScriptBin "podman" ''
    printf '%s\n' "$*"
  '';
  puller = import ../pull-images.nix { inherit pkgs manifest; };
in
pkgs.runCommand "scion-image-puller-${arch}-check" {
  nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
} ''
  output=$(PATH="${runtime}/bin:$PATH" ${puller}/bin/scion-pull-images podman localhost/scion)
  test "$(printf '%s\n' "$output" | wc -l)" -eq 18
  printf '%s\n' "$output" | grep -F "pull ghcr.io/phynics/scion-claude@${claude.digest}" > /dev/null
  printf '%s\n' "$output" | grep -F "tag ghcr.io/phynics/scion-claude@${claude.digest} localhost/scion/scion-claude:latest" > /dev/null
  if printf '%s\n' "$output" | grep -E 'scion-(base|hub)@'; then
    echo "The image pull app must not pull internal base or Hub images" >&2
    exit 1
  fi
  touch "$out"
''
