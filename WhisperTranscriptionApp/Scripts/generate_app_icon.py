#!/usr/bin/env python3
"""Generate AppIcon PNGs for WhisperTranscriptionApp."""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

BG = (0x1A, 0x1A, 0x2E)
ACCENT = (0x00, 0xD4, 0xAA)

# idiom, size label, point size, scale, filename
ICON_SPECS = [
    ("iphone", "20x20", 20, 2, "AppIcon-20@2x.png"),
    ("iphone", "20x20", 20, 3, "AppIcon-20@3x.png"),
    ("iphone", "29x29", 29, 2, "AppIcon-29@2x.png"),
    ("iphone", "29x29", 29, 3, "AppIcon-29@3x.png"),
    ("iphone", "40x40", 40, 2, "AppIcon-40@2x.png"),
    ("iphone", "40x40", 40, 3, "AppIcon-40@3x.png"),
    ("iphone", "60x60", 60, 2, "AppIcon-60@2x.png"),
    ("iphone", "60x60", 60, 3, "AppIcon-60@3x.png"),
    ("ipad", "20x20", 20, 1, "AppIcon-20~ipad.png"),
    ("ipad", "20x20", 20, 2, "AppIcon-20@2x~ipad.png"),
    ("ipad", "29x29", 29, 1, "AppIcon-29~ipad.png"),
    ("ipad", "29x29", 29, 2, "AppIcon-29@2x~ipad.png"),
    ("ipad", "40x40", 40, 1, "AppIcon-40~ipad.png"),
    ("ipad", "40x40", 40, 2, "AppIcon-40@2x~ipad.png"),
    ("ipad", "76x76", 76, 1, "AppIcon-76.png"),
    ("ipad", "76x76", 76, 2, "AppIcon-76@2x.png"),
    ("ipad", "83.5x83.5", 83.5, 2, "AppIcon-83.5@2x.png"),
    ("ios-marketing", "1024x1024", 1024, 1, "AppIcon-1024.png"),
]


def draw_icon(size: int) -> Image.Image:
    img = Image.new("RGB", (size, size), BG)
    draw = ImageDraw.Draw(img)

    margin = size * 0.22
    bar_count = 5
    gap = size * 0.04
    total_width = size - margin * 2
    bar_width = (total_width - gap * (bar_count - 1)) / bar_count
    heights = [0.35, 0.55, 0.85, 0.5, 0.7]
    x = margin

    for height_ratio in heights:
        bar_height = (size - margin * 2) * height_ratio
        top = size - margin - bar_height
        draw.rounded_rectangle(
            [x, top, x + bar_width, size - margin],
            radius=max(2, int(bar_width * 0.35)),
            fill=ACCENT,
        )
        x += bar_width + gap

    return img


def main() -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)

    for _idiom, _label, point, scale, filename in ICON_SPECS:
        pixel = int(point * scale)
        icon = draw_icon(pixel)
        icon.save(ICONSET / filename, format="PNG")
        print(f"Wrote {filename} ({pixel}x{pixel})")


if __name__ == "__main__":
    main()
