#!/usr/bin/env python3
"""Generate LyricsX's okurigana fallback from the official KANJIDIC2 XML.gz."""
import argparse
import gzip
import hashlib
import re
from collections import defaultdict
from pathlib import Path
from xml.etree import ElementTree

OKURIGANA = re.compile(r"([ぁ-ゖー]+)\.([ぁ-ゖー]+)")
CODE_TYPES = {"ucs", "jis208", "jis212", "jis213"}
DEFAULT_OUTPUT = (Path(__file__).resolve().parents[1]
                  / "LyricsX/Supporting Files/JapaneseOkurigana.tsv")


def generate(source):
    root = ElementTree.fromstring(gzip.decompress(source))
    characters = root.findall("character")
    codes, readings, aliases = {}, defaultdict(set), defaultdict(set)
    for entry in characters:
        glyph = entry.findtext("literal")
        if not glyph or len(glyph) != 1:
            continue
        for code in entry.findall("codepoint/cp_value"):
            kind = code.get("cp_type")
            if kind in CODE_TYPES:
                codes[kind, code.text] = glyph
        for reading in entry.findall(".//reading[@r_type='ja_kun']"):
            if match := OKURIGANA.fullmatch(reading.text or ""):
                readings[glyph].add(match.groups())
    for entry in characters:
        glyph = entry.findtext("literal")
        for variant in entry.findall("misc/variant"):
            other = codes.get((variant.get("var_type"), variant.text))
            if other and other != glyph:
                aliases[glyph].add(other)

    version = root.findtext("header/database_version")
    if not version or not readings:
        raise ValueError("Expected versioned KANJIDIC2 with dotted kun readings")
    yield f"# KANJIDIC2 {version}; source SHA256: {hashlib.sha256(source).hexdigest()}"
    yield "# Glyph<TAB>okurigana<TAB>kanji reading; see KANJIDIC2-LICENSE.html"
    for glyph in sorted(readings.keys() | aliases.keys()):
        forms = readings[glyph].copy()
        # Use only reciprocal, explicitly encoded variants, not transitive
        # links or a generic traditional-to-simplified Chinese conversion.
        for other in aliases[glyph]:
            if glyph in aliases[other]:
                forms.update(readings.get(other, ()))
        for stem, suffix in sorted(forms, key=lambda form: (form[1], form[0])):
            yield f"{glyph}\t{suffix}\t{stem}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="downloaded kanjidic2.xml.gz")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    args.output.write_bytes(("\n".join(generate(args.source.read_bytes())) + "\n").encode())


if __name__ == "__main__":
    main()
