#!/usr/bin/env python3
"""Insert a new <item> into a Sparkle appcast.xml file.

Append-only and idempotent: the new <item> is spliced in as plain text
in front of the first existing <item>; every other byte of the file —
including the CDATA blocks of older items — is left untouched. If an
item for the same version is already present, the file is not modified.

Inputs (env):
    APPCAST_PATH            path to the appcast.xml file to modify
    VERSION                 e.g. "1.9.0"
    BUILD                   e.g. "2925"
    ED_SIGNATURE            value for sparkle:edSignature attribute
    ZIP_LENGTH              value for length attribute (string of integer)
    MIN_SYSTEM_VERSION      minimumSystemVersion, e.g. "10.15"
    RELEASE_NOTES_PATH      (optional) defaults to ReleaseNotes/<VERSION>_en.md
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def require(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        sys.exit(f"[ERROR] Required env var missing: {name}")
    return value


def rfc822_now() -> str:
    return datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")


def main() -> int:
    appcast_path = Path(require("APPCAST_PATH"))
    version = require("VERSION")
    build = require("BUILD")
    ed_signature = require("ED_SIGNATURE")
    zip_length = require("ZIP_LENGTH")
    min_system_version = require("MIN_SYSTEM_VERSION")
    release_notes_path = Path(
        os.environ.get("RELEASE_NOTES_PATH", f"ReleaseNotes/{version}_en.md")
    )

    if not appcast_path.exists():
        sys.exit(f"[ERROR] APPCAST_PATH does not exist: {appcast_path}")
    if not release_notes_path.exists():
        sys.exit(f"[ERROR] RELEASE_NOTES_PATH does not exist: {release_notes_path}")

    raw = appcast_path.read_text(encoding="utf-8")

    short_version_tag = (
        f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
    )
    if short_version_tag in raw:
        print(f"[INFO] {appcast_path}: item {version} already present, no change.")
        return 0

    enclosure_url = (
        "https://github.com/MxIris-LyricsX-Project/LyricsX/releases/download/"
        f"v{version}/LyricsX_{version}+{build}.zip"
    )
    description = release_notes_path.read_text(encoding="utf-8").strip()
    if "]]>" in description:
        sys.exit("[ERROR] Release notes contain ']]>', which would break the CDATA block.")

    new_item = (
        "        <item>\n"
        f"            <title>{version}</title>\n"
        f"            <pubDate>{rfc822_now()}</pubDate>\n"
        f"            <sparkle:version>{build}</sparkle:version>\n"
        f"            {short_version_tag}\n"
        f"            <sparkle:minimumSystemVersion>{min_system_version}</sparkle:minimumSystemVersion>\n"
        f"            <description><![CDATA[{description}]]></description>\n"
        f'            <enclosure url="{enclosure_url}" length="{zip_length}"'
        f' type="application/octet-stream" sparkle:edSignature="{ed_signature}" />\n'
        "        </item>\n"
    )

    channel_pos = raw.find("<channel>")
    if channel_pos == -1:
        sys.exit(f"[ERROR] No <channel> element in {appcast_path}")

    # Splice in front of the first existing <item>; if the channel has no
    # items yet, splice just before </channel>.
    item_pos = raw.find("        <item>", channel_pos)
    if item_pos != -1:
        updated = raw[:item_pos] + new_item + raw[item_pos:]
    else:
        close_pos = raw.find("    </channel>", channel_pos)
        if close_pos == -1:
            sys.exit(f"[ERROR] No </channel> element in {appcast_path}")
        updated = raw[:close_pos] + new_item + raw[close_pos:]

    appcast_path.write_text(updated, encoding="utf-8")
    print(f"[INFO] {appcast_path}: inserted item for v{version} (build {build}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
