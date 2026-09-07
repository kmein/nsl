# nsl-bootstrap <spec.json>
#
# Installs a machine's root filesystem once, from the host, as root. Started by
# nsl-bootstrap-<name>.service, which skips it once the marker file exists.

usage() {
  echo "usage: nsl-bootstrap <spec.json>" >&2
  exit 2
}

[ $# -eq 1 ] || usage
spec=$1
[ -r "$spec" ] || { echo "nsl: cannot read $spec" >&2; exit 1; }

if [ "$(id -u)" != 0 ]; then
  echo "nsl: nsl-bootstrap must run as root" >&2
  exit 1
fi

get() { jq -r --arg k "$1" '.[$k] // empty' "$spec"; }

name=$(get name)
distro=$(get distro)
release=$(get release)
variant=$(get variant)
arch=$(get arch)
image=$(get image)
server=$(get imageServer)
user=$(get user)
home=$(get home)
shell=$(get shell)
sudo_group=$(get sudoGroup)
adapter=$(get adapter)
extra=$(get extraBootstrap)
spec_hash=$(get specHash)
private_network=$(jq -r '.privateNetwork' "$spec")
packages=$(jq -r '.packages | join(" ")' "$spec")

root=/var/lib/machines/$name
state=/var/lib/nsl/$name
mkdir -p "$state"

# A previous attempt may have left a half-installed root filesystem behind:
# it has no marker, so start over rather than booting something incomplete.
if [ -e "$root" ] && [ ! -e "$state/bootstrapped" ]; then
  echo "nsl: discarding incomplete root filesystem for $name"
  machinectl remove "$name" || rm -rf --one-file-system "$root"
fi

if [ -e "$state/bootstrapped" ]; then
  echo "nsl: $name is already bootstrapped"
  exit 0
fi

if [ -n "$image" ]; then
  echo "nsl: importing $name from $image"
  importctl -m -q import-tar "$image" "$name"
else
  echo "nsl: looking up $distro $release ($arch/$variant) on $server"
  index=$(curl -fsSL --retry 5 --retry-delay 2 "$server/meta/1.0/index-system") || {
    echo "nsl: cannot fetch the image index from $server" >&2
    exit 1
  }
  path=$(printf '%s\n' "$index" |
    awk -F';' -v d="$distro" -v r="$release" -v a="$arch" -v v="$variant" \
      '$1==d && $2==r && $3==a && $4==v { p=$6 } END { if (p != "") print p }')
  if [ -z "$path" ]; then
    echo "nsl: $server has no $variant image for $distro $release on $arch." >&2
    echo "nsl: available releases: $(printf '%s\n' "$index" |
      awk -F';' -v d="$distro" -v a="$arch" -v v="$variant" '$1==d && $3==a && $4==v { print $2 }' |
      sort -u | tr '\n' ' ')" >&2
    exit 1
  fi
  echo "nsl: downloading $server$path"
  # importctl follows the mirror redirect, verifies against the SHA256SUMS
  # published next to the image and unpacks straight into /var/lib/machines.
  # -N skips the pristine second copy it would otherwise keep.
  importctl -m -N -q --verify=checksum pull-tar "$server${path}rootfs.tar.xz" "$name"
  printf '%s\n' "$path" > "$state/image"
fi

# Distributions describe themselves in one of these two places, sometimes
# through a symlink that only resolves inside the machine, so test for the
# link itself rather than what it points at.
if ! [ -e "$root/etc/os-release" ] && ! [ -L "$root/etc/os-release" ] &&
  ! [ -e "$root/usr/lib/os-release" ]; then
  echo "nsl: $root has no os-release, this does not look like a root filesystem" >&2
  exit 1
fi

if [ "$adapter" != none ]; then
  printf '%s\n' "$name" > "$root/etc/hostname"

  if [ "$private_network" = true ]; then
    # The machine has its own namespace, so let its networkd configure host0
    # from systemd's shipped 80-container-host0.network.
    systemctl --root="$root" enable systemd-networkd.service systemd-resolved.service || true
    ln -sf ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
  else
    # Sharing the host's network namespace: the image's own network stack has
    # no business here. It would fight the host's resolved for 127.0.0.53 and
    # try to reconfigure the host's interfaces, which it has no capability for.
    systemctl --root="$root" mask \
      systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service \
      systemd-resolved.service systemd-timesyncd.service NetworkManager.service || true
  fi

  if [ -n "$user" ]; then
    mkdir -p "$root/etc/sudoers.d"
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$user" > "$root/etc/sudoers.d/nsl"
    chmod 0440 "$root/etc/sudoers.d/nsl"
    if [ -n "$home" ]; then mkdir -p "$root$home"; fi
  fi
fi

if [ "$adapter" != none ] && [ -n "$user$packages" ]; then
  uid=""; gid=""; group=""
  if [ -n "$user" ]; then
    entry=$(getent passwd "$user") || { echo "nsl: no host user '$user'" >&2; exit 1; }
    uid=$(printf '%s' "$entry" | cut -d: -f3)
    gid=$(printf '%s' "$entry" | cut -d: -f4)
    group=$(getent group "$gid" | cut -d: -f1)
    [ -n "$group" ] || group=$user
  fi

  echo "nsl: setting up $name"
  # Run the guest half inside the new root filesystem: package managers and
  # useradd have to be the machine's own. The host network is shared here so
  # that installing packages works; user namespacing is off, so files stay
  # root-owned and are id-mapped later if the machine asks for it.
  systemd-nspawn --quiet --directory="$root" --as-pid2 --register=no --keep-unit \
    --console=pipe --settings=no --resolv-conf=replace-host \
    --bind-ro="$NSL_GUEST_DIR:/run/nsl" \
    --bind-ro="$extra:/run/nsl-extra.sh" \
    --setenv=NSL_USER="$user" \
    --setenv=NSL_UID="$uid" \
    --setenv=NSL_GID="$gid" \
    --setenv=NSL_GROUP="$group" \
    --setenv=NSL_HOME="$home" \
    --setenv=NSL_SHELL="$shell" \
    --setenv=NSL_SUDO_GROUP="$sudo_group" \
    --setenv=NSL_ADAPTER="$adapter" \
    --setenv=NSL_PACKAGES="$packages" \
    -- /bin/sh /run/nsl/common.sh
fi

printf '%s\n' "$spec_hash" > "$state/spec-hash"
: > "$state/bootstrapped"
echo "nsl: $name is ready"
