"""Tests for the CraftOS-PC raw mode codec.

The golden packets here were captured from a real ``craftos --raw`` run rather
than produced by this codec, so a decoder that is self-consistently wrong still
fails. That distinction has already earned its keep in this repository: a test
double more permissive than the real thing hides integration bugs.
"""

import unittest

import rawterm


# Captured from `craftos --raw --script t3.lua` on CraftOS-PC v2.8.3.
GOLDEN_TITLE = (
    "!CPC0034BAAAADMAEwBDcmFmdE9TIFRlcm1pbmFsOiBDb21wdXRlciAwAA==8b66ce16")


class FramingTests(unittest.TestCase):
    def test_decodes_a_captured_title_packet(self):
        packet = rawterm.decode_packet(GOLDEN_TITLE)
        self.assertEqual(packet.type, rawterm.PACKET_TERMINAL_CHANGE)
        self.assertEqual(packet.window, 0)

    def test_rejects_a_corrupted_checksum(self):
        corrupt = GOLDEN_TITLE[:-8] + "deadbeef"
        with self.assertRaises(rawterm.ChecksumError):
            rawterm.decode_packet(corrupt)

    def test_rejects_a_wrong_magic(self):
        with self.assertRaises(rawterm.ProtocolError):
            rawterm.decode_packet("!XXX0004AAAA0000abcd1234")

    def test_frames_round_trip_through_encode(self):
        payload = b"\x01\x00\x41\x08"
        line = rawterm.encode_packet(payload)
        self.assertTrue(line.startswith("!CPC"))
        self.assertEqual(rawterm.decode_packet(line.strip()).payload, payload)

    def test_reader_ignores_non_packet_noise_between_packets(self):
        stream = ["some emulator warning on stdout", GOLDEN_TITLE, "", "another line"]
        packets = list(rawterm.read_packets(stream))
        self.assertEqual([p.type for p in packets], [rawterm.PACKET_TERMINAL_CHANGE])


class RunLengthTests(unittest.TestCase):
    def test_decodes_pairs_of_value_and_count(self):
        self.assertEqual(rawterm.rle_decode(b"\x41\x03\x42\x01", 4), b"AAAB")

    def test_stops_at_the_expected_length(self):
        # A trailing run that would overshoot is truncated, not allowed to grow
        # the buffer past width*height and desynchronise every later field.
        self.assertEqual(rawterm.rle_decode(b"\x41\xff", 3), b"AAA")

    def test_reports_how_many_bytes_it_consumed(self):
        data, used = rawterm.rle_decode_with_length(b"\x41\x02\x42\x02\x99\x01", 4)
        self.assertEqual(data, b"AABB")
        self.assertEqual(used, 4)


class ScreenTests(unittest.TestCase):
    """Decoding of a full terminal-contents packet built to the documented layout."""

    def _terminal_packet(self, width, height, text, colours, cursor=(0, 0)):
        import struct
        body = struct.pack(
            "<BBBBHHHHB3x", rawterm.PACKET_TERMINAL_CONTENTS, 0, 0, 0,
            width, height, cursor[0], cursor[1], 0)
        body += bytes(bytearray(text))
        body += bytes(bytearray(colours))
        body += bytes(48)
        return body

    def test_reads_dimensions_and_text(self):
        text = b"".join(bytes((ord(c), 1)) for c in "AB")
        colours = bytes((0x0F, 2))
        packet = self._terminal_packet(2, 1, text, colours)
        screen = rawterm.Screen.from_payload(packet)
        self.assertEqual((screen.width, screen.height), (2, 1))
        self.assertEqual(screen.lines(), ["AB"])

    def test_splits_colour_bytes_into_background_and_foreground(self):
        text = bytes((ord("X"), 1))
        colours = bytes((0x3E, 1))  # high nybble background, low nybble foreground
        screen = rawterm.Screen.from_payload(self._terminal_packet(1, 1, text, colours))
        self.assertEqual(screen.background_at(0, 0), 3)
        self.assertEqual(screen.foreground_at(0, 0), 0xE)

    def test_exposes_the_cursor_position(self):
        text = bytes((32, 4))
        colours = bytes((0, 4))
        screen = rawterm.Screen.from_payload(
            self._terminal_packet(2, 2, text, colours, cursor=(1, 1)))
        self.assertEqual(screen.cursor, (1, 1))


class InputEncodingTests(unittest.TestCase):
    def test_encodes_a_key_press_with_the_documented_flags(self):
        payload = rawterm.key_packet(rawterm.KEYS["enter"], pressed=True)
        self.assertEqual(payload[0], rawterm.PACKET_KEY_EVENT)
        self.assertEqual(payload[2], rawterm.KEYS["enter"])
        self.assertEqual(payload[3] & 0x01, 0)  # bit 0 clear = key down

    def test_encodes_a_key_release(self):
        payload = rawterm.key_packet(rawterm.KEYS["enter"], pressed=False)
        self.assertEqual(payload[3] & 0x01, 1)

    def test_encodes_a_typed_character_in_character_mode(self):
        payload = rawterm.char_packet("q")
        self.assertEqual(payload[2], ord("q"))
        self.assertEqual(payload[3] & 0x08, 0x08)

    def test_encodes_a_mouse_click_with_32_bit_coordinates(self):
        import struct
        payload = rawterm.mouse_packet("click", button=1, x=40, y=12)
        self.assertEqual(payload[0], rawterm.PACKET_MOUSE_EVENT)
        self.assertEqual(payload[2], 0)
        self.assertEqual(struct.unpack("<I", payload[4:8])[0], 40)
        self.assertEqual(struct.unpack("<I", payload[8:12])[0], 12)

    def test_rejects_an_unknown_mouse_event(self):
        with self.assertRaises(ValueError):
            rawterm.mouse_packet("teleport", button=1, x=1, y=1)


class PrintableKeyTests(unittest.TestCase):
    """A driver must reproduce the key+char pairing a real keyboard produces."""

    def test_digits_and_letters_are_printable(self):
        self.assertEqual(rawterm.PRINTABLE_KEYS["one"], "1")
        self.assertEqual(rawterm.PRINTABLE_KEYS["q"], "q")

    def test_navigation_keys_are_not_printable(self):
        # These must NOT emit a char event; doing so would insert stray
        # characters into a search box every time a test moved the selection.
        for name in ("enter", "up", "down", "left", "right", "delete", "f10"):
            self.assertNotIn(name, rawterm.PRINTABLE_KEYS)

    def test_every_printable_key_is_a_real_key(self):
        for name in rawterm.PRINTABLE_KEYS:
            self.assertIn(name, rawterm.KEYS,
                          "%r is printable but not a known key" % name)


if __name__ == "__main__":
    unittest.main()
