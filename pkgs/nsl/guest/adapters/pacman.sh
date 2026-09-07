# Arch Linux
pkg_install() {
  pacman -Sy --noconfirm --needed "$@"
}

ensure_base() {
  # A fresh image has an empty keyring, so the first install would fail.
  if [ ! -s /etc/pacman.d/gnupg/trustdb.gpg ]; then
    pacman-key --init
    pacman-key --populate archlinux
  fi
  command -v sudo >/dev/null 2>&1 || pkg_install sudo
}
