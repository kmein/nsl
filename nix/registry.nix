# Distributions NSL knows how to bootstrap from images.linuxcontainers.org.
#
# release:   default index release, checked against the index on 2026-09-07.
#            Bump by hand; `nsl images <distro>` lists what the server offers.
# adapter:   package-manager family, see pkgs/nsl/guest/adapters/<adapter>.sh
# sudoGroup: group that grants sudo in that distribution
{
  debian = {
    release = "trixie";
    adapter = "apt";
    sudoGroup = "sudo";
  };
  ubuntu = {
    release = "resolute";
    adapter = "apt";
    sudoGroup = "sudo";
  };
  kali = {
    release = "current";
    adapter = "apt";
    sudoGroup = "sudo";
  };
  archlinux = {
    release = "current";
    adapter = "pacman";
    sudoGroup = "wheel";
  };
  fedora = {
    release = "44";
    adapter = "dnf";
    sudoGroup = "wheel";
  };
  rockylinux = {
    release = "10";
    adapter = "dnf";
    sudoGroup = "wheel";
  };
  almalinux = {
    release = "10";
    adapter = "dnf";
    sudoGroup = "wheel";
  };
  centos = {
    release = "10-Stream";
    adapter = "dnf";
    sudoGroup = "wheel";
  };
  opensuse = {
    release = "tumbleweed";
    adapter = "zypper";
    sudoGroup = "wheel";
  };
  # NixOS guests boot fine, but NixOS regenerates /etc/passwd itself, so the
  # user/package steps are skipped; declare users in the guest configuration.
  nixos = {
    release = "unstable";
    adapter = "none";
    sudoGroup = "wheel";
  };
}
