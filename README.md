# NSL, the NixOS Subsystem for Linux

Run Debian, Ubuntu, Arch, Fedora or openSUSE on your NixOS machine the way WSL
runs them on Windows: declare them in your configuration, and enter them with
one command. Each one is a real distribution with its own package manager,
running as a `systemd-nspawn` machine that shares your network and your home
directory.

```nix
{
  inputs.nsl.url = "github:kfm/nsl";

  # in your NixOS configuration
  imports = [ inputs.nsl.nixosModules.default ];

  nsl = {
    enable = true;
    defaultUser = "alice";
    machines = {
      ubuntu.distro = "ubuntu";
      arch = {
        distro = "archlinux";
        packages = [ "base-devel" ];
      };
    };
  };
}
```

After `nixos-rebuild switch`:

```console
$ nsl shell ubuntu
alice@ubuntu:~$ sudo apt install ripgrep
alice@ubuntu:~$ rg -n TODO ~/src        # your real home directory
```

The first `nsl shell` downloads the distribution, which takes a minute. After
that the machine starts in about a second and keeps whatever you install in it.

## What you get

Inside a machine you are the same user as on the host, with the same name, uid
and home directory, and passwordless `sudo`. Your home is bind mounted, so both
sides see the same files. The machine shares the host's network, so it needs no
addresses or firewall rules of its own, and its journal shows up in the host's.

Machines are real systemd systems, so services inside them work normally.

## Commands

| Command | |
|---|---|
| `nsl list` | machines and their state |
| `nsl shell <name> [cmd]` | enter a machine, starting it if needed |
| `nsl root <name> [cmd]` | the same, as root |
| `nsl run <name> -- cmd` | run something non-interactively, exit code and all |
| `nsl start\|stop\|restart <name>` | |
| `nsl status <name>`, `nsl logs <name>` | |
| `nsl reset <name>` | throw a machine away and install it again |
| `nsl images [distro]` | what the image server currently offers |

Users mirrored into a machine may run all of these without authenticating; add
others with `nsl.users`.

## Options

Everything lives under `nsl.machines.<name>`:

| Option | Default | |
|---|---|---|
| `distro` | | one of the distributions below |
| `release` | current | a release the image server offers, see `nsl images` |
| `image` | null | a root filesystem tarball to use instead of downloading one |
| `user` | `nsl.defaultUser` | host user to mirror inside the machine |
| `shell` | `/bin/bash` | that user's login shell, as a path inside the machine |
| `bindHome` | true with a user | bind mount the user's home from the host |
| `packages` | `[]` | packages installed during bootstrap |
| `extraBootstrap` | `""` | shell commands run inside the machine during bootstrap |
| `autoStart` | false | start the machine at boot |
| `bindMounts` | `[]` | further host directories to expose |
| `privateNetwork` | false | give the machine its own network namespace |
| `privateUsers` | false | give the machine its own user namespace |
| `nspawn` | `{}` | settings merged into `systemd.nspawn.<name>` |

Top level: `nsl.enable`, `nsl.defaultUser`, `nsl.users`, `nsl.imageServer`,
`nsl.package`.

Distributions: `debian`, `ubuntu`, `kali`, `archlinux`, `fedora`, `rockylinux`,
`almalinux`, `centos`, `opensuse`, `nixos`.

## Things worth knowing

**Bootstrap runs once.** `packages` and `extraBootstrap` shape a machine when it
is first installed. Changing them later does nothing; install things from inside
the machine, or run `nsl reset <name>` to build it again from scratch. `nsl list`
marks machines whose declaration has moved on.

**Images cannot be pinned by release alone.** The image server keeps only the
last few daily builds, so two hosts bootstrapping the same machine a week apart
get different builds. For a reproducible machine, fetch a tarball yourself and
pass it as `image`.

**Removing a machine stops it but keeps its files.** They stay in
`/var/lib/machines/<name>` until you run `nsl reset`, so a machine deleted from
your configuration by accident does not take your work with it.

**With `autoStart`, the first switch waits for the download.** The bootstrap
runs as part of the unit that switch-to-configuration starts. Leave `autoStart`
off if you would rather wait at your first `nsl shell`.

**Machines need systemd inside.** That covers every distribution above. Alpine
and Void images are built around other init systems and are not supported yet.

**`privateNetwork` needs networkd.** Set `systemd.network.enable = true` on the
host. The module adds the DHCP firewall rule and keeps NetworkManager off the
`ve-*` links. The shared-network default needs none of this and is what most
people want.

## Requirements

NixOS 24.11 or newer, for `importctl`. The VM test needs KVM.

## Development

```console
$ nix flake check -L      # runs the whole thing in a VM, offline
$ nix run .#demo-vm       # a VM with five distributions declared
```

## How it works

The module writes an nspawn settings file, a one-shot bootstrap unit and a
drop-in on systemd's own `systemd-nspawn@.service` for each machine, so systemd
runs the machines and NSL only describes them. Bootstrapping resolves the image
through the server's index, hands the download to `importctl` (which checks it
against the published checksums and unpacks it), and then runs a short script
inside the new filesystem to mirror your user and install packages. The `nsl`
command is a front end over `machinectl`, `systemd-run` and `journalctl`.
