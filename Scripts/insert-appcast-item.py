#!/usr/bin/env python3
"""Splice one release's item into a live Sparkle appcast.

Release.zsh's release_deploy_appcast hook runs this once per live feed (see
CLAUDE.md, "Release Workflow"). AppRelease has Sparkle's generate_appcast write
the release into a feed of its own; this copies that item's signature, length,
date, channel and minimum system into the live feed, adds the English release
notes as HTML, and titles it with the whole tag version (1.9.1-beta.1), where
generate_appcast would use the app's numeric one.

Append-only: the new <item> is spliced in as text in front of the first
existing <item>, and every other byte of the feed is left as it was. If the
feed already has an item for this version, that item is replaced where it
stands: running a release again builds a new zip, and an item kept from the
first run would carry the old zip's signature and length, which Sparkle
rejects.

    insert-appcast-item.py --feed appcast.xml --generated-feed appcast-item.xml \\
        --build 10901101 --version 1.9.1-beta.1 --release-notes ReleaseNotes/1.9.1-beta.1_en.md
"""
from __future__ import annotations

import argparse
import html
import re
import sys
import xml.etree.ElementTree as ElementTree
from dataclasses import dataclass
from pathlib import Path

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def sparkle(name: str) -> str:
    return f"{{{SPARKLE_NAMESPACE}}}{name}"


def fail(message: str) -> None:
    sys.exit(f"[ERROR] {message}")


@dataclass
class GeneratedItem:
    publication_date: str
    channel: str | None
    minimum_system_version: str
    enclosure_url: str
    enclosure_length: str
    enclosure_type: str
    ed_signature: str


def read_generated_item(generated_feed_path: Path, build: str) -> GeneratedItem:
    """The item generate_appcast wrote for this build, and nothing it guessed for us."""
    root = ElementTree.parse(generated_feed_path).getroot()
    matching_items = [
        item for item in root.iter("item")
        if (item.findtext(sparkle("version")) or "").strip() == build
    ]
    if len(matching_items) != 1:
        fail(
            f"{generated_feed_path} has {len(matching_items)} items for build {build}, "
            "expected one; delete the file and publish again"
        )
    item = matching_items[0]

    def required_text(tag: str, description: str) -> str:
        value = (item.findtext(tag) or "").strip()
        if not value:
            fail(f"generate_appcast wrote no {description} for build {build}")
        return value

    enclosure = item.find("enclosure")
    if enclosure is None:
        fail(f"generate_appcast wrote no <enclosure> for build {build}")
    enclosure_values = {
        "url": enclosure.get("url", ""),
        "length": enclosure.get("length", ""),
        "edSignature": enclosure.get(sparkle("edSignature"), ""),
    }
    for name, value in enclosure_values.items():
        if not value:
            fail(f"generate_appcast wrote no {name} on the enclosure for build {build}")

    channel = (item.findtext(sparkle("channel")) or "").strip() or None
    return GeneratedItem(
        publication_date=required_text("pubDate", "<pubDate>"),
        channel=channel,
        # The main app's LSMinimumSystemVersion, not the widget's higher floor: macOS 12 to 14 still
        # get updates, they only go without the widget.
        minimum_system_version=required_text(sparkle("minimumSystemVersion"), "<sparkle:minimumSystemVersion>"),
        enclosure_url=enclosure_values["url"],
        enclosure_length=enclosure_values["length"],
        enclosure_type=enclosure.get("type", "application/octet-stream"),
        ed_signature=enclosure_values["edSignature"],
    )


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


def existing_item_range(appcast_text: str, short_version_tag: str) -> tuple[int, int] | None:
    """Where the feed's item for this version starts and ends, if it has one."""
    short_version_index = appcast_text.find(short_version_tag)
    if short_version_index == -1:
        return None
    item_start_index = appcast_text.rfind("        <item>", 0, short_version_index)
    item_end_index = appcast_text.find("        </item>", short_version_index)
    if item_start_index == -1 or item_end_index == -1:
        fail(f"Found {short_version_tag}, but could not locate its <item> block.")
    return item_start_index, item_end_index + len("        </item>\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Splice one release's item into a live Sparkle appcast.")
    parser.add_argument("--feed", type=Path, required=True, help="the live appcast.xml to change")
    parser.add_argument("--generated-feed", type=Path, required=True, help="the feed generate_appcast wrote")
    parser.add_argument("--build", required=True, help="the build number, CFBundleVersion")
    parser.add_argument("--version", required=True, help="the tag without its v, e.g. 1.9.1-beta.1")
    parser.add_argument("--release-notes", type=Path, required=True, help="the English release notes")
    arguments = parser.parse_args()

    for path in (arguments.feed, arguments.generated_feed, arguments.release_notes):
        if not path.exists():
            fail(f"{path} does not exist")

    generated_item = read_generated_item(arguments.generated_feed, arguments.build)
    raw = arguments.feed.read_text(encoding="utf-8")
    description = markdown_to_html(arguments.release_notes.read_text(encoding="utf-8").strip())
    if "]]>" in description:
        fail("Release notes contain ']]>', which would break the CDATA block.")

    version = arguments.version
    short_version_tag = (
        f"<sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>"
    )
    channel_element = (
        f"            <sparkle:channel>{html.escape(generated_item.channel)}</sparkle:channel>\n"
        if generated_item.channel else ""
    )
    new_item = (
        "        <item>\n"
        f"            <title>{html.escape(version)}</title>\n"
        f"            <pubDate>{html.escape(generated_item.publication_date)}</pubDate>\n"
        f"{channel_element}"
        f"            <sparkle:version>{html.escape(arguments.build)}</sparkle:version>\n"
        f"            {short_version_tag}\n"
        f"            <sparkle:minimumSystemVersion>{html.escape(generated_item.minimum_system_version)}</sparkle:minimumSystemVersion>\n"
        f"            <description><![CDATA[{description}]]></description>\n"
        f'            <enclosure url="{html.escape(generated_item.enclosure_url)}"'
        f' length="{html.escape(generated_item.enclosure_length)}"'
        f' type="{html.escape(generated_item.enclosure_type)}"'
        f' sparkle:edSignature="{html.escape(generated_item.ed_signature)}" />\n'
        "        </item>\n"
    )

    existing_range = existing_item_range(raw, short_version_tag)
    if existing_range is not None:
        item_start_index, item_end_index = existing_range
        updated = raw[:item_start_index] + new_item + raw[item_end_index:]
        if updated == raw:
            print(f"[INFO] {arguments.feed}: item {version} already up to date, no change.")
        else:
            arguments.feed.write_text(updated, encoding="utf-8")
            print(f"[INFO] {arguments.feed}: replaced the item for v{version} (build {arguments.build}).")
        return 0

    channel_position = raw.find("<channel>")
    if channel_position == -1:
        fail(f"No <channel> element in {arguments.feed}")

    # Splice in front of the first existing <item>; if the channel has no
    # items yet, splice just before </channel>.
    item_position = raw.find("        <item>", channel_position)
    if item_position != -1:
        updated = raw[:item_position] + new_item + raw[item_position:]
    else:
        close_position = raw.find("    </channel>", channel_position)
        if close_position == -1:
            fail(f"No </channel> element in {arguments.feed}")
        updated = raw[:close_position] + new_item + raw[close_position:]

    arguments.feed.write_text(updated, encoding="utf-8")
    print(f"[INFO] {arguments.feed}: inserted item for v{version} (build {arguments.build}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
