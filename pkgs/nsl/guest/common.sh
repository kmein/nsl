# Runs as PID 2 inside a freshly unpacked machine, once. The adapter provides
# the package manager commands; everything here is plain POSIX sh because the
# machine may not have bash yet.
set -eu

. "/run/nsl/adapters/$NSL_ADAPTER.sh"

log() { echo "nsl: $*"; }

if [ -n "$NSL_PACKAGES" ] || [ -n "$NSL_USER" ]; then
  ensure_base
fi

if [ -n "$NSL_USER" ]; then
  if ! getent group "$NSL_GID" >/dev/null 2>&1; then
    groupadd -g "$NSL_GID" "$NSL_GROUP" 2>/dev/null ||
      groupadd -g "$NSL_GID" "nsl$NSL_GID"
  fi
  group=$(getent group "$NSL_GID" | cut -d: -f1)

  # Distribution images ship their own users; if one already sits on our uid or
  # name, move it out of the way so the mirrored user matches the host exactly.
  existing=$(getent passwd "$NSL_UID" | cut -d: -f1)
  if [ -n "$existing" ] && [ "$existing" != "$NSL_USER" ]; then
    log "freeing uid $NSL_UID, held by $existing"
    usermod -u 60000 "$existing" || userdel "$existing"
  fi

  if getent passwd "$NSL_USER" >/dev/null 2>&1; then
    usermod -u "$NSL_UID" -g "$NSL_GID" -d "$NSL_HOME" -s "$NSL_SHELL" "$NSL_USER"
  else
    log "creating user $NSL_USER ($NSL_UID:$NSL_GID)"
    useradd -u "$NSL_UID" -g "$NSL_GID" -M -d "$NSL_HOME" -s "$NSL_SHELL" "$NSL_USER"
  fi

  # The home directory is usually bind mounted from the host; only create it
  # when it is the machine's own.
  [ -d "$NSL_HOME" ] || mkdir -p "$NSL_HOME"

  if getent group "$NSL_SUDO_GROUP" >/dev/null 2>&1; then
    usermod -aG "$NSL_SUDO_GROUP" "$NSL_USER"
  fi
  # No password is ever valid for this account: the host decides who may enter
  # the machine, and sudo inside it is passwordless through /etc/sudoers.d/nsl.
  usermod -p '*' "$NSL_USER" >/dev/null 2>&1 || true

  if [ ! -x "$NSL_SHELL" ]; then
    log "$NSL_SHELL is missing, falling back to /bin/sh"
    usermod -s /bin/sh "$NSL_USER"
  fi
fi

if [ -n "$NSL_PACKAGES" ]; then
  log "installing $NSL_PACKAGES"
  # shellcheck disable=SC2086
  pkg_install $NSL_PACKAGES
fi

if [ -s /run/nsl-extra.sh ]; then
  log "running extraBootstrap"
  sh /run/nsl-extra.sh
fi
