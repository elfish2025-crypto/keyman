#!/usr/bin/env python3
"""Keep one installed Keyman app; retain verified, non-launchable recovery archives."""
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import time
import zipfile
from contextlib import contextmanager

BUNDLE_ID = "com.local.keyman"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def bundle_info(path):
    path = pathlib.Path(path)
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"Not a regular application directory: {path}")
    info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "Keyman":
        raise ValueError(f"Not a Keyman bundle: {path}")
    return info


def manifest(path):
    """Compare bundle contents, symlinks and permissions independently of its outer name."""
    bundle_info(path)
    entries = {}
    for directory, subdirs, files in os.walk(path, followlinks=False):
        for name in sorted(subdirs + files):
            item = pathlib.Path(directory) / name
            metadata = item.lstat()
            mode = stat.S_IMODE(metadata.st_mode)
            if item.is_symlink():
                value = ["link", mode, os.readlink(item)]
            elif item.is_dir():
                value = ["directory", mode]
            elif item.is_file():
                value = ["file", mode, hashlib.sha256(item.read_bytes()).hexdigest()]
            else:
                raise ValueError(f"Unsupported item in app: {item}")
            entries[item.relative_to(path).as_posix()] = value
    return entries


def digest(entries):
    return hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()


def safe_extract(archive, destination):
    with zipfile.ZipFile(archive) as package:
        for item in package.infolist():
            name = pathlib.PurePosixPath(item.filename)
            if name.is_absolute() or ".." in name.parts:
                raise ValueError("Unsafe archive path")
            if stat.S_ISLNK(item.external_attr >> 16):
                target = pathlib.PurePosixPath(package.read(item).decode())
                if target.is_absolute() or ".." in target.parts:
                    raise ValueError("Unsafe archive symlink")
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(destination)], check=True, capture_output=True)
    candidates = [item for item in pathlib.Path(destination).iterdir()
                  if item.name != "__MACOSX" and item.is_dir() and (item / "Contents/Info.plist").is_file()]
    if len(candidates) != 1:
        raise ValueError("Archive must contain exactly one Keyman app")
    bundle_info(candidates[0])
    return candidates[0]


def verify_archive(archive, expected):
    with tempfile.TemporaryDirectory(prefix=".keyman-verify-", suffix=".noindex", dir=pathlib.Path(archive).parent) as temp:
        recovered = safe_extract(archive, temp)
        if manifest(recovered) != expected:
            raise ValueError("Archive verification failed; original application retained")


def archive_bundle(source, archives):
    """No source is removed here. Verify recovery before the caller retires a bundle."""
    source, archives = pathlib.Path(source), pathlib.Path(archives)
    info = bundle_info(source)
    entries = manifest(source)
    archives.mkdir(parents=True, exist_ok=True, mode=0o700)
    version = str(info.get("CFBundleShortVersionString", "unknown"))
    version = "".join(c for c in version if c.isalnum() or c in ".-_")
    archive = archives / f"Keyman-{version}-{digest(entries)[:16]}.zip"
    if archive.exists():
        verify_archive(archive, entries)
    else:
        with tempfile.TemporaryDirectory(prefix=".keyman-archive-", suffix=".noindex", dir=archives) as temp:
            pending = pathlib.Path(temp) / "app.zip"
            subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(source), str(pending)], check=True, capture_output=True)
            verify_archive(pending, entries)
            pending.chmod(0o600)
            os.replace(pending, archive)
    return archive, entries


def retire_bundle(source, archive, expected, registry):
    if manifest(source) != expected:
        raise ValueError(f"Application changed during archival; source retained: {source}")
    verify_archive(archive, expected)
    registry("-u", source)
    shutil.rmtree(source)


def register(action, path):
    subprocess.run([LSREGISTER, action, str(path)], check=True, capture_output=True)


def registered_app_paths():
    result = subprocess.run([LSREGISTER, "-dump"], capture_output=True, text=True, check=True)
    paths = set()
    for block in re.split(r"\n-{10,}\n", result.stdout):
        if not re.search(r"^identifier:\s+com\.local\.keyman\s*$", block, re.MULTILINE):
            continue
        match = re.search(r"^path:\s+(.+?)\s+\(0x[0-9a-f]+\)\s*$", block, re.MULTILINE)
        if match:
            paths.add(pathlib.Path(match.group(1)))
    return paths


def running_executables():
    result = subprocess.run(["/usr/bin/pgrep", "-x", "Keyman"], capture_output=True, text=True)
    ids = result.stdout.split()
    if not ids:
        return []
    result = subprocess.run(["/bin/ps", "-p", ",".join(ids), "-o", "comm="], capture_output=True, text=True, check=True)
    return [pathlib.Path(line.strip()) for line in result.stdout.splitlines() if line.strip()]


