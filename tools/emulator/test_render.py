"""Tests for the PNG writer, BMP reader and terminal renderer.

These are host-only: nothing here starts the emulator, so a rendering
regression is caught in a fraction of a second rather than behind a 30 second
boot. The PNG assertions decode the bytes this module wrote rather than
trusting a viewer, because "opens in my image viewer" is a much weaker claim
than "every chunk CRC checks out".
"""

import os
import struct
import tempfile
import unittest
import zlib

import png as pnglib
import provision
import rawterm
import render

FONT_ATLAS = provision.Provisioner().font_path()
HAVE_FONT = FONT_ATLAS is not None

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def iter_chunks(blob):
    """Yield ``(tag, data)`` for each chunk, raising if a CRC does not match."""
    offset = len(PNG_SIGNATURE)
    while offset < len(blob):
        length = struct.unpack(">I", blob[offset:offset + 4])[0]
        tag = blob[offset + 4:offset + 8]
        data = blob[offset + 8:offset + 8 + length]
        stored = struct.unpack(">I", blob[offset + 8 + length:offset + 12 + length])[0]
        if zlib.crc32(tag + data) != stored:
            raise AssertionError("CRC mismatch on chunk %r" % tag)
        yield tag, data
        offset += 12 + length


def decode_png(path):
    """Decode a PNG this module wrote back into ``(width, height, pixels)``."""
    with open(path, "rb") as handle:
        blob = handle.read()
    assert blob[:8] == PNG_SIGNATURE
    width = height = None
    compressed = b""
    for tag, data in iter_chunks(blob):
        if tag == b"IHDR":
            width, height = struct.unpack(">II", data[:8])
        elif tag == b"IDAT":
            compressed += data
    raw = zlib.decompress(compressed)
    stride = width * 3
    pixels = bytearray()
    for y in range(height):
        line = raw[y * (stride + 1):(y + 1) * (stride + 1)]
        assert line[0] == 0, "expected filter type 0 on scanline %d" % y
        pixels += line[1:]
    return width, height, bytes(pixels)


def pixel_at(pixels, width, x, y):
    offset = (y * width + x) * 3
    return tuple(pixels[offset:offset + 3])


class WritePngTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.path = os.path.join(self.tempdir.name, "out.png")

    def test_writes_a_signature_and_matching_ihdr_dimensions(self):
        blob = pnglib.write_png(self.path, 3, 2, bytes(3 * 2 * 3))
        self.assertEqual(blob[:8], PNG_SIGNATURE)
        chunks = dict(iter_chunks(blob))  # iterating validates every chunk CRC
        self.assertEqual(struct.unpack(">II", chunks[b"IHDR"][:8]), (3, 2))
        # 8-bit colour type 2 (truecolour); anything else and the pixel data
        # below would be interpreted with the wrong stride by a real decoder.
        self.assertEqual(tuple(chunks[b"IHDR"][8:13]), (8, 2, 0, 0, 0))

    def test_idat_expands_to_unfiltered_scanlines(self):
        # Every scanline must carry filter byte 0, because the writer never
        # computes filters -- a stray non-zero byte would mean the compressor
        # was handed data at the wrong offset.
        width, height = 5, 4
        pnglib.write_png(self.path, width, height, bytes(width * height * 3))
        with open(self.path, "rb") as handle:
            blob = handle.read()
        raw = zlib.decompress(b"".join(d for t, d in iter_chunks(blob) if t == b"IDAT"))
        self.assertEqual(len(raw), height * (1 + width * 3))
        self.assertEqual(set(raw[y * (1 + width * 3)] for y in range(height)), {0})

    def test_round_trips_the_pixels_it_was_given(self):
        pixels = bytes(range(2 * 2 * 3))
        pnglib.write_png(self.path, 2, 2, pixels)
        self.assertEqual(decode_png(self.path), (2, 2, pixels))

    def test_rejects_a_pixel_buffer_of_the_wrong_length(self):
        with self.assertRaises(ValueError):
            pnglib.write_png(self.path, 4, 4, bytes(4 * 4 * 3 - 1))


@unittest.skipUnless(HAVE_FONT, "CraftOS font atlas is not unpacked here")
class ReadBmpTests(unittest.TestCase):
    def test_reads_the_shipped_font_atlas_dimensions(self):
        width, height, rows = pnglib.read_bmp(FONT_ATLAS)
        self.assertEqual((width, height), (512, 512))
        self.assertEqual(len(rows), 512)
        self.assertEqual(len(rows[0]), 512)


