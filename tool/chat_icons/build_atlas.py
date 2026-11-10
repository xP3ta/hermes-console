#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
# SPDX-License-Identifier: GPL-3.0-only
"""Builds assets/chat_icons/<id>.webp from rendered Generative Icons frames.

The ten chat icons come from the MIT-licensed Generative Icons library
(https://generativeicons.com, LottieFiles). Each source `.lottie` (outline,
weight 2, "light" motion: `a/<id>.json`) was rasterised frame by frame with
lottie-web 5.13.0 (MIT, build-time only, never shipped) in headless Chromium
(`render_frames.cjs` + `render.html`) at 64 px. This script keeps only the
frames in which the animation still changes (the rest is a held pose), samples
every second frame (30 fps) and writes one horizontal lossless WebP strip per
icon, recoloured white so the app can tint it with the theme (srcIn).

Usage: build_atlas.py FRAMES_DIR OUT_DIR   (FRAMES_DIR/<id>/fNNN.png)
Output: OUT_DIR/<id>.webp and OUT_DIR/atlas.json {id: {frames, frameMs, size}}.
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageChops

ICONS = [
    "reasoning", "terminal-agent", "tool-call", "delegate-task",
    "parallel-tools", "response-stream", "check", "error", "queued",
    "agent-team",
]
SIZE = 64
STEP = 2  # 60 fps source -> 30 fps
THRESHOLD = 40


def alpha_sum(a: Image.Image, b: Image.Image) -> int:
    diff = ImageChops.difference(a.getchannel("A"), b.getchannel("A"))
    return sum(diff.getdata())


def build(frames_dir: Path, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    meta = {}
    for icon in ICONS:
        files = sorted((frames_dir / icon).glob("f*.png"))
        frames = [Image.open(f).convert("RGBA") for f in files]
        changes = [alpha_sum(a, b) for a, b in zip(frames, frames[1:])]
        last = max((i for i, c in enumerate(changes) if c > THRESHOLD), default=0) + 1
        picked = list(range(0, last + 1, STEP))
        if picked[-1] != last:
            picked.append(last)
        strip = Image.new("RGBA", (SIZE * len(picked), SIZE), (0, 0, 0, 0))
        for slot, index in enumerate(picked):
            frame = frames[index]
            alpha = frame.getchannel("A")
            white = Image.new("RGBA", frame.size, (255, 255, 255, 0))
            white.putalpha(alpha)
            strip.paste(white, (slot * SIZE, 0))
        strip.save(out_dir / f"{icon}.webp", lossless=True, quality=100, method=6)
        meta[icon] = {"frames": len(picked), "frameMs": round(1000 * STEP / 60), "size": SIZE}
    (out_dir / "atlas.json").write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    build(Path(sys.argv[1]), Path(sys.argv[2]))
