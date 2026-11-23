"""Renders THIRD_PARTY_NOTICES.md and the licence texts into the credits the About Arx panel shows.

`make credits` writes `Containers/macOS/Credits.rtf`, which the container copies into the app's
Resources; AppFeature's About Arx shows it. RTF rather than HTML: AppKit imports HTML through
WebKit, which takes seconds on the main thread. A unit test fails when the file is out of date.
"""

import re
import sys
from pathlib import Path

from .core.paths import ROOT


NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
ARX_LICENSE = ROOT / "LICENSE"
HELIUM_LICENSE = ROOT / "Packages/engine/Licenses/helium/LICENSE"
LICENSES = ROOT / "Distribution/Licenses"
CREDITS = ROOT / "Containers/macOS/Credits.rtf"

INTRODUCTION = (
    "Arx is free software: you can redistribute it and modify it under the terms of the GNU General "
    "Public License, version 3. It comes with no warranty. Arx is built on the software below. The "
    "licences follow, starting with the GNU General Public License, version 3, which covers Arx and "
    "the Helium engine."
)
LICENCE_TITLES = {
    "ungoogled-chromium.txt": "ungoogled-chromium licence (BSD 3-Clause)",
    "chromium.txt": "Chromium licence (BSD 3-Clause)",
    "MIT.txt": "MIT License",
    "Apache-2.0.txt": "Apache License, Version 2.0",
    "swift-nio-NOTICE.txt": "SwiftNIO NOTICE",
    "swift-log-NOTICE.txt": "SwiftLog NOTICE",
    "Sparkle.txt": "Sparkle licence and the licences of code it includes",
}
HEADER = r"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}{\f1\fmodern Menlo;}}\f0\fs22"


def escape(text):
    """RTF-escapes plain text; anything outside ASCII becomes \\uN with a ? fallback."""
    output = []
    for character in text:
        if character in "\\{}":
            output.append("\\" + character)
        elif character == "\t":
            output.append("\\tab ")
        elif ord(character) < 128:
            output.append(character)
        else:
            for unit in character.encode("utf-16-be").hex(" ", 2).split():
                value = int(unit, 16)
                output.append(f"\\u{value - 65536 if value > 32767 else value}?")
    return "".join(output)


def link(label, target):
    return f'{{\\field{{\\*\\fldinst{{HYPERLINK "{escape(target)}"}}}}{{\\fldrslt {label}}}}}'


def inline(text):
    """Code spans, bold and links. Relative links name files in the source tree, so only their text stays."""
    rendered = []
    for part in re.split(r"(`[^`]+`)", text):
        if part.startswith("`") and part.endswith("`") and len(part) > 1:
            rendered.append(f"{{\\f1\\fs20 {escape(part[1:-1])}}}")
            continue
        pieces = re.split(r"(\[[^\]]+\]\([^)]+\)|<https?://[^>\s]+>|\*\*.+?\*\*)", part)
        for piece in pieces:
            if match := re.fullmatch(r"\[([^\]]+)\]\(([^)]+)\)", piece):
                label, target = escape(match.group(1)), match.group(2)
                rendered.append(link(label, target) if re.match(r"https?://", target) else label)
            elif match := re.fullmatch(r"<(https?://[^>\s]+)>", piece):
                rendered.append(link(escape(match.group(1)), match.group(1)))
            elif match := re.fullmatch(r"\*\*(.+?)\*\*", piece):
                rendered.append(f"{{\\b {escape(match.group(1))}}}")
            else:
                rendered.append(escape(piece))
    return "".join(rendered)


def heading(text, level=2):
    size = {1: 28, 2: 24, 3: 22}[level]
    return f"\\pard\\sb240\\sa80{{\\b\\fs{size} {text}}}\\par"


def paragraph(text):
    return f"\\pard\\sa120 {text}\\par"


def preformatted(text):
    lines = "\\line ".join(escape(line) for line in text.rstrip("\n").splitlines())
    return f"\\pard\\sa120{{\\f1\\fs18 {lines}}}\\par"


def markdown(source):
    """The subset THIRD_PARTY_NOTICES.md uses: headings, paragraphs, lists, tables and fenced code."""
    output, words, lines = [], [], source.splitlines()
    index = 0

    def flush():
        if words:
            output.append(paragraph(inline(" ".join(words))))
            words.clear()

    while index < len(lines):
        line = lines[index]
        if line.startswith("```"):
            flush()
            block = []
            index += 1
            while index < len(lines) and not lines[index].startswith("```"):
                block.append(lines[index])
                index += 1
            output.append(preformatted("\n".join(block)))
        elif match := re.match(r"(#{1,3}) (.*)", line):
            flush()
            output.append(heading(inline(match.group(2)), len(match.group(1))))
        elif line.startswith("- "):
            flush()
            while index < len(lines) and lines[index].startswith("- "):
                output.append(f"\\pard\\li240\\fi-240\\sa60 \\bullet\\tab {inline(lines[index][2:])}\\par")
                index += 1
            continue
        elif line.startswith("|"):
            flush()
            first = True
            while index < len(lines) and lines[index].startswith("|"):
                cells = [cell.strip() for cell in lines[index].strip().strip("|").split("|")]
                if not all(re.fullmatch(r"-+", cell) for cell in cells):
                    row = " \\u8212? ".join(inline(cell) for cell in cells)
                    output.append(f"\\pard\\sa40 {{\\b {row}}}\\par" if first else f"\\pard\\sa40 {row}\\par")
                    first = False
                index += 1
            continue
        elif not line.strip():
            flush()
        else:
            words.append(line.strip())
        index += 1
    flush()
    return "\n".join(output)


def render():
    sections = [
        HEADER,
        paragraph(escape(INTRODUCTION)),
        markdown(NOTICES.read_text()),
        heading("Arx and Helium licence: GNU General Public License, version 3"),
        preformatted(ARX_LICENSE.read_text()),
    ]
    for name, title in LICENCE_TITLES.items():
        sections.append(heading(escape(title)))
        sections.append(preformatted((LICENSES / name).read_text()))
    sections.append("}")
    return "\n".join(sections) + "\n"


def main(arguments=()):
    CREDITS.write_text(render())
    print(f"Wrote {CREDITS.relative_to(ROOT)}", flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
