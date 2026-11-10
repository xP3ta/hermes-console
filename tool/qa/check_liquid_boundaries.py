#!/usr/bin/env python3
"""Source-only material ratchet; never invokes Dart, Flutter or a device."""

import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
FILTER_OWNERS = {
    "lib/core/design/glass_strip.dart",
    "lib/core/widgets/frosted_backdrop.dart",  # legacy adapter, same policy
    "lib/core/design/smoked_glass.dart",  # glass_strip's blur-then-tone filter
}
FILTER = re.compile(r"\b(?:BackdropFilter\s*\(|ImageFilter\s*\.\s*(?:blur|shader)\s*\()")
MATERIAL = re.compile(r"\b(?:HermesGlassStrip|HermesLiquidSurface|FrostedBackdrop)(?:\s*\.\s*glass)?\s*\(")
CALLBACK = re.compile(r"\b(?:itemBuilder|separatorBuilder)\s*:")
# Preserve positions/newlines, and ignore tokens in comments and strings.
IGNORED = re.compile(r"//[^\n]*|/\*[\s\S]*?\*/|r?(?:'''[\s\S]*?'''|\"\"\"[\s\S]*?\"\"\"|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\")")


def code_only(source):
    return IGNORED.sub(lambda match: re.sub(r"[^\n]", " ", match.group()), source)


def callback_end(code, start):
    """An expression/block ends at a comma or close at the caller's depth."""
    stack = []
    pairs = {"(": ")", "[": "]", "{": "}"}
    for pos in range(start, len(code)):
        char = code[pos]
        if char in pairs:
            stack.append(pairs[char])
        elif char in ")]}":
            if not stack:
                return pos
            if stack[-1] != char:
                raise ValueError(f"unbalanced callback at character {pos}")
            stack.pop()
        elif char == "," and not stack:
            return pos
    return len(code)


def violations(path, source):
    code = code_only(source)
    found = []
    if path not in FILTER_OWNERS:
        found += [(m.start(), "filter outside shared renderer") for m in FILTER.finditer(code)]
    for callback in CALLBACK.finditer(code):
        end = callback_end(code, callback.end())
        found += [(m.start(), "material inside collection builder")
                  for m in MATERIAL.finditer(code, callback.end(), end)]
    return [f"{path}:{source.count(chr(10), 0, pos) + 1}: {why}" for pos, why in found]


def self_test():
    assert violations("lib/screen.dart", "BackdropFilter(filter: f)")
    assert violations("lib/screen.dart", "ImageFilter.shader(s)")
    assert not violations("lib/screen.dart", "// BackdropFilter()\nText('ImageFilter.blur()')")
    assert violations("lib/screen.dart", "ListView(itemBuilder: (_, i) => FrostedBackdrop.glass(child: w),)")
    assert violations("lib/screen.dart", "ListView(itemBuilder: (_, i) { return HermesGlassStrip(child: w); })")
    assert not violations("lib/screen.dart", "HermesGlassStrip(child: ListView(itemBuilder: (_, i) => Text('$i')))")
    assert not violations("lib/screen.dart", "ListView(itemBuilder: (_, i) => Text('$i')), HermesGlassStrip(child: w)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    errors = []
    files = sorted((ROOT / "lib").rglob("*.dart"))
    for path in files:
        errors += violations(path.relative_to(ROOT).as_posix(), path.read_text())
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"liquid boundaries: {len(files)} Dart sources, no escaped/per-row filters")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
