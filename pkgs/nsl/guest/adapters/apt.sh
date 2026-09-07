# Debian, Ubuntu, Kali
export DEBIAN_FRONTEND=noninteractive
_updated=

_update() { [ -n "$_updated" ] || { apt-get update -q; _updated=1; }; }

pkg_install() {
  _update
  apt-get install -y -q --no-install-recommends "$@"
}

ensure_base() {
  # The default images carry sudo already; a minimal one may not.
  command -v useradd >/dev/null 2>&1 || pkg_install passwd
  command -v sudo >/dev/null 2>&1 || pkg_install sudo
}
