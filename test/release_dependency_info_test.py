"""The direct APK carries no AGP dependency-information block.

AGP adds library-dependency metadata, "compressed, encrypted by a Google Play
signing key, and stored in the signing block" of release apps
(developer.android.com/build/dependencies). In 1.4.1 that block (APK Signing
Block id 0x504b4453, AGP 9.0.1 apkzlib SigningExtension.DEPENDENCY_INFO_BLOCK_ID)
was the only difference between two otherwise identical universal APKs, so
the direct lane's byte-identity gate could never pass. The APK leaves it out;
the Play bundle keeps it (the Play comparison does not read the signing block).
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GRADLE = ROOT / "android/app/build.gradle.kts"


def dependencies_info_block(text: str) -> str | None:
    match = re.search(r"\bdependenciesInfo\s*\{([^{}]*)\}", text)
    return match.group(1) if match else None


class DependencyInfoTest(unittest.TestCase):
    def test_the_apk_leaves_out_the_dependency_information_block(self):
        block = dependencies_info_block(GRADLE.read_text(encoding="utf-8"))
        self.assertIsNotNone(block, "android { dependenciesInfo { … } } is declared")
        self.assertRegex(block, r"\bincludeInApk\s*=\s*false\b")

    def test_the_play_bundle_keeps_it(self):
        block = dependencies_info_block(GRADLE.read_text(encoding="utf-8")) or ""
        self.assertNotRegex(block, r"\bincludeInBundle\s*=\s*false\b")


if __name__ == "__main__":
    unittest.main()
