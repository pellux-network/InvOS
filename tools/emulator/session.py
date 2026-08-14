"""Drive a CraftOS-PC computer from the host and read its screen.

This is the piece that makes an emulated InvOS controller usable from a script:
it installs the working tree onto an emulated computer, starts CraftOS-PC in raw
mode, and exposes the running terminal as something you can assert against, wait
on, type into and click.

Two design choices are deliberate.

**The install list comes from `storage/deployment_manifest.lua`, not from a glob.**
The manifest is the repository's runtime allow-list, so booting from it means the
emulator exercises exactly the file set a real deployment would produce. A module
that someone forgot to add to the manifest fails to boot here rather than in
Minecraft, which turns the manifest from a checklist into something a test proves.

**Data lives in a scratch directory that is rebuilt per run.** `storage/data/` on
a live computer holds config, aliases, metadata and possibly an active journal;
AGENTS.md is emphatic that host tooling must never read or write a live tree, and
a per-run scratch copy makes it impossible for this harness to try.
"""

import os
import re
import shutil
import subprocess
import threading
import time
import queue

import rawterm
import render

DEFAULT_BOOT_TIMEOUT = 30.0


class EmulatorError(Exception):
    """The emulator could not be started, or died while being driven."""


class Timeout(EmulatorError):
    """A wait_for condition never became true."""


def manifest_files(manifest_path):
    """Parse the deployment manifest's file list.

    The manifest is Lua, but its shape is a flat list of quoted paths, so a
    regex reads it without needing a Lua interpreter on the host. Anything that
    stops matching should fail loudly rather than silently install fewer files,
    hence the sanity check on the count.
    """
    with open(manifest_path, "r", encoding="utf-8") as handle:
        source = handle.read()
    files = re.findall(r'"([^"]+\.lua)"', source)
    if len(files) < 10:
        raise EmulatorError(
            "parsed only %d files from %s; the manifest format may have changed"
            % (len(files), manifest_path))
    return files


