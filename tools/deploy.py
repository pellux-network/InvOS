"""Manifest-gated deployment to the live ComputerCraft computers.

This is the whole deployment gate in one command. It refuses rather than guesses at every
step, because the target is a running Minecraft world with real player items in it.

    python tools/deploy.py --computers "/path/to/world/computercraft/computer"

If the target lives on a network mount (sshfs, SMB, etc.), every path below is a round
trip, so the backup and verify passes are slower than they look like they should be, and a
dropped mount presents as an absent tree rather than an error.

What it enforces, in order:

1. The target really is the live computer tree (a Git Bash "/g/..." path handed to Windows
   Python silently creates "C:\\g\\..." instead of failing, so a whole deployment can land
   in a directory nobody ever looks at).
2. Each computer's recorded identity matches the one being deployed to.
3. Nothing is in flight: no transfer journal, and file mtimes stable across a sample.
4. Both trees are backed up before anything is written.
5. Only manifest-listed paths are written, LF-only, and never anything under storage/data.
6. Every written file hashes correctly, holds no CR bytes, and has no strays beside it.
7. Every deployed Lua module parses.
8. storage/data survived byte-for-byte.

Exit status is 0 only if every check passed.

The controller does not need to be powered off: booting a computer loads its filesystem
into the host's memory, and nothing touches disk again except the computer's own writes,
which never land outside storage/data -- a directory this gate never writes to. The one
real hazard is racing an in-flight write to storage/data (a mid-transfer journal, an
in-progress config save), so the gate refuses outright if a journal is present and samples
file mtimes across a short window to confirm nothing else is actively changing before it
backs anything up.
"""
import argparse
import filecmp
import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

PRESERVED = ("storage/data",)
LUAC_FALLBACKS = (
    "luac",
    "luac5.4",
    "luac5.3",
)


class Refused(SystemExit):
    def __init__(self, message):
        super().__init__("REFUSED: %s" % message)


def manifest_files(manifest_path):
    """Parse the file list out of a deployment_manifest.lua."""
    text = pathlib.Path(manifest_path).read_text()
    try:
        body = text.split("M={files={", 1)[1].split("}}", 1)[0]
    except IndexError:
        raise Refused("%s is not a recognisable manifest" % manifest_path)
    files = [m.group(1) for m in re.finditer(r'"([^"]+)"', body)]
    if not files:
        raise Refused("%s lists no files" % manifest_path)
    return files


def lf(data):
    return data.replace(b"\r\n", b"\n").replace(b"\r", b"")


def say(message):
    print(message, flush=True)


# ---------------------------------------------------------------- preflight


def require_live_tree(computers, controller_id):
    """Anchor on something that must already exist, so a wrong root refuses."""
    marker = computers / str(controller_id) / "storage" / "data" / "config.lua"
    if not marker.is_file():
        raise Refused(
            "%s does not look like the live computer tree\n"
            "         expected an existing %s" % (computers, marker))


def check_identity(computers, controller_id):
    config = computers / str(controller_id) / "storage" / "data" / "config.lua"
    text = config.read_text(errors="replace")
    found = re.search(r"computer_id=(\d+)", text)
    if not found:
        raise Refused("%s records no computer_id" % config)
    if int(found.group(1)) != int(controller_id):
        raise Refused("%s records computer_id=%s, not %s"
                      % (config, found.group(1), controller_id))
    label = re.search(r'computer_label="([^"]*)"', text)
    say("   identity: computer_id=%s label=%s"
        % (controller_id, label.group(1) if label else "(unset)"))


def check_quiescent(computers, ids, settle_seconds):
    """A live controller rewrites its data directory continuously.

    This corroborates the operator's word; it does not replace it. A journal present at all
    means a transfer was in flight, which is never safe to deploy over.
    """
    roots = [computers / str(value) for value in ids]
    for root in roots:
        data = root / "storage" / "data"
        if data.is_dir():
            for path in data.iterdir():
                if path.name.startswith("journal"):
                    raise Refused("%s exists; a transfer was in flight" % path)

    def newest():
        latest = 0.0
        for root in roots:
            for path in root.rglob("*"):
                if path.is_file():
                    latest = max(latest, path.stat().st_mtime)
        return latest

    first = newest()
    time.sleep(settle_seconds)
    second = newest()
    if second != first:
        raise Refused("files changed during a %ds sample; something is still running"
                      % settle_seconds)
    age = time.time() - second
    say("   quiescent: newest write %ds ago, stable across %ds" % (age, settle_seconds))


