#!/usr/bin/env python3
"""Generate WowFriendly/Media/smile.tga and frown.tga.

32x32, uncompressed 32-bit BGRA TGA (bottom-left origin), written by hand with no
third-party modules. Pass --preview DIR to also write PNG copies for eyeballing.
"""
import math
import os
import struct
import sys
import zlib

SIZE = 32
SS = 4  # supersampling factor per axis for anti-aliasing

SMILE_FACE = (120, 200, 80)
FROWN_FACE = (225, 85, 70)
OUTLINE = (40, 40, 40)
FEATURE = (30, 30, 30)


def sample(x, y, kind):
    """Colour and alpha for a point in [0,1]^2 (y grows downward)."""
    dx, dy = x - 0.5, y - 0.5
    d = math.hypot(dx, dy)
    if d > 0.47:
        return None
    if d > 0.42:
        return OUTLINE
    # eyes
    for ex in (0.36, 0.64):
        if math.hypot(x - ex, y - 0.38) < 0.065:
            return FEATURE
    # mouth: arc of a circle, thick band
    if kind == "smile":
        md = math.hypot(x - 0.5, y - 0.44)
        if abs(md - 0.26) < 0.035 and y > 0.58:
            return FEATURE
    else:
        md = math.hypot(x - 0.5, y - 0.90)
        if abs(md - 0.26) < 0.035 and 0.52 < y < 0.72:
            return FEATURE
    return SMILE_FACE if kind == "smile" else FROWN_FACE


def render(kind):
    """Return rows (top to bottom) of (r, g, b, a) tuples."""
    rows = []
    for py in range(SIZE):
        row = []
        for px in range(SIZE):
            r = g = b = a = 0
            for sy in range(SS):
                for sx in range(SS):
                    x = (px + (sx + 0.5) / SS) / SIZE
                    y = (py + (sy + 0.5) / SS) / SIZE
                    c = sample(x, y, kind)
                    if c is not None:
                        r += c[0]
                        g += c[1]
                        b += c[2]
                        a += 1
            n = SS * SS
            if a:
                row.append((r // a, g // a, b // a, a * 255 // n))
            else:
                row.append((0, 0, 0, 0))
        rows.append(row)
    return rows


def write_tga(path, rows):
    header = struct.pack(
        "<BBBHHBHHHHBB",
        0,      # id length
        0,      # colour map type
        2,      # image type: uncompressed true-colour
        0, 0, 0,  # colour map spec
        0, 0,   # x, y origin
        SIZE, SIZE,
        32,     # bits per pixel
        8,      # descriptor: 8 alpha bits, bottom-left origin
    )
    body = bytearray()
    for row in reversed(rows):  # bottom-left origin: last row first
        for r, g, b, a in row:
            body += bytes((b, g, r, a))
    with open(path, "wb") as f:
        f.write(header)
        f.write(body)


def write_png(path, rows):
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter type none
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    media = os.path.join(root, "WowFriendly", "Media")
    os.makedirs(media, exist_ok=True)
    preview = None
    if "--preview" in argv:
        preview = argv[argv.index("--preview") + 1]
        os.makedirs(preview, exist_ok=True)
    for kind in ("smile", "frown"):
        rows = render(kind)
        out = os.path.join(media, kind + ".tga")
        write_tga(out, rows)
        print("wrote", out, os.path.getsize(out), "bytes")
        if preview:
            p = os.path.join(preview, kind + ".png")
            write_png(p, rows)
            print("wrote", p)


if __name__ == "__main__":
    main(sys.argv[1:])
