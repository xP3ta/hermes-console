#!/usr/bin/env python3
"""Report statically identifiable UI literals outside ARB (not a Dart AST).

Counts are candidates, not an exhaustive semantic inventory: computed copy,
concatenation and custom widgets can contain additional text. Technical names
and symbols remain candidates; a person must assess translation needs.
"""

from collections import Counter
import json
from pathlib import Path
import re


TOKENS = re.compile(
    r'(?P<comment>//[^\n]*|/\*[\s\S]*?\*/)'
    r'|(?P<string>r?(?:"""[\s\S]*?"""|\x27\x27\x27[\s\S]*?\x27\x27\x27'
    r'|"(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27))'
)
VISIBLE = re.compile(
    r'(?:\b(?:Text|SelectableText)\s*\(\s*(?:r)?'
    r'|\b(?:label|title|subtitle|caption|tooltip|hintText|labelText|helperText|'
    r'errorText|semanticLabel|semanticsLabel|message|description)\s*:\s*(?:r)?)$'
)


def inventory(root=Path("lib")):
    entries = []
    for path in sorted(root.rglob("*.dart")):
        if "l10n" in path.parts:
            continue
        source = path.read_text()
        tokens = list(TOKENS.finditer(source))
        clean = list(source)
        for token in tokens:
            if token.lastgroup == "comment":
                clean[token.start():token.end()] = ["\n" if c == "\n" else " " for c in token.group()]
        clean = "".join(clean)
        helpers = re.findall(
            r'String\s+([A-Za-z_]\w*)\(\s*String es\w*\s*,\s*String en\w*\s*\)', clean,
        )
        for token in tokens:
            if token.lastgroup != "string":
                continue
            prefix = clean[max(0, token.start() - 120):token.start()]
            category = None
            for helper in helpers:
                if re.search(r'\b' + re.escape(helper) + r'\(\s*$', prefix):
                    category = ("bilingual _text(es, en)" if helper == "_text"
                                else "other bilingual helper")
                    break
            if category is None and re.search(r'\b(?:_english|_isEnglish|isEnglish|english|spanish|_spanish|_es|_en)\s*\?\s*$', prefix):
                category = "bilingual conditional candidate"
            elif category is None and VISIBLE.search(prefix):
                category = "UI literal candidate"
            if category:
                entries.append({
                    "path": str(path),
                    "line": source.count("\n", 0, token.start()) + 1,
                    "category": category,
                    "literal": token.group(),
                })
    return entries


if __name__ == "__main__":
    rows = inventory()
    print(json.dumps({"counts": dict(Counter(row["category"] for row in rows)),
                      "entries": rows}, ensure_ascii=False, indent=2))
