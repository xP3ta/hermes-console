import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "android/app/src/main/AndroidManifest.xml"
RECEIVER = (
    ROOT
    / "android/app/src/main/kotlin/com/hermesagent/hermes_android"
    / "HermesAutomationRebootReceiver.kt"
)


class RebootReceiverActionsTest(unittest.TestCase):
    """The receiver is exported, so it may only accept system-protected actions."""

    PROTECTED = {
        "android.intent.action.BOOT_COMPLETED",
        "android.intent.action.MY_PACKAGE_REPLACED",
    }

    def test_manifest_filter_has_only_protected_broadcasts(self):
        text = MANIFEST.read_text()
        block = re.search(
            r'<receiver\s+android:name="\.HermesAutomationRebootReceiver".*?</receiver>',
            text,
            re.S,
        )
        self.assertIsNotNone(block)
        actions = set(re.findall(r'<action android:name="([^"]+)"', block.group(0)))
        self.assertEqual(actions, self.PROTECTED)
        self.assertNotIn("intent.action.QUICKBOOT", text)

    def test_receiver_code_rejects_unprotected_actions(self):
        code = RECEIVER.read_text()
        self.assertNotIn("intent.action.QUICKBOOT", code)
        self.assertIn("Intent.ACTION_BOOT_COMPLETED", code)
        self.assertIn("Intent.ACTION_MY_PACKAGE_REPLACED", code)
        self.assertIn("!isSupported(intent.action)", code)


class CoreLabelWorkflowTest(unittest.TestCase):
    def test_label_job_skips_fork_pull_requests(self):
        text = (ROOT / ".github/workflows/review-core-label.yml").read_text()
        self.assertIn(
            "if: github.event.pull_request.head.repo.full_name == github.repository",
            text,
        )
        self.assertNotIn("pull_request_target", text)


if __name__ == "__main__":
    unittest.main()
