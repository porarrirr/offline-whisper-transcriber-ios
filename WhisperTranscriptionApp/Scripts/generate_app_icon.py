#!/usr/bin/env python3
"""Generate the light, dark, and tinted iOS app icon masters.

The checked-in masters are generated with image v2. This script remains as a
small validation helper and intentionally does not overwrite the generated
artwork.
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
SIZE = 1024

VARIANTS = {
    "AppIcon.png": ((0xF4, 0xF8, 0xF7), (0x0B, 0x6B, 0x57)),
    "AppIcon-Dark.png": ((0x05, 0x0B, 0x12), (0x42, 0xE8, 0xB6)),
    "AppIcon-Tinted.png": ((0x12, 0x12, 0x12), (0xE8, 0xE8, 0xE8)),
}


def main() -> None:
    for filename in VARIANTS:
        path = ICONSET / filename
        with Image.open(path) as image:
            if image.size != (SIZE, SIZE):
                raise ValueError(f"{path} must be {SIZE}x{SIZE}, got {image.size}")
        print(f"Validated {filename} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
