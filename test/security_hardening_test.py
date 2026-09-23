import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_bridge(home):
    web = types.SimpleNamespace(json_response=lambda data, status=200, **_: data)
    aiohttp = types.ModuleType("aiohttp")
    aiohttp.web = web
    sys.modules["aiohttp"] = aiohttp
    os.environ["BRIDGE_HERMES_HOME"] = str(home)
    os.environ["BRIDGE_TOKEN"] = "security-test-token"
    return load_module(
        "bridge_security_test_module",
        ROOT / "assets/bridge/hermes_bridge.py",
    )


class BridgeUrlSecurityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bridge-url-test-")
        self.bridge = load_bridge(Path(self.temp.name))

    def tearDown(self):
        self.temp.cleanup()

    def test_configurable_base_url_allows_only_http_and_https(self):
        self.assertEqual(
            self.bridge._normalize_base_url("https://models.example/api"),
            "https://models.example/api/v1",
        )
        self.assertEqual(
            self.bridge._normalize_base_url("http://192.0.2.10:8000/v1"),
            "http://192.0.2.10:8000/v1",
        )
        for rejected in (
            "file:///etc/passwd",
            "ftp://models.example/v1",
            "https://user:secret@models.example/v1",
            "https://models.example/v1?token=secret",
            "https://models.example/v1#fragment",
            "http:///missing-host",
        ):
            with self.subTest(rejected=rejected), self.assertRaises(ValueError):
                self.bridge._normalize_base_url(rejected)

    def test_urlopen_rejects_non_http_before_dispatch(self):
        with mock.patch.object(self.bridge.urllib.request, "build_opener") as build:
            with self.assertRaises(ValueError):
                self.bridge._urlopen_http("file:///etc/passwd", timeout=1)
            build.assert_not_called()

    def test_loopback_probe_rejects_non_loopback_target(self):
        with mock.patch.object(self.bridge.urllib.request, "build_opener") as build:
            with self.assertRaises(ValueError):
                self.bridge._urlopen_http(
                    "http://example.com/api/tags",
                    timeout=1,
                    loopback_only=True,
                )
            build.assert_not_called()

    def test_redirects_keep_the_same_scheme_and_loopback_policy(self):
        handler = self.bridge._ValidatedRedirectHandler(loopback_only=True)
        for rejected in (
            "ftp://127.0.0.1/model",
            "http://example.com/model",
            "file:///etc/passwd",
        ):
            with self.subTest(rejected=rejected), self.assertRaises(ValueError):
                handler.redirect_request(None, None, 302, "", {}, rejected)


class SbomXmlSecurityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sbom = load_module(
            "sbom_security_test_module",
            ROOT / "tool/sbom/generate.py",
        )

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sbom-xml-test-")
        self.directory = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_normal_pom_license_is_parsed(self):
        pom = self.directory / "normal.pom"
        pom.write_text(
            "<project><licenses><license><name>Apache License Version 2.0"
            "</name></license></licenses></project>",
            encoding="utf-8",
        )
        self.assertEqual(self.sbom.pom_licences(pom), {"Apache-2.0"})

    def test_gplv3_appendix_reference_does_not_become_lgpl(self):
        license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
        self.assertIn("GNU Lesser General Public License", license_text)
        self.assertEqual(
            self.sbom.licence_expression(license_text),
            "GPL-3.0-only",
        )

    def test_dtd_and_entity_pom_is_rejected(self):
        pom = self.directory / "entity.pom"
        pom.write_text(
            '<!DOCTYPE project [<!ENTITY license "Apache License Version 2.0">]>'
            "<project><licenses><license><name>&license;</name></license></licenses>"
            "</project>",
            encoding="utf-8",
        )
        self.assertEqual(self.sbom.pom_licences(pom), set())

    def test_sbom_fingerprint_ignores_uninventoried_asset_cache(self):
        assets = self.directory / "assets/bridge"
        assets.mkdir(parents=True)
        (assets / "identity.png").write_bytes(b"tracked-visual")
        cache = assets / "__pycache__/bridge.cpython-314.pyc"
        cache.parent.mkdir()

        with mock.patch.object(self.sbom, "ROOT", self.directory):
            expected = self.sbom.fingerprint_inputs()
            cache.write_bytes(b"local-bytecode-cache")
            self.assertEqual(self.sbom.fingerprint_inputs(), expected)
            self.assertNotIn(cache, self.sbom.inventory_asset_paths())

    def test_oversized_pom_is_rejected(self):
        pom = self.directory / "oversized.pom"
        pom.write_bytes(
            b"<project>" + b" " * self.sbom.MAX_POM_BYTES + b"</project>"
        )
        self.assertEqual(self.sbom.pom_licences(pom), set())


class GatewayMutationFenceSourceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.chat = (ROOT / "lib/core/screens/chat_screen.dart").read_text(
            encoding="utf-8"
        )
        cls.voice = (
            ROOT
            / "lib/core/services/voice/conversation/local_voice_conversation_controller.dart"
        ).read_text(encoding="utf-8")
        cls.gateway = (ROOT / "lib/core/services/tui_gateway_client.dart").read_text(
            encoding="utf-8"
        )

    def _method_body(self, signature, next_signature):
        start = self.gateway.rindex(signature)
        end = self.gateway.index(next_signature, start)
        return self.gateway[start:end]

    def test_chat_uses_one_fenced_steer_path_and_voice_cannot_reach_it(self):
        self.assertEqual(self.chat.count("_chat.steer("), 1)
        self.assertNotIn("chat.steer(", self.voice)
        self.assertNotIn("_chat.redirect(", self.chat)
        self.assertNotIn("chat.redirect(", self.voice)

    def test_steer_and_redirect_use_the_exclusive_session_fence(self):
        steer = self._method_body(
            "Future<void> steer(", "Future<DesktopRedirectDisposition> redirect("
        )
        redirect = self._method_body(
            "Future<DesktopRedirectDisposition> redirect(", "Future<void> interrupt("
        )
        for method in (steer, redirect):
            self.assertIn("_requestExclusiveSessionMutation", method)
            self.assertNotIn("await _request(", method)


class BotOwnedNavigationSourceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.main = (ROOT / "lib/main.dart").read_text(encoding="utf-8")
        cls.sessions = (
            ROOT / "lib/core/screens/session_list_screen.dart"
        ).read_text(encoding="utf-8")

    @staticmethod
    def _body(source, signature, next_signature):
        start = source.index(signature)
        end = source.index(next_signature, start)
        return source[start:end]

    def test_legacy_and_library_bot_opens_use_mission_control_owner(self):
        widget_open = self._body(
            self.main,
            "Future<NavigationDeliveryOutcome> _openWidgetSession(",
            "Future<void> setThemeId(",
        )
        library_open = self._body(
            self.sessions,
            "Future<void> _openChat(Session session)",
            "Future<void> _openDetail(Session session)",
        )
        self.assertIn("missionControlTargetForSession(target)", widget_open)
        self.assertIn("missionControlTargetForSession(session)", library_open)
        self.assertIn("MissionControlScreen(", library_open)


class ReleaseWorkflowBoundaryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / ".github/workflows/build-apk.yml").read_text(
            encoding="utf-8"
        )

    def test_public_workflow_builds_no_signed_channel_artifact(self):
        self.assertNotIn("flutter build apk", self.workflow)
        self.assertNotIn("flutter build appbundle", self.workflow)
        self.assertNotIn("--flavor full", self.workflow)
        self.assertNotIn("--flavor play", self.workflow)
        self.assertNotIn("--flavor qa", self.workflow)
        self.assertIn("CI verification only", self.workflow)

    def test_sensitive_builds_and_staging_are_local_only(self):
        double_build = (ROOT / "tool/release/double_build.sh").read_text(encoding="utf-8")
        play_stage = (ROOT / "tool/release/stage_play_private.sh").read_text(encoding="utf-8")
        self.assertIn("flutter build apk --release --flavor full", double_build)
        self.assertIn("flutter build appbundle --release --flavor play", double_build)
        self.assertIn("--split-per-abi", double_build)
        self.assertIn("mv -- \"$STAGING_ROOT\" \"$OUTPUT_ROOT\"", double_build)
        self.assertIn("mv -- \"$WORK\" \"$DESTINATION_CANONICAL\"", play_stage)
        self.assertNotIn("gh release", double_build + play_stage)

    def test_exact_public_basenames_live_in_reviewed_contract(self):
        contract = json.loads(
            (ROOT / "tool/release/release_contract.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            contract["channels"]["direct-public"]["publicAssets"],
            [
                "SHA256SUMS",
                "app-arm64-v8a-full-release.apk",
                "app-armeabi-v7a-full-release.apk",
                "app-x86_64-full-release.apk",
                "hermes-console-release-evidence.tar.gz",
                "provenance.intoto.jsonl",
            ],
        )
        self.assertNotIn(
            "app-play-release.aab",
            contract["channels"]["direct-public"]["publicAssets"],
        )

    def test_workflow_never_exposes_prepublication_candidates(self):
        self.assertNotIn("actions/upload-artifact", self.workflow)
        self.assertNotIn("actions/download-artifact", self.workflow)
        self.assertNotIn("actions/attest", self.workflow)
        self.assertNotIn("KEYSTORE_BASE64", self.workflow)
        self.assertNotIn("EXPECTED_CERT_SHA256", self.workflow)
        self.assertNotIn("contents: write", self.workflow)
        self.assertNotIn("gh release", self.workflow)


if __name__ == "__main__":
    unittest.main()
