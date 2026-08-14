"""Locate or fetch a CraftOS-PC build for the harness to drive.

Nothing here installs into the system. The archive is downloaded once into a
cache directory and extracted, so the emulator can be provisioned on a fresh
machine or CI runner without root and without changing the developer's
environment. An already-installed `craftos` on PATH wins over downloading.

Two archive shapes are supported: the Linux AppImage (used headlessly, e.g.
in CI) and the Windows portable zip (used for `--raw` automation and, via
``gui_executable``, the interactive GUI build described in
docs/emulator.md). Both are official releases from the craftos2 GitHub repo,
matched by ``CRAFTOS_VERSION`` so the two platforms stay on the same build.
"""

import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile

CRAFTOS_VERSION = "v2.8.3"
RELEASE_BASE = ("https://github.com/MCJack123/craftos2/releases/download/%s"
                 % CRAFTOS_VERSION)
APPIMAGE_URL = "%s/CraftOS-PC.x86_64.AppImage" % RELEASE_BASE
WINDOWS_ZIP_URL = "%s/CraftOS-PC-Portable-Win64.zip" % RELEASE_BASE

IS_WINDOWS = sys.platform == "win32"

# AppImage runtime dependencies that are not part of a minimal Ubuntu install.
# They are reported rather than installed: this tool has no business running
# apt on a developer's machine. The Windows portable zip bundles every DLL it
# needs, so there is nothing equivalent to check there.
SHARED_LIBRARIES = ("libpulse.so.0", "libXss.so.1")


def default_cache_dir():
    if IS_WINDOWS:
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~\\AppData\\Local")
        return os.path.join(base, "invos-emulator")
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "invos-emulator")


class Provisioner(object):
    def __init__(self, cache_dir=None, url=None):
        self.cache_dir = cache_dir or default_cache_dir()
        self.url = url or (WINDOWS_ZIP_URL if IS_WINDOWS else APPIMAGE_URL)

    @property
    def archive_path(self):
        name = "CraftOS-PC.zip" if IS_WINDOWS else "CraftOS-PC.AppImage"
        return os.path.join(self.cache_dir, name)

    @property
    def extracted_root(self):
        return os.path.join(self.cache_dir, "windows" if IS_WINDOWS else "squashfs-root")

    @property
    def executable(self):
        """The build the raw-mode harness drives: a console so stdio pipes work."""
        if IS_WINDOWS:
            return os.path.join(self.extracted_root, "CraftOS-PC_console.exe")
        return os.path.join(self.extracted_root, "AppRun")

    @property
    def gui_executable(self):
        """The windowed build, for a human to watch and drive by hand.

        On Windows this is the dedicated GUI exe the portable zip ships
        alongside the console one. Elsewhere the same executable serves both
        purposes: AppRun opens an SDL window whenever ``--raw`` is omitted.
        """
        if IS_WINDOWS:
            return os.path.join(self.extracted_root, "CraftOS-PC.exe")
        return self.executable

    @property
    def rom_dir(self):
        if IS_WINDOWS:
            # The portable zip is flat: rom/ and hdfont.bmp sit at its root.
            return self.extracted_root
        return os.path.join(self.extracted_root, "usr", "share", "craftos")

    def font_roots(self):
        """Places the font atlas may live, best first.

        The extracted archive is the usual case, but a system package or a
        CRAFTOS_PC override puts the ROM somewhere else entirely, and a
        screenshot must not fail just because the emulator was installed a
        different way.
        """
        roots = [self.rom_dir]
        override = os.environ.get("CRAFTOS_PC")
        if override:
            base = os.path.dirname(os.path.abspath(override))
            if IS_WINDOWS:
                # <prefix>\CraftOS-PC.exe -> <prefix>
                roots.append(base)
            else:
                # <prefix>/usr/bin/craftos -> <prefix>/usr/share/craftos
                roots.append(os.path.join(os.path.dirname(base), "share", "craftos"))
                roots.append(os.path.join(base, "usr", "share", "craftos"))
        if not IS_WINDOWS:
            roots += ["/usr/share/craftos", "/usr/local/share/craftos"]
        return [root for root in roots if os.path.isdir(root)]

    def font_path(self):
        for root in self.font_roots():
            candidate = os.path.join(root, "hdfont.bmp")
            if os.path.isfile(candidate):
                return candidate
        return None

    def find_existing(self):
        """An emulator already on PATH, if there is one."""
        names = ("craftos-pc.exe", "CraftOS-PC.exe", "craftos.exe") if IS_WINDOWS \
            else ("craftos", "craftos-pc")
        for name in names:
            found = shutil.which(name)
            if found:
                return found
        return None

    def ensure(self, quiet=False):
        """Return a path to a runnable CraftOS-PC, downloading it if needed."""
        existing = os.environ.get("CRAFTOS_PC")
        if existing and os.path.exists(existing):
            return existing

        if os.path.exists(self.executable):
            return self.executable

        on_path = self.find_existing()
        if on_path:
            return on_path

        os.makedirs(self.cache_dir, exist_ok=True)
        if not os.path.exists(self.archive_path):
            if not quiet:
                print("Downloading CraftOS-PC %s ..." % CRAFTOS_VERSION, file=sys.stderr)
            temporary = self.archive_path + ".part"
            urllib.request.urlretrieve(self.url, temporary)
            os.replace(temporary, self.archive_path)

        if not quiet:
            print("Extracting %s ..." % os.path.basename(self.archive_path), file=sys.stderr)
        if IS_WINDOWS:
            with zipfile.ZipFile(self.archive_path) as archive:
                archive.extractall(self.extracted_root)
        else:
            os.chmod(self.archive_path, 0o755)
            subprocess.run([self.archive_path, "--appimage-extract"],
                           cwd=self.cache_dir, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return self.executable

    def check_libraries(self):
        """Return the shared libraries the AppImage needs but cannot find."""
        if IS_WINDOWS:
            return []
        missing = []
        for name in SHARED_LIBRARIES:
            found = subprocess.run(["/sbin/ldconfig", "-p"],
                                   capture_output=True, text=True)
            if name not in found.stdout:
                missing.append(name)
        return missing

    def describe_missing(self, missing):
        return ("CraftOS-PC needs shared libraries this system does not have: %s\n"
                "Install them with:\n    sudo apt-get install -y %s"
                % (", ".join(missing), " ".join(_packages_for(missing))))


def _packages_for(libraries):
    mapping = {"libpulse.so.0": "libpulse0", "libXss.so.1": "libxss1"}
    return sorted({mapping.get(name, name) for name in libraries})
