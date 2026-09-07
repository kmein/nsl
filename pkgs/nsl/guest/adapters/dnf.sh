# Fedora, Rocky, Alma, CentOS Stream
_dnf() { if command -v dnf >/dev/null 2>&1; then dnf "$@"; else yum "$@"; fi; }

pkg_install() {
  _dnf install -y "$@"
}

ensure_base() {
  command -v useradd >/dev/null 2>&1 || pkg_install shadow-utils
  command -v sudo >/dev/null 2>&1 || pkg_install sudo
}
