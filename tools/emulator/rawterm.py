"""Codec for the CraftOS-PC raw mode terminal protocol.

Raw mode is how this harness sees and drives an emulated computer: the emulator
writes one framed packet per terminal update on stdout, and accepts key, mouse
and generic event packets on stdin. That makes a running CraftOS computer
inspectable without a display server, which is the only reason any of this is
viable in CI or over SSH.

Protocol reference: https://www.craftos-pc.cc/docs/rawmode

Two details matter for fidelity and are easy to get wrong:

* Colours come from the palette carried *in the packet*, not from ComputerCraft's
  default sixteen. InvOS repaints the palette through `app/theme.lua`, so a
  renderer that assumed the defaults would show colours no player would ever see.
* Multi-byte fields are little-endian, and the terminal-contents packet packs
  background into the high nybble of each colour byte and foreground into the low
  nybble -- the opposite order to how `term.blit` writes them.
"""

import base64
import binascii
import struct

MAGIC = "!CPC"
MAGIC_LARGE = "!CPD"

PACKET_TERMINAL_CONTENTS = 0
PACKET_KEY_EVENT = 1
PACKET_MOUSE_EVENT = 2
PACKET_GENERIC_EVENT = 3
PACKET_TERMINAL_CHANGE = 4
PACKET_MESSAGE = 5
PACKET_VERSION = 6

# Cell geometry of the shipped HD font atlas (hdfont.bmp), measured from the
# image rather than assumed: 16x16 grid, 16x22 pitch, 12x18 glyph inset by 2px.
FONT_COLUMNS = 16
GLYPH_WIDTH = 12
GLYPH_HEIGHT = 18
CELL_PITCH_X = 16
CELL_PITCH_Y = 22
GLYPH_INSET = 2

MOUSE_EVENTS = {"click": 0, "up": 1, "scroll": 2, "drag": 3}

# Keys that a real keyboard reports as a `char` event as well as a `key` event.
# ComputerCraft programs may rely on receiving both -- InvOS arms a
# `suppress_char` when a digit selects a page, expecting the paired char to
# arrive and be swallowed -- so a driver that sends only the key event leaves
# that state armed and eats the next character the user types.
PRINTABLE_KEYS = {
    "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
    "six": "6", "seven": "7", "eight": "8", "nine": "9", "zero": "0",
    "minus": "-", "equals": "=", "space": " ", "comma": ",", "period": ".",
    "slash": "/", "backslash": "\\", "semiColon": ";", "apostrophe": "'",
    "grave": "`", "leftBracket": "[", "rightBracket": "]", "multiply": "*",
}
for _letter in "abcdefghijklmnopqrstuvwxyz":
    PRINTABLE_KEYS[_letter] = _letter

# The ComputerCraft keys API as this runtime actually defines it, dumped from
# CraftOS-PC v2.8.3 rather than copied from CC:Tweaked's sources. CraftOS-PC uses
# the classic LWJGL codes (enter is 28, up is 200), *not* the GLFW codes that
# modern CC:Tweaked documents (where enter would be 257). That difference matters
# because the raw mode key field is a single byte, which the GLFW codes overflow.
# test_smoke.KeyTableTests re-dumps this table from the running emulator and
# fails if a future version renumbers anything.
KEYS = {
    "one": 2, "two": 3, "three": 4, "four": 5, "five": 6, "six": 7,
    "seven": 8, "eight": 9, "nine": 10, "zero": 11, "minus": 12, "equals": 13,
    "backspace": 14, "tab": 15,
    "q": 16, "w": 17, "e": 18, "r": 19, "t": 20, "y": 21, "u": 22, "i": 23,
    "o": 24, "p": 25, "leftBracket": 26, "rightBracket": 27,
    "return": 28, "enter": 28, "leftCtrl": 29,
    "a": 30, "s": 31, "d": 32, "f": 33, "g": 34, "h": 35, "j": 36, "k": 37,
    "l": 38, "semiColon": 39, "apostrophe": 40, "grave": 41, "leftShift": 42,
    "backslash": 43,
    "z": 44, "x": 45, "c": 46, "v": 47, "b": 48, "n": 49, "m": 50,
    "comma": 51, "period": 52, "slash": 53, "rightShift": 54, "multiply": 55,
    "leftAlt": 56, "space": 57, "capsLock": 58,
    "f1": 59, "f2": 60, "f3": 61, "f4": 62, "f5": 63, "f6": 64, "f7": 65,
    "f8": 66, "f9": 67, "f10": 68, "f11": 87, "f12": 88,
    "numLock": 69, "scrollLock": 70,
    "numPad7": 71, "numPad8": 72, "numPad9": 73, "numPadSubtract": 74,
    "numPad4": 75, "numPad5": 76, "numPad6": 77, "numPadAdd": 78,
    "numPad1": 79, "numPad2": 80, "numPad3": 81, "numPad0": 82,
    "numPadDecimal": 83, "numPadEnter": 156, "numPadEquals": 141,
    "numPadComma": 179, "numPadDivide": 181,
    "rightCtrl": 157, "rightAlt": 184, "pause": 197,
    "home": 199, "up": 200, "pageUp": 201, "left": 203, "right": 205,
    "end": 207, "down": 208, "pageDown": 209, "insert": 210, "delete": 211,
}


