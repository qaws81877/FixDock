#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 FixDock contributors
"""Write Resources/AppIcon.png, a simple placeholder (no upstream artwork)."""

import struct
import zlib
from pathlib import Path

SIZE = 1024
F = [
    "11110",
    "10000",
    "11100",
    "10000",
    "10000",
    "10000",
    "10000",
]
D = [
    "11100",
    "10010",
    "10001",
    "10001",
    "10001",
    "10010",
    "11100",
]


def inside_round_rect(x, y):
    left, top, right, bottom = 80, 80, 944, 944
    radius = 190
    if x < left or y < top or x >= right or y >= bottom:
        return False
    if x < left + radius and y < top + radius:
        cx, cy = left + radius, top + radius
    elif x >= right - radius and y < top + radius:
        cx, cy = right - radius - 1, top + radius
    elif x < left + radius and y >= bottom - radius:
        cx, cy = left + radius, bottom - radius - 1
    elif x >= right - radius and y >= bottom - radius:
        cx, cy = right - radius - 1, bottom - radius - 1
    else:
        return True
    dx, dy = x - cx, y - cy
    return dx * dx + dy * dy <= radius * radius


def letter_pixels(glyph, origin_x, origin_y, cell):
    pixels = set()
    for row, line in enumerate(glyph):
        for col, bit in enumerate(line):
            if bit != "1":
                continue
            for dy in range(cell):
                for dx in range(cell):
                    pixels.add((origin_x + col * cell + dx, origin_y + row * cell + dy))
    return pixels


def png(width, height, rows):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + row for row in rows)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def main():
    cell = 34
    gap = 28
    f_width = len(F[0]) * cell
    d_width = len(D[0]) * cell
    block_w = f_width + gap + d_width
    block_h = len(F) * cell
    origin_x = (SIZE - block_w) // 2
    origin_y = (SIZE - block_h) // 2
    ink = letter_pixels(F, origin_x, origin_y, cell)
    ink |= letter_pixels(D, origin_x + f_width + gap, origin_y, cell)
    blue = (22, 84, 158, 255)
    white = (255, 255, 255, 255)
    clear = (0, 0, 0, 0)
    rows = []
    for y in range(SIZE):
        row = bytearray()
        for x in range(SIZE):
            if (x, y) in ink and inside_round_rect(x, y):
                row.extend(white)
            elif inside_round_rect(x, y):
                row.extend(blue)
            else:
                row.extend(clear)
        rows.append(bytes(row))
    destination = Path(__file__).resolve().parents[1] / "Resources" / "AppIcon.png"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(png(SIZE, SIZE, rows))
    print(f"wrote {destination} ({destination.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
