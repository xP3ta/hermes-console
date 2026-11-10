"""REVIEW-R5-B #4: the Dashboard refuses a display WebSocket whose http(s)
Origin is not its bound host (hermes_cli/web_server_boundary.py
ws_host_origin_reason) and trusts a non-web Origin. bridge.html is served
from https://appassets.androidplatform.net, so its socket is opened from a
sandboxed frame (opaque origin: Origin null)."""

import base64
import hashlib
import pathlib
import re
import unittest

NOVNC = pathlib.Path(__file__).resolve().parents[1] / "assets/novnc"


def _csp(html: str) -> str:
    match = re.search(
        r'<meta http-equiv="Content-Security-Policy" content="([^"]+)">', html
    )
    assert match, "no CSP"
    return match.group(1)


def _hash(text: str) -> str:
    digest = hashlib.sha256(text.encode("utf-8")).digest()
    return "'sha256-" + base64.b64encode(digest).decode() + "'"


class NovncOriginTest(unittest.TestCase):
    def test_bridge_hands_noVNC_the_null_origin_channel(self):
        html = (NOVNC / "bridge.html").read_text(encoding="utf-8")
        self.assertIn("import NullOriginSocket from './null-origin-socket.js';", html)
        self.assertIn("new NullOriginSocket(wsUrl)", html)
        self.assertNotRegex(html, r"new RFB\([^)]*,\s*wsUrl\s*,")
        csp = _csp(html)
        self.assertIn("frame-src 'self';", csp)
        self.assertNotIn("unsafe", csp)

    def test_the_relay_frame_has_an_opaque_origin(self):
        src = (NOVNC / "null-origin-socket.js").read_text(encoding="utf-8")
        sandbox = re.findall(r"setAttribute\('sandbox', '([^']*)'\)", src)
        self.assertEqual(sandbox, ["allow-scripts"])
        # Never widened afterwards (allow-same-origin would give it our origin).
        self.assertNotIn("sandbox.add", src)
        self.assertNotIn("sandbox =", src)

    def test_the_relay_only_runs_its_hashed_script_and_opens_sockets(self):
        html = (NOVNC / "ws-relay.html").read_text(encoding="utf-8")
        scripts = re.findall(r"<script>(.*?)</script>", html, re.S)
        self.assertEqual(len(scripts), 1)
        csp = _csp(html)
        self.assertTrue(csp.startswith("default-src 'none';"))
        self.assertIn("script-src " + _hash(scripts[0]) + ";", csp)
        self.assertIn("connect-src ws: wss:;", csp)
        # It answers its parent only, once, and only for ws(s) URLs.
        self.assertIn("event.source !== window.parent", scripts[0])
        self.assertIn("/^wss?:\\/\\//i.test(data.url)", scripts[0])


if __name__ == "__main__":
    unittest.main()