class ProtocolError(Exception):
    """A byte stream that does not conform to the raw mode protocol."""


class ChecksumError(ProtocolError):
    """A packet whose CRC-32 does not match its payload."""


class Packet(object):
    __slots__ = ("type", "window", "payload")

    def __init__(self, type, window, payload):
        self.type = type
        self.window = window
        self.payload = payload

    def __repr__(self):
        return "Packet(type=%d, window=%d, %d bytes)" % (
            self.type, self.window, len(self.payload))


def encode_packet(payload):
    """Frame a payload into a raw mode line, without the trailing newline."""
    encoded = base64.b64encode(payload).decode("ascii")
    # The checksum covers the base64 text, not the bytes it decodes to. Verified
    # against captured packets from CraftOS-PC v2.8.3; checksumming the decoded
    # payload instead produces a self-consistent stream the emulator rejects.
    checksum = binascii.crc32(encoded.encode("ascii")) & 0xFFFFFFFF
    return "%s%04X%s%08x" % (MAGIC, len(encoded), encoded, checksum)


def decode_packet(line):
    """Decode one framed raw mode line into a :class:`Packet`."""
    line = line.strip()
    magic = line[:4]
    if magic == MAGIC:
        size_width = 4
    elif magic == MAGIC_LARGE:
        size_width = 12
    else:
        raise ProtocolError("bad magic %r" % magic)

    try:
        size = int(line[4:4 + size_width], 16)
    except ValueError:
        raise ProtocolError("bad size field %r" % line[4:4 + size_width])

    start = 4 + size_width
    encoded = line[start:start + size]
    checksum_text = line[start + size:start + size + 8]
    try:
        payload = base64.b64decode(encoded)
    except binascii.Error as error:
        raise ProtocolError("bad base64 payload: %s" % error)

    try:
        expected = int(checksum_text, 16)
    except ValueError:
        raise ProtocolError("bad checksum field %r" % checksum_text)
    if (binascii.crc32(encoded.encode("ascii")) & 0xFFFFFFFF) != expected:
        raise ChecksumError("checksum mismatch on a %d byte payload" % len(payload))

    if len(payload) < 2:
        raise ProtocolError("packet shorter than its two byte header")
    return Packet(payload[0], payload[1], payload)


def read_packets(lines):
    """Yield packets from an iterable of lines, skipping anything unframed.

    The emulator writes warnings and SDL chatter to the same stream, so a reader
    that assumed every line was a packet would die on the first one.
    """
    for line in lines:
        text = line.strip() if isinstance(line, str) else line.decode("utf-8", "replace").strip()
        if not text.startswith((MAGIC, MAGIC_LARGE)):
            continue
        yield decode_packet(text)


def rle_decode(data, length):
    """Expand run-length-encoded ``data`` to exactly ``length`` bytes."""
    return rle_decode_with_length(data, length)[0]


def rle_decode_with_length(data, length):
    """Expand RLE ``data`` to ``length`` bytes, also returning bytes consumed.

    The consumed count is what lets the caller find the next field: a
    terminal-contents packet packs text, then colours, then the palette, each
    starting wherever the previous one happened to end.
    """
    out = bytearray()
    index = 0
    while len(out) < length:
        if index + 1 >= len(data):
            raise ProtocolError("run-length data ended %d bytes early"
                                % (length - len(out)))
        value = data[index]
        count = data[index + 1]
        index += 2
        # Clamp rather than extend past the declared size: a run that overshoots
        # would otherwise push every following field out of alignment.
        out += bytes((value,)) * min(count, length - len(out))
    return bytes(out), index


