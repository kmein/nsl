# NSL, the NixOS Subsystem for Linux

Run Debian, Ubuntu, Arch, Fedora or openSUSE on your NixOS machine the way WSL
runs them on Windows: declare them in your configuration, and enter them with
one command. Each one is a real distribution with its own package manager,
running as a `systemd-nspawn` machine that shares your network and your home
directory.

WSL runs Linux on Windows because Windows is not Linux. NSL runs Linux on NixOS
because, as far as many shell scripts can tell, NixOS is not Linux either.

## Why

You run NixOS. You have made your peace with `/usr/bin` containing one
program, and with `./configure && make install` being something other people
do. Most days this is fine. Some days the world sends you one of these:

- A vendor `install.sh` that opens with `apt-get install` and closes with
  strong opinions about `/opt`.
- A prebuilt binary that `ls` can see and the kernel cannot. "No such file or
  directory", it says, of a file that is right there.
- A tutorial, a colleague and a Stack Overflow answer, all agreeing that the
  fix is `sudo apt install libfoo-dev`.
- A `.deb` you just built and would like to see installed once before telling
  anyone it works.

The NixOS answer to all of these is the same: understand the thing, package
the thing, upstream the thing. It is the right answer. It is also a weekend.
NSL is for the other six days. Declare an Ubuntu in your configuration, drop
into it, run the script as written, and get on with whatever you were doing.
Your home directory comes along, so the result lands where you would have put
it anyway.

### The installer that supports Ubuntu 22.04 and 24.04

The tool you need ships as `curl | sh`. The script wants `apt`, `/usr/lib`
and a `/etc/os-release` it has heard of. Give it all three:

```console
$ nsl shell ubuntu
nsl: installing ubuntu resolute, this happens once
alice@ubuntu:~$ curl -fsSL https://example.com/install.sh | sh
alice@ubuntu:~$ exit
$ ls ~/.local/bin
some-tool
```

The binary is now in `~/.local/bin` on both sides, because the machine's
`~/.local/bin` is the host's. On the host it is a file. Inside the machine it
is a program. Run it with `nsl shell ubuntu some-tool`, and whatever it writes
lands in the same home directory either way.

### Does it work on Fedora?

You maintain something with an install script, or a `.deb` and an `.rpm`, and
the bug reports arrive from distributions you do not run. Declare the
distributions you do not run:

```nix
nsl.machines = {
  debian.distro = "debian";
  fedora.distro = "fedora";
  arch.distro = "archlinux";
};
```

```console
$ for m in debian fedora arch; do
    nsl run $m -- ~/src/thing/install.sh && echo "$m: ok"
  done
```

`nsl run` hands back the command's exit code and its output untouched, so this
loop is a test, not a demonstration. The first run downloads three
distributions, which is the only time it will. Three machines, one
`nixos-rebuild switch`, and none of them can see the others' package manager,
which is how they prefer it.

### Following the tutorial as written

The blog post says `sudo apt install` eleven times and `make` once. You could
translate each line into a `shell.nix`, guessing which of the eleven packages
is called something else in nixpkgs. Or:

```console
$ nsl shell ubuntu
alice@ubuntu:~$ sudo apt install build-essential libgtk-3-dev libssl-dev
alice@ubuntu:~$ cd ~/src/the-thing && make
```

When it works, you know what the derivation has to say, which is the hard
part. When it does not, `nsl reset ubuntu` and nobody has to know.

## Getting started

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nsl.url = "github:kmein/nsl";

  outputs = { nixpkgs, nsl, ... }: {
    nixosConfigurations.laptop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ nsl.nixosModules.default ./configuration.nix ];
    };
  };
}
```

```nix
# configuration.nix
{
  nsl = {
    enable = true;
    defaultUser = "alice";
    machines = {
      ubuntu.distro = "ubuntu";
      arch = {
        distro = "archlinux";
        packages = [ "base-devel" "neovim" "btop" "fastfetch" ];
      };
    };
  };
}
```

After `nixos-rebuild switch`, the first `nsl shell ubuntu` downloads and
installs the distribution, which takes about twenty seconds on a fast
connection. After that the machine starts in a second or two and keeps
whatever you put in it.

## Not to be confused with

- **[nix-ld](https://github.com/nix-community/nix-ld), [buildFHSEnv](https://nixos.org/manual/nixpkgs/stable/#sec-fhs-environments), [steam-run](https://wiki.nixos.org/wiki/Steam#FHS_environment_only).** These teach one program to lie about
  where its libraries are. Useful when it is one program. NSL is for when it
  is a whole distribution's worth of assumptions, and a package manager to go
  with them.
- **[distrobox](https://distrobox.it), [toolbox](https://containertoolbx.org).** The same idea on podman. If you like it, keep it.
  NSL uses `systemd-nspawn`, so a machine is a real systemd system:
  `machinectl` knows it, its journal lands in yours, and services inside it
  work without ceremony.
- **[docker](https://www.docker.com).** Containers you throw away. NSL machines are containers you live
  in; they keep their state and are meant to.
- **A virtual machine.** Shares nothing, boots slowly and costs RAM you were
  using. An NSL machine shares your kernel, your network and your home, and
  starts in a second or two.

## What you get

Inside a machine you are the same user as on the host, with the same name, uid
and home directory, and passwordless `sudo`. Your home is bind mounted, so both
sides see the same files. The machine shares the host's network, so it needs no
addresses or firewall rules of its own, and its journal shows up in the host's.

Machines are real systemd systems, so services inside them work normally.

Distributions: `debian`, `ubuntu`, `kali`, `archlinux`, `fedora`, `rockylinux`,
`almalinux`, `centos`, `opensuse`, `nixos`.

## Commands

| Command | |
|---|---|
| `nsl list` | machines and their state |
| `nsl shell <name> [cmd]` | enter a machine, starting it if needed |
| `nsl root <name> [cmd]` | the same, as root |
| `nsl run <name> -- cmd` | run something non-interactively, exit code and all (needs root) |
| `nsl start\|stop\|restart <name>` | |
| `nsl status <name>`, `nsl logs <name>` | |
| `nsl reset <name>` | throw a machine away and install it again |
| `nsl images [distro]` | what the image server currently offers |

Users mirrored into a machine may run all of these without authenticating; add
others with `nsl.users`. Two exceptions ask for `sudo`: `nsl reset`, which
deletes files, and `nsl run`, which speaks to the machine's own service manager
in order to hand you back the command's exit code and unaltered output.

Every option is documented at <https://kmein.github.io/nsl/>, or in
`nix/module.nix` if you prefer the source.

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
$ nix flake check -L      # the whole thing in a VM, offline
$ nix run .#smoke-vm      # installs five real distributions, checks them, reports
$ nix run .#demo-vm       # the same five, to poke at by hand
```

`nix flake check` builds a NixOS root filesystem and serves it from a second VM
laid out like the real image server, so it never touches the network. That
leaves the real server untested, which is what `smoke-vm` is for: run it after
changing the bootstrap, or when the releases in `nix/registry.nix` look stale.

## How it works

The module writes an nspawn settings file, a one-shot bootstrap unit and a
drop-in on systemd's own `systemd-nspawn@.service` for each machine, so systemd
runs the machines and NSL only describes them. Bootstrapping resolves the image
through the server's index, hands the download to `importctl` (which checks it
against the published checksums and unpacks it), and then runs a short script
inside the new filesystem to mirror your user and install packages. The `nsl`
command is a front end over `machinectl`, `systemd-run` and `journalctl`.

## License

MIT. The distributions NSL downloads are not NSL: each image comes from its own
project under its own terms.
