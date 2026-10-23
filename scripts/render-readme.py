#!/usr/bin/env python3
"""Render README artwork from production SwiftUI views with fictional data.

Requires macOS, a logged-in graphical session, Xcode 26+ and Python 3.
No third-party packages, screen recording or personal-data fixtures are used.
"""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="pulse-readme-") as scratch:
        work = Path(scratch)
        contents = work / "Demo.app/Contents"
        resources = contents / "Resources"
        resources.mkdir(parents=True)
        (contents / "MacOS").mkdir()
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Demo", "CFBundleIdentifier": "dev.pulse.readme-demo",
            "CFBundleDevelopmentRegion": "en", "LSUIElement": True,
        }))
        shutil.copytree(ROOT / "Pulse/en.lproj", resources / "en.lproj")
        subprocess.run([
            "xcrun", "actool", str(ROOT / "Pulse/Assets.xcassets"), "--compile", str(resources),
            "--platform", "macosx", "--minimum-deployment-target", "14.0",
        ], check=True)
        sources = sorted(str(p) for p in (ROOT / "Pulse").rglob("*.swift") if p.name != "AppDelegate.swift")
        executable = contents / "MacOS/Demo"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", *sources,
            str(ROOT / "scripts/render-readme.swift"), "-o", str(executable),
        ], check=True)
        frames = work / "frames"
        subprocess.run([str(executable), str(ROOT), str(frames)], check=True)
        for name in ("pulse-overview.gif", "pulse-overview.png"):
            shutil.copyfile(frames / name, ROOT / "docs/images" / name)
            print(f"Saved docs/images/{name}")


if __name__ == "__main__":
    main()
