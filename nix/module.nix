{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nsl;
  registry = import ./registry.nix;

  archFor = {
    x86_64-linux = "amd64";
    aarch64-linux = "arm64";
    armv7l-linux = "armhf";
    riscv64-linux = "riscv64";
    loongarch64-linux = "loong64";
  };
  hostSystem = pkgs.stdenv.hostPlatform.system;
  hostArch = archFor.${hostSystem} or null;

  machineOpts =
    { name, config, ... }:
    {
      options = {
        distro = lib.mkOption {
          type = lib.types.enum (lib.attrNames registry);
          example = "debian";
          description = "Distribution to install, as named by the image server index.";
        };

        release = lib.mkOption {
          type = lib.types.str;
          default = registry.${config.distro}.release;
          defaultText = lib.literalMD "the current release of `distro`";
          example = "trixie";
          description = ''
            Release to install. Run `nsl images <distro>` to see what the image
            server currently offers; it only keeps the last few daily builds of
            each release.
          '';
        };

        variant = lib.mkOption {
          type = lib.types.str;
          default = "default";
          description = ''
            Image variant, the fourth column of the image server index. The
            `default` variant is the one NSL is built for; `cloud` images run
            cloud-init and are not useful here.
          '';
        };

        image = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression ''pkgs.fetchurl { url = "..."; hash = "..."; }'';
          description = ''
            Root filesystem tarball to import instead of downloading one. Use
            this to pin an image, or to bootstrap without network access. The
            tarball must unpack to a root filesystem containing `/etc/os-release`
            and an init at `/sbin/init`.
          '';
        };

        user = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = cfg.defaultUser;
          defaultText = lib.literalExpression "config.nsl.defaultUser";
          example = "alice";
          description = ''
            Host user to mirror inside the machine. A user with the same name,
            uid, gid and home directory is created at bootstrap and given
            passwordless sudo. Set to null for a machine with only root.
          '';
        };

        shell = lib.mkOption {
          type = lib.types.str;
          default = "/bin/bash";
          description = ''
            Login shell of the mirrored user. This is a path inside the machine,
            not on the host.
          '';
        };

        bindHome = lib.mkOption {
          type = lib.types.bool;
          default = config.user != null;
          defaultText = lib.literalMD "true when `user` is set";
          description = "Bind mount the mirrored user's home directory from the host.";
        };

        packages = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [
            "git"
            "build-essential"
          ];
          description = ''
            Packages installed once during bootstrap, named as the machine's own
            package manager names them. Adding packages later has no effect until
            the machine is rebuilt with `nsl reset`; install them from inside
            instead.
          '';
        };

        extraBootstrap = lib.mkOption {
          type = lib.types.lines;
          default = "";
          example = "locale-gen en_US.UTF-8";
          description = ''
            Shell commands run as root inside the machine at the end of
            bootstrap. Runs once, like {option}`packages`.
          '';
        };

        autoStart = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Start this machine at boot. When false the machine is started on
            demand by `nsl shell` or `nsl start`.

            Note that with this enabled the first `nixos-rebuild switch` after
            declaring the machine waits for the image download to finish.
          '';
        };

        privateNetwork = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Give the machine its own network namespace, connected to the host by
            a virtual ethernet link, instead of sharing the host's network.

            This needs {option}`systemd.network.enable` on the host and is less
            well tested than the shared default.
          '';
        };

        privateUsers = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Run the machine in its own user namespace, so its root is not the
            host's root. Bind mounts are then id-mapped, which the filesystem
            holding them must support.
          '';
        };

        bindMounts = lib.mkOption {
          default = [ ];
          example = [
            {
              hostPath = "/srv/data";
              mountPoint = "/data";
            }
          ];
          description = "Additional host directories to bind mount into the machine.";
          type = lib.types.listOf (
            lib.types.submodule (
              { config, ... }:
              {
                options = {
                  hostPath = lib.mkOption {
                    type = lib.types.str;
                    description = "Directory on the host.";
                  };
                  mountPoint = lib.mkOption {
                    type = lib.types.str;
                    default = config.hostPath;
                    defaultText = lib.literalMD "`hostPath`";
                    description = "Where it appears inside the machine.";
                  };
                  readOnly = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Mount read-only.";
                  };
                };
              }
            )
          );
        };

        nspawn = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
          default = { };
          example = {
            execConfig.Capability = "CAP_NET_ADMIN";
          };
          description = ''
            Settings merged into {option}`systemd.nspawn.<name>`, taking
            precedence over what NSL generates. See {manpage}`systemd.nspawn(5)`.
          '';
        };
      };
    };

  machines = cfg.machines;
  machineNames = lib.attrNames machines;

  homeOf = m: if m.user == null then null else config.users.users.${m.user}.home;

  # Runtime spec, read by nsl-bootstrap and by the nsl CLI.
  specOf =
    name: m:
    let
      base = {
        inherit name;
        inherit (m)
          distro
          release
          variant
          shell
          packages
          privateNetwork
          privateUsers
          bindHome
          ;
        arch = hostArch;
        image = m.image;
        imageServer = cfg.imageServer;
        user = m.user;
        home = homeOf m;
        sudoGroup = registry.${m.distro}.sudoGroup;
        adapter = registry.${m.distro}.adapter;
        extraBootstrap = pkgs.writeText "nsl-extra-${name}.sh" m.extraBootstrap;
      };
    in
    base // { specHash = builtins.hashString "sha256" (builtins.toJSON base); };

  nspawnFor =
    name: m:
    let
      idmap = lib.optionalString m.privateUsers ":idmap";
      home = homeOf m;
      homeBind = lib.optional (m.bindHome && home != null) "${home}:${home}${idmap}";
      binds = lib.filter (b: !b.readOnly) m.bindMounts;
      roBinds = lib.filter (b: b.readOnly) m.bindMounts;
      renderBind = b: "${b.hostPath}:${b.mountPoint}${idmap}";
    in
    lib.mkMerge [
      {
        execConfig = {
          Boot = true;
          # The template unit passes -U; the .nspawn file wins because it is
          # started with --settings=override.
          PrivateUsers = if m.privateUsers then "pick" else false;
          # nixpkgs patches systemd-nspawn to only recognise /etc/zoneinfo, so
          # the "auto" default leaves a dangling /etc/localtime in the machine.
          Timezone = "copy";
          ResolvConf =
            if m.privateNetwork then
              "off"
            else if config.services.resolved.enable then
              "replace-stub"
            else
              "replace-host";
          LinkJournal = "try-guest";
        };
        filesConfig = {
          PrivateUsersOwnership = if m.privateUsers then "auto" else "off";
          Bind = homeBind ++ map renderBind binds;
          BindReadOnly = map renderBind roBinds;
        };
        networkConfig = {
          VirtualEthernet = m.privateNetwork;
          Private = m.privateNetwork;
        };
      }
      m.nspawn
    ];

  anyPrivateNetwork = lib.any (m: m.privateNetwork) (lib.attrValues machines);

  polkitUsers = lib.unique (
    cfg.users ++ lib.filter (u: u != null) (map (m: m.user) (lib.attrValues machines))
  );

  validName = name: builtins.match "[a-z0-9][a-z0-9-]{0,62}" name != null;

