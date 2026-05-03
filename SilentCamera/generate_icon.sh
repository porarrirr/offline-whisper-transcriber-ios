#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_DIR="$SCRIPT_DIR/SilentCamera/Assets.xcassets/AppIcon.appiconset"

echo "=== アプリアイコン生成 ==="

# Pythonの確認
if ! command -v python3 &> /dev/null; then
    echo "エラー: python3 が見つかりません"
    exit 1
fi

python3 << 'PYTHON_SCRIPT'
import struct
import zlib
import os

def create_png(width, height, color_rgb):
    def chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    header = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))

    raw = b''
    camera_color = (40, 40, 40)
    lens_color = (100, 100, 100)
    center_x, center_y = width // 2, height // 2
    radius = int(min(width, height) * 0.3)
    lens_radius = int(radius * 0.4)

    for y in range(height):
        raw += b'\x00'
        for x in range(width):
            dx = x - center_x
            dy = y - center_y
            dist = (dx*dx + dy*dy) ** 0.5

            if dist < lens_radius:
                raw += bytes([60, 130, 240])
            elif dist < radius:
                raw += bytes(camera_color)
            else:
                r = int(color_rgb[0] * (1 - dist/(width*0.7)) + 20 * (dist/(width*0.7)))
                g = int(color_rgb[1] * (1 - dist/(width*0.7)) + 20 * (dist/(width*0.7)))
                b = int(color_rgb[2] * (1 - dist/(width*0.7)) + 20 * (dist/(width*0.7)))
                raw += bytes([
                    max(0, min(255, r)),
                    max(0, min(255, g)),
                    max(0, min(255, b))
                ])

    compressed = zlib.compress(raw)
    idat = chunk(b'IDAT', compressed)
    iend = chunk(b'IEND', b'')

    return header + ihdr + idat + iend

color = (34, 34, 34)
output_dir = os.environ.get('ICON_DIR', '.')
png_data = create_png(1024, 1024, color)

output_path = os.path.join(output_dir, 'icon.png')
with open(output_path, 'wb') as f:
    f.write(png_data)

print(f"アイコンを生成しました: {output_path}")
PYTHON_SCRIPT

# Contents.json の更新
cat > "$ICON_DIR/Contents.json" << 'EOF'
{
  "images" : [
    {
      "filename" : "icon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

echo "=== 完了 ==="
