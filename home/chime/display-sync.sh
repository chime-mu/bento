set -euo pipefail

drm_root=${BENTO_DISPLAY_SYNC_DRM_ROOT:-/sys/class/drm}
retry_seconds=${BENTO_DISPLAY_SYNC_RETRY_SECONDS:-1}

preferred_mode_from_edid() {
  python3 - "$1" <<'PY'
import pathlib
import sys
from math import hypot

data = pathlib.Path(sys.argv[1]).read_bytes()
if (
    len(data) < 128
    or data[:8] != b"\x00\xff\xff\xff\xff\xff\xff\x00"
    or sum(data[:128]) % 256
):
    raise SystemExit(1)


def modeline(
    pixel_clock: int,
    width: int,
    hblank: int,
    hfront: int,
    hsync: int,
    hsync_positive: bool,
    height: int,
    vblank: int,
    vfront: int,
    vsync: int,
    vsync_positive: bool,
) -> str | None:
    if (
        pixel_clock <= 0
        or width < 64
        or height < 64
        or hfront <= 0
        or hsync <= 0
        or vfront <= 0
        or vsync <= 0
        or hblank < hfront + hsync
        or vblank < vfront + vsync
        or width + hblank > 65535
        or height + vblank > 65535
    ):
        return None

    # Hyprland 0.56 truncates a fractional MHz clock before converting it to
    # kHz. Supplying the nearest integral MHz preserves the intended refresh
    # as closely as that parser permits, while the active pixel size is exact.
    clock_mhz = max(1, (pixel_clock + 500_000) // 1_000_000)
    hsync_start = width + hfront
    hsync_end = hsync_start + hsync
    htotal = width + hblank
    vsync_start = height + vfront
    vsync_end = vsync_start + vsync
    vtotal = height + vblank
    hflag = "+hsync" if hsync_positive else "-hsync"
    vflag = "+vsync" if vsync_positive else "-vsync"
    return (
        f"modeline {clock_mhz} {width} {hsync_start} {hsync_end} {htotal} "
        f"{height} {vsync_start} {vsync_end} {vtotal} {hflag} {vflag}"
    )


def scale_for_mode(
    width: int,
    height: int,
    physical_width_mm: int,
    physical_height_mm: int,
) -> str:
    if physical_width_mm <= 0 or physical_height_mm <= 0:
        return "auto"

    diagonal_inches = hypot(physical_width_mm, physical_height_mm) / 25.4
    if diagonal_inches <= 0:
        return "auto"

    ppi = hypot(width, height) / diagonal_inches
    requested = 2.0 if ppi > 200 else 1.5 if ppi > 140 else 1.0

    # Hyprland requires scaled logical dimensions to land on whole pixels. It
    # searches scale values in 1/120 increments around the requested value;
    # choose the closest clean value here so an explicit dynamic scale does not
    # trigger its stale-physical-size fallback or a warning notification.
    requested_120 = round(requested * 120)
    clean_120 = min(
        (
            candidate
            for candidate in range(30, 481)
            if (width * 120) % candidate == 0
            and (height * 120) % candidate == 0
        ),
        key=lambda candidate: (abs(candidate - requested_120), -candidate),
    )
    return f"{clean_120 / 120:.6f}".rstrip("0").rstrip(".")


base_physical_width_mm = data[21] * 10
base_physical_height_mm = data[22] * 10

# QEMU puts large and dynamically generated modes in a DisplayID 1.3 Type I
# timing block. Its base EDID contains only compatibility modes, so inspect
# DisplayID before falling back to a legacy base-block detailed timing.
displayid_timings: list[tuple[bool, str, int, int]] = []
available_extensions = len(data) // 128 - 1
extension_count = min(data[126], available_extensions)
for extension_index in range(extension_count):
    block_start = (extension_index + 1) * 128
    block = data[block_start : block_start + 128]
    if (
        len(block) != 128
        or block[0] != 0x70
        or block[1] >> 4 != 1
        or sum(block) % 256
    ):
        continue

    data_end = 5 + block[2]
    if data_end > 126 or sum(block[1 : data_end + 1]) % 256:
        continue

    position = 5
    while position + 3 <= data_end:
        tag = block[position]
        payload_length = block[position + 2]
        payload_start = position + 3
        payload_end = payload_start + payload_length
        if payload_end > data_end:
            break

        if tag == 0x03 and payload_length and payload_length % 20 == 0:
            payload = block[payload_start:payload_end]
            for offset in range(0, len(payload), 20):
                timing = payload[offset : offset + 20]
                pixel_clock = (int.from_bytes(timing[0:3], "little") + 1) * 10_000
                width = int.from_bytes(timing[4:6], "little") + 1
                hblank = int.from_bytes(timing[6:8], "little") + 1
                raw_hfront = int.from_bytes(timing[8:10], "little")
                hfront = (raw_hfront & 0x7FFF) + 1
                raw_hsync = int.from_bytes(timing[10:12], "little")
                hsync = raw_hsync + 1
                height = int.from_bytes(timing[12:14], "little") + 1
                vblank = int.from_bytes(timing[14:16], "little") + 1
                raw_vfront = int.from_bytes(timing[16:18], "little")
                vfront = (raw_vfront & 0x7FFF) + 1
                raw_vsync = int.from_bytes(timing[18:20], "little")
                vsync = raw_vsync + 1
                decoded = modeline(
                    pixel_clock,
                    width,
                    hblank,
                    hfront,
                    hsync,
                    bool(raw_hfront & 0x8000),
                    height,
                    vblank,
                    vfront,
                    vsync,
                    bool(raw_vfront & 0x8000),
                )
                if decoded:
                    displayid_timings.append(
                        (bool(timing[3] & 0x80), decoded, width, height)
                    )

        position = payload_end

if displayid_timings:
    _, preferred, preferred_width, preferred_height = next(
        (entry for entry in displayid_timings if entry[0]),
        displayid_timings[0],
    )
    scale = scale_for_mode(
        preferred_width,
        preferred_height,
        base_physical_width_mm,
        base_physical_height_mm,
    )
    print(f"{preferred}\t{scale}")
    raise SystemExit(0)

for offset in range(54, 126, 18):
    timing = data[offset : offset + 18]
    pixel_clock = int.from_bytes(timing[0:2], "little") * 10_000
    # QEMU emits progressive timings with separate digital sync. Reject the
    # interlaced, stereo, or analog/composite forms that need other handling.
    if (
        not pixel_clock
        or timing[17] & 0x80
        or timing[17] & 0x61
        or timing[17] & 0x18 != 0x18
    ):
        continue

    width = timing[2] | ((timing[4] & 0xF0) << 4)
    hblank = timing[3] | ((timing[4] & 0x0F) << 8)
    hfront = timing[8] | ((timing[11] & 0xC0) << 2)
    hsync = timing[9] | ((timing[11] & 0x30) << 4)
    height = timing[5] | ((timing[7] & 0xF0) << 4)
    vblank = timing[6] | ((timing[7] & 0x0F) << 8)
    vfront = (timing[10] >> 4) | ((timing[11] & 0x0C) << 2)
    vsync = (timing[10] & 0x0F) | ((timing[11] & 0x03) << 4)
    physical_width_mm = timing[12] | ((timing[14] & 0xF0) << 4)
    physical_height_mm = timing[13] | ((timing[14] & 0x0F) << 8)
    if not physical_width_mm or not physical_height_mm:
        physical_width_mm = base_physical_width_mm
        physical_height_mm = base_physical_height_mm
    decoded = modeline(
        pixel_clock,
        width,
        hblank,
        hfront,
        hsync,
        bool(timing[17] & 0x02),
        height,
        vblank,
        vfront,
        vsync,
        bool(timing[17] & 0x04),
    )
    if decoded:
        scale = scale_for_mode(
            width,
            height,
            physical_width_mm,
            physical_height_mm,
        )
        print(f"{decoded}\t{scale}")
        raise SystemExit(0)

# Stock QEMU can snapshot Cocoa's transient startup geometry before the guest
# asks for its configured 1920x1080 scanout. That produces a valid QEMU EDID
# with no usable preferred DTD; Hyprland then treats the first compatibility
# mode (currently 5120x2160) as preferred. Dynamic QEMU will replace this EDID
# on the first Cocoa geometry update. Until then, and permanently for --no-gl,
# recognize QEMU's vendor/product identity and retain Bento's readable fallback.
if data[8:12] == b"\x49\x14\x34\x12":
    print("1920x1080@60\t1")
    raise SystemExit(0)

raise SystemExit(1)
PY
}

apply_preferred_modes() {
  local connector
  local connector_name
  local mode
  local output
  local preferred
  local response
  local rule
  local scale

  shopt -s nullglob
  for connector in "$drm_root"/card*-Virtual-*; do
    [[ -d $connector && -r $connector/status && -r $connector/edid ]] || continue
    [[ $(<"$connector/status") == connected ]] || continue

    connector_name=${connector##*/}
    output=${connector_name#*-}
    if ! preferred=$(preferred_mode_from_edid "$connector/edid"); then
      continue
    fi
    IFS=$'\t' read -r mode scale <<<"$preferred"
    [[ -n $mode && -n $scale ]] || continue

    # Aquamarine 0.14 does not refresh its mode cache when an existing DRM
    # connector's EDID or physical size changes. A complete modeline bypasses
    # that cache; an explicit scale calculated from the fresh EDID avoids its
    # stale fullscreen dimensions. Keep the output field empty so Bento's
    # single catch-all monitor rule remains independent of Virtual-1.
    #
    # `hyprctl eval`, not `hyprctl keyword`: home/chime/hyprland.nix writes a Lua
    # config, and the two are mutually exclusive — `keyword` answers "keyword
    # can't work with non-legacy parsers. Use eval." under the Lua config manager,
    # and `eval` is refused under the legacy one. The reply is the same either
    # way: `ok`, or `error: …` with a non-zero exit.
    #
    # Neither $mode (a modeline or WxH@Hz) nor $scale (a number) can contain a
    # quote, so interpolating them into the Lua source needs no escaping.
    rule="hl.monitor({ output = \"\", mode = \"$mode\", position = \"auto\", scale = \"$scale\" })"
    if ! response=$(hyprctl eval "$rule" 2>&1); then
      printf 'bento-display-sync: failed to apply %s to %s: %s\n' \
        "$mode" "$output" "$response" >&2
    elif [[ $response != ok ]]; then
      printf 'bento-display-sync: Hyprland rejected %s for %s: %s\n' \
        "$mode" "$output" "$response" >&2
    fi
  done
  shopt -u nullglob
}

reload_on_display_change() {
  local action=""
  local hotplug=""
  local line

  while IFS= read -r line; do
    if [[ -z $line ]]; then
      if [[ $action == change && $hotplug == 1 ]]; then
        apply_preferred_modes
      fi
      action=""
      hotplug=""
      continue
    fi

    case "$line" in
      ACTION=*) action=${line#ACTION=} ;;
      HOTPLUG=*) hotplug=${line#HOTPLUG=} ;;
    esac
  done

  # udev normally separates events with a blank line, but also handle a final
  # complete event when a test stream or a terminating monitor ends at EOF.
  if [[ $action == change && $hotplug == 1 ]]; then
    apply_preferred_modes
  fi
}

hypr_event_socket() {
  if [[ -n ${BENTO_DISPLAY_SYNC_HYPR_SOCKET:-} ]]; then
    printf '%s' "$BENTO_DISPLAY_SYNC_HYPR_SOCKET"
    return 0
  fi
  [[ -n ${XDG_RUNTIME_DIR:-} && -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || return 1
  printf '%s/hypr/%s/.socket2.sock' \
    "$XDG_RUNTIME_DIR" "$HYPRLAND_INSTANCE_SIGNATURE"
}

# Hyprland announces events on a unix socket, which bash cannot open. python3 is
# already a dependency for the EDID decoder, so it does the streaming and the
# filtering stays below, next to the udev one.
stream_hypr_events() {
  python3 - "$1" <<'PY'
import socket
import sys

stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
stream.connect(sys.argv[1])
pending = b""
while True:
    chunk = stream.recv(4096)
    if not chunk:
        break
    pending += chunk
    while b"\n" in pending:
        line, pending = pending.split(b"\n", 1)
        sys.stdout.buffer.write(line + b"\n")
        sys.stdout.flush()
PY
}

# A config reload throws away every runtime `hl.monitor` this service has applied
# and falls back to the catch-all rule in home/chime/hyprland.nix, which is
# deliberately `scale = 1` — the safe value for the window before any EDID has
# been read. `bento rebuild switch` reaches that path through home-manager's
# activation, so a rebuild silently halves the desktop's scale.
#
# No DRM hotplug follows a reload, so `reload_on_display_change` never sees it.
# `hyprctl eval` does not itself emit `configreloaded`, so re-applying here
# cannot feed back into another reload.
reapply_on_config_reload() {
  local line

  while IFS= read -r line; do
    [[ $line == configreloaded* ]] || continue
    apply_preferred_modes
  done
}

case "${1:-}" in
  --decode-edid)
    [[ $# -eq 2 ]] || {
      echo "usage: bento-display-sync --decode-edid EDID" >&2
      exit 2
    }
    preferred_mode_from_edid "$2"
    ;;
  --once)
    [[ $# -eq 1 ]] || exit 2
    apply_preferred_modes
    ;;
  --from-stdin)
    [[ $# -eq 1 ]] || exit 2
    reload_on_display_change
    ;;
  --from-hypr-stdin)
    [[ $# -eq 1 ]] || exit 2
    reapply_on_config_reload
    ;;
  "")
    # QEMU changes virtio-gpu's EDID whenever its Cocoa window geometry changes.
    # Linux exposes that as a DRM hotplug change. Apply once for session startup,
    # then recreate the udev monitor whenever it exits.
    apply_preferred_modes
    # Hyprland's own event socket, watched alongside udev because a config reload
    # produces no DRM hotplug. Backgrounded rather than run through a second
    # `|` so that neither watcher's restart loop can stall the other; systemd
    # tears it down with the rest of the service's cgroup.
    (
      while true; do
        if hypr_socket=$(hypr_event_socket) && [[ -S $hypr_socket ]]; then
          stream_hypr_events "$hypr_socket" | reapply_on_config_reload || true
        fi
        sleep "$retry_seconds"
      done
    ) &
    while true; do
      udevadm monitor --udev --subsystem-match=drm --property |
        reload_on_display_change || true
      sleep "$retry_seconds"
    done
    ;;
  *)
    echo "usage: bento-display-sync [--once|--decode-edid EDID|--from-stdin|--from-hypr-stdin]" >&2
    exit 2
    ;;
esac
