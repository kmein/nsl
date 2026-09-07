# A VM that installs several distributions from the real image server, checks
# them, prints a report and powers off: nix run .#smoke-vm
#
# nix flake check cannot do this, because a Nix build has no network. Run this
# after changing the bootstrap, or when the releases in nix/registry.nix look
# stale.
{ config, pkgs, ... }:

{
  system.stateVersion = config.system.nixos.release;
  networking.hostName = "nsl-smoke";
  time.timeZone = "Europe/Berlin";

  users.users.demo = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;

  nsl = {
    enable = true;
    defaultUser = "demo";
    machines = {
      debian = {
        distro = "debian";
        packages = [ "hello" ];
      };
      ubuntu.distro = "ubuntu";
      arch.distro = "archlinux";
      fedora.distro = "fedora";
      rocky.distro = "rockylinux";
    };
  };

  systemd.services.nsl-smoke = {
    description = "Check every declared machine against the real image server";
    wantedBy = [ "multi-user.target" ];
    after = [
      "multi-user.target"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    path = [
      config.nsl.package
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "infinity";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = ''
      set +e
      pass=0
      fail=0
      check() {
        label=$1
        shift
        if out=$("$@" 2>&1); then
          pass=$((pass + 1))
          echo "  ok    $label $(echo "$out" | head -1)"
        else
          fail=$((fail + 1))
          echo "  FAIL  $label: $(echo "$out" | head -2 | tr '\n' ' ')"
        fi
      }

      runuser -u demo -- touch /home/demo/from-the-host

      for m in ${toString (builtins.attrNames config.nsl.machines)}; do
        echo "=== $m"
        started=$(date +%s)
        if ! check "install and start ($m)" nsl start "$m"; then continue; fi
        echo "  took $(( $(date +%s) - started ))s"
        check "the distribution it claims" nsl run "$m" -- sh -c '. /etc/os-release; echo "$PRETTY_NAME"'
        check "runs as the host user" nsl run "$m" -- id -un
        check "passwordless sudo" nsl run "$m" -- sudo -n true
        check "sees the host home" nsl run "$m" -- test -e /home/demo/from-the-host
        check "writes to the host home" nsl run "$m" -- sh -c "touch /home/demo/written-by-$m"
        check "knows the time zone" nsl run "$m" -- sh -c 'test -e /etc/localtime && date +%Z'
        check "resolves names" nsl run "$m" -- getent hosts deb.debian.org
        check "has its own hostname" nsl run "$m" -- hostname
        check "journal reaches the host" journalctl -M "$m" -n 1 -q
        check "unprivileged shell" runuser -u demo -- nsl shell "$m" /bin/sh -c "touch /home/demo/entered-$m"
        check "stops" nsl stop "$m"
      done

      echo "=== reinstall"
      first=${builtins.head (builtins.attrNames config.nsl.machines)}
      check "reset" nsl reset --yes "$first"
      check "installs again" nsl start "$first"
      check "stops again" nsl stop "$first"

      echo
      nsl list
      echo
      echo "shared home now holds: $(ls /home/demo | tr '\n' ' ')"
      echo
      echo "===== $pass checks passed, $fail failed ====="
      systemctl poweroff
    '';
  };

  virtualisation = {
    diskSize = 30720;
    memorySize = 4096;
    cores = 4;
    graphics = false;
  };
}
