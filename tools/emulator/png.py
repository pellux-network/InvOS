"""Minimal PNG encoding and BMP decoding.

Pillow is not a dependency of this repository and installing one for a developer
tool that writes a single flat RGB image would be a poor trade. Both formats are
used here in exactly one shape -- 32bpp BITFIELDS BMP in, 8-bit RGB PNG out --
so the handful of bytes each needs are spelled out directly.
"""

import struct
import zlib


def write_png(path, width, height, pixels):
    """Write 8-bit RGB PNG. ``pixels`` is a bytes-like of width*height*3 bytes."""
    expected = width * height * 3
    if len(pixels) != expected:
        raise ValueError("expected %d pixel bytes, got %d" % (expected, len(pixels)))

    # Filter type 0 (None) on every scanline: the images are tiny and flat-colour,
    # so zlib alone compresses them well enough that per-line filter search is noise.
    stride = width * 3
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += pixels[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    blob = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(blob)
    return blob


def read_bmp(path):
    """Read a 32bpp BMP into ``(width, height, rows)`` with rows top-down.

    Each row is a list of ``(r, g, b, a)`` tuples. Only the uncompressed and
    BITFIELDS variants that CraftOS-PC ships its font as are supported; anything
    else raises rather than silently decoding to garbage.
    """
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:2] != b"BM":
        raise ValueError("not a BMP file: %s" % path)

    pixel_offset = struct.unpack("<I", data[10:14])[0]
    width, height = struct.unpack("<ii", data[18:26])
    bits = struct.unpack("<H", data[28:30])[0]
    compression = struct.unpack("<I", data[30:34])[0]
    if bits != 32 or compression not in (0, 3):
        raise ValueError("unsupported BMP: %d bpp, compression %d" % (bits, compression))

    # A negative height means the rows are already stored top-down.
    top_down = height < 0
    height = abs(height)

    rows = []
    stride = width * 4
    for y in range(height):
        start = pixel_offset + y * stride
        line = data[start:start + stride]
        row = [(line[x * 4 + 2], line[x * 4 + 1], line[x * 4], line[x * 4 + 3])
               for x in range(width)]
        rows.append(row)
    if not top_down:
        rows.reverse()
    return width, height, rows
