# SPDX-FileCopyrightText: 2026 Hermes Console contributors
# SPDX-License-Identifier: GPL-3.0-only
"""Physical retirement guards; requires the existing PyYAML test tool."""
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class MobileBridgeAssetRetirementTest(unittest.TestCase):
    def test_exclusive_mobile_bridge_is_not_declared_or_present(self):
        manifest = yaml.safe_load((ROOT / "pubspec.yaml").read_text())
        assets = manifest["flutter"]["assets"]
        self.assertNotIn("assets/bridge/hermes_bridge.py", assets)
        self.assertFalse((ROOT / "assets/bridge/hermes_bridge.py").exists())
        # A parent directory declaration must not silently repackage it.
        for entry in assets:
            path = ROOT / entry
            if entry.endswith("/") and path.is_dir():
                self.assertFalse(any(p.name == "hermes_bridge.py" for p in path.iterdir()))

    def test_dart_has_no_exclusive_bridge_imports_or_exports(self):
        violations = []
        for directory in ("lib", "test"):
            for path in (ROOT / directory).rglob("*.dart"):
                code = re.sub(r"/\*.*?\*/|//[^\n]*", "", path.read_text(), flags=re.S)
                for directive in re.findall(r"\b(?:import|export)\s+['\"]([^'\"]+)['\"]", code):
                    if Path(directive).name.startswith("bridge_"):
                        violations.append((str(path.relative_to(ROOT)), directive))
        self.assertEqual(violations, [])


if __name__ == "__main__":
    unittest.main()
