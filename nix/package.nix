{ lib, buildGoModule, buildNpmPackage, go, nodejs, src, version, rev }:

let
  web = buildNpmPackage {
    pname = "scion-web";
    inherit version;
    src = src + "/web";
    nodejs = nodejs;
    npmDepsHash = "sha256-BW2mAZSK2alZMQNpUOlCosTWqAkYwycSaNAfLD8LlyQ=";
    npmBuildScript = "build";
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/dist/client"
      cp -r dist/client/. "$out/dist/client/"
      runHook postInstall
    '';
  };
in
buildGoModule {
  pname = "google-scion";
  inherit version src;
  vendorHash = "sha256-8FwhN7R4FSn/nIyxXmK8elqM1Ty72ws+pBDv0H/czXU=";
  subPackages = [ "cmd/scion" ];
  ldflags = [
    "-X github.com/GoogleCloudPlatform/scion/pkg/version.Version=${version}"
    "-X github.com/GoogleCloudPlatform/scion/pkg/version.Commit=${rev}"
    "-X github.com/GoogleCloudPlatform/scion/pkg/version.BuildTime=1970-01-01T00:00:00Z"
  ];
  preBuild = ''
    mkdir -p web/dist/client
    cp -r ${web}/dist/client/. web/dist/client/
  '';
  doCheck = false;
  meta = {
    description = "Scion CLI, Hub, Broker and embedded web dashboard";
    homepage = "https://github.com/GoogleCloudPlatform/scion";
    license = lib.licenses.asl20;
    mainProgram = "scion";
    platforms = lib.platforms.unix;
  };
}