in
{
  options.nsl = {
    enable = lib.mkEnableOption "NSL, foreign Linux distributions in systemd-nspawn machines";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/nsl/package.nix { };
      defaultText = lib.literalMD "the `nsl` package from this flake";
      description = "The nsl command line tool and bootstrap helper to use.";
    };

    imageServer = lib.mkOption {
      type = lib.types.str;
      default = "https://images.linuxcontainers.org";
      description = ''
        Image server to download root filesystems from. It must publish the
        simplestreams-style index at `/meta/1.0/index-system` and a `SHA256SUMS`
        next to each image.
      '';
    };

    defaultUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alice";
      description = "Host user mirrored into every machine that does not set its own.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Host users allowed to start, stop and enter NSL machines without
        authenticating. Users mirrored into a machine are granted this anyway.
      '';
    };

    machines = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule machineOpts);
      default = { };
      example = lib.literalExpression ''
        {
          ubuntu.distro = "ubuntu";
          arch = {
            distro = "archlinux";
            packages = [ "base-devel" ];
          };
        }
      '';
      description = "Machines to make available, each running in its own systemd-nspawn container.";
    };
  };

  config = lib.mkIf (cfg.enable && machines != { }) {
    assertions = [
      {
        assertion = hostArch != null;
        message = "nsl: no image server architecture is known for ${hostSystem}.";
      }
    ]
    ++ lib.concatMap (
      name:
      let
        m = machines.${name};
      in
      [
        {
          assertion = validName name;
          message = "nsl.machines.${name}: name must be a lowercase hostname (letters, digits and dashes, at most 63 characters).";
        }
        {
          assertion = m.user == null || config.users.users ? ${m.user};
          message = "nsl.machines.${name}: user '${toString m.user}' is not a user on this host.";
        }
        {
          assertion = !(config.containers ? ${name});
          message = "nsl.machines.${name}: a NixOS container of the same name exists; both would register as machine '${name}'.";
        }
        {
          assertion = !m.privateNetwork || config.systemd.network.enable;
          message = "nsl.machines.${name}: privateNetwork needs systemd.network.enable on the host, which configures the ve-${name} link.";
        }
      ]
    ) machineNames;

    environment.systemPackages = [ cfg.package ];

    environment.etc = lib.mapAttrs' (
      name: m:
      lib.nameValuePair "nsl/machines/${name}.json" {
        text = builtins.toJSON (specOf name m);
      }
    ) machines;

    systemd.nspawn = lib.mapAttrs nspawnFor machines;

    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (
        name: m:
        lib.nameValuePair "nsl-bootstrap-${name}" {
          description = "Install NSL machine ${name} (${m.distro} ${m.release})";
          # Skipped once the machine has been bootstrapped. `nsl reset` removes
          # the marker along with the root filesystem.
          unitConfig = {
            ConditionPathExists = "!/var/lib/nsl/${name}/bootstrapped";
            RequiresMountsFor = "/var/lib/machines";
          };
          after = [ "systemd-machined.service" ] ++ lib.optional (m.image == null) "network-online.target";
          wants = lib.optional (m.image == null) "network-online.target";
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = false;
            Delegate = true;
            # An image download over a slow link must not be killed halfway.
            TimeoutStartSec = "infinity";
            StateDirectory = "nsl/${name}";
            ExecStart = "${cfg.package}/bin/nsl-bootstrap /etc/nsl/machines/${name}.json";
          };
        }
      ) machines)
      # The drop-in is what makes switch-to-configuration treat the template
      # instance as ours, so removing a machine from the configuration stops it.
      (lib.mapAttrs' (
        name: m:
        lib.nameValuePair "systemd-nspawn@${name}" {
          overrideStrategy = "asDropin";
          requires = [ "nsl-bootstrap-${name}.service" ];
          after = [ "nsl-bootstrap-${name}.service" ];
          wantedBy = lib.optional m.autoStart "machines.target";
          restartIfChanged = false;
        }
      ) machines)
    ];

    security.polkit = lib.mkIf (polkitUsers != [ ]) {
      enable = true;
      extraConfig = ''
        // Let NSL users manage their own machines without authenticating.
        polkit.addRule(function(action, subject) {
          var users = ${builtins.toJSON polkitUsers};
          var machines = ${builtins.toJSON machineNames};
          if (users.indexOf(subject.user) < 0) return polkit.Result.NOT_HANDLED;

          if (["org.freedesktop.machine1.shell",
               "org.freedesktop.machine1.login",
               "org.freedesktop.machine1.manage-machines"].indexOf(action.id) >= 0 &&
              machines.indexOf(action.lookup("machine")) >= 0)
            return polkit.Result.YES;

          if (action.id == "org.freedesktop.systemd1.manage-units") {
            var unit = action.lookup("unit");
            for (var i = 0; i < machines.length; i++) {
              if (unit == "systemd-nspawn@" + machines[i] + ".service" ||
                  unit == "nsl-bootstrap-" + machines[i] + ".service")
                return polkit.Result.YES;
            }
          }
          return polkit.Result.NOT_HANDLED;
        });
      '';
    };

    # Host side of privateNetwork: systemd-networkd's shipped 80-container-ve.network
    # runs DHCP and masquerading on ve-*, as long as nothing else claims those
    # links and the firewall lets the DHCP requests in.
    networking.dhcpcd.denyInterfaces = lib.mkIf anyPrivateNetwork [ "ve-*" ];

    services.udev.extraRules = lib.mkIf (anyPrivateNetwork && config.networking.networkmanager.enable) ''
      # Leave the host side of NSL machine links to systemd-networkd.
      ENV{INTERFACE}=="ve-*", ENV{NM_UNMANAGED}="1"
    '';

    networking.firewall = lib.mkIf (anyPrivateNetwork && config.networking.firewall.enable) {
      extraCommands = lib.mkIf (!config.networking.nftables.enable) ''
        ${pkgs.iptables}/bin/iptables -A nixos-fw -i ve-+ -p udp -m udp --dport 67 -j nixos-fw-accept
      '';
      extraInputRules = lib.mkIf config.networking.nftables.enable ''
        iifname "ve-*" udp dport 67 accept comment "DHCP for NSL machines"
      '';
    };
  };
}
