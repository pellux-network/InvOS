"""Render a decoded CraftOS terminal frame to a PNG.

The goal is that a rendered frame is indistinguishable from what the same
computer shows in Minecraft, so nothing here is approximated:

* Glyphs come from ``hdfont.bmp``, the font atlas CraftOS-PC itself draws with,
  blitted from the same 16x22 cell grid at the same 12x18 glyph size.
* Colours come from the palette carried in each terminal packet, so the palette
  InvOS installs through `app/theme.lua` is what gets drawn. Rendering against
  ComputerCraft's default sixteen would show colours the running program has
  explicitly replaced.
* Background is filled per cell before the glyph is drawn, which is what makes
  InvOS's background-filled cells -- the only structure the CC font can express,
  since it has no box-drawing characters -- come out looking like structure.

The emulator's own ``term.screenshot()`` is not usable here: it reports success
but writes nothing and then hangs when no GUI renderer is attached, which is
exactly the headless case this harness exists to serve.
"""

import os

import png as pnglib
from rawterm import (CELL_PITCH_X, CELL_PITCH_Y, FONT_COLUMNS, GLYPH_HEIGHT,
                     GLYPH_INSET, GLYPH_WIDTH)

# CraftOS-PC leaves a border around the terminal grid, in the colour of the cell
# nearest each edge. Matching it keeps rendered frames the same shape as the
# emulator's own window rather than cropping tight to the text.
DEFAULT_MARGIN = 4


class Font(object):
    """The CraftOS font atlas, decoded into per-character alpha masks."""

    def __init__(self, path):
        self.path = path
        width, height, rows = pnglib.read_bmp(path)
        if width < FONT_COLUMNS * CELL_PITCH_X:
            raise ValueError("font atlas %s is too small: %dpx wide" % (path, width))
        self.masks = {}
        for code in range(256):
            column = code % FONT_COLUMNS
            row = code // FONT_COLUMNS
            x0 = column * CELL_PITCH_X + GLYPH_INSET
            y0 = row * CELL_PITCH_Y + GLYPH_INSET
            if y0 + GLYPH_HEIGHT > height:
                self.masks[code] = None
                continue
            mask = []
            for dy in range(GLYPH_HEIGHT):
                source = rows[y0 + dy]
                mask.append([source[x0 + dx][3] >= 128 for dx in range(GLYPH_WIDTH)])
            self.masks[code] = mask

    def mask_for(self, code):
        return self.masks.get(code & 0xFF)


def find_font(search_roots):
    """Locate ``hdfont.bmp`` under any of ``search_roots``."""
    for root in search_roots:
        if not root:
            continue
        candidate = os.path.join(root, "hdfont.bmp")
        if os.path.isfile(candidate):
            return candidate
        for base, _dirs, files in os.walk(root):
            if "hdfont.bmp" in files:
                return os.path.join(base, "hdfont.bmp")
    raise FileNotFoundError(
        "could not find hdfont.bmp in: %s" % ", ".join(str(r) for r in search_roots))


def render_screen(screen, font, path, margin=DEFAULT_MARGIN, scale=1):
    """Render ``screen`` to a PNG at ``path``, returning (width, height)."""
    cell_w, cell_h = GLYPH_WIDTH, GLYPH_HEIGHT
    inner_w = screen.width * cell_w
    inner_h = screen.height * cell_h
    out_w = inner_w + margin * 2
    out_h = inner_h + margin * 2

    palette = screen.palette
    buffer = bytearray(out_w * out_h * 3)

    def put(x, y, colour):
        if 0 <= x < out_w and 0 <= y < out_h:
            offset = (y * out_w + x) * 3
            buffer[offset:offset + 3] = bytes(colour)

    for cy in range(screen.height):
        for cx in range(screen.width):
            background = palette[screen.background_at(cx, cy)]
            foreground = palette[screen.foreground_at(cx, cy)]
            base_x = margin + cx * cell_w
            base_y = margin + cy * cell_h

            for dy in range(cell_h):
                row_offset = ((base_y + dy) * out_w + base_x) * 3
                buffer[row_offset:row_offset + cell_w * 3] = bytes(background) * cell_w

            mask = font.mask_for(screen.char_at(cx, cy))
            if mask is None:
                continue
            for dy in range(cell_h):
                mask_row = mask[dy]
                for dx in range(cell_w):
                    if mask_row[dx]:
                        put(base_x + dx, base_y + dy, foreground)

    # The border takes the *background* colour of the nearest cell. Copying the
    # rendered pixel instead would drag glyph ink out into the margin, smearing
    # the top and bottom rows of text -- which is not what the emulator draws.
    for y in range(out_h):
        cell_y = min(max((y - margin) // cell_h, 0), screen.height - 1)
        for x in range(out_w):
            if margin <= x < margin + inner_w and margin <= y < margin + inner_h:
                continue
            cell_x = min(max((x - margin) // cell_w, 0), screen.width - 1)
            put(x, y, palette[screen.background_at(cell_x, cell_y)])

    if scale > 1:
        buffer, out_w, out_h = _scale(buffer, out_w, out_h, scale)

    pnglib.write_png(path, out_w, out_h, bytes(buffer))
    return out_w, out_h


def _scale(buffer, width, height, factor):
    """Nearest-neighbour upscale, which is how Minecraft magnifies the terminal."""
    out_w, out_h = width * factor, height * factor
    out = bytearray(out_w * out_h * 3)
    for y in range(out_h):
        src_row = (y // factor) * width
        for x in range(out_w):
            src = (src_row + x // factor) * 3
            dst = (y * out_w + x) * 3
            out[dst:dst + 3] = buffer[src:src + 3]
    return out, out_w, out_h
