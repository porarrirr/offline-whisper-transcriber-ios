#!/usr/bin/env python3
"""Resize App Store screenshots to required pixel dimensions (letterbox, no stretch)."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

# App background (~#0D1117)
LETTERBOX_RGB = (13, 17, 23)

IPHONE_PORTRAIT = (1284, 2778)
IPAD_PORTRAIT = (2048, 2732)
IPAD_LANDSCAPE = (2732, 2048)


def fit_letterbox(src: Image.Image, target_w: int, target_h: int) -> Image.Image:
    src = src.convert("RGB")
    scale = min(target_w / src.width, target_h / src.height)
    new_w = max(1, round(src.width * scale))
    new_h = max(1, round(src.height * scale))
    resized = src.resize((new_w, new_h), Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", (target_w, target_h), LETTERBOX_RGB)
    x = (target_w - new_w) // 2
    y = (target_h - new_h) // 2
    canvas.paste(resized, (x, y))
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("-o", "--output-dir", type=Path, required=True)
    parser.add_argument(
        "--device",
        choices=("iphone-6.5", "ipad-13-portrait", "ipad-13-landscape"),
        required=True,
    )
    args = parser.parse_args()

    if args.device == "iphone-6.5":
        target = IPHONE_PORTRAIT
    elif args.device == "ipad-13-portrait":
        target = IPAD_PORTRAIT
    else:
        target = IPAD_LANDSCAPE

    args.output_dir.mkdir(parents=True, exist_ok=True)

    for i, path in enumerate(args.inputs, start=1):
        img = Image.open(path)
        out = fit_letterbox(img, *target)
        stem = path.stem.split("-")[0] if path.stem else path.name
        name = f"{i:02d}-{stem}-{target[0]}x{target[1]}.png"
        out_path = args.output_dir / name
        out.save(out_path, format="PNG", optimize=True)
        print(f"{path.name} ({img.width}x{img.height}) -> {out_path} ({target[0]}x{target[1]})")


if __name__ == "__main__":
    main()
