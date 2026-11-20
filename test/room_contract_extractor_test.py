"""tool/contract/extract_room_contract.py over a miniature hermes-agent
checkout: the room shapes come out of the validators' source, a field added
inline to a validator shows up in the snapshot, and what the extractor does
not understand aborts it instead of producing a weaker snapshot."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tool/contract/extract_room_contract.py"

DISCUSSION = '''
from gateway import hosted_room_router as router

_USER_PAYLOAD_FIELDS = frozenset({"text", "thread_id"})
_COORDINATES = frozenset({"member_id", "task_id"})
_TERMINAL_FIELDS = {
    kind: _COORDINATES | {"seen_through_seq", *extra} for kind, extra in (
        ("turn.settled", ("passed",)), ("turn.failed", ("error",)))}
_TERMINAL_OPTIONAL_FIELDS = {"turn.failed": frozenset({"reason_code"})}
_GATEWAY_EVENT_FIELDS = {"room.activity": (frozenset({"status"}), ())}
_TARGET_FIELDS = {"local": frozenset({"kind", "profile"})}
_REMOTE_MEMBER_FIELDS = frozenset({"route"})
MAX_USER_TEXT_BYTES = 64 * 1024


def validate_user_payload(value):
    payload = _exact_fields(value, label="user payload", required=_USER_PAYLOAD_FIELDS,
                            optional={USER_OPTIONAL})
    return payload


def _validate_user_event(kind, payload, actor, room):
    payload = validate_user_payload(payload)
    return payload


def _validate_terminal_event(kind, payload, actor, room):
    _exact_fields(payload, label=f"{kind} payload", required=_TERMINAL_FIELDS[kind],
                  optional=_TERMINAL_OPTIONAL_FIELDS.get(kind, frozenset()))
    return payload


def _validate_gateway_event(kind, payload, actor, room):
    fields, identifier_fields = _GATEWAY_EVENT_FIELDS[kind]
    _exact_fields(payload, label=f"{kind} payload", required=fields)
    if kind == "room.activity" and payload.get("status") not in {"settled", "bounded"}:
        raise ValueError("status")
    return payload


def _validate_member(raw, index, known_profiles):
    member = _exact_fields(raw, label="member", required=frozenset({"member_id", "profile"}),
                           optional=frozenset({"target"}))
    return member


_EVENT_VALIDATORS = {
    "message.user": _validate_user_event,
    **dict.fromkeys(("turn.settled", "turn.failed"), _validate_terminal_event),
    **dict.fromkeys(_GATEWAY_EVENT_FIELDS, _validate_gateway_event),
    router.ROUTED_EVENT_KIND: router.validate_routed_event}
'''

ROUTER = '''
ROUTED_EVENT_KIND = "room.routed"
ROUTED_FIELDS = frozenset({"thread_id", "member_ids"})


def validate_routed_event(kind, payload, actor, room):
    from gateway.hosted_room_discussion import _exact_fields
    _exact_fields(payload, label=f"{kind} payload", required=ROUTED_FIELDS)
    return payload
'''

ROOMS = '''
MAX_ACTOR_ID_CHARS = 128
MAX_ACTOR_LABEL_CHARS = 200
_EVENT_KINDS_BY_ACTOR = {
    "user": frozenset({"message.user"}),
    "gateway": frozenset({"room.activity", "room.routed", "turn.failed", "turn.settled", "turn.started"})}
_OPTIONAL_ACTOR_FIELDS = (("display_name", MAX_ACTOR_LABEL_CHARS), ("profile", MAX_ACTOR_ID_CHARS))
_ACTOR_FIELDS = frozenset({"kind", "id", *(field for field, _ in _OPTIONAL_ACTOR_FIELDS)})
'''

ATTACHMENTS = '''
MAX_ATTACHMENTS_PER_MESSAGE = 8
MAX_ATTACHMENT_BYTES = 15_000_000
MAX_MESSAGE_ATTACHMENT_BYTES = 25_000_000
MAX_ATTACHMENT_NAME_CHARS = 255
MAX_ATTACHMENT_MIME_CHARS = 127
_ATTACHMENT_FIELDS = frozenset({"attachment_id", "kind", "name", "size", "mime"})
_ATTACHMENT_KINDS = frozenset({"image", "pdf", "file"})
'''

METHODS = (
    "groups.capabilities", "groups.create", "groups.list", "groups.log", "groups.send",
    "groups.state")


def contract() -> str:
    def ref(name: str) -> dict:
        return {"$ref": f"#/components/schemas/{name}"}

    schemas = {
        "Result": {"type": "object", "properties": {"event": ref("RoomEvent")}},
        "RoomEvent": {"type": "object", "properties": {"kind": {"type": "string"}}},
        "Unused": {"type": "object"},
    }
    methods = [{"name": name, "result": {"schema": ref("Result")}} for name in METHODS]
    return json.dumps({"methods": methods, "components": {"schemas": schemas}})


class ExtractRoomContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.checkout = Path(self.tmp.name) / "hermes-agent"
        self.output = Path(self.tmp.name) / "hosted-rooms.json"
        self.git("init", "-q", str(self.checkout), cwd=Path(self.tmp.name))
        self.commit(optional='"attachments"')

    def git(self, *args: str, cwd: Path | None = None) -> str:
        return subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
            cwd=cwd or self.checkout, check=True, capture_output=True, text=True,
        ).stdout

    def write(self, rel: str, text: str) -> None:
        path = self.checkout / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text))

    def commit(self, *, optional: str, discussion: str = DISCUSSION) -> None:
        self.write("gateway/hosted_room_discussion.py", discussion.replace("USER_OPTIONAL", optional))
        self.write("gateway/hosted_room_router.py", ROUTER)
        self.write("gateway/hosted_rooms.py", ROOMS)
        self.write("session_rules/hosted_attachments.py", ATTACHMENTS)
        self.write("apps/shared/src/gateway-contract.openrpc.json", contract())
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "snapshot")

    def extract(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), str(self.checkout), str(self.output)],
            capture_output=True, text=True,
        )

    def snapshot(self) -> dict:
        result = self.extract()
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(self.output.read_text())

    def test_reads_every_closed_shape_from_the_validators(self) -> None:
        snapshot = self.snapshot()
        payloads = snapshot["events"]["payloads"]

        self.assertEqual(
            payloads["message.user"],
            {"required": ["text", "thread_id"], "optional": ["attachments"]})
        self.assertEqual(
            payloads["turn.failed"],
            {"required": ["error", "member_id", "seen_through_seq", "task_id"],
             "optional": ["reason_code"]})
        self.assertEqual(
            payloads["room.activity"],
            {"required": ["status"], "optional": [], "enums": {"status": ["bounded", "settled"]}})
        self.assertEqual(
            payloads["room.routed"], {"required": ["member_ids", "thread_id"], "optional": []})
        # A kind the server never closes is recorded as an open payload.
        self.assertEqual(payloads["turn.started"], {})
        self.assertEqual(
            snapshot["events"]["actor_fields"], ["display_name", "id", "kind", "profile"])
        self.assertEqual(
            snapshot["member"],
            {"required": ["member_id", "profile"], "optional": ["target"],
             "targets": {"local": ["kind", "profile"]}, "remote_fields": ["route"]})
        self.assertEqual(snapshot["attachment"]["kinds"], ["file", "image", "pdf"])
        self.assertEqual(snapshot["limits"]["user_text_bytes"], 65536)
        self.assertEqual(sorted(snapshot["methods"]), list(METHODS))
        # Only the schemas the parsed results reach are copied.
        self.assertEqual(sorted(snapshot["schemas"]), ["Result", "RoomEvent"])
        head = self.git("rev-parse", "HEAD").strip()
        self.assertEqual(snapshot["source"]["checkout_commit"], head)
        self.assertEqual(snapshot["source"]["files"]["gateway/hosted_rooms.py"], head)

    def test_a_field_added_inline_to_a_validator_reaches_the_snapshot(self) -> None:
        # The 1.4.0 break: the owner message grew an optional field written
        # inline in the validator call, not as a named constant.
        self.commit(optional='"attachments", "mentions"')

        payloads = self.snapshot()["events"]["payloads"]

        self.assertEqual(payloads["message.user"]["optional"], ["attachments", "mentions"])

    def test_a_dirty_source_file_is_refused(self) -> None:
        self.write("gateway/hosted_rooms.py", ROOMS + "\nEXTRA = 1\n")

        result = self.extract()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("uncommitted changes", result.stderr)
        self.assertFalse(self.output.exists())

    def test_a_shape_it_cannot_evaluate_aborts(self) -> None:
        self.commit(optional='"attachments"', discussion=DISCUSSION.replace(
            "optional={USER_OPTIONAL}", "optional=extra_fields()"))

        result = self.extract()

        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot extract the room contract", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
