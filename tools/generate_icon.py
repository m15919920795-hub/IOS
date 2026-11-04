#!/usr/bin/env python3
"""Generate a small code-native camera icon without external assets or dependencies."""
from pathlib import Path
import struct
import zlib

size = 1024
rows = bytearray()
for y in range(size):
    rows.append(0)
    for x in range(size):
        t = (x + y) / 2046
        color = (int(9 + 8 * t), int(76 + 75 * t), int(105 + 78 * t))
        # Viewfinder corners and a centered lens, all drawn with simple geometry.
        corner = any(
            ((cx <= x < cx + 150 and cy <= y < cy + 28) or
             (cx <= x < cx + 28 and cy <= y < cy + 150))
            for cx, cy in [(230, 245)]
        )
        corner |= (644 <= x < 794 and 245 <= y < 273) or (766 <= x < 794 and 245 <= y < 395)
        corner |= (230 <= x < 380 and 751 <= y < 779) or (230 <= x < 258 and 629 <= y < 779)
        corner |= (644 <= x < 794 and 751 <= y < 779) or (766 <= x < 794 and 629 <= y < 779)
        radius = (x - 512) ** 2 + (y - 512) ** 2
        if corner or 155 ** 2 <= radius <= 190 ** 2:
            color = (238, 251, 255)
        elif radius <= 85 ** 2:
            color = (76, 222, 204)
        rows.extend(color)

def chunk(kind, body):
    return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)

output = Path(__file__).resolve().parents[1] / 'GXCameraViewer/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
output.write_bytes(png + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b''))
print(output)
