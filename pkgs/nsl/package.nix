{
  lib,
  stdenvNoCC,
  writeShellApplication,
  runCommand,
  systemd,
  curl,
  jq,
  gawk,
  coreutils,
  shadow,
  gnused,
  e2fsprogs,
}:

let
  guest = runCommand "nsl-guest-scripts" { } ''
    mkdir -p $out
    cp -r ${./guest}/* $out/
    chmod -R a+rX $out
  '';

  runtime = [
    systemd
    curl
    jq
    gawk
    coreutils
    shadow
    gnused
    e2fsprogs # chattr, to clear immutable files before deleting a machine
  ];

  nsl = writeShellApplication {
    name = "nsl";
    runtimeInputs = runtime;
    text = builtins.readFile ./nsl.sh;
    meta.mainProgram = "nsl";
  };

  bootstrap = writeShellApplication {
    name = "nsl-bootstrap";
    runtimeInputs = runtime;
    runtimeEnv.NSL_GUEST_DIR = guest;
    text = builtins.readFile ./bootstrap.sh;
  };
in
stdenvNoCC.mkDerivation {
  pname = "nsl";
  version = "0.1.0";

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share
    ln -s ${nsl}/bin/nsl $out/bin/nsl
    ln -s ${bootstrap}/bin/nsl-bootstrap $out/bin/nsl-bootstrap
    ln -s ${guest} $out/share/nsl
    runHook postInstall
  '';

  passthru = { inherit guest; };

  meta = {
    description = "Run foreign Linux distributions on NixOS in systemd-nspawn machines";
    mainProgram = "nsl";
    platforms = lib.platforms.linux;
  };
}
