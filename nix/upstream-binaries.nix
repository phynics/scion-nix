# Upstream's own release tarballs: statically linked, web dashboard embedded,
# published for all four platforms by Scion's build-release workflow. Hashes
# live in sources.json and are refreshed by scripts/update.py.
{ pkgs, sources }:

let
  system = pkgs.stdenv.hostPlatform.system;
  asset = {
    x86_64-linux = "scion-linux-amd64";
    aarch64-linux = "scion-linux-arm64";
    x86_64-darwin = "scion-darwin-amd64";
    aarch64-darwin = "scion-darwin-arm64";
  }.${system};
in
pkgs.stdenv.mkDerivation {
  pname = "google-scion";
  inherit (sources) version;
  src = pkgs.fetchurl {
    url = "https://github.com/GoogleCloudPlatform/scion/releases/download/${sources.version}/${asset}.tar.gz";
    hash = sources.binaries.${system};
  };
  sourceRoot = ".";
  # Static today; patch the interpreter should a future release link dynamically.
  nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 scion "$out/bin/scion"
    runHook postInstall
  '';
  meta = {
    description = "Scion CLI, Hub, Broker and web dashboard (upstream release binary)";
    homepage = "https://github.com/GoogleCloudPlatform/scion";
    license = pkgs.lib.licenses.asl20;
    mainProgram = "scion";
    platforms = builtins.attrNames sources.binaries;
    sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
  };
}
