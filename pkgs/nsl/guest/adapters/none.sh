# NixOS and anything else that manages its own users and packages declaratively.
pkg_install() {
  echo "nsl: this machine manages its own packages; ignoring: $*" >&2
}

ensure_base() { :; }