@unittest.skipUnless(HAVE_FONT, "CraftOS font atlas is not unpacked here")
class FontGeometryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.font = render.Font(FONT_ATLAS)

    def test_a_printable_glyph_has_ink_and_space_has_none(self):
        # This is the check that proves the 16x22 cell pitch and 2px inset are
        # right: if the grid were off by even one row or column, 'A' would pick
        # up part of a neighbouring cell and ' ' would stop being empty.
        letter = self.font.mask_for(ord("A"))
        blank = self.font.mask_for(ord(" "))
        self.assertTrue(any(any(row) for row in letter))
        self.assertFalse(any(any(row) for row in blank))

    def test_masks_are_the_declared_glyph_size(self):
        mask = self.font.mask_for(ord("A"))
        self.assertEqual(len(mask), rawterm.GLYPH_HEIGHT)
        self.assertEqual(len(mask[0]), rawterm.GLYPH_WIDTH)


def make_screen(width, height, text, colours, palette=None, cursor=(0, 0)):
    """Build a Screen directly, bypassing the wire format the renderer never sees."""
    if palette is None:
        palette = [(i * 16, i * 8, 255 - i * 16) for i in range(16)]
    return rawterm.Screen(width, height, bytes(text), bytes(colours),
                          palette, cursor, False)


class StubFont(object):
    """A font whose only glyph is a solid block, so ink is trivial to locate."""

    def __init__(self, inked_codes=()):
        self.inked = set(inked_codes)

    def mask_for(self, code):
        if code & 0xFF not in self.inked:
            return None
        return [[True] * rawterm.GLYPH_WIDTH for _ in range(rawterm.GLYPH_HEIGHT)]


class RenderScreenTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.path = os.path.join(self.tempdir.name, "frame.png")

    def test_output_size_is_the_grid_plus_two_margins(self):
        screen = make_screen(4, 3, b" " * 12, bytes(12))
        size = render.render_screen(screen, StubFont(), self.path, margin=4)
        expected = (4 * rawterm.GLYPH_WIDTH + 8, 3 * rawterm.GLYPH_HEIGHT + 8)
        self.assertEqual(size, expected)
        self.assertEqual(decode_png(self.path)[:2], expected)

    def test_a_cell_is_filled_with_its_background_palette_colour(self):
        # The renderer must use the palette carried by the frame, not
        # ComputerCraft's defaults, since InvOS repaints the palette at boot.
        palette = [(0, 0, 0)] * 16
        palette[5] = (10, 200, 30)
        # Two cells: the second has background index 5 (high nybble).
        screen = make_screen(2, 1, b"  ", bytes((0x00, 0x50)), palette=palette)
        render.render_screen(screen, StubFont(), self.path, margin=2)
        width, _height, pixels = decode_png(self.path)
        centre_x = 2 + rawterm.GLYPH_WIDTH + rawterm.GLYPH_WIDTH // 2
        centre_y = 2 + rawterm.GLYPH_HEIGHT // 2
        self.assertEqual(pixel_at(pixels, width, centre_x, centre_y), (10, 200, 30))
        # The first cell keeps index 0, so the two cells must not be identical.
        self.assertEqual(
            pixel_at(pixels, width, 2 + rawterm.GLYPH_WIDTH // 2, centre_y), (0, 0, 0))

    def test_glyph_ink_is_drawn_in_the_foreground_colour(self):
        palette = [(0, 0, 0)] * 16
        palette[1] = (255, 255, 255)
        # Background index 0, foreground index 1, and the stub inks 'X' solid.
        screen = make_screen(1, 1, b"X", bytes((0x01,)), palette=palette)
        render.render_screen(screen, StubFont([ord("X")]), self.path, margin=1)
        width, _height, pixels = decode_png(self.path)
        self.assertEqual(pixel_at(pixels, width, 1 + rawterm.GLYPH_WIDTH // 2,
                                  1 + rawterm.GLYPH_HEIGHT // 2), (255, 255, 255))

    def test_margin_takes_the_background_of_the_nearest_cell(self):
        palette = [(0, 0, 0)] * 16
        palette[7] = (9, 9, 200)
        screen = make_screen(1, 1, b"X", bytes((0x70,)), palette=palette)
        render.render_screen(screen, StubFont([ord("X")]), self.path, margin=3)
        width, _height, pixels = decode_png(self.path)
        # Corner pixel: outside the grid entirely, so it must be the cell's
        # background rather than glyph ink smeared outwards.
        self.assertEqual(pixel_at(pixels, width, 0, 0), (9, 9, 200))

    def test_scale_two_doubles_both_dimensions(self):
        screen = make_screen(2, 2, b"    ", bytes(4))
        single = render.render_screen(screen, StubFont(), self.path, margin=4)
        doubled = render.render_screen(screen, StubFont(), self.path, margin=4, scale=2)
        self.assertEqual(doubled, (single[0] * 2, single[1] * 2))
        self.assertEqual(decode_png(self.path)[:2], doubled)


if __name__ == "__main__":
    unittest.main()