class Screen(object):
    """A decoded text-mode terminal frame.

    Holds exactly what the emulator drew: characters, per-cell colour indices,
    the cursor, and the sixteen live palette entries as RGB triples.
    """

    def __init__(self, width, height, text, colours, palette, cursor, blinking):
        self.width = width
        self.height = height
        self.text = text
        self.colours = colours
        self.palette = palette
        self.cursor = cursor
        self.blinking = blinking

    @classmethod
    def from_payload(cls, payload):
        if payload[0] != PACKET_TERMINAL_CONTENTS:
            raise ProtocolError("not a terminal contents packet")
        mode = payload[2]
        blinking = bool(payload[3])
        width, height = struct.unpack("<HH", payload[4:8])
        cursor_x, cursor_y = struct.unpack("<HH", payload[8:12])
        if mode != 0:
            raise ProtocolError(
                "graphics mode %d is not supported; InvOS is a text-mode application" % mode)

        cells = width * height
        body = payload[16:]
        text, used = rle_decode_with_length(body, cells)
        colours, used_colours = rle_decode_with_length(body[used:], cells)
        palette_start = used + used_colours
        palette_bytes = body[palette_start:palette_start + 48]
        if len(palette_bytes) < 48:
            raise ProtocolError("packet ended before its 16 colour palette")
        palette = [tuple(palette_bytes[i * 3:i * 3 + 3]) for i in range(16)]

        return cls(width, height, text, colours, palette,
                   (cursor_x, cursor_y), blinking)

    def background_at(self, x, y):
        return (self.colours[y * self.width + x] >> 4) & 0x0F

    def foreground_at(self, x, y):
        return self.colours[y * self.width + x] & 0x0F

    def char_at(self, x, y):
        return self.text[y * self.width + x]

    def lines(self):
        """The screen as plain strings, one per row, control bytes as spaces."""
        rows = []
        for y in range(self.height):
            row = self.text[y * self.width:(y + 1) * self.width]
            rows.append("".join(chr(b) if 32 <= b < 127 else
                                (chr(b) if b > 127 else " ") for b in row))
        return rows

    def text_dump(self):
        return "\n".join(line.rstrip() for line in self.lines())

    def contains(self, needle):
        return any(needle in line for line in self.lines())


def rle_encode(data):
    """Run-length encode as value/count byte pairs, the form the decoder expects.

    Counts are a single byte, so a run longer than 255 is split. Overshooting a
    run would push every following field out of alignment, which is why
    ``rle_decode_with_length`` clamps rather than trusts.
    """
    out = bytearray()
    index = 0
    while index < len(data):
        value = data[index]
        run = 1
        while index + run < len(data) and data[index + run] == value and run < 255:
            run += 1
        out += bytes((value, run))
        index += run
    return bytes(out)


def encode_terminal_contents(window, text, width=None, height=None):
    """Build a terminal-contents payload holding ``text``, one line per row.

    Only the tests use this -- in a real run the emulator is the only producer --
    but a decoder with no encoder cannot be exercised without booting an
    emulator, and window routing is exactly the kind of logic that should not
    need one. The layout mirrors :meth:`Screen.from_payload` field for field.
    """
    lines = text.split("\n")
    width = width or max(len(line) for line in lines)
    height = height or len(lines)

    cells = bytearray()
    for row in range(height):
        line = lines[row] if row < len(lines) else ""
        cells += line.ljust(width)[:width].encode("ascii", "replace")

    header = struct.pack("<BBBBHHHH", PACKET_TERMINAL_CONTENTS, window,
                         0,      # mode: text
                         0,      # cursor blink
                         width, height,
                         0, 0)   # cursor x, y
    header += b"\x00\x00\x00\x00"  # payload[12:16]; the decoder's body starts at 16
    colours = bytes((0x0F,)) * (width * height)  # bg high nybble, fg low nybble
    return header + rle_encode(bytes(cells)) + rle_encode(colours) + bytes(48)


def key_packet(key, pressed=True, held=False, window=0):
    """Build a key event payload. ``key`` is a ComputerCraft key code."""
    flags = 0
    if not pressed:
        flags |= 0x01
    if held:
        flags |= 0x02
    return struct.pack("<BBBB", PACKET_KEY_EVENT, window, key & 0xFF, flags)


def char_packet(character, window=0):
    """Build a typed-character event payload (flag bit 3 selects character mode)."""
    if len(character) != 1:
        raise ValueError("expected a single character, got %r" % (character,))
    return struct.pack("<BBBB", PACKET_KEY_EVENT, window,
                       ord(character) & 0xFF, 0x08)


def mouse_packet(event, button, x, y, window=0):
    """Build a mouse event payload. Coordinates are 1-based terminal cells."""
    if event not in MOUSE_EVENTS:
        raise ValueError("unknown mouse event %r; expected one of %s"
                         % (event, ", ".join(sorted(MOUSE_EVENTS))))
    return struct.pack("<BBBBII", PACKET_MOUSE_EVENT, window,
                       MOUSE_EVENTS[event], button, x, y)


# Packet type 3 (generic events) is deliberately not implemented. It carries
# Lua values in a bespoke binary serialisation, and nothing in this harness needs
# to raise arbitrary events yet -- an unverified encoder would be worse than none.
