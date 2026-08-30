#!/usr/bin/env python3
"""Regenerate home/chime/theme/tokyo-night.png.

The wallpaper is committed as a PNG — a flake cannot see an untracked file, and a
wallpaper is the classic case of "my change did nothing" (learned/phase-2.md §3). This
script exists so the committed blob has a provenance: it is not a downloaded image of
unknown licence, it is these forty lines of arithmetic over the Tokyo Night palette in
home/chime/theme/colors.nix.

    python3 scripts/make-wallpaper.py

Deterministic: same input, byte-identical output, so re-running it produces no diff.
Pure standard library (zlib + struct) on purpose — the point is that it runs anywhere
with a python3, including inside the VM, with nothing installed.

The motif is a bento box: five cells, one big, laid out on a grid. Deliberately almost
invisible — a wallpaper on a machine whose desktop is drawn by llvmpipe should be flat
colour and low contrast, not something the CPU has to composite against.
"""

import struct
import zlib
from pathlib import Path

W, H = 1920, 1080
OUT = Path(__file__).resolve().parent.parent / "home/chime/theme/tokyo-night.png"

# Tokyo Night, the same values as home/chime/theme/colors.nix. Kept as literals rather
# than parsed out of the .nix file: a 40-line PNG writer should not grow a Nix parser.
BG = (0x1A, 0x1B, 0x26)  # bg
BG_DARK = (0x16, 0x16, 0x1E)  # bgDark
BG_HIGH = (0x29, 0x2E, 0x42)  # bgHighlight
BLUE0 = (0x3D, 0x59, 0xA1)  # blue0
BLUE = (0x7A, 0xA2, 0xF7)  # blue
FG = (0xC0, 0xCA, 0xF5)  # fg

# Cells as fractions of the panel: (x0, y0, x1, y1, accent). One large cell, two stacked
# beside it, two along the bottom — a bento tray, not a uniform grid.
CELLS = [
    (0.00, 0.00, 0.52, 0.58, False),
    (0.52, 0.00, 1.00, 0.30, False),
    (0.52, 0.30, 1.00, 0.58, True),
    (0.00, 0.58, 0.30, 1.00, False),
    (0.30, 0.58, 1.00, 1.00, False),
]

PANEL_W, PANEL_H = 1180, 660
GAP, RADIUS, BORDER = 22.0, 20.0, 1.6

# 4x4 Bayer matrix, scaled to ±1 LSB. A 1920-pixel-wide gradient crosses fewer than 256
# levels, so without dithering it bands visibly in flat dark blues — and ordered dither
# costs far less PNG size than random noise, because it is itself a repeating pattern.
BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def mix(a, b, t):
    t = 0.0 if t < 0.0 else 1.0 if t > 1.0 else t
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def over(dst, src, alpha):
    """Composite src over dst at the given alpha."""
    return tuple(dst[i] + (src[i] - dst[i]) * alpha for i in range(3))


def rounded_rect_coverage(px, py, x0, y0, x1, y1, r):
    """Signed distance to a rounded rectangle, as coverage in [0, 1] with a 1px edge.

    Negative distance is inside. Analytic rather than sampled, so the corners are smooth
    at any radius without supersampling the whole image.
    """
    cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    hx, hy = (x1 - x0) / 2.0 - r, (y1 - y0) / 2.0 - r
    dx, dy = abs(px - cx) - hx, abs(py - cy) - hy
    outside = ((max(dx, 0.0)) ** 2 + (max(dy, 0.0)) ** 2) ** 0.5
    return outside + min(max(dx, dy), 0.0) - r


def build():
    px0 = (W - PANEL_W) / 2.0
    py0 = (H - PANEL_H) / 2.0

    # Absolute cell rectangles, inset by half the gap on every internal edge.
    rects = []
    for fx0, fy0, fx1, fy1, accent in CELLS:
        rects.append(
            (
                px0 + fx0 * PANEL_W + GAP / 2,
                py0 + fy0 * PANEL_H + GAP / 2,
                px0 + fx1 * PANEL_W - GAP / 2,
                py0 + fy1 * PANEL_H - GAP / 2,
                accent,
            )
        )

    rows = []
    for y in range(H):
        row = bytearray()
        fy = y / (H - 1)
        for x in range(W):
            fx = x / (W - 1)

            # Base: a diagonal wash from bg to bgDark, so the top-left is the lightest
            # corner and the bar (which lives at the top) has something to sit against.
            c = mix(BG, BG_DARK, (fx * 0.45 + fy * 0.75))

            # Two soft glows: bgHighlight up where the bar is, a cold blue0 low and right.
            dx, dy = (fx - 0.28) * 1.35, fy - 0.22
            g = max(0.0, 1.0 - (dx * dx + dy * dy) ** 0.5 / 0.95)
            c = over(c, BG_HIGH, 0.55 * g * g)

            dx, dy = (fx - 0.80) * 1.20, fy - 0.88
            g = max(0.0, 1.0 - (dx * dx + dy * dy) ** 0.5 / 0.70)
            c = over(c, BLUE0, 0.16 * g * g)

            for rx0, ry0, rx1, ry1, accent in rects:
                d = rounded_rect_coverage(x + 0.5, y + 0.5, rx0, ry0, rx1, ry1, RADIUS)
                if d > 1.0:
                    continue
                tint = BLUE if accent else FG
                fill = 0.075 if accent else 0.030
                edge = 0.30 if accent else 0.10
                # Inside gets the fill; the border is the band within BORDER of the edge.
                inside = min(1.0, max(0.0, 0.5 - d))
                border = min(1.0, max(0.0, 0.5 - abs(d + BORDER / 2) + BORDER / 2))
                c = over(c, tint, fill * inside)
                c = over(c, tint, edge * border)
                break

            dither = (BAYER[y & 3][x & 3] - 7.5) / 8.0
            for i in range(3):
                v = int(c[i] + dither + 0.5)
                row.append(0 if v < 0 else 255 if v > 255 else v)
        rows.append(bytes(row))
    return rows


def write_png(rows, path):
    stride = W * 3
    raw = bytearray()
    prev = bytes(stride)
    for row in rows:
        # Filter type 2 (Up). The image is a mostly-vertical gradient, so the difference
        # against the row above is near zero almost everywhere and deflate eats it.
        raw.append(2)
        raw.extend((row[i] - prev[i]) & 0xFF for i in range(stride))
        prev = row

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


if __name__ == "__main__":
    write_png(build(), OUT)
    print(f"{OUT} ({OUT.stat().st_size // 1024} KiB)")
