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

import html
import os
import re
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


def markdown_to_html(markdown_text: str) -> str:
    """Convert the limited Markdown used in release notes to HTML.

    Sparkle renders the appcast <description> as HTML, so embedding raw
    Markdown shows its literal syntax (`#`, `**`, `-`) and collapses the
    paragraphs. This handles the subset the notes use: `#`/`##` headings,
    `- ` bullet lists, `**bold**`, `[text](url)` links, `---` rules, and
    blank-line-separated paragraphs.
    """
    def render_inline(text: str) -> str:
        escaped = html.escape(text, quote=False)
        with_links = re.sub(
            r"\[([^\]]+)\]\((https?://[^\s)]+)\)", r'<a href="\2">\1</a>', escaped
        )
        return re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", with_links)

    rendered_lines: list[str] = []
    inside_list = False

    def close_list() -> None:
        nonlocal inside_list
        if inside_list:
            rendered_lines.append("</ul>")
            inside_list = False

    for line in markdown_text.splitlines():
        stripped = line.strip()
        if not stripped:
            close_list()
        elif stripped == "---":
            close_list()
            rendered_lines.append("<hr>")
        elif stripped.startswith("## "):
            close_list()
            rendered_lines.append(f"<h3>{render_inline(stripped[3:])}</h3>")
        elif stripped.startswith("# "):
            close_list()
            rendered_lines.append(f"<h2>{render_inline(stripped[2:])}</h2>")
        elif stripped.startswith("- "):
            if not inside_list:
                rendered_lines.append("<ul>")
                inside_list = True
            rendered_lines.append(f"<li>{render_inline(stripped[2:])}</li>")
        else:
            close_list()
            rendered_lines.append(f"<p>{render_inline(stripped)}</p>")

    close_list()
    return "\n".join(rendered_lines)


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
    description = markdown_to_html(release_notes_path.read_text(encoding="utf-8").strip())
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
