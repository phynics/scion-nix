{ pkgs, scion, tag }:

# Container image for the Scion server: the native Hub + Web process (and
# optionally a Runtime Broker) running inside a container, for the hosted
# modes on Podman, Docker, Kubernetes, or Cloud Run.
#
# Unlike upstream's scion-hub image, this uses the Nix-built binary with the
# web dashboard embedded, so --enable-web serves the UI. It carries no agent
# harnesses; agents run on a Runtime Broker that pulls the harness images.
#
# Defaults suit Single-node hosted: SQLite and templates live in the
# /home/scion/.scion volume. For HA hosted, pass the Postgres, hub ID, GCS
# bucket and session secret through SCION_SERVER_* environment variables.

let
  uid = "1000";
  accounts = pkgs.runCommand "scion-server-accounts" { } ''
    mkdir -p "$out/etc"
    cat > "$out/etc/passwd" <<'EOF'
    root:x:0:0:root:/root:/bin/sh
    scion:x:${uid}:${uid}:Scion:/home/scion:/bin/sh
    nobody:x:65534:65534:nobody:/var/empty:/bin/false
    EOF
    cat > "$out/etc/group" <<'EOF'
    root:x:0:
    scion:x:${uid}:
    nobody:x:65534:
    EOF
  '';
  root = pkgs.buildEnv {
    name = "scion-server-root";
    paths = [
      scion
      accounts
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.git
      pkgs.openssh
      pkgs.tini
      pkgs.dockerTools.caCertificates
      pkgs.dockerTools.binSh
      pkgs.dockerTools.usrBinEnv
    ];
    pathsToLink = [ "/bin" "/etc" "/share" "/usr" ];
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "scion-server";
  inherit tag;
  contents = [ root ];
  extraCommands = ''
    mkdir -p home/scion/.scion tmp workspace
    chmod 1777 tmp
  '';
  fakeRootCommands = ''
    chown -R ${uid}:${uid} home/scion workspace
  '';
  config = {
    User = "${uid}:${uid}";
    WorkingDir = "/home/scion";
    Env = [
      "HOME=/home/scion"
      "USER=scion"
      "PATH=/bin"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
    ];
    Entrypoint = [ "/bin/tini" "--" ];
    # Upstream runs its server images through `sh -c exec` because an
    # exec-form command was observed to daemonize; keep the same form.
    Cmd = [ "/bin/sh" "-c" "exec scion server start --foreground --hosted --enable-hub --enable-web --host 0.0.0.0 --web-port 8080" ];
    ExposedPorts = { "8080/tcp" = { }; "9800/tcp" = { }; };
    Volumes = { "/home/scion/.scion" = { }; };
    Labels = {
      "org.opencontainers.image.title" = "scion-server";
      "org.opencontainers.image.description" = "Scion Hub, Web dashboard and Runtime Broker (native binary with embedded web assets)";
      "org.opencontainers.image.source" = "https://github.com/phynics/scion-nix";
      "org.opencontainers.image.version" = scion.version;
      "org.opencontainers.image.licenses" = "Apache-2.0";
    };
  };
}