class Installation(object):
    """A computer directory built from the repository's deployment manifest."""

    def __init__(self, controller_root, computer_dir):
        self.controller_root = os.path.abspath(controller_root)
        self.computer_dir = os.path.abspath(computer_dir)

    def install(self, extra_files=None):
        manifest = os.path.join(self.controller_root, "storage", "deployment_manifest.lua")
        files = manifest_files(manifest)

        if os.path.isdir(self.computer_dir):
            shutil.rmtree(self.computer_dir)
        os.makedirs(self.computer_dir)

        missing = []
        for relative in files:
            source = os.path.join(self.controller_root, relative)
            if not os.path.isfile(source):
                missing.append(relative)
                continue
            destination = os.path.join(self.computer_dir, relative)
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            shutil.copyfile(source, destination)
        if missing:
            raise EmulatorError(
                "deployment manifest lists %d file(s) that do not exist: %s"
                % (len(missing), ", ".join(missing[:5])))

        os.makedirs(os.path.join(self.computer_dir, "storage", "data"), exist_ok=True)
        for name, contents in (extra_files or {}).items():
            path = os.path.join(self.computer_dir, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(contents)
        return files


class Session(object):
    """A running CraftOS-PC computer driven over raw mode."""

    def __init__(self, executable, data_dir, script=None, font_path=None,
                 computer_id=0, extra_args=None):
        self.executable = executable
        self.data_dir = os.path.abspath(data_dir)
        self.script = script
        self.font_path = font_path
        self.computer_id = computer_id
        self.extra_args = list(extra_args or [])
        self.process = None
        self.screen = None
        self.title = None
        self._queue = queue.Queue()
        self._reader = None
        self._stderr = []
        self._font = None

    # -- lifecycle ---------------------------------------------------------

    def start(self):
        command = [self.executable, "--raw", "--directory", self.data_dir,
                   "--id", str(self.computer_id)]
        if self.script:
            command += ["--script", self.script]
        command += self.extra_args

        self.process = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, bufsize=0)

        self._reader = threading.Thread(target=self._read_stdout, daemon=True)
        self._reader.start()
        threading.Thread(target=self._read_stderr, daemon=True).start()
        return self

    def _read_stdout(self):
        for line in self.process.stdout:
            text = line.decode("utf-8", "replace").strip()
            if not text.startswith((rawterm.MAGIC, rawterm.MAGIC_LARGE)):
                continue
            try:
                self._queue.put(rawterm.decode_packet(text))
            except rawterm.ProtocolError:
                # A malformed frame is worth ignoring rather than killing the
                # session: the stream resynchronises on the next packet.
                continue

    def _read_stderr(self):
        for line in self.process.stderr:
            self._stderr.append(line.decode("utf-8", "replace").rstrip())

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        # Closing the pipes matters for a suite that starts many sessions: three
        # descriptors leak per session otherwise, and Python reports them as
        # ResourceWarnings that bury real output.
        if self.process:
            for pipe in (self.process.stdin, self.process.stdout,
                         self.process.stderr):
                if pipe is not None:
                    try:
                        pipe.close()
                    except (OSError, ValueError):
                        pass
        return self

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()
        return False

    @property
    def stderr(self):
        return "\n".join(self._stderr)

    # -- reading the screen ------------------------------------------------

    def pump(self, timeout=0.2):
        """Consume pending packets, updating the current screen. Returns bool."""
        updated = False
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            try:
                packet = self._queue.get(timeout=max(remaining, 0.01))
            except queue.Empty:
                break
            if packet.type == rawterm.PACKET_TERMINAL_CONTENTS:
                # Only window 0 is the computer's own terminal; monitors arrive
                # as further windows and would otherwise overwrite it.
                if packet.window == 0:
                    self.screen = rawterm.Screen.from_payload(packet.payload)
                    updated = True
            elif packet.type == rawterm.PACKET_TERMINAL_CHANGE:
                body = packet.payload[6:].split(b"\x00")[0]
                self.title = body.decode("utf-8", "replace")
        return updated

    def wait_for(self, predicate, timeout=DEFAULT_BOOT_TIMEOUT, description=None):
        """Pump until ``predicate(screen)`` is true, or raise :class:`Timeout`."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(timeout=0.25)
            if self.screen is not None and predicate(self.screen):
                return self.screen
            if self.process.poll() is not None:
                raise EmulatorError(
                    "emulator exited with code %d while waiting for %s\n%s"
                    % (self.process.returncode, description or "a condition", self.stderr))
        raise Timeout(
            "timed out after %.1fs waiting for %s.\nLast screen:\n%s"
            % (timeout, description or "a condition",
               self.screen.text_dump() if self.screen else "(no frame received)"))

    def wait_for_text(self, needle, timeout=DEFAULT_BOOT_TIMEOUT):
        return self.wait_for(lambda s: s.contains(needle), timeout,
                             description="text %r" % needle)

    def settle(self, quiet_for=0.6, timeout=10.0):
        """Pump until no new frame arrives for ``quiet_for`` seconds.

        Screens that animate or redraw in stages would otherwise be captured
        mid-repaint, which shows up as a screenshot no player would ever see.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            if not self.pump(timeout=quiet_for):
                return self.screen
        return self.screen

    def text(self):
        return self.screen.text_dump() if self.screen else ""

    # -- driving input -----------------------------------------------------

    def _send(self, payload):
        if not self.process or self.process.poll() is not None:
            raise EmulatorError("emulator is not running")
        self.process.stdin.write((rawterm.encode_packet(payload) + "\n").encode("ascii"))
        self.process.stdin.flush()

    def press(self, key, settle=0.15):
        """Press and release a named key, e.g. ``press("enter")``.

        A printable key also emits the `char` event a real keyboard pairs with
        it. Sending the key alone is not what a keyboard does, and the
        difference is observable: InvOS arms a `suppress_char` when a digit
        selects a page, so a missing char event stays armed and silently
        swallows the next character typed.
        """
        if isinstance(key, str):
            if key not in rawterm.KEYS:
                raise ValueError("unknown key %r" % key)
            code = rawterm.KEYS[key]
            printable = rawterm.PRINTABLE_KEYS.get(key)
        else:
            code = key
            printable = None
        self._send(rawterm.key_packet(code, pressed=True))
        if printable is not None:
            self._send(rawterm.char_packet(printable))
        self._send(rawterm.key_packet(code, pressed=False))
        if settle:
            self.pump(timeout=settle)
        return self

    def type_text(self, text, settle=0.05):
        """Type a string as character events, as a player's keyboard would."""
        for character in text:
            self._send(rawterm.char_packet(character))
            if settle:
                self.pump(timeout=settle)
        return self

    def click(self, x, y, button=1, settle=0.2):
        """Click terminal cell (x, y), 1-based, as ComputerCraft reports them."""
        self._send(rawterm.mouse_packet("click", button, x, y))
        self._send(rawterm.mouse_packet("up", button, x, y))
        if settle:
            self.pump(timeout=settle)
        return self

    # -- output ------------------------------------------------------------

    def screenshot(self, path, scale=1, font_roots=()):
        if self.screen is None:
            raise EmulatorError("no frame has been received yet")
        if self._font is None:
            path_to_font = self.font_path or render.find_font(font_roots)
            self._font = render.Font(path_to_font)
        return render.render_screen(self.screen, self._font, path, scale=scale)
