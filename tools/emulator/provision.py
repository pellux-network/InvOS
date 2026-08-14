"""Locate or fetch a CraftOS-PC build for the harness to drive.

Nothing here installs into the system. The AppImage is downloaded once into a
cache directory and extracted, so the emulator can be provisioned on a fresh
machine or CI runner without root and without changing the developer's
environment. An already-installed `craftos` on PATH wins over downloading.
"""

import os
import shutil
import subprocess
import sys
import urllib.request

CRAFTOS_VERSION = "v2.8.3"
APPIMAGE_URL = ("https://github.com/MCJack123/craftos2/releases/download/"
                "%s/CraftOS-PC.x86_64.AppImage" % CRAFTOS_VERSION)

# AppImage runtime dependencies that are not part of a minimal Ubuntu install.
# They are reported rather than installed: this tool has no business running
# apt on a developer's machine.
SHARED_LIBRARIES = ("libpulse.so.0", "libXss.so.1")


def default_cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "invos-emulator")


class Provisioner(object):
    def __init__(self, cache_dir=None, url=APPIMAGE_URL):
        self.cache_dir = cache_dir or default_cache_dir()
        self.url = url

    @property
    def appimage_path(self):
        return os.path.join(self.cache_dir, "CraftOS-PC.AppImage")

    @property
    def extracted_root(self):
        return os.path.join(self.cache_dir, "squashfs-root")

    @property
    def executable(self):
        return os.path.join(self.extracted_root, "AppRun")

    @property
    def rom_dir(self):
        return os.path.join(self.extracted_root, "usr", "share", "craftos")

    def font_roots(self):
        """Places the font atlas may live, best first.

        The extracted AppImage is the usual case, but a system package or a
        CRAFTOS_PC override puts the ROM somewhere else entirely, and a
        screenshot must not fail just because the emulator was installed a
        different way.
        """
        roots = [self.rom_dir]
        override = os.environ.get("CRAFTOS_PC")
        if override:
            # <prefix>/usr/bin/craftos -> <prefix>/usr/share/craftos
            base = os.path.dirname(os.path.dirname(os.path.abspath(override)))
            roots.append(os.path.join(base, "share", "craftos"))
            roots.append(os.path.join(os.path.dirname(os.path.abspath(override)),
                                      "usr", "share", "craftos"))
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
        return shutil.which("craftos") or shutil.which("craftos-pc")

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
        if not os.path.exists(self.appimage_path):
            if not quiet:
                print("Downloading CraftOS-PC %s ..." % CRAFTOS_VERSION, file=sys.stderr)
            temporary = self.appimage_path + ".part"
            urllib.request.urlretrieve(self.url, temporary)
            os.replace(temporary, self.appimage_path)
        os.chmod(self.appimage_path, 0o755)

        if not quiet:
            print("Extracting AppImage ...", file=sys.stderr)
        subprocess.run([self.appimage_path, "--appimage-extract"],
                       cwd=self.cache_dir, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return self.executable

    def check_libraries(self):
        """Return the shared libraries the AppImage needs but cannot find."""
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
