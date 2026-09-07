{
  pkgs,
  lib,
  testers,
  nslModule,
}:

let
  images = import ./guest-image.nix { inherit pkgs lib; };
in
testers.runNixOSTest {
  name = "nsl";

  nodes = {
    # Stands in for images.linuxcontainers.org.
    server = {
      networking.firewall.allowedTCPPorts = [ 80 ];
      services.nginx = {
        enable = true;
        virtualHosts."server".root = images.tree;
      };
      virtualisation.additionalPaths = [ images.tree ];
    };

    machine = {
      imports = [ nslModule ];

      nsl = {
        enable = true;
        imageServer = "http://server";
        defaultUser = "alice";
        machines = {
          # Downloaded through the index, started at boot.
          dl = {
            distro = "nixos";
            autoStart = true;
          };
          # Pinned tarball, own user namespace, started on demand.
          local = {
            distro = "nixos";
            image = images.rootfs;
            privateUsers = true;
          };
        };
      };

      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
      };

      nix.settings.substituters = lib.mkForce [ ];
      virtualisation = {
        diskSize = 16384;
        memorySize = 3072;
        cores = 2;
        additionalPaths = [ images.rootfs ];
      };
    };
  };

  testScript = ''
    start_all()
    server.wait_for_unit("nginx.service")
    machine.wait_for_unit("multi-user.target")

    with subtest("a declared machine is downloaded and booted at boot"):
        machine.wait_for_unit("nsl-bootstrap-dl.service")
        machine.wait_until_succeeds("test -e /var/lib/nsl/dl/bootstrapped", timeout=600)
        machine.wait_until_succeeds("systemctl -M dl is-active default.target", timeout=300)

    with subtest("the machine sees the host user's home directory"):
        machine.succeed("touch /home/alice/from-the-host")
        machine.succeed(
            "systemd-run -M dl -P --wait -q --uid=alice"
            " /run/current-system/sw/bin/test -e /home/alice/from-the-host"
        )

    with subtest("nsl list reports both machines"):
        out = machine.succeed("nsl list")
        assert "dl" in out and "local" in out, out
        assert "running" in out, out

    with subtest("the mirrored user can enter and control the machine unprivileged"):
        machine.succeed("su - alice -c 'nsl shell dl /run/current-system/sw/bin/true'")
        assert "1000" in machine.succeed(
            "su - alice -c 'nsl run dl -- /run/current-system/sw/bin/id -u'"
        )
        # nsl run passes the command's exit code back to the caller.
        machine.fail("su - alice -c 'nsl run dl -- /run/current-system/sw/bin/false'")
        machine.succeed("su - alice -c 'nsl stop dl'")
        machine.wait_until_succeeds("test $(systemctl is-active systemd-nspawn@dl) = inactive")
        machine.succeed("su - alice -c 'nsl start dl'")
        machine.wait_until_succeeds("systemctl -M dl is-active default.target", timeout=300)

    with subtest("the machine's journal is readable from the host"):
        machine.succeed("journalctl -M dl -n 1")

    with subtest("a pinned image starts on demand, in its own user namespace"):
        machine.succeed("nsl start local")
        machine.wait_until_succeeds("systemctl -M local is-active default.target", timeout=300)
        machine.succeed("test $(machinectl status local | grep -c 'ID Shift: ') = 1")
        machine.succeed(
            "systemd-run -M local -P --wait -q --uid=alice"
            " /run/current-system/sw/bin/test -e /home/alice/from-the-host"
        )

    with subtest("reset discards a machine so it is installed again"):
        machine.succeed("nsl reset --yes local")
        machine.fail("test -e /var/lib/machines/local")
        machine.fail("test -e /var/lib/nsl/local/bootstrapped")
        machine.succeed("nsl start local")
        machine.wait_until_succeeds("systemctl -M local is-active default.target", timeout=300)

    with subtest("machines come back after a reboot"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.wait_until_succeeds("systemctl -M dl is-active default.target", timeout=300)
        # Bootstrapping does not happen twice.
        machine.succeed("test $(systemctl is-active nsl-bootstrap-dl.service) != active")
  '';
}
