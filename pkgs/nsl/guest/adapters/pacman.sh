# Arch Linux
pkg_install() {
  pacman -Sy --noconfirm --needed "$@"
}

# makepkg refuses root, so build as the mirrored user, whose sudoers drop-in
# lets it install the result. its home is not mounted yet during bootstrap and
# belongs to root, hence a scratch HOME for the helper's cache, on disk since
# nspawn's /tmp is a small tmpfs. yay is built from source because the -bin
# helpers break whenever libalpm bumps its soname.
aur_install() {
  pkg_install base-devel git
  build=$(mktemp -d -p /var/tmp)
  chown "$NSL_USER" "$build"
  if ! command -v yay >/dev/null 2>&1; then
    runuser -u "$NSL_USER" -- git clone -q --depth 1 https://aur.archlinux.org/yay.git "$build/yay"
    (cd "$build/yay" && runuser -u "$NSL_USER" -- env HOME="$build" makepkg -si --noconfirm --rmdeps)
  fi
  runuser -u "$NSL_USER" -- env HOME="$build" yay -S --noconfirm --needed \
    --answerclean None --answerdiff None --removemake "$@"
  rm -rf "$build"
}

ensure_base() {
  # A fresh image has an empty keyring, so the first install would fail.
  if [ ! -s /etc/pacman.d/gnupg/trustdb.gpg ]; then
    pacman-key --init
    pacman-key --populate archlinux
  fi
  command -v sudo >/dev/null 2>&1 || pkg_install sudo
}
