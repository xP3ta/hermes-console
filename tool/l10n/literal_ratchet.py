#!/usr/bin/env python3
"""Inventory every Dart string in lib, including strings inside interpolation.

This is a lexical ratchet, not a claim to infer visibility/data flow. Every new
literal (even in a helper, service, ternary or custom widget) needs an explicit
reviewed entry. The ten named generated ARB outputs are the only excluded files. Counts
prevent reusing an allowed spelling at a new call site unnoticed.
"""
from collections import Counter
import json
from pathlib import Path


class DartStrings:
    def __init__(self, source):
        self.source = source
        self.rows = []

    def comment(self, i):
        s = self.source
        if s.startswith('//', i):
            end = s.find('\n', i)
            return len(s) if end < 0 else end
        if s.startswith('/*', i):
            depth = 1
            i += 2
            while i < len(s) and depth:
                if s.startswith('/*', i):
                    depth += 1
                    i += 2
                elif s.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            return i
        return i

    def code(self, i=0, interpolation=False):
        s = self.source
        depth = 1
        while i < len(s):
            end = self.comment(i)
            if end != i:
                i = end
                continue
            raw = s[i] == 'r' and i + 1 < len(s) and s[i + 1] in "\"'"
            if s[i] in "\"'" or raw:
                i = self.string(i, raw)
            elif interpolation and s[i] == '{':
                depth += 1
                i += 1
            elif interpolation and s[i] == '}':
                depth -= 1
                i += 1
                if depth == 0:
                    return i
            else:
                i += 1
        if interpolation:
            raise ValueError('Unclosed interpolation')
        return i

    def string(self, start, raw):
        s = self.source
        i = start + int(raw)
        quote = s[i:i + 3] if s[i:i + 3] in ('"""', "'''") else s[i]
        i += len(quote)
        text = []
        while i < len(s):
            if s.startswith(quote, i):
                end = i + len(quote)
                self.rows.append({'offset': start, 'line': s.count('\n', 0, start) + 1,
                                  'literal': s[start:end], 'text': ''.join(text)})
                return end
            if not raw and s[i] == '\\':
                text.append(s[i:i + 2])
                i += 2
            elif not raw and s.startswith('${', i):
                i = self.code(i + 2, interpolation=True)
                text.append('{…}')
            elif not raw and s[i] == '$' and i + 1 < len(s) and (s[i + 1].isascii() and (s[i + 1].isalpha() or s[i + 1] == '_')):
                i += 2
                while i < len(s) and s[i].isascii() and (s[i].isalnum() or s[i] == '_'):
                    i += 1
                text.append('{…}')
            else:
                text.append(s[i])
                i += 1
        raise ValueError(f'Unclosed string at line {s.count(chr(10), 0, start) + 1}')

    def scan(self):
        self.code()
        return sorted(self.rows, key=lambda row: row['offset'])


def inventory(root=Path('lib')):
    result = []
    for path in sorted(root.rglob('*.dart')):
        generated = {'app_localizations.dart', *(f'app_localizations_{lang}.dart' for lang in ('es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'))}
        if path.parent == root / 'l10n' and path.name in generated:
            continue  # Generated Strings API; ARB parity guards its inputs.
        for row in DartStrings(path.read_text(encoding='utf-8')).scan():
            result.append({'path': path.as_posix(), **row})
    return result


def counts(rows):
    return Counter((row['path'], row['literal']) for row in rows)


def check(rows, allowlist):
    actual = counts(rows)
    expected = Counter()
    for path, entries in allowlist.items():
        for entry in entries:
            if not entry['reason'].strip() or entry['count'] < 1:
                raise ValueError(f'Missing review reason or count: {path}')
            key = (path, entry['literal'])
            if key in expected:
                raise ValueError(f'Duplicate allowlist entry: {key}')
            expected[key] = entry['count']
    return actual - expected, expected - actual


if __name__ == '__main__':
    allowed = json.loads(Path('tool/l10n/literal_allowlist.json').read_text(encoding='utf-8'))
    added, removed = check(inventory(), allowed)
    for kind, changes in [('UNREVIEWED', added), ('STALE', removed)]:
        for (path, literal), count in sorted(changes.items()):
            print(f'{kind} {path}: {literal!r} (x{count})')
    if added or removed:
        raise SystemExit(1)
    print('PASS: all lib Dart literals match the reviewed allowlist and counts')