@contextmanager
def installation_lock(support):
    support.mkdir(parents=True, exist_ok=True)
    with (support / ".app-install.lock").open("a") as lock:
        os.chmod(lock.name, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("另一个 Keyman 安装或整理操作正在进行。")
        yield


def cleanup(project, user_root, registry=register, active_paths=None):
    applications = user_root / "Applications"
    official = applications / "Keyman.app"
    bundle_info(official)
    support = user_root / "Library/Application Support/Keyman"
    archives = support / "App Archives.noindex"
    old_backup_directory = support / "App Backups"
    sources = sorted(applications.glob("Keyman.backup.*.app"))
    if old_backup_directory.exists():
        sources += sorted(old_backup_directory.glob("Keyman.*.backup"))
    development_app = project / "dist/Keyman.app"
    if development_app.exists():
        sources.append(development_app)
    active_paths = running_executables() if active_paths is None else active_paths
    for source in sources:
        if any(path.is_relative_to(source) for path in active_paths):
            raise RuntimeError(f"请先退出正在运行的旧版，再整理：{source}")
    records = []
    receipt_path = support / f"app-cleanup-{time.time_ns()}.json"
    report = {"officialApp": str(official), "retiredCopies": records, "configurationAndKeysChanged": False}
    registered = registered_app_paths() if registry is register else None
    def unregister_if_present(action, path):
        # Non-launchable .backup directories have no Launch Services registration.
        if registered is None or path in registered:
            registry(action, path)
    for source in sources:
        archive, expected = archive_bundle(source, archives)
        if source == development_app:
            package = project / "dist/Keyman.app.zip"
            # A newer packaged build, if present, is independent and must be retained.
            if not package.exists():
                shutil.copy2(archive, package)
        retire_bundle(source, archive, expected, unregister_if_present)
        records.append({"originalPath": str(source), "archive": str(archive), "contentSHA256": digest(expected)})
        receipt_path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        receipt_path.chmod(0o600)
    if old_backup_directory.exists() and not any(old_backup_directory.iterdir()):
        old_backup_directory.rmdir()
    registry("-f", official)
    return report


def install(source, project, user_root, registry=register, verifier=None, active_paths=None):
    applications = user_root / "Applications"
    applications.mkdir(parents=True, exist_ok=True)
    official = applications / "Keyman.app"
    archives = user_root / "Library/Application Support/Keyman/App Archives.noindex"
    active_paths = running_executables() if active_paths is None else active_paths
    cli_dir = user_root / ".local/bin"
    cli = cli_dir / "keyman"
    if cli.exists() and not cli.is_symlink():
        raise ValueError("The keyman command is not a symlink; retained for manual review")
    if verifier is None:
        verifier = lambda app: subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True, capture_output=True)
    changed = True
    # Staging in the destination volume permits rename and is excluded from normal app discovery.
    with tempfile.TemporaryDirectory(prefix=".keyman-install-", suffix=".noindex", dir=applications) as temp:
        app = safe_extract(source, temp)
        verifier(app)
        wanted = manifest(app)
        changed = not official.exists() or manifest(official) != wanted
        if changed:
            if any(path.is_relative_to(official) for path in active_paths):
                raise RuntimeError("请先退出 Keyman，再安装不同的版本，避免旧进程继续使用新配置。")
            previous = pathlib.Path(temp) / "previous.backup"
            if official.exists():
                archive_bundle(official, archives)
                os.replace(official, previous)
            try:
                os.replace(app, official)
                verifier(official)
            except Exception:
                if official.exists():
                    shutil.rmtree(official)
                if previous.exists():
                    os.replace(previous, official)
                raise
    cli_dir.mkdir(parents=True, exist_ok=True)
    temporary_link = cli_dir / f".keyman-link-{time.time_ns()}"
    temporary_link.symlink_to(official / "Contents/MacOS/Keyman")
    os.replace(temporary_link, cli)
    report = cleanup(project, user_root, registry, active_paths)
    report["applicationReplaced"] = changed
    report["version"] = bundle_info(official).get("CFBundleShortVersionString")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["cleanup", "install"])
    parser.add_argument("--source", type=pathlib.Path)
    args = parser.parse_args()
    project = pathlib.Path(__file__).resolve().parent.parent
    user_root = pathlib.Path.home()
    with installation_lock(user_root / "Library/Application Support/Keyman"):
        if args.operation == "cleanup":
            report = cleanup(project, user_root)
        else:
            source = args.source or project / "dist/Keyman.app.zip"
            report = install(source, project, user_root)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
