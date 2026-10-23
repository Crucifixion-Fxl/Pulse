#!/usr/bin/env python3
"""Render README artwork from production SwiftUI views with fictional data.

Requires macOS, a graphical session, Xcode 26+, Python 3, ffmpeg and gifsicle.
No third-party packages, screen recording or personal-data fixtures are used.
"""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    if shutil.which("ffmpeg") is None:
        raise SystemExit("ffmpeg is required to encode the 50 fps GIF")
    if shutil.which("gifsicle") is None:
        raise SystemExit("gifsicle is required to optimize the README GIF")
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
        # Keep fixture-only accessors out of the shipping app. Swift's private
        # setters remain accessible to an extension in this temporary file.
        demo_model = work / "AppModel.swift"
        demo_model.write_text(
            (ROOT / "Pulse/App/AppModel.swift").read_text()
            + "\n" + (ROOT / "scripts/readme-model-fixtures.swift").read_text()
        )
        sources = sorted(
            str(demo_model if p.name == "AppModel.swift" else p)
            for p in (ROOT / "Pulse").rglob("*.swift") if p.name != "AppDelegate.swift"
        )
        executable = contents / "MacOS/Demo"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", *sources,
            str(ROOT / "scripts/render-readme.swift"), "-o", str(executable),
        ], check=True)
        frames = work / "frames"
        subprocess.run([str(executable), str(ROOT), str(frames)], check=True)
        compositor = work / "compose"
        subprocess.run(["xcrun", "swiftc", str(ROOT / "scripts/compose-readme.swift"),
                        "-o", str(compositor)], check=True)
        motion = work / "motion"
        subprocess.run([str(compositor), str(frames), str(motion)], check=True)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-framerate", "50",
            "-i", str(motion / "frame-%04d.png"), "-filter_complex",
            "[0:v]split[a][b];[a]palettegen=stats_mode=full:reserve_transparent=0[p];"
            "[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
            "-loop", "0", str(motion / "pulse-raw.gif"),
        ], check=True)
        subprocess.run([
            "gifsicle", "-O3", "-Okeep-empty", str(motion / "pulse-raw.gif"),
            "-o", str(motion / "pulse-overview.gif"),
        ], check=True)
        for name in ("pulse-overview.gif", "pulse-overview.png"):
            shutil.copyfile(motion / name, ROOT / "docs/images" / name)
            print(f"Saved docs/images/{name}")


if __name__ == "__main__":
    main()
