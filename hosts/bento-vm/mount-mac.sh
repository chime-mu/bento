#!/usr/bin/env bash
set -euo pipefail
umask 077

mount_path="${BENTO_MAC_MOUNT_PATH:-/mnt/bento-mac}"
link_path="${BENTO_MAC_LINK_PATH:-/home/chime/Mac}"
virtio_devices="${BENTO_VIRTIO_DEVICES:-/sys/bus/virtio/devices}"
marker_path="${BENTO_MAC_MARKER_PATH:-/var/lib/bento-mac-mount/managed-link}"
mount_tag=bento-mac

remove_managed_paths() {
  if [[ -f ${marker_path} ]]; then
    if [[ -L ${link_path} && "$(readlink "${link_path}")" == "${mount_path}" ]]; then
      rm -f -- "${link_path}"
    fi
    rm -f -- "${marker_path}"
  fi
  if mountpoint -q "${mount_path}"; then
    umount "${mount_path}"
  fi
  rmdir -- "${mount_path}" 2>/dev/null || true
}

if [[ ${1:-} == --stop ]]; then
  remove_managed_paths
  exit 0
fi

tag_present=0
for tag_file in "${virtio_devices}"/*/mount_tag; do
  if [[ -r ${tag_file} ]] && [[ "$(tr -d '\0\n' < "${tag_file}")" == "${mount_tag}" ]]; then
    tag_present=1
    break
  fi
done

if [[ ${tag_present} -eq 0 ]]; then
  # Clean up only the symlink Bento itself owns. A real ~/Mac directory or a different
  # symlink is user data and is never replaced or removed.
  remove_managed_paths
  exit 0
fi

# The service deliberately uses umask 077, but the guest user must be able to
# traverse the mount's parent. On a fresh image /mnt may not exist yet, so make
# both directories with explicit traversal modes instead of inheriting umask.
install -d -m 0755 -- "$(dirname -- "${mount_path}")"
install -d -m 0755 -- "${mount_path}"
if ! mountpoint -q "${mount_path}"; then
  mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576,cache=mmap \
    "${mount_tag}" "${mount_path}"
fi

if [[ -f ${marker_path} && -L ${link_path} \
      && "$(readlink "${link_path}")" == "${mount_path}" ]]; then
  :
elif [[ ! -e ${link_path} && ! -L ${link_path} ]]; then
  ln -s "${mount_path}" "${link_path}"
  chown -h 1000:100 "${link_path}"
  mkdir -p -- "$(dirname -- "${marker_path}")"
  printf '%s\n' "${link_path}" > "${marker_path}"
else
  rm -f -- "${marker_path}"
  systemd-cat -t bento-mac-mount -p warning <<EOF
The Mac folder is mounted at ${mount_path}, but ${link_path} already exists. Bento preserved it and did not create the ~/Mac symlink.
EOF
fi
