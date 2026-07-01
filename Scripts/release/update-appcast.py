#!/usr/bin/env python3
"""Insert or refresh an <item> in a Sparkle appcast.xml file.

Append-only for new releases: the new <item> is spliced in as plain text
in front of the first existing <item>; every other byte of the file is left
untouched. If an item for the same version is already present, only its
<description> CDATA block is refreshed from the current release notes.

Inputs (env):
    APPCAST_PATH            path to the appcast.xml file to modify
    VERSION                 e.g. "1.9.0"
    BUILD                   e.g. "2925"
    ED_SIGNATURE            value for sparkle:edSignature attribute
    ZIP_LENGTH              value for length attribute (string of integer)
    MIN_SYSTEM_VERSION      minimumSystemVersion, e.g. "10.15"
    RELEASE_NOTES_PATH      (optional) defaults to ReleaseNotes/<VERSION>_en.md
    IS_PRERELEASE           (optional) "true" emits <sparkle:channel>beta</...>
                            so only opted-in clients pick the item up; any
                            other value (or unset) produces a stable item
                            visible to every client.
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


def replace_existing_item_description(
    appcast_text: str,
    short_version_tag: str,
    description: str,
) -> tuple[str, bool]:
    short_version_index = appcast_text.find(short_version_tag)
    if short_version_index == -1:
        return appcast_text, False

    item_start_index = appcast_text.rfind("        <item>", 0, short_version_index)
    item_end_index = appcast_text.find("        </item>", short_version_index)
    if item_start_index == -1 or item_end_index == -1:
        sys.exit(f"[ERROR] Found {short_version_tag}, but could not locate its <item> block.")

    item_end_index += len("        </item>")
    item_text = appcast_text[item_start_index:item_end_index]
    description_pattern = re.compile(
        r"<description><!\[CDATA\[.*?\]\]></description>",
        re.DOTALL,
    )
    if not description_pattern.search(item_text):
        sys.exit(f"[ERROR] Found {short_version_tag}, but it has no <description> block.")

    refreshed_description = f"<description><![CDATA[{description}]]></description>"
    refreshed_item_text = description_pattern.sub(refreshed_description, item_text, count=1)
    if refreshed_item_text == item_text:
        return appcast_text, True

    refreshed_appcast_text = (
        appcast_text[:item_start_index]
        + refreshed_item_text
        + appcast_text[item_end_index:]
    )
    return refreshed_appcast_text, True


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
    description = markdown_to_html(release_notes_path.read_text(encoding="utf-8").strip())
    if "]]>" in description:
        sys.exit("[ERROR] Release notes contain ']]>', which would break the CDATA block.")

    short_version_tag = (
        f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
    )
    refreshed_raw, item_already_present = replace_existing_item_description(
        raw,
        short_version_tag,
        description,
    )
    if item_already_present:
        if refreshed_raw == raw:
            print(f"[INFO] {appcast_path}: item {version} already present, no change.")
        else:
            appcast_path.write_text(refreshed_raw, encoding="utf-8")
            print(f"[INFO] {appcast_path}: refreshed description for v{version}.")
        return 0

    enclosure_url = (
        "https://github.com/MxIris-LyricsX-Project/LyricsX/releases/download/"
        f"v{version}/LyricsX_{version}+{build}.zip"
    )
    is_prerelease = os.environ.get("IS_PRERELEASE", "").lower() == "true"
    channel_element = (
        "            <sparkle:channel>beta</sparkle:channel>\n"
        if is_prerelease else ""
    )

    new_item = (
        "        <item>\n"
        f"            <title>{version}</title>\n"
        f"            <pubDate>{rfc822_now()}</pubDate>\n"
        f"{channel_element}"
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
