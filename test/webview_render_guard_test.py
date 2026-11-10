"""REVIEW-R5-B #1: Android ends the whole app when a WebView renderer dies
unless a WebViewClient returns true from onRenderProcessGone. Neither
webview_flutter 4.14 nor Android's default does, so Console's own clients
must, for the in-app browser and for noVNC alike."""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
KT = ROOT / "android/app/src/main/kotlin/com/hermesagent/hermes_android"


class WebViewRenderGuardTest(unittest.TestCase):
    def test_delegating_client_survives_a_dead_renderer(self):
        src = (KT / "DelegatingWebViewClient.kt").read_text(encoding="utf-8")
        body = re.search(
            r"override fun onRenderProcessGone\([^)]*\): Boolean \{(.*?)\n    \}",
            src,
            re.S,
        )
        self.assertIsNotNone(body, "onRenderProcessGone must be overridden")
        self.assertIn("onRendererGone()", body.group(1))
        self.assertIn("return true", body.group(1))
        self.assertNotIn("return false", body.group(1))

    def test_novnc_client_is_a_delegating_client(self):
        src = (KT / "ScreenAssetHost.kt").read_text(encoding="utf-8")
        self.assertRegex(src, r"\) : DelegatingWebViewClient\(inner, onRendererGone\)")
        self.assertIn('invokeMethod("renderGone"', src)

    def test_browser_guard_is_registered_and_wraps_the_client(self):
        guard = (KT / "WebViewRenderGuard.kt").read_text(encoding="utf-8")
        self.assertIn("DelegatingWebViewClient(", guard)
        self.assertIn('invokeMethod("renderGone", id)', guard)
        main = (KT / "MainActivity.kt").read_text(encoding="utf-8")
        self.assertIn("WebViewRenderGuard.register(flutterEngine)", main)


if __name__ == "__main__":
    unittest.main()
