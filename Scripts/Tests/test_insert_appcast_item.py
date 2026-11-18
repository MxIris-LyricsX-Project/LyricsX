"""Tests for Scripts/insert-appcast-item.py, the step that puts a release into the live Sparkle feeds.

Run from the repository root:

    python3 -m unittest discover -s Scripts/Tests

The generated feeds below copy the shape generate_appcast (Sparkle 2.9.3) wrote for a real LyricsX
zip; GENERATED_WITHOUT_SIGNATURE is what it writes when the private key does not match the app's
SUPublicEDKey: a warning, exit status 0, and an enclosure with no signature.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "insert-appcast-item.py"

LIVE_FEED = """<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>LyricsX</title>
        <description>Most recent changes with links to updates.</description>
        <language>en</language>
        <item>
            <title>1.9.0</title>
            <pubDate>Wed, 11 Nov 2026 12:18:15 +0000</pubDate>
            <sparkle:version>10900999</sparkle:version>
            <sparkle:shortVersionString>1.9.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
            <description><![CDATA[<h2>What's New</h2>]]></description>
            <enclosure url="https://github.com/MxIris-LyricsX-Project/LyricsX/releases/download/v1.9.0/LyricsX_1.9.0+10900999.zip" length="11338057" type="application/octet-stream" sparkle:edSignature="OldSignature==" />
        </item>
        <item>
            <title>1.8.9</title>
            <sparkle:version>10809999</sparkle:version>
            <sparkle:shortVersionString>1.8.9</sparkle:shortVersionString>
        </item>
    </channel>
</rss>
"""


def generated_feed(build: str, short_version: str, signature: str | None, channel: str | None) -> str:
    channel_line = f"            <sparkle:channel>{channel}</sparkle:channel>\n" if channel else ""
    signature_attribute = f' sparkle:edSignature="{signature}"' if signature else ""
    return f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>LyricsX</title>
        <item>
            <title>{short_version}</title>
            <pubDate>Thu, 12 Nov 2026 23:41:03 +0800</pubDate>
{channel_line}            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/MxIris-LyricsX-Project/LyricsX/releases/download/v1.9.1-beta.1/LyricsX_1.9.1-beta.1+{build}.zip" length="11400000" type="application/octet-stream"{signature_attribute}/>
        </item>
    </channel>
</rss>
"""


class InsertAppcastItemTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        self.directory = Path(temporary_directory.name)
        self.feed_path = self.directory / "appcast.xml"
        self.feed_path.write_text(LIVE_FEED, encoding="utf-8")
        self.notes_path = self.directory / "notes_en.md"
        self.notes_path.write_text("# What's New\n\n## Fixes\n\n- The **menu bar** icon is square.\n", encoding="utf-8")

    def run_script(self, generated: str, build: str = "10901101", version: str = "1.9.1-beta.1") -> subprocess.CompletedProcess[str]:
        generated_path = self.directory / "appcast-item.xml"
        generated_path.write_text(generated, encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(SCRIPT_PATH), "--feed", str(self.feed_path), "--generated-feed", str(generated_path),
             "--build", build, "--version", version, "--release-notes", str(self.notes_path)],
            capture_output=True, text=True,
        )

    def test_a_new_release_goes_in_front_and_leaves_every_other_byte(self) -> None:
        result = self.run_script(generated_feed("10901101", "1.9.1", "NewSignature==", "beta"))
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = self.feed_path.read_text(encoding="utf-8")
        first_item_start = LIVE_FEED.index("        <item>")
        self.assertEqual(feed[:first_item_start], LIVE_FEED[:first_item_start])
        self.assertTrue(feed.endswith(LIVE_FEED[first_item_start:]))
        new_item = feed[first_item_start:len(feed) - len(LIVE_FEED[first_item_start:])]
        self.assertIn("<title>1.9.1-beta.1</title>", new_item)
        self.assertIn("<sparkle:shortVersionString>1.9.1-beta.1</sparkle:shortVersionString>", new_item)
        self.assertIn("<sparkle:version>10901101</sparkle:version>", new_item)
        self.assertIn("<sparkle:channel>beta</sparkle:channel>", new_item)
        self.assertIn("<sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>", new_item)
        self.assertIn("<pubDate>Thu, 12 Nov 2026 23:41:03 +0800</pubDate>", new_item)
        self.assertIn(
            'url="https://github.com/MxIris-LyricsX-Project/LyricsX/releases/download/v1.9.1-beta.1/LyricsX_1.9.1-beta.1+10901101.zip"'
            ' length="11400000" type="application/octet-stream" sparkle:edSignature="NewSignature=="',
            new_item,
        )
        self.assertIn("<li>The <strong>menu bar</strong> icon is square.</li>", new_item)

    def test_a_final_release_has_no_channel(self) -> None:
        result = self.run_script(generated_feed("10901999", "1.9.1", "NewSignature==", None), build="10901999", version="1.9.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = self.feed_path.read_text(encoding="utf-8")
        new_item = feed[feed.index("        <item>"):feed.index("        </item>")]
        self.assertIn("<sparkle:version>10901999</sparkle:version>", new_item)
        self.assertNotIn("sparkle:channel", new_item)

    def test_running_a_release_again_replaces_its_item_with_the_new_zip(self) -> None:
        first = self.run_script(generated_feed("10901101", "1.9.1", "FirstSignature==", "beta"))
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.run_script(generated_feed("10901101", "1.9.1", "SecondSignature==", "beta"))
        self.assertEqual(second.returncode, 0, second.stderr)
        feed = self.feed_path.read_text(encoding="utf-8")
        self.assertEqual(feed.count("<sparkle:shortVersionString>1.9.1-beta.1</sparkle:shortVersionString>"), 1)
        self.assertIn('sparkle:edSignature="SecondSignature=="', feed)
        self.assertNotIn("FirstSignature==", feed)
        self.assertEqual(feed.count("        <item>"), 3)
        self.assertTrue(feed.endswith(LIVE_FEED[LIVE_FEED.index("        <item>"):]))

    def test_running_it_again_with_the_same_zip_changes_nothing(self) -> None:
        generated = generated_feed("10901101", "1.9.1", "NewSignature==", "beta")
        self.assertEqual(self.run_script(generated).returncode, 0)
        feed_after_first_run = self.feed_path.read_text(encoding="utf-8")
        second = self.run_script(generated)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("no change", second.stdout)
        self.assertEqual(self.feed_path.read_text(encoding="utf-8"), feed_after_first_run)

    def test_an_unsigned_item_from_a_mismatched_key_leaves_the_feed_alone(self) -> None:
        result = self.run_script(generated_feed("10901101", "1.9.1", None, "beta"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("edSignature", result.stderr)
        self.assertEqual(self.feed_path.read_text(encoding="utf-8"), LIVE_FEED)

    def test_a_generated_feed_without_this_build_leaves_the_feed_alone(self) -> None:
        result = self.run_script(generated_feed("10901102", "1.9.1", "NewSignature==", "beta"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0 items for build 10901101", result.stderr)
        self.assertEqual(self.feed_path.read_text(encoding="utf-8"), LIVE_FEED)


if __name__ == "__main__":
    unittest.main()
