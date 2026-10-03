"""Create an opaque 1024px Hermes app icon using only Python's standard library."""

import math
import struct
import sys
import zlib

SIZE = 1024
GOLD = (219, 191, 128)


def segment_distance(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def coverage(distance, half_width):
    return max(0.0, min(1.0, (half_width + 0.0015 - distance) / 0.003))


vertices = [
    (0.49 * math.cos(math.pi / 6 + i * math.pi / 3),
     0.49 * math.sin(math.pi / 6 + i * math.pi / 3))
    for i in range(6)
]
lines = list(zip(vertices, vertices[1:] + vertices[:1]))
lines += [
    ((-0.235, -0.23), (-0.235, 0.23)),
    ((0.235, -0.23), (0.235, 0.23)),
    ((-0.235, 0), (0.235, 0)),
]


def chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data +
            struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))


rows = bytearray()
for y in range(SIZE):
    rows.append(0)
    py = (SIZE / 2 - y - 0.5) / (SIZE / 2)
    for x in range(SIZE):
        px = (x + 0.5 - SIZE / 2) / (SIZE / 2)
        radial = max(0, 1 - math.hypot(px, py))
        background = (int(14 + 8 * radial), int(17 + 9 * radial), int(22 + 10 * radial))
        ring = coverage(abs(math.hypot(px, py) - 0.70), 0.007) * 0.33
        symbol = max(
            coverage(segment_distance(px, py, *a, *b), 0.022 if i < 6 else 0.029)
            for i, (a, b) in enumerate(lines)
        )
        strength = max(ring, symbol)
        rows.extend(int(background[i] * (1 - strength) + GOLD[i] * strength) for i in range(3))

png = bytearray(b"\x89PNG\r\n\x1a\n")
png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
png += chunk(b"IEND", b"")
with open(sys.argv[1], "wb") as output:
    output.write(png)
