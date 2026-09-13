#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Gathers App Store screenshots out of xcresult bundles into a Desktop folder.

    collect-shots.py <bundle.xcresult> [...]

Only attachments named `appstore-NN-...` are taken. Each goes into a folder for
its device size, under a name that says what it shows. App Store Connect
refuses images with an alpha channel, so any capture that has one is written as
a best-quality JPEG instead of a PNG.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

DEST = pathlib.Path.home() / "Desktop" / "SSHBorg App Store Screenshots"
FOLDERS = {"iPhone 17 Pro Max": "iPhone 6.9 inch", "iPad Pro 13-inch (M5)": "iPad 13 inch"}
TITLES = {
    "01": "Host list", "02": "Terminal", "03": "SFTP file browser",
    "04": "Generate SSH key", "05": "Extra key bar editor", "06": "Settings",
    "07": "SSH keys",
}


def sips(path, *args):
    return subprocess.run(["sips", *args, str(path)], capture_output=True, text=True).stdout


for bundle in sys.argv[1:]:
    out = pathlib.Path(tempfile.mkdtemp())
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle,
                    "--output-path", str(out)], check=True, capture_output=True)
    for test in json.loads((out / "manifest.json").read_text()):
        for a in test.get("attachments", []):
            m = re.match(r"appstore-(\d\d)-", a.get("suggestedHumanReadableName", ""))
            folder = FOLDERS.get(a.get("deviceName"))
            if not m or not folder:
                continue
            number = m.group(1)
            target_dir = DEST / folder
            target_dir.mkdir(parents=True, exist_ok=True)
            base = target_dir / f"{number} - {TITLES.get(number, 'Screen')}"
            for old in target_dir.glob(f"{number} - *"):
                old.unlink()
            source = out / a["exportedFileName"]
            if "hasAlpha: yes" in sips(source, "-g", "hasAlpha"):
                target = base.with_suffix(".jpg")
                subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "best",
                                str(source), "--out", str(target)], check=True, capture_output=True)
            else:
                target = base.with_suffix(".png")
                shutil.copy(source, target)
            info = sips(target, "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha")
            w = re.search(r"pixelWidth: (\d+)", info).group(1)
            h = re.search(r"pixelHeight: (\d+)", info).group(1)
            alpha = re.search(r"hasAlpha: (\w+)", info)
            print(f"{folder}/{target.name}: {w}x{h} alpha={alpha.group(1) if alpha else 'no'}")
    shutil.rmtree(out)
