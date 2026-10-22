#!/usr/bin/env python3
"""Check localized Android XML resources without Android, Dart or Flutter.

Spanish is the key/placeholder reference. Existing Portuguese and default
English resources are checked too. Android configuration folders (night, v31)
are not locales. Nontranslatable resources are excluded from message parity.
"""

import argparse
from collections import Counter
from pathlib import Path
import re
import xml.etree.ElementTree as ET

FILES = ('strings.xml', 'launcher_widgets_strings.xml', 'new_session_widget.xml')
LOCALE_DIRECTORY = re.compile(r'values-(?:[a-z]{2,3}(?:-r[A-Z]{2})?|b\+[^/]+)$')
FORMAT = re.compile(r'%(?:\d+\$)?[-#+ 0,(<]*\d*(?:\.\d+)?[tT]?[a-zA-Z%]')
QUANTITIES = {'zero', 'one', 'two', 'few', 'many', 'other'}


def _require(condition, guard, detail):
    if not condition:
        raise ValueError(f'[{guard}] {detail}')


def _check_text(text):
    _require(bool(text.strip()), 'empty', 'empty message')
    # Android quoting protects apostrophes and leading resource sigils.
    # Only an odd number of backslashes escapes the following character.
    quoted = False
    first = True
    i = 0
    while i < len(text):
        char = text[i]
        if char == '\\':
            i += 2
            first = False
            continue
        if char == '"':
            quoted = not quoted
        elif char == "'":
            _require(quoted, 'apostrophe', 'unescaped apostrophe')
        elif char in '@?' and first:
            _require(quoted, 'sigil', 'escape leading @ or ?')
        if not char.isspace() and char != '"':
            first = False
        i += 1
    _require(not quoted, 'quote', 'unclosed Android quote')


def read_resources(path):
    root = ET.parse(path).getroot()
    _require(root.tag == 'resources', 'root', 'XML root must be resources')
    messages = {}
    for element in root:
        if element.get('translatable') == 'false':
            continue
        name = element.get('name')
        _require(bool(name), 'name', 'resource needs a name')
        _require(name not in messages, 'duplicate', f'duplicate name {name}')
        _require(element.tag in {'string', 'plurals'}, 'type',
                 f'{name}: unsupported resource type {element.tag}')
        if element.tag == 'string':
            values = [''.join(element.itertext())]
        else:
            quantities = [item.get('quantity') for item in element]
            _require(len(quantities) == len(set(quantities)) and
                     all(q in QUANTITIES for q in quantities), 'quantity',
                     f'{name}: invalid or duplicate plural quantity')
            _require('other' in quantities, 'other', f'{name}: missing other')
            values = [''.join(item.itertext()) for item in element]
        for value in values:
            _check_text(value)
        messages[name] = (element.tag, values)
    return messages


def _signature(text):
    return Counter(FORMAT.findall(text) + re.findall(r'\\[ntr]', text))


def check_resources(resource_root):
    resource_root = Path(resource_root)
    errors = []
    directories = sorted(p for p in resource_root.iterdir()
                         if p.is_dir() and (p.name == 'values' or
                                           LOCALE_DIRECTORY.fullmatch(p.name)))
    # Always require the Spanish reference, even when the whole folder is absent.
    reference_dir = resource_root / 'values-es'
    if reference_dir not in directories:
        directories.append(reference_dir)
    for filename in FILES:
        parsed = {}
        for directory in directories:
            path = directory / filename
            try:
                _require(path.is_file(), 'file', f'missing file {path}')
                parsed[directory] = read_resources(path)
            except ET.ParseError as error:
                errors.append(f'{path}: [XML] {error}')
            except (OSError, ValueError) as error:
                errors.append(f'{path}: {error}')
        reference = parsed.get(reference_dir)
        if reference is None:
            continue
        for directory, catalog in parsed.items():
            try:
                _require(not reference.keys() - catalog.keys(), 'missing',
                         'missing keys: ' + ', '.join(sorted(reference.keys() - catalog.keys())))
                _require(not catalog.keys() - reference.keys(), 'extra',
                         'extra keys: ' + ', '.join(sorted(catalog.keys() - reference.keys())))
                for name in reference.keys() & catalog.keys():
                    kind, values = catalog[name]
                    expected_kind, expected_values = reference[name]
                    _require(kind == expected_kind, 'type', f'{name}: resource type differs')
                    # Plural categories vary by language. Every branch must have
                    # the same format arguments as the reference's branches.
                    for value in values:
                        _require(any(_signature(value) == _signature(v)
                                     for v in expected_values), 'placeholders',
                                 f'{name}: placeholders differ')
            except ValueError as error:
                errors.append(f'{directory / filename}: {error}')
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('resource_root', nargs='?', type=Path,
                        default=Path('android/app/src/main/res'))
    args = parser.parse_args(argv)
    try:
        errors = check_resources(args.resource_root)
    except OSError as error:
        parser.error(str(error))
    if errors:
        for error in errors:
            print('FAIL ' + error)
        return 1
    print('PASS Android XML: exact keys, resource types, placeholders and escapes')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
