#!/usr/bin/env python3
"""Insert a new <item> into a Sparkle appcast.xml file.

Idempotent: if an <item> with the same <sparkle:shortVersionString> already
exists, the file is left untouched and the script exits 0.

Inputs (env):
    APPCAST_PATH            path to the appcast.xml file to modify
    VERSION                 e.g. "1.9.0"
    BUILD                   e.g. "2925"
    ED_SIGNATURE            value for sparkle:edSignature attribute
    ZIP_LENGTH              value for length attribute (string of integer)
    MIN_SYSTEM_VERSION      (optional) defaults to "11.0"
    RELEASE_NOTES_PATH      (optional) defaults to ReleaseNotes/<VERSION>_en.md
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)


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
    min_system_version = os.environ.get("MIN_SYSTEM_VERSION", "11.0")
    release_notes_path = Path(
        os.environ.get("RELEASE_NOTES_PATH", f"ReleaseNotes/{version}_en.md")
    )

    if not appcast_path.exists():
        sys.exit(f"[ERROR] APPCAST_PATH does not exist: {appcast_path}")
    if not release_notes_path.exists():
        sys.exit(f"[ERROR] RELEASE_NOTES_PATH does not exist: {release_notes_path}")

    tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        sys.exit(f"[ERROR] No <channel> element in {appcast_path}")

    short_tag = f"{{{SPARKLE_NS}}}shortVersionString"
    for existing in channel.findall("item"):
        existing_short = existing.findtext(short_tag)
        if existing_short == version:
            print(f"[INFO] {appcast_path}: item {version} already present, no change.")
            return 0

    enclosure_url = (
        "https://github.com/MxIris-LyricsX-Project/LyricsX/releases/download/"
        f"v{version}/LyricsX_{version}+{build}.zip"
    )
    description = release_notes_path.read_text(encoding="utf-8").strip()

    item = ET.Element("item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, "pubDate").text = rfc822_now()
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = build
    ET.SubElement(item, short_tag).text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = min_system_version

    desc = ET.SubElement(item, "description")
    DESC_PLACEHOLDER = "@@LYRICSX_DESC_CDATA_PLACEHOLDER@@"
    desc.text = DESC_PLACEHOLDER

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", enclosure_url)
    enclosure.set("length", zip_length)
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{{{SPARKLE_NS}}}edSignature", ed_signature)

    insert_index = 0
    for index, child in enumerate(list(channel)):
        if child.tag == "item":
            insert_index = index
            break
        insert_index = index + 1
    channel.insert(insert_index, item)

    ET.indent(tree, space="    ")
    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)

    raw = appcast_path.read_text(encoding="utf-8")
    expected_decl = '<?xml version="1.0" encoding="utf-8" standalone="yes"?>'
    if not raw.startswith(expected_decl):
        first_newline = raw.index("\n")
        raw = expected_decl + raw[first_newline:]
    raw = raw.replace(DESC_PLACEHOLDER, f"<![CDATA[{description}]]>")
    appcast_path.write_text(raw, encoding="utf-8")

    print(f"[INFO] {appcast_path}: inserted item for v{version} (build {build}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
