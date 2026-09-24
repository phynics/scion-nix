{ pkgs, version, binaryRelease }:

let
  platform = {
    x86_64-linux = { os = "linux"; arch = "amd64"; sha256 = "f9bcecff7d36cee0ff9a003a2d7354426a9d65c44d00993445cea6436ae051da"; };
    aarch64-linux = { os = "linux"; arch = "arm64"; sha256 = "2a247aad54acebf394f302b68f6f36fc7e0a8f88b278032fdce7de0f67ebe548"; };
    x86_64-darwin = { os = "darwin"; arch = "amd64"; sha256 = "7a5db8740cb902c3e60b268bd05343fc4c1eae03c233dafd0cc138174ae3e26a"; };
    aarch64-darwin = { os = "darwin"; arch = "arm64"; sha256 = "022f2665f8e220ea24046b53d60e86783078e6c732c190923e4312def4ef89cc"; };
  }.${pkgs.stdenv.hostPlatform.system};
in
pkgs.stdenv.mkDerivation {
  pname = "google-scion";
  inherit version;
  src = pkgs.fetchurl {
    url = "https://github.com/phynics/scion-nix/releases/download/${binaryRelease}/scion-${platform.os}-${platform.arch}.tar.gz";
    inherit (platform) sha256;
  };
  nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
  buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.stdenv.cc.cc.lib ];
  unpackPhase = ''
    tar -xzf "$src"
  '';
  installPhase = ''
    install -Dm755 scion "$out/bin/scion"
  '';
  meta = {
    description = "Prebuilt Scion CLI, Hub, Broker and web dashboard";
    homepage = "https://github.com/GoogleCloudPlatform/scion";
    license = pkgs.lib.licenses.asl20;
    mainProgram = "scion";
    platforms = pkgs.lib.platforms.unix;
  };
}
