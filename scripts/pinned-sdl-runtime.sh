#!/usr/bin/env bash
# Checksum-pinned SDL2 compatibility and SDL3 bottles used by Bento's QEMU.
# This file is sourced by build-qemu-gl.sh.

readonly BENTO_SDL2_ROOT="sdl2-compat/2.32.70"
readonly BENTO_SDL3_ROOT="sdl3/3.4.14"
readonly BENTO_SDL2_ARCHIVE="sdl2-compat--2.32.70.arm64_sequoia.bottle.tar.gz"
readonly BENTO_SDL3_ARCHIVE="sdl3--3.4.14.arm64_sequoia.bottle.tar.gz"
readonly BENTO_SDL2_SHA256="b5da3b02dfd9a68368f62a317b29f845dad4f29e067fc4aa81a351ca527a82c3"
readonly BENTO_SDL3_SHA256="012d5bb068548cb42df1fd6ab231a8ef76e706a82822d84ed71a10be7f155263"

bento_sdl_download_bottle() {
  local formula="$1" digest="$2" output="$3" token_json token actual
  token_json="$(curl --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 20 \
    --get --data-urlencode 'service=ghcr.io' \
    --data-urlencode "scope=repository:homebrew/core/${formula}:pull" \
    'https://ghcr.io/token')"
  token="$(/usr/bin/python3 -c '
import json, sys
value = json.load(sys.stdin).get("token")
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
' <<<"${token_json}")"
  curl --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 20 \
    --header "Authorization: Bearer ${token}" \
    --output "${output}" \
    "https://ghcr.io/v2/homebrew/core/${formula}/blobs/sha256:${digest}"
  actual="$(shasum -a 256 "${output}" | awk '{print $1}')"
  [[ ${actual} == "${digest}" ]] || {
    echo "error: ${formula} bottle checksum mismatch" >&2
    return 1
  }
}

bento_sdl_verify_archive() {
  local archive="$1" digest="$2" root="$3" actual
  actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
  [[ ${actual} == "${digest}" ]] || return 1
  /usr/bin/python3 - "${archive}" "${root}" <<'PY'
import posixpath
import sys
import tarfile

archive, root = sys.argv[1:]
with tarfile.open(archive, "r:gz") as source:
    members = source.getmembers()
    if not members:
        raise SystemExit("empty SDL bottle")
    for member in members:
        name = posixpath.normpath(member.name.lstrip("./"))
        if name != root and not name.startswith(root + "/"):
            raise SystemExit(f"SDL bottle path escapes {root}: {member.name}")
        if member.ischr() or member.isblk() or member.isfifo():
            raise SystemExit(f"unsupported SDL bottle member: {member.name}")
        if member.issym():
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
            if target != root and not target.startswith(root + "/"):
                raise SystemExit(f"SDL bottle symlink escapes {root}: {member.name}")
PY
}

bento_sdl_prepare() {
  local archive_dir="$1" destination="$2" sdl2_archive sdl3_archive
  sdl2_archive="${archive_dir}/${BENTO_SDL2_ARCHIVE}"
  sdl3_archive="${archive_dir}/${BENTO_SDL3_ARCHIVE}"
  mkdir -p -- "${archive_dir}" "${destination}"

  if ! bento_sdl_verify_archive "${sdl2_archive}" "${BENTO_SDL2_SHA256}" "${BENTO_SDL2_ROOT}" 2>/dev/null; then
    rm -f -- "${sdl2_archive}"
    echo "==> Downloading pinned SDL2-compat 2.32.70"
    bento_sdl_download_bottle sdl2-compat "${BENTO_SDL2_SHA256}" "${sdl2_archive}"
    bento_sdl_verify_archive "${sdl2_archive}" "${BENTO_SDL2_SHA256}" "${BENTO_SDL2_ROOT}"
  fi
  if ! bento_sdl_verify_archive "${sdl3_archive}" "${BENTO_SDL3_SHA256}" "${BENTO_SDL3_ROOT}" 2>/dev/null; then
    rm -f -- "${sdl3_archive}"
    echo "==> Downloading pinned SDL3 3.4.14"
    bento_sdl_download_bottle sdl3 "${BENTO_SDL3_SHA256}" "${sdl3_archive}"
    bento_sdl_verify_archive "${sdl3_archive}" "${BENTO_SDL3_SHA256}" "${BENTO_SDL3_ROOT}"
  fi

  if [[ ! -f ${destination}/${BENTO_SDL2_ROOT}/lib/libSDL2-2.0.0.dylib \
        || ! -f ${destination}/${BENTO_SDL3_ROOT}/lib/libSDL3.0.dylib ]]; then
    tar -xzf "${sdl2_archive}" -C "${destination}"
    tar -xzf "${sdl3_archive}" -C "${destination}"
  fi
}
