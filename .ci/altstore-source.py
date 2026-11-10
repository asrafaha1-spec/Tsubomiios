#!/usr/bin/env python3
"""Adds a release to the AltStore / SideStore source (dist/altstore/source.json).

Users add https://raw.githubusercontent.com/<repo>/main/dist/altstore/source.json as a source in
AltStore or SideStore and get every new release as an in-app update.

Usage: altstore-source.py <source.json> <repo> <version> <build> <ipa path> <download url> [notes file]
"""
import datetime
import json
import os
import sys

source_path, repo, version, build, ipa_path, download_url = sys.argv[1:7]
notes = ""
if len(sys.argv) > 7 and os.path.exists(sys.argv[7]):
    notes = open(sys.argv[7], encoding="utf-8").read().strip()

raw = f"https://raw.githubusercontent.com/{repo}/main/dist/altstore"
description = (
    "Vita3KiOS is a PlayStation Vita emulator for iPhone and iPad, built on the Vita3K core.\n"
    "\n"
    "- Install games, updates and DLC from .vpk, .zip, .pkg or a dumped folder\n"
    "- JIT through StikDebug, works in LiveContainer\n"
    "- Per-game settings, community patches, cheats and mods\n"
    "- On-screen controls you can rearrange, controller support and button remapping\n"
    "- External storage: keep your games on a USB drive, SSD or SD card\n"
    "\n"
    "You need your own PS Vita firmware and games.\n"
    "\n"
    "Discord (help and bug reports): https://discord.gg/pZyQDPHKF"
)

if os.path.exists(source_path):
    source = json.load(open(source_path, encoding="utf-8"))
else:
    source = {}

source.update({
    "name": "Vita3KiOS",
    "identifier": "org.vita3k.ios.source",
    "subtitle": "PS Vita emulator for iOS",
    "description": description,
    "iconURL": f"{raw}/icon.png",
    "website": f"https://github.com/{repo}",
    "tintColor": "#E97F02",
    "news": source.get("news", []),
})

apps = source.setdefault("apps", [])
app = next((a for a in apps if a.get("bundleIdentifier") == "org.vita3k.ios"), None)
if app is None:
    app = {"bundleIdentifier": "org.vita3k.ios", "versions": []}
    apps.append(app)

app.update({
    "name": "Vita3KiOS",
    "developerName": "oledz-i",
    "subtitle": "PS Vita emulator",
    "localizedDescription": description,
    "iconURL": f"{raw}/icon.png",
    "tintColor": "#E97F02",
    "category": "games",
    "screenshots": app.get("screenshots", []),
    "appPermissions": {
        "entitlements": [
            "get-task-allow",
            "com.apple.developer.kernel.extended-virtual-addressing",
            "com.apple.developer.kernel.increased-memory-limit",
        ],
        "privacy": {},
    },
})

entry = {
    "version": version,
    "buildVersion": str(build),
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": notes or f"Vita3KiOS {version}",
    "downloadURL": download_url,
    "size": os.path.getsize(ipa_path),
    "minOSVersion": "17.4",
}
versions = [v for v in app.get("versions", []) if v.get("version") != version]
app["versions"] = [entry] + versions

# Legacy fields still read by older AltStore / SideStore builds
for key in ("version", "versionDate", "versionDescription", "downloadURL", "size"):
    app.pop(key, None)
app["version"] = version
app["versionDate"] = entry["date"]
app["versionDescription"] = entry["localizedDescription"]
app["downloadURL"] = download_url
app["size"] = entry["size"]

os.makedirs(os.path.dirname(source_path), exist_ok=True)
with open(source_path, "w", encoding="utf-8") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"AltStore source: {version} ({build}) -> {download_url}")
