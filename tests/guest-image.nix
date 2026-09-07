# A NixOS root filesystem tarball, plus an image server tree laid out the way
# images.linuxcontainers.org lays one out, so the test can bootstrap a machine
# without touching the network.
{
  pkgs,
  lib,
  nixosPath ? "${pkgs.path}/nixos",
}:

let
  guestSystem =
    (import "${nixosPath}/lib/eval-config.nix" {
      system = null;
      modules = [
        "${nixosPath}/modules/virtualisation/lxc-container.nix"
        "${nixosPath}/modules/profiles/minimal.nix"
        (
          { config, ... }:
          {
            nixpkgs.pkgs = pkgs;
            system.stateVersion = config.system.nixos.release;

            # The machine shares the host's network namespace, so it must not
            # run a DHCP client of its own on the host's interfaces.
            networking.useDHCP = false;
            networking.useHostResolvConf = false;

            users.users.alice = {
              isNormalUser = true;
              uid = 1000;
              group = "users";
              extraGroups = [ "wheel" ];
            };
            security.sudo.wheelNeedsPassword = false;
          }
        )
      ];
    }).config;

  tarball = guestSystem.system.build.tarball;

  # distro;release;arch;variant;date;path, the same shape as the real index.
  buildPath = "/images/nixos/unstable/${arch}/default/20260101_00:00/";
  arch =
    {
      x86_64-linux = "amd64";
      aarch64-linux = "arm64";
    }
    .${pkgs.stdenv.hostPlatform.system};
in
rec {
  inherit tarball arch buildPath;

  rootfs = "${tree}${buildPath}rootfs.tar.xz";

  tree = pkgs.runCommand "nsl-test-image-server" { } ''
    mkdir -p $out/meta/1.0 $out${buildPath}
    cp ${tarball}/tarball/*.tar.xz $out${buildPath}rootfs.tar.xz
    ( cd $out${buildPath} && sha256sum rootfs.tar.xz > SHA256SUMS )
    echo 'nixos;unstable;${arch};default;20260101_00:00;${buildPath}' > $out/meta/1.0/index-system
  '';
}
