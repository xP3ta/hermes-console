#!/usr/bin/env python3
"""Validate translated ARB catalogs without dependencies or Flutter.

This checks the unescaped ICU subset used by the app. Flutter gen-l10n is
still required: this tool does not replace its parser or a linguistic review.
"""

import argparse
from collections import Counter
from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys


BRANDS = (
    "Hermes", "Console", "Nous", "XPeta Lab", "OpenAI", "OpenRouter",
    "GitHub", "Google Play", "Telegram", "Discord", "Android", "Claude",
    "Obtainium", "Tailscale", "WireGuard",
)
LOCALE = re.compile(r"[a-z]{2,3}(?:_[A-Z][a-z]{3})?(?:_(?:[A-Z]{2}|[0-9]{3}))?\Z")
IDENTIFIER = re.compile(r"[A-Za-z][A-Za-z0-9_]*")
CATEGORIES = {"zero", "one", "two", "few", "many", "other"}


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_catalog(path):
    catalog = json.loads(Path(path).read_text(encoding="utf-8"),
                         object_pairs_hook=_unique_object)
    if not isinstance(catalog, dict):
        raise ValueError("catalog must be a JSON object")
    return catalog


@dataclass
class Argument:
    name: str
    kind: str
    choices: dict
    start: int
    end: int


class IcuParser:
    """Balanced recursive parser; positions also support plural normalization."""

    def __init__(self, text):
        self.text = text
        self.pos = 0
        self.arguments = []

    def _space(self):
        while self.pos < len(self.text) and self.text[self.pos].isspace():
            self.pos += 1

    def _expect(self, char):
        self._space()
        if self.pos >= len(self.text) or self.text[self.pos] != char:
            raise ValueError(f"expected {char!r} at {self.pos}")
        self.pos += 1

    def _identifier(self):
        self._space()
        match = IDENTIFIER.match(self.text, self.pos)
        if not match:
            raise ValueError(f"expected argument identifier at {self.pos}")
        self.pos = match.end()
        return match.group()

    def parse(self):
        self._message(False)
        return self.arguments

    def _message(self, nested):
        while self.pos < len(self.text):
            char = self.text[self.pos]
            if char == "}":
                if not nested:
                    raise ValueError(f"unexpected closing brace at {self.pos}")
                return
            if char == "{":
                self._argument()
            else:
                self.pos += 1
        if nested:
            raise ValueError("unclosed ICU branch")

    def _argument(self):
        start = self.pos
        self._expect("{")
        name = self._identifier()
        self._space()
        if self.pos < len(self.text) and self.text[self.pos] == "}":
            self.pos += 1
            self.arguments.append(Argument(name, "value", {}, start, self.pos))
            return
        self._expect(",")
        kind = self._identifier()
        if kind not in {"plural", "select", "selectordinal"}:
            raise ValueError(f"unsupported ICU type {kind!r}")
        self._expect(",")
        choices = {}
        while True:
            self._space()
            if self.pos >= len(self.text):
                raise ValueError("unclosed ICU argument")
            if self.text[self.pos] == "}":
                self.pos += 1
                break
            match = re.match(r"(?:=[0-9]+|[A-Za-z_][A-Za-z0-9_]*)", self.text[self.pos:])
            if not match:
                raise ValueError(f"invalid ICU selector at {self.pos}")
            selector = match.group()
            self.pos += len(selector)
            if selector in choices:
                raise ValueError(f"duplicate ICU selector {selector}")
            if kind != "select" and selector not in CATEGORIES and not selector.startswith("="):
                raise ValueError(f"invalid plural category {selector}")
            self._expect("{")
            body_start = self.pos
            self._message(True)
            choices[selector] = self.text[body_start:self.pos]
            self._expect("}")
        if "other" not in choices:
            raise ValueError("ICU argument requires other")
        self.arguments.append(Argument(name, kind, choices, start, self.pos))


def _brand_count(message, brand):
    # ASCII boundaries allow native suffixes and adjacent CJK characters.
    return len(re.findall(r"(?<![A-Za-z0-9_])" + re.escape(brand)
                          + r"(?![A-Za-z0-9_])", message))


def validate_catalog(source, translated, expected_locale=None):
    errors = []
    locale = translated.get("@@locale")
    if not isinstance(locale, str) or not LOCALE.fullmatch(locale):
        errors.append("missing or invalid @@locale")
    elif expected_locale is not None and locale != expected_locale:
        errors.append(f"filename locale {expected_locale} differs from @@locale {locale}")
    source_keys = {key for key in source if not key.startswith("@")}
    target_keys = {key for key in translated if not key.startswith("@")}
    if source_keys - target_keys:
        errors.append("missing keys: " + ", ".join(sorted(source_keys - target_keys)))
    if target_keys - source_keys:
        errors.append("extra keys: " + ", ".join(sorted(target_keys - source_keys)))
    for key in sorted(source_keys & target_keys):
        original, target = source[key], translated[key]
        if not isinstance(original, str) or not isinstance(target, str):
            errors.append(f"{key}: message must be a string")
            continue
        try:
            before = IcuParser(original).parse()
            after = IcuParser(target).parse()
        except ValueError as error:
            errors.append(f"{key}: ICU: {error}")
            continue
        before_structures = Counter((a.name, a.kind) for a in before if a.kind != "value")
        after_structures = Counter((a.name, a.kind) for a in after if a.kind != "value")
        types_differ = {(a.name, a.kind) for a in before} != {(a.name, a.kind) for a in after}
        if types_differ or before_structures != after_structures:
            errors.append(f"{key}: arguments or ICU structures differ")
        before_selects = Counter((a.name, tuple(sorted(a.choices))) for a in before if a.kind == "select")
        after_selects = Counter((a.name, tuple(sorted(a.choices))) for a in after if a.kind == "select")
        if before_selects != after_selects:
            errors.append(f"{key}: select cases differ")
        if isinstance(locale, str) and locale.split("_")[0] in {"zh", "ja", "ko"}:
            if any(a.kind in {"plural", "selectordinal"} and set(a.choices) != {"other"} for a in after):
                errors.append(f"{key}: {locale} plurals must use only other")
        if original.count("\n") != target.count("\n"):
            errors.append(f"{key}: newlines differ")
        if original.count("`") != target.count("`"):
            errors.append(f"{key}: backticks differ")
        for brand in BRANDS:
            if _brand_count(original, brand) > _brand_count(target, brand):
                errors.append(f"{key}: brand {brand} was removed or translated")
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalogs", nargs="+", type=Path)
    parser.add_argument("--source", type=Path, default=Path("lib/l10n/app_es.arb"))
    args = parser.parse_args(argv)
    try:
        source = load_catalog(args.source)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    failed = False
    for path in args.catalogs:
        try:
            catalog = load_catalog(path)
            expected = path.stem.removeprefix("app_")
            errors = validate_catalog(source, catalog, expected)
        except (ValueError, OSError) as error:
            errors = [str(error)]
        if errors:
            failed = True
            print(f"FAIL {path}: {len(errors)} error(s)")
            for error in errors:
                print(f"  {error}")
        else:
            count = sum(not key.startswith("@") for key in catalog)
            print(f"PASS {path}: {count} messages")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
