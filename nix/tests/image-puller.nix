{ pkgs, manifest }:

let
  arch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  platform = "linux/${arch}";
  digestOf = name: (builtins.head (builtins.filter
    (image: image.name == name && image.platform == platform)
    manifest.images)).digest;
  claude = digestOf "scion-claude";
  opencode = digestOf "scion-opencode";
  runtime = pkgs.writeShellScriptBin "podman" ''
    printf '%s\n' "$*"
  '';
  puller = import ../pull-images.nix { inherit pkgs manifest; };
  harnessCount = builtins.length puller.harnessNames;
in
pkgs.runCommand "scion-image-puller-${arch}-check" {
  nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
} ''
  export PATH="${runtime}/bin:$PATH"

  # Every harness, retagged for a local registry prefix.
  output=$(${puller}/bin/scion-pull-images podman localhost/scion)
  test "$(printf '%s\n' "$output" | wc -l)" -eq ${toString (2 * harnessCount)}
  printf '%s\n' "$output" | grep -Fx "pull ghcr.io/phynics/scion-claude@${claude}" > /dev/null
  printf '%s\n' "$output" | grep -Fx "tag ghcr.io/phynics/scion-claude@${claude} localhost/scion/scion-claude:latest" > /dev/null
  if printf '%s\n' "$output" | grep -E 'scion-(base|hub)@|core-base@'; then
    echo "The image pull app must not pull base or server images" >&2
    exit 1
  fi

  # A selected subset, with and without the scion- prefix.
  output=$(${puller}/bin/scion-pull-images podman ghcr.io/phynics opencode scion-claude)
  test "$(printf '%s\n' "$output" | wc -l)" -eq 4
  printf '%s\n' "$output" | grep -Fx "tag ghcr.io/phynics/scion-opencode@${opencode} ghcr.io/phynics/scion-opencode:latest" > /dev/null

  # Unknown harnesses and runtimes are rejected.
  if ${puller}/bin/scion-pull-images podman ghcr.io/phynics not-a-harness 2> /dev/null; then exit 1; fi
  if ${puller}/bin/scion-pull-images nerdctl 2> /dev/null; then exit 1; fi
  touch "$out"
''
