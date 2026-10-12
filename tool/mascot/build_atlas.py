#!/usr/bin/env python3
"""Builds the header mascot atlases from the CC0 companion sheets.

Input:  assets/companions/<slug>/spritesheet.webp (CC0-1.0, 8x9 grid of
        192x208 frames; rows 0-4 used).
Output: assets/mascot/<slug>.webp, one lossless atlas per sprite.

Each atlas keeps only the cells the mascot engine draws, cropped to one
shared cell box, and is luminance-normalised so the body is white and the
eyes stay dark. The engine tints it with a single modulate colour filter,
which gives every profile its own colour without extra assets.

Atlas layout (8 columns x 4 rows of CELL_W x CELL_H):
  row 0: idle bob (sheet row 0, 8 frames)
  row 1: working sway (sheet row 1, 8 frames)
  row 2: wave (sheet row 3, 8 frames)
  row 3: eyes open, eyes closed (sheet row 2 frames 0 and 3),
         error A, error B (sheet row 4 frames 0 and 4)

Run from the repository root: python3 tool/mascot/build_atlas.py
Needs Pillow with WebP support.
"""
from PIL import Image

SLUGS = ('pixel', 'nimbus', 'violet')
FW, FH = 192, 208
# Union of the opaque bounds of every used frame of every sprite, padded.
X0, Y0, CELL_W, CELL_H = 29, 39, 140, 134

CELLS = (
    [(0, c) for c in range(8)]
    + [(1, c) for c in range(8)]
    + [(3, c) for c in range(8)]
    + [(2, 0), (2, 3), (4, 0), (4, 4)]
)


def body_luma(frame):
    colors = [c for c in frame.getcolors(1 << 20) if c[1][3] == 255]
    _, (r, g, b, _) = max(colors)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def build(slug):
    sheet = Image.open(f'assets/companions/{slug}/spritesheet.webp').convert('RGBA')
    atlas = Image.new('RGBA', (CELL_W * 8, CELL_H * 4), (0, 0, 0, 0))
    for index, (row, col) in enumerate(CELLS):
        frame = sheet.crop((col * FW, row * FH, (col + 1) * FW, (row + 1) * FH))
        luma = body_luma(frame)
        cell = frame.crop((X0, Y0, X0 + CELL_W, Y0 + CELL_H))
        out = Image.new('RGBA', cell.size)
        px = []
        for r, g, b, a in cell.getdata():
            if a == 0:
                px.append((0, 0, 0, 0))
                continue
            v = min(255, round(255 * (0.2126 * r + 0.7152 * g + 0.0722 * b) / luma))
            px.append((v, v, v, a))
        out.putdata(px)
        atlas.paste(out, ((index % 8) * CELL_W, (index // 8) * CELL_H))
    atlas.save(f'assets/mascot/{slug}.webp', lossless=True, quality=100, method=6)


if __name__ == '__main__':
    for slug in SLUGS:
        build(slug)
