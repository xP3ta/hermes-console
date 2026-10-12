"""The release policy must describe the manifests the repository really builds.

`tool/release/full_release_policy.json` is what `inspect_public_apk.py` enforces
on the signed APKs (exact permissions, foreground services and package queries).
The `play` and `full` flavors share `android/app/src/main/AndroidManifest.xml`
(there is no `src/play`, and `src/full` is empty), so one policy covers both.
These tests tie the policy to that manifest, to the plugins that add the rest,
to the docs that justify each permission and to the pinned build commands, so a
change to one of them cannot silently leave the others describing another app.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tool/release"))
import check_manifest_policy as checker  # noqa: E402
import inspect_public_apk as inspector  # noqa: E402

ANDROID = "{http://schemas.android.com/apk/res/android}"
TOOLS = "{http://schemas.android.com/tools}"
POLICY = json.loads((ROOT / "tool/release/full_release_policy.json").read_text(encoding="utf-8"))
MAIN = ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml").getroot()

# Permissions of the merged manifest that the app's own manifest does not
# declare, with the dependency that adds each one (checked against the signed
# 1.2.15 artifacts with aapt2, apkanalyzer and bundletool).
CONTRIBUTED_BY_DEPENDENCIES = {
    "android.permission.WAKE_LOCK": "flutter_foreground_task / androidx.work",
    "android.permission.USE_FINGERPRINT": "local_auth_android (legacy alias of USE_BIOMETRIC)",
    "android.permission.BLUETOOTH": (
        "com.github.davidliu:audioswitch, pulled in by flutter_webrtc; "
        "maxSdkVersion 30, routes GPT-Live call audio to a Bluetooth headset on Android 11 and older"
    ),
    "dev.xpetalab.hermesconsole.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION": (
        "androidx.core (signature permission for non-exported dynamic receivers)"
    ),
}
RETIRED_LOCAL_AGENT = (
    "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
    "com.termux.permission.RUN_COMMAND",
)


def declared_permissions(root: ET.Element) -> dict[str, int | None]:
    result: dict[str, int | None] = {}
    for element in root.findall("uses-permission"):
        if element.get(f"{TOOLS}node") == "remove":
            continue
        maximum = element.get(f"{ANDROID}maxSdkVersion")
        result[element.get(f"{ANDROID}name")] = int(maximum) if maximum else None
    return result


def removed_permissions(root: ET.Element) -> set[str]:
    return {
        element.get(f"{ANDROID}name")
        for element in root.findall("uses-permission")
        if element.get(f"{TOOLS}node") == "remove"
    }


class PolicyFollowsTheManifestTest(unittest.TestCase):
    def policy_permissions(self) -> dict[str, int | None]:
        return {entry["name"]: entry.get("maxSdkVersion") for entry in POLICY["permissions"]}

    def test_flavors_share_one_manifest_and_the_full_one_adds_nothing(self):
        self.assertFalse((ROOT / "android/app/src/play").exists())
        full = ET.parse(ROOT / "android/app/src/full/AndroidManifest.xml").getroot()
        self.assertEqual([child.tag for child in full], [])

    def test_every_permission_the_app_declares_is_in_the_policy_with_the_same_limit(self):
        policy = self.policy_permissions()
        for name, maximum in declared_permissions(MAIN).items():
            with self.subTest(name=name):
                self.assertIn(name, policy)
                self.assertEqual(policy[name], maximum)

    def test_the_rest_comes_from_named_dependencies(self):
        policy = self.policy_permissions()
        extra = set(policy) - set(declared_permissions(MAIN))
        self.assertEqual(extra, set(CONTRIBUTED_BY_DEPENDENCIES))
        self.assertEqual(policy["android.permission.BLUETOOTH"], 30)

    def test_bluetooth_headset_routing_never_makes_the_radio_a_requirement(self):
        features = {
            element.get(f"{ANDROID}name"): element.get(f"{ANDROID}required")
            for element in MAIN.findall("uses-feature")
        }
        self.assertEqual(features.get("android.hardware.bluetooth"), "false")
        for hardware in ("android.hardware.camera.any", "android.hardware.microphone"):
            self.assertEqual(features.get(hardware), "false")

    def test_what_the_manifest_strips_is_forbidden_by_the_policy(self):
        self.assertLessEqual(removed_permissions(MAIN), set(POLICY["forbiddenPermissions"]))
        self.assertFalse(set(POLICY["forbiddenPermissions"]) & set(self.policy_permissions()))

    def test_the_retired_local_agent_is_forbidden_in_every_flavor(self):
        self.assertLessEqual(
            {*RETIRED_LOCAL_AGENT, "android.permission.QUERY_ALL_PACKAGES"},
            set(POLICY["forbiddenPermissions"]),
        )
        self.assertEqual(POLICY["packageQueries"], [])
        for path in (
            ROOT / "tool/release/full_release_policy.json",
            ROOT / "android/app/src/main/AndroidManifest.xml",
            ROOT / "android/app/src/full/AndroidManifest.xml",
        ):
            text = path.read_text(encoding="utf-8").lower()
            for marker in ("termux", "fdroid", "f-droid"):
                if path.name == "full_release_policy.json" and marker == "termux":
                    # Only the forbidden RUN_COMMAND permission may name it.
                    self.assertEqual(text.count("termux"), 1, path)
                else:
                    self.assertNotIn(marker, text, path)
        self.assertEqual(MAIN.findall("queries/package"), [])

    def test_foreground_services_match_the_manifest(self):
        namespace = re.search(
            r'namespace\s*=\s*"([A-Za-z0-9_.]+)"',
            (ROOT / "android/app/build.gradle.kts").read_text(encoding="utf-8"),
        ).group(1)
        services = {}
        for service in MAIN.find("application").findall("service"):
            types = service.get(f"{ANDROID}foregroundServiceType")
            if not types:
                continue
            name = service.get(f"{ANDROID}name")
            services[namespace + name if name.startswith(".") else name] = sorted(types.split("|"))
        self.assertEqual(
            services,
            {entry["name"]: sorted(entry["types"]) for entry in POLICY["foregroundServices"]},
        )

    def test_every_foreground_service_permission_has_a_type_in_use(self):
        in_use = {kind for entry in POLICY["foregroundServices"] for kind in entry["types"]}
        permissions = {
            re.sub(r"[^a-z]", "", name.removeprefix("android.permission.FOREGROUND_SERVICE_").lower())
            for name in self.policy_permissions()
            if name.startswith("android.permission.FOREGROUND_SERVICE_")
        }
        self.assertEqual(permissions, {kind.lower() for kind in in_use})


class DocsDescribeThePolicyTest(unittest.TestCase):
    def test_every_permission_is_justified_in_the_play_permissions_table(self):
        text = (ROOT / "docs/PLAY_PERMISSIONS.md").read_text(encoding="utf-8")
        for entry in POLICY["permissions"]:
            short = entry["name"].removeprefix("android.permission.")
            with self.subTest(permission=short):
                self.assertIn(f"`{short}`", text)

    def test_the_docs_do_not_claim_there_is_no_bluetooth_permission(self):
        for name in ("PLAY_PERMISSIONS.md", "SECURITY_POLICY.md"):
            text = (ROOT / "docs" / name).read_text(encoding="utf-8").lower()
            with self.subTest(document=name):
                self.assertNotIn("no bluetooth permission", text)
                self.assertIn("bluetooth", text)

    def test_the_docs_name_no_retired_permission_as_declared(self):
        text = (ROOT / "docs/PLAY_PERMISSIONS.md").read_text(encoding="utf-8")
        table, status = text.split("## Sensitive and restricted permissions", 1)
        self.assertNotIn("RUN_COMMAND", table)
        self.assertNotIn("REQUEST_IGNORE_BATTERY_OPTIMIZATIONS", table)
        self.assertIn("`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: not declared in any flavor", status)


class PinnedBuildCommandsTest(unittest.TestCase):
    def test_no_build_input_still_reads_or_pins_the_retired_local_agent_define(self):
        for path in [
            *sorted((ROOT / "tool").rglob("*.py")),
            *sorted((ROOT / "tool").rglob("*.sh")),
            *sorted((ROOT / "lib").rglob("*.dart")),
            *sorted((ROOT / "android/app").rglob("*.kts")),
            *sorted((ROOT / "android/app/src").rglob("*.kt")),
            ROOT / ".github/workflows/build-apk.yml",
        ]:
            with self.subTest(path=path.relative_to(ROOT).as_posix()):
                self.assertNotIn("HERMES_LOCAL_AGENT", path.read_text(encoding="utf-8"))

    def test_the_pinned_commands_are_what_double_build_runs(self):
        import double_build_manifest
        import play_build_binding
        import public_build_binding

        script = (ROOT / "tool/release/double_build.sh").read_text(encoding="utf-8")
        self.assertEqual(public_build_binding.BUILD_COMMAND, double_build_manifest.BUILD_COMMANDS["direct-public"])
        self.assertEqual(play_build_binding.BUILD_COMMAND, double_build_manifest.BUILD_COMMANDS["play-private"])
        for command in double_build_manifest.BUILD_COMMANDS.values():
            words = command.split()
            self.assertEqual(words[:2], ["flutter", "build"])
            for word in words[2:]:
                with self.subTest(word=word):
                    self.assertIn(word, script)
        defines = re.findall(r"--dart-define=(\S+)", script)
        self.assertEqual(sorted(defines), ["HERMES_FLAVOR=full", "HERMES_FLAVOR=play"])


class InspectorReadsRealToolOutputTest(unittest.TestCase):
    """Shapes printed by aapt and apkanalyzer 12.0 on a real signed 1.2.15 APK."""

    def test_a_compiled_manifest_prints_foreground_service_types_as_a_hex_mask(self):
        self.assertEqual(inspector.foreground_service_types("0x1"), ["dataSync"])
        self.assertEqual(
            sorted(inspector.foreground_service_types("0x283")),
            ["dataSync", "mediaPlayback", "microphone", "remoteMessaging"],
        )
        self.assertEqual(inspector.foreground_service_types("dataSync|microphone"), ["dataSync", "microphone"])

    def test_a_mask_with_an_unknown_bit_or_no_type_is_rejected(self):
        for mask in ("0x0", "0x4000", "0x8000000"):
            with self.subTest(mask=mask), self.assertRaises(inspector.InspectionError):
                inspector.foreground_service_types(mask)

    def test_apkanalyzer_permission_lines_carry_a_quoted_limit(self):
        parsed = inspector.parse_analyzer_permissions(
            "android.permission.INTERNET\nandroid.permission.BLUETOOTH' maxSdkVersion='30\n"
        )
        self.assertEqual(
            parsed,
            [
                {"name": "android.permission.BLUETOOTH", "maxSdkVersion": 30},
                {"name": "android.permission.INTERNET"},
            ],
        )
        with self.assertRaises(inspector.InspectionError):
            inspector.parse_analyzer_permissions("android.permission.INTERNET\nandroid.permission.INTERNET\n")

    def test_aapt_lists_every_permission_line_and_keeps_the_limit(self):
        lines = (
            "package: name='a.b' versionCode='1' versionName='1.0'\n"
            "uses-permission: name='android.permission.INTERNET'\n"
            "uses-permission: name='android.permission.CAMERA'\n"
            "uses-permission: name='android.permission.VIBRATE'\n"
            "uses-permission: name='android.permission.BLUETOOTH' maxSdkVersion='30'\n"
            "sdkVersion:'24'\ntargetSdkVersion:'36'\n"
            "native-code: 'arm64-v8a'\n"
        )
        self.assertEqual(
            inspector.parse_aapt(lines)["permissions"],
            [
                {"name": "android.permission.BLUETOOTH", "maxSdkVersion": 30},
                {"name": "android.permission.CAMERA"},
                {"name": "android.permission.INTERNET"},
                {"name": "android.permission.VIBRATE"},
            ],
        )

    def test_split_apks_carry_the_flutter_abi_offset(self):
        self.assertEqual(inspector.ABI_VERSION_CODE_OFFSETS, {"armeabi-v7a": 1000, "arm64-v8a": 2000, "x86_64": 4000})


class CheckerRejectsTheLocalAgentTest(unittest.TestCase):
    def manifest(self, extra_permissions: str = "", queries: str = "") -> dict:
        permissions = "".join(
            f'<uses-permission android:name="{entry["name"]}"'
            + (f' android:maxSdkVersion="{entry["maxSdkVersion"]}"' if "maxSdkVersion" in entry else "")
            + "/>"
            for entry in POLICY["permissions"]
        )
        services = "".join(
            f'<service android:name="{entry["name"]}" android:foregroundServiceType="{"|".join(entry["types"])}"/>'
            for entry in POLICY["foregroundServices"]
        )
        text = (
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="a.b" '
            'android:versionName="1.0" android:versionCode="1">'
            '<uses-sdk android:minSdkVersion="24" android:targetSdkVersion="36"/>'
            f"{permissions}{extra_permissions}"
            f'<application android:label="Console">{services}</application>{queries}</manifest>'
        )
        return inspector.parse_manifest(text)

    def policy(self) -> dict:
        return inspector.expected_policy(ROOT / "tool/release/full_release_policy.json")

    def test_the_policy_itself_is_accepted(self):
        self.assertEqual(checker.differences(self.manifest(), self.policy()), [])

    def test_termux_permission_and_queries_are_reported(self):
        manifest = self.manifest(
            '<uses-permission android:name="com.termux.permission.RUN_COMMAND"/>',
            '<queries><package android:name="com.termux"/><package android:name="org.fdroid.fdroid"/></queries>',
        )
        problems = "\n".join(checker.differences(manifest, self.policy()))
        self.assertIn("forbidden permission present: com.termux.permission.RUN_COMMAND", problems)
        self.assertIn("package query not in policy: com.termux", problems)
        self.assertIn("package query not in policy: org.fdroid.fdroid", problems)

    def test_battery_exemption_and_global_package_visibility_are_reported(self):
        manifest = self.manifest(
            '<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>'
            '<uses-permission android:name="android.permission.QUERY_ALL_PACKAGES"/>'
        )
        problems = "\n".join(checker.differences(manifest, self.policy()))
        self.assertIn("forbidden permission present: android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS", problems)
        self.assertIn("forbidden permission present: android.permission.QUERY_ALL_PACKAGES", problems)

    def test_a_dropped_or_loosened_permission_is_reported(self):
        manifest = self.manifest()
        manifest["permissions"] = [
            {"name": entry["name"]} if entry["name"].endswith("BLUETOOTH") else entry
            for entry in manifest["permissions"]
            if not entry["name"].endswith("CAMERA")
        ]
        problems = "\n".join(checker.differences(manifest, self.policy()))
        self.assertIn("permission missing from manifest: android.permission.CAMERA", problems)
        self.assertIn("android.permission.BLUETOOTH (maxSdkVersion 30)", problems)


if __name__ == "__main__":
    unittest.main()
