# A throwaway NixOS VM with several NSL machines declared, for trying the real
# image server: nix run .#demo-vm, then log in as demo (password "demo") and
# run `nsl shell debian`.
{ config, pkgs, ... }:

{
  system.stateVersion = config.system.nixos.release;
  networking.hostName = "nsl-demo";

  users.users.demo = {
    isNormalUser = true;
    uid = 1000;
    password = "demo";
    extraGroups = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;
  services.getty.autologinUser = "demo";

  nsl = {
    enable = true;
    defaultUser = "demo";
    machines = {
      debian.distro = "debian";
      ubuntu.distro = "ubuntu";
      arch.distro = "archlinux";
      fedora.distro = "fedora";
      rocky.distro = "rockylinux";
    };
  };

  virtualisation = {
    diskSize = 20480;
    memorySize = 4096;
    cores = 4;
    graphics = false;
  };
}