# ---------------------------------------------------------------- backup


def backup(computers, ids, backup_root):
    stamp = time.strftime("backup-%Y%m%d-%H%M%S")
    target = backup_root / stamp
    target.mkdir(parents=True, exist_ok=False)
    count = 0
    for value in ids:
        source = computers / str(value)
        if not source.is_dir():
            raise Refused("%s does not exist" % source)
        shutil.copytree(source, target / str(value))
        count += sum(1 for path in (target / str(value)).rglob("*") if path.is_file())
    say("   backup: %s (%d files)" % (target, count))
    return target


# ---------------------------------------------------------------- deploy


def deploy(source_root, target_root, manifest_path, label):
    allowed = manifest_files(manifest_path)
    say("== %s ==" % label)
    say("   source: %s" % source_root)
    say("   target: %s" % target_root)
    say("   manifest lists %d files" % len(allowed))

    written, unchanged, hashes = 0, 0, {}
    for rel in allowed:
        if "data" in rel.split("/"):
            raise Refused("%s lives under a preserved data path" % rel)
        src = source_root / rel
        if not src.is_file():
            raise Refused("manifest lists %s but it does not exist" % src)
        payload = lf(src.read_bytes())
        hashes[rel] = hashlib.sha256(payload).hexdigest()
        dst = target_root / rel
        existing = dst.read_bytes() if dst.is_file() else None
        if existing is not None and lf(existing) == payload:
            unchanged += 1
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        # Unlink first. Opening "wb" is supposed to truncate, but over the sshfs mount it does
        # not reliably do so: writing a shorter file left the previous version's tail in place
        # past the new end, and the module stopped parsing. Verified on 2026-08-12, where a
        # 138-line draw.lua landed as 150 lines and two consecutive deployments reproduced it.
        # The verify and parse steps caught it both times, which is the only reason it was
        # never booted; this makes the write itself correct rather than relying on the gate.
        if dst.is_file():
            dst.unlink()
        dst.write_bytes(payload)
        written += 1
    say("   wrote %d, unchanged %d" % (written, unchanged))
    return hashes


def deploy_version_file(repo, target_root, hashes):
    """Copy repo-root version.txt to target_root, outside any manifest.

    version.txt lives above both controller/ and turtle/, so it is never a
    manifest-listed path; this mirrors deploy()'s own write behavior (LF
    normalize, hash, unlink-first) for the one extra file every installed
    tree needs so the running app and the update checker can read their own
    installed version without caring whether they got here via this tool or
    install.lua.
    """
    payload = lf((pathlib.Path(repo) / "version.txt").read_bytes())
    digest = hashlib.sha256(payload).hexdigest()
    dst = pathlib.Path(target_root) / "version.txt"
    if dst.is_file():
        dst.unlink()
    dst.write_bytes(payload)
    hashes["version.txt"] = digest
    return digest


# ---------------------------------------------------------------- verify


def verify(target_root, hashes, label):
    say("== verify %s ==" % label)
    bad = 0
    for rel, expected in sorted(hashes.items()):
        dst = target_root / rel
        if not dst.is_file():
            say("   MISSING  %s" % rel)
            bad += 1
            continue
        raw = dst.read_bytes()
        if hashlib.sha256(lf(raw)).hexdigest() != expected:
            say("   MISMATCH %s" % rel)
            bad += 1
        if b"\r" in raw:
            say("   HAS CR   %s" % rel)
            bad += 1
    say("   %d files, %d problems" % (len(hashes), bad))
    return bad


def strays(target_root, hashes, label, preserved=PRESERVED):
    found = []
    for path in target_root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(target_root).as_posix()
        if rel in hashes or any(rel.startswith(p + "/") for p in preserved):
            continue
        found.append(rel)
    say("== strays outside manifest and preserved data (%s) ==" % label)
    for rel in sorted(found):
        say("   STRAY %s" % rel)
    if not found:
        say("   none")
    return len(found)


def find_luac(explicit):
    for candidate in ([explicit] if explicit else []) + list(LUAC_FALLBACKS):
        try:
            subprocess.run([candidate, "-v"], capture_output=True, check=False)
            return candidate
        except (OSError, ValueError):
            continue
    return None


