#!/usr/bin/env python3
"""Disable each catalog guard in memory and require the tests to catch it."""

import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import types
import unittest


MUTATIONS = {
    "duplicate JSON key": ("if key in result:", "if False:"),
    "JSON object": ("if not isinstance(catalog, dict):", "if False:"),
    "required locale": (
        "if not isinstance(locale, str) or not LOCALE.fullmatch(locale):", "if False:",
    ),
    "filename locale": (
        "elif expected_locale is not None and locale != expected_locale:", "elif False:",
    ),
    "missing keys": ("if source_keys - target_keys:", "if False:"),
    "extra keys": ("if target_keys - source_keys:", "if False:"),
    "message string": (
        "if not isinstance(original, str) or not isinstance(target, str):", "if False:",
    ),
    "unclosed branch": (
        'if nested:\n            raise ValueError("unclosed ICU branch")',
        'if False:\n            raise ValueError("unclosed ICU branch")',
    ),
    "ICU type": (
        'if kind not in {"plural", "select", "selectordinal"}:', "if False:",
    ),
    "duplicate selector": ("if selector in choices:", "if False:"),
    "plural category": (
        'if kind != "select" and selector not in CATEGORIES and not selector.startswith("="):',
        "if False:",
    ),
    "required other": ('if "other" not in choices:', "if False:"),
    "arguments": (
        "if types_differ or before_structures != after_structures:",
        "if False:",
    ),
    "ICU occurrence counts": (
        "if types_differ or before_structures != after_structures:",
        "if types_differ:",
    ),
    "select cases": ("if before_selects != after_selects:", "if False:"),
    "CJK plural": (
        'if isinstance(locale, str) and locale.split("_")[0] in {"zh", "ja", "ko"}:',
        "if False:",
    ),
    "newlines": ('if original.count("\\n") != target.count("\\n"):', "if False:"),
    "backticks": ('if original.count("`") != target.count("`"):', "if False:"),
    "brands": (
        "if _brand_count(original, brand) > _brand_count(target, brand):", "if False:",
    ),
}


def main():
    directory = Path(__file__).parent
    source = (directory / "translate_check.py").read_text()
    survivors = []
    for name, (before, after) in MUTATIONS.items():
        if source.count(before) != 1:
            raise ValueError(f"mutation anchor must be unique: {name}")
        mutant = types.ModuleType("translate_check")
        sys.modules["translate_check"] = mutant
        exec(compile(source.replace(before, after), "translate_check.py", "exec"), mutant.__dict__)
        spec = importlib.util.spec_from_file_location("guard_tests", directory / "test_translate_check.py")
        tests = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tests)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = unittest.TextTestRunner(stream=output).run(
                unittest.defaultTestLoader.loadTestsFromModule(tests),
            )
        if result.wasSuccessful():
            survivors.append(name)
            print(f"SURVIVED: {name}")
        else:
            print(f"KILLED: {name}")
    print(f"{len(MUTATIONS) - len(survivors)}/{len(MUTATIONS)} guard mutants killed")
    return int(bool(survivors))


if __name__ == "__main__":
    sys.exit(main())
