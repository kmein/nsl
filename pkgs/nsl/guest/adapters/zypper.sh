# openSUSE
pkg_install() {
  zypper --non-interactive install "$@"
}

ensure_base() {
  command -v useradd >/dev/null 2>&1 || pkg_install shadow
  command -v sudo >/dev/null 2>&1 || pkg_install sudo
}
