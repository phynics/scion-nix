# Scion built from the pinned source in sources.json: the npm web client first,
# then the Go binary with those assets embedded. scripts/update.py recomputes
# vendorHash and npmDepsHash through passthru.web.npmDeps and goModules.
{ lib, buildGoModule, buildNpmPackage, fetchFromGitHub, nodejs, sources }:

let
  inherit (sources) version rev;
  src = fetchFromGitHub {
    owner = "GoogleCloudPlatform";
    repo = "scion";
    inherit rev;
    inherit (sources) hash;
  };
  web = buildNpmPackage {
    pname = "scion-web";
    inherit version;
    src = src + "/web";
    nodejs = nodejs;
    inherit (sources) npmDepsHash;
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
  inherit (sources) vendorHash;
  postPatch = ''
    # The pinned handler checks a resource name that has no registered read grant.
    substituteInPlace pkg/hub/handlers_runtime_brokers.go \
      --replace-fail 'Resource{Type: "runtime_broker", ID: id}, ActionRead' 'Resource{Type: "broker", ID: id}, ActionRead' \
      --replace-fail 'Resource{Type: "runtime_broker", ID: brokerID}, ActionRead' 'Resource{Type: "broker", ID: brokerID}, ActionRead'

    # Defaults are merged as maps. Remove these before embedding so a site can
    # really opt out of Kubernetes and the remote profile.
    substituteInPlace pkg/config/embeds/default_settings.yaml \
      --replace-fail $'  kubernetes:\n    type: kubernetes\n    context: ""\n    namespace: ""\n' "" \
      --replace-fail $'  remote:\n    runtime: kubernetes\n' ""
  '';
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
  passthru = { inherit web src; };
  meta = {
    description = "Scion CLI, Hub, Broker and embedded web dashboard";
    homepage = "https://github.com/GoogleCloudPlatform/scion";
    license = lib.licenses.asl20;
    mainProgram = "scion";
    platforms = lib.platforms.unix;
  };
}