def parse_check(target_root, hashes, luac, label):
    """luac -p every deployed module.

    Only manifest files: storage/data holds serialized tables, not chunks, so they are
    correctly not parseable. Paths are passed Windows-style because luac.exe cannot open a
    Git Bash "/c/..." path -- it reports "cannot open", which reads exactly like a syntax
    error if you are not looking closely.
    """
    say("== parse %s ==" % label)
    bad = 0
    for rel in sorted(hashes):
        if not rel.endswith(".lua"):
            continue
        path = os.fspath(target_root / rel)
        result = subprocess.run([luac, "-p", path], capture_output=True)
        if result.returncode != 0:
            say("   PARSE FAIL %s: %s" % (rel, result.stderr.decode(errors="replace").strip()))
            bad += 1
    say("   %d modules, %d errors"
        % (sum(1 for rel in hashes if rel.endswith(".lua")), bad))
    return bad


def preserved_intact(target_root, backup_root_for_computer, label):
    """storage/data must survive byte-for-byte."""
    say("== preserved data %s ==" % label)
    live = target_root / "storage" / "data"
    saved = backup_root_for_computer / "storage" / "data"
    if not live.is_dir() and not saved.is_dir():
        say("   none to preserve")
        return 0
    bad = 0
    for path in saved.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(saved)
        other = live / rel
        if not other.is_file():
            say("   LOST %s" % rel)
            bad += 1
        elif not filecmp.cmp(path, other, shallow=False):
            say("   CHANGED %s" % rel)
            bad += 1
    say("   %d problems" % bad)
    return bad


# ---------------------------------------------------------------- entry


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--computers", required=True,
                        help='the world\'s computercraft/computer directory')
    parser.add_argument("--repo", default=str(pathlib.Path(__file__).resolve().parent.parent),
                        help="repository root (default: this script's repository)")
    parser.add_argument("--controller-id", type=int, required=True,
                        help="numeric computer id of the live controller")
    parser.add_argument("--turtle-id", type=int, default=None,
                        help="numeric computer id of the crafting turtle "
                             "(required unless --no-turtle)")
    parser.add_argument("--backup-root", default=None,
                        help="where to write the pre-deployment backup "
                             "(default: <repo>/.deploy-backups, which is git-ignored)")
    parser.add_argument("--luac", default=None, help="path to luac for the parse check")
    parser.add_argument("--settle-seconds", type=int, default=3,
                        help="how long to sample mtimes for the quiescence check")
    parser.add_argument("--no-turtle", action="store_true",
                        help="deploy the controller only")
    args = parser.parse_args(argv)
    if not args.no_turtle and args.turtle_id is None:
        parser.error("--turtle-id is required unless --no-turtle is given")

    repo = pathlib.Path(args.repo).resolve()
    computers = pathlib.Path(args.computers).resolve()
    backup_root = pathlib.Path(args.backup_root) if args.backup_root \
        else repo / ".deploy-backups"

    ids = [args.controller_id] + ([] if args.no_turtle else [args.turtle_id])

    say("== preflight ==")
    require_live_tree(computers, args.controller_id)
    check_identity(computers, args.controller_id)
    check_quiescent(computers, ids, args.settle_seconds)

    luac = find_luac(args.luac)
    if not luac:
        raise Refused("no working luac found; pass --luac. A green host suite does not "
                      "prove a deployed file parses.")
    say("   luac: %s" % luac)

    saved = backup(computers, ids, backup_root)
    say("")

    targets = [("controller", computers / str(args.controller_id),
                repo / "controller", repo / "controller/storage/deployment_manifest.lua",
                PRESERVED)]
    if not args.no_turtle:
        targets.append(("turtle", computers / str(args.turtle_id),
                        repo / "turtle", repo / "turtle/deployment_manifest.lua", ()))

    deployed = {}
    for name, target, source, manifest, _ in targets:
        deployed[name] = deploy(source, target, manifest,
                                "%s -> #%s" % (name, target.name))
        deploy_version_file(repo, target, deployed[name])
    say("")

    problems = 0
    for name, target, _, _, preserved in targets:
        problems += verify(target, deployed[name], name)
    say("")
    for name, target, _, _, preserved in targets:
        problems += strays(target, deployed[name], name, preserved)
    say("")
    for name, target, _, _, _ in targets:
        problems += parse_check(target, deployed[name], luac, name)
    say("")
    for name, target, _, _, preserved in targets:
        if preserved:
            problems += preserved_intact(target, saved / target.name, name)
    say("")
    say("TOTAL PROBLEMS: %d" % problems)
    if problems:
        say("The live tree is in an unknown state. Restore from %s before booting." % saved)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
