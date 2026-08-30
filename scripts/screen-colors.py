#!/usr/bin/env python3
# bento — what colour is the guest's screen, actually.
#
#   ./scripts/screen-colors.py shot.png --hist        # the 12 commonest colours
#   ./scripts/screen-colors.py shot.png 960,600 40,86 # specific pixels
#
# The companion to scripts/vm-screenshot.sh. That script makes the QEMU scanout the
# authority on what the guest is displaying; this one turns the answer into *numbers* that
# can be compared against home/chime/theme/colors.nix, instead of a judgement about a
# thumbnail.
#
# Phases 3 and 4 verified rendering by looking at the picture, which answers "is something
# there?" but not "is it the right colour?" — and those are different questions. Phase 5
# used this to establish that the ghostty window was 96.9% #1a1b26, the theme's own
# background, rather than something that merely looked dark.
#
# **Pure standard library, on purpose.** macOS ships no PIL and this has to run on the
# host, where the screenshots land. A PNG is zlib plus five filter types, which is about
# forty lines — cheaper than making the repo depend on a Python environment.
#
# Only the formats QEMU's `screendump` actually emits are handled: 8 bits per channel,
# non-interlaced. Anything else asserts rather than quietly returning wrong colours.
import sys, zlib, struct
from collections import Counter


def load(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, w = 8, b"", None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        ctype = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        if ctype == b"IHDR":
            w, h, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and interlace == 0, (depth, interlace)
            channels = {0: 1, 2: 3, 4: 2, 6: 4}[color]
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break
        pos += 12 + length

    raw = zlib.decompress(idat)
    stride = w * channels
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p : p + stride])
        p += stride
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            x = line[i]
            if f == 1:
                x += a
            elif f == 2:
                x += b
            elif f == 3:
                x += (a + b) >> 1
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                x += a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = x & 0xFF
        out[y * stride : (y + 1) * stride] = line
        prev = line
    return w, h, channels, out


def hexat(w, ch, buf, x, y):
    i = (y * w + x) * ch
    return "#%02x%02x%02x" % (buf[i], buf[i + 1], buf[i + 2])


path = sys.argv[1]
w, h, ch, buf = load(path)
print(f"{path}: {w}x{h}, {ch} channels")

if "--hist" in sys.argv:
    c = Counter()
    for y in range(0, h, 3):
        for x in range(0, w, 3):
            c[hexat(w, ch, buf, x, y)] += 1
    total = sum(c.values())
    for col, n in c.most_common(12):
        print(f"  {col}  {100*n/total:5.1f}%")
else:
    for arg in sys.argv[2:]:
        x, y = (int(v) for v in arg.split(","))
        print(f"  ({x:>4},{y:>4}) = {hexat(w, ch, buf, x, y)}")
