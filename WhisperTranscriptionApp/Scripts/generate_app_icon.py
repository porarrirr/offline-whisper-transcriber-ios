#!/usr/bin/env python3
"""Generate the light, dark, and tinted iOS app icon masters."""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
SIZE = 1024

VARIANTS = {
    "AppIcon.png": ((0xF4, 0xF8, 0xF7), (0x0B, 0x6B, 0x57)),
    "AppIcon-Dark.png": ((0x05, 0x0B, 0x12), (0x42, 0xE8, 0xB6)),
    "AppIcon-Tinted.png": ((0x12, 0x12, 0x12), (0xE8, 0xE8, 0xE8)),
}


def draw_icon(background: tuple[int, int, int], mark: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGB", (SIZE, SIZE), background)
    draw = ImageDraw.Draw(image)

    # Three capsules read as both an audio waveform and transcribed quotation.
    capsule_width = 164
    gap = 54
    heights = (356, 508, 356)
    total_width = capsule_width * 3 + gap * 2
    x = (SIZE - total_width) // 2

    for height in heights:
        top = (SIZE - height) // 2
        draw.rounded_rectangle(
            (x, top, x + capsule_width, top + height),
            radius=capsule_width // 2,
            fill=mark,
        )
        x += capsule_width + gap

    return image


def main() -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)

    for png in ICONSET.glob("*.png"):
        png.unlink()

    for filename, (background, mark) in VARIANTS.items():
        draw_icon(background, mark).save(ICONSET / filename, format="PNG", optimize=True)
        print(f"Wrote {filename} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
