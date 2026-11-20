#!/usr/bin/env python3
"""Snapshot of Hermes' hosted-room wire shapes for Console's contract test.

Usage: tool/contract/extract_room_contract.py HERMES_AGENT_CHECKOUT [OUTPUT]
  default output: test/fixtures/contract/hosted-rooms.json

The published gateway contract (apps/shared/src/gateway-contract.openrpc.json)
types every ``groups.*`` result but leaves a room event's ``payload`` open:
the shape of each event kind exists only as the server's validators
(``_EVENT_VALIDATORS`` in gateway/hosted_room_discussion.py). This script
copies the ``groups.*`` result schemas Console parses from the contract and
derives, from the validators' source, the field names, enum values and limits
of every closed room shape (test/hosted_room_contract_test.dart feeds them to
Console's parsers).

The checkout is read, never imported or run: only committed blobs
(``git show HEAD:``) are parsed with ``ast``, and only literal constant
expressions (sets, dicts, comprehensions over them, arithmetic) are evaluated.
Anything else the extraction depends on aborts instead of producing a weaker
snapshot.
"""

from __future__ import annotations

import ast
import builtins
import json
import operator
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / "test/fixtures/contract/hosted-rooms.json"
REPOSITORY = "https://github.com/NousResearch/hermes-agent"
LICENSE = "MIT (Copyright (c) 2025 Nous Research)"
OPENRPC = "apps/shared/src/gateway-contract.openrpc.json"
DISCUSSION = "gateway/hosted_room_discussion.py"
ROOMS = "gateway/hosted_rooms.py"
# The manifest rules moved from gateway/ to session_rules/ upstream; the old
# path then only re-imports them.
ATTACHMENTS = ("session_rules/hosted_attachments.py", "gateway/hosted_room_attachments.py")
# groups.* results whose fields Console reads (lib/core/models/hosted_groups.dart
# and lib/core/services/tui_gateway_client.dart).
PARSED_METHODS = (
    "groups.capabilities",
    "groups.create",
    "groups.list",
    "groups.log",
    "groups.send",
    "groups.state",
)
REF_PREFIX = "#/components/schemas/"


class Unsupported(Exception):
    """The source uses something this extractor does not understand."""


def git(checkout: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(checkout), *args], check=True, capture_output=True, text=True
    ).stdout


class Checkout:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.files: dict[str, str] = {}  # path -> commit that last changed it
        self.modules: dict[str, Module] = {}

    def show(self, rel: str) -> str | None:
        if git(self.path, "status", "--porcelain", "--", rel).strip():
            raise SystemExit(f"error: {rel} has uncommitted changes in {self.path}")
        try:
            text = git(self.path, "show", f"HEAD:{rel}")
        except subprocess.CalledProcessError:
            return None
        self.files[rel] = git(self.path, "log", "-1", "--format=%H", "--", rel).strip()
        return text

    def module(self, rel: str) -> Module:
        if rel not in self.modules:
            source = self.show(rel)
            if source is None:
                raise Unsupported(f"{rel} is not in the checkout")
            self.modules[rel] = Module(self, rel, source)
        return self.modules[rel]


class FunctionRef:
    def __init__(self, module: Module, node: ast.FunctionDef) -> None:
        self.module = module
        self.node = node


class Module:
    def __init__(self, checkout: Checkout, rel: str, source: str) -> None:
        self.checkout = checkout
        self.rel = rel
        self.assigns: dict[str, ast.expr] = {}
        self.functions: dict[str, ast.FunctionDef] = {}
        self.imports: dict[str, tuple[str, str | None]] = {}
        self.cache: dict[str, Any] = {}
        for node in ast.parse(source, rel).body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1:
                if isinstance(node.targets[0], ast.Name):
                    self.assigns[node.targets[0].id] = node.value
            elif isinstance(node, ast.AnnAssign) and node.value is not None:
                if isinstance(node.target, ast.Name):
                    self.assigns[node.target.id] = node.value
            elif isinstance(node, ast.FunctionDef):
                self.functions[node.name] = node
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                package = node.module.split(".")[0]
                if package not in {"gateway", "session_rules"}:
                    continue
                for alias in node.names:
                    if node.module == package:  # from gateway import x as y
                        target = (f"{package}/{alias.name}.py", None)
                    else:  # from gateway.x import NAME
                        target = (node.module.replace(".", "/") + ".py", alias.name)
                    self.imports[alias.asname or alias.name] = target

    def constant(self, name: str) -> Any:
        if name not in self.cache:
            self.cache[name] = self._resolve(name)
        return self.cache[name]

    def _resolve(self, name: str) -> Any:
        if name in self.assigns:
            return evaluate(self, self.assigns[name], {})
        if name in self.functions:
            return FunctionRef(self, self.functions[name])
        if name in self.imports:
            rel, symbol = self.imports[name]
            module = self.checkout.module(rel)
            return module if symbol is None else module.constant(symbol)
        if name in SAFE_CALLS:
            return SAFE_CALLS[name]
        raise Unsupported(f"{self.rel}: cannot resolve {name}")

    def defines(self, name: str) -> bool:
        return name in self.assigns


SAFE_CALLS: dict[str, Any] = {
    "dict": dict,
    "frozenset": frozenset,
    "list": list,
    "set": set,
    "sorted": sorted,
    "tuple": tuple,
}
BINARY = {
    ast.Add: operator.add,
    ast.BitAnd: operator.and_,
    ast.BitOr: operator.or_,
    ast.Mult: operator.mul,
    ast.Sub: operator.sub,
}


def evaluate(module: Module, node: ast.expr, local: dict[str, Any]) -> Any:
    where = f"{module.rel}:{getattr(node, 'lineno', '?')}"
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Name):
        if node.id in local:
            value = local[node.id]
            return value.resolve(node.id) if isinstance(value, Lazy) else value
        return module.constant(node.id)
    if isinstance(node, ast.Attribute):
        base = evaluate(module, node.value, local)
        if isinstance(base, Module):
            return base.constant(node.attr)
        if base is dict and node.attr == "fromkeys":
            return dict.fromkeys
        if isinstance(base, dict) and node.attr == "get":
            return base.get
        raise Unsupported(f"{where}: attribute {node.attr}")
    if isinstance(node, (ast.Set, ast.List, ast.Tuple)):
        items: list[Any] = []
        for element in node.elts:
            if isinstance(element, ast.Starred):
                items.extend(evaluate(module, element.value, local))
            else:
                items.append(evaluate(module, element, local))
        if isinstance(node, ast.Set):
            return frozenset(items)
        return items if isinstance(node, ast.List) else tuple(items)
    if isinstance(node, ast.Dict):
        out: dict[Any, Any] = {}
        for key, value in zip(node.keys, node.values):
            if key is None:
                out.update(evaluate(module, value, local))
            else:
                out[evaluate(module, key, local)] = evaluate(module, value, local)
        return out
    if isinstance(node, ast.BinOp) and type(node.op) in BINARY:
        left = evaluate(module, node.left, local)
        right = evaluate(module, node.right, local)
        return BINARY[type(node.op)](left, right)
    if isinstance(node, ast.Call) and not node.keywords:
        function = evaluate(module, node.func, local)
        allowed = set(SAFE_CALLS.values()) | {dict.fromkeys}
        bound_get = getattr(function, "__name__", None) == "get" and isinstance(
            getattr(function, "__self__", None), dict
        )
        if function not in allowed and not bound_get:
            raise Unsupported(f"{where}: call")
        if any(isinstance(arg, ast.Starred) for arg in node.args):
            raise Unsupported(f"{where}: starred call")
        return function(*(evaluate(module, arg, local) for arg in node.args))
    if isinstance(node, ast.Subscript):
        return evaluate(module, node.value, local)[evaluate(module, node.slice, local)]
    if isinstance(node, (ast.DictComp, ast.SetComp, ast.ListComp, ast.GeneratorExp)):
        results: list[Any] = []
        _comprehend(module, node, list(node.generators), dict(local), results)
        if isinstance(node, ast.DictComp):
            return dict(results)
        return frozenset(results) if isinstance(node, ast.SetComp) else results
    raise Unsupported(f"{where}: {type(node).__name__}")


def _bind(target: ast.expr, value: Any, local: dict[str, Any]) -> None:
    if isinstance(target, ast.Name):
        local[target.id] = value
    elif isinstance(target, ast.Tuple):
        values = list(value)
        if len(values) != len(target.elts):
            raise Unsupported("comprehension unpacking")
        for element, item in zip(target.elts, values):
            _bind(element, item, local)
    else:
        raise Unsupported("comprehension target")


def _comprehend(
    module: Module, node: Any, generators: list[ast.comprehension], local: dict[str, Any],
    results: list[Any],
) -> None:
    if not generators:
        if isinstance(node, ast.DictComp):
            key = evaluate(module, node.key, local)
            results.append((key, evaluate(module, node.value, local)))
        else:
            results.append(evaluate(module, node.elt, local))
        return
    generator, rest = generators[0], generators[1:]
    if generator.ifs or generator.is_async:
        raise Unsupported(f"{module.rel}: filtered comprehension")
    for item in evaluate(module, generator.iter, local):
        scope = dict(local)
        _bind(generator.target, item, scope)
        _comprehend(module, node, rest, scope, results)


class Lazy:
    """A function-local name evaluated only when an expression needs it."""

    def __init__(self, resolve: Any) -> None:
        self.resolve = resolve


def _function_locals(module: Module, function: ast.FunctionDef, bound: dict[str, Any]):
    """Lazy resolver of a function's simple top-level assignments."""
    assigned: dict[str, tuple[ast.expr, int | None]] = {}
    for statement in function.body:
        if not isinstance(statement, ast.Assign) or len(statement.targets) != 1:
            continue
        target = statement.targets[0]
        if isinstance(target, ast.Name):
            assigned.setdefault(target.id, (statement.value, None))
        elif isinstance(target, ast.Tuple):
            for index, element in enumerate(target.elts):
                if isinstance(element, ast.Name):
                    assigned.setdefault(element.id, (statement.value, index))
    local: dict[str, Any] = dict(bound)

    def resolve(name: str) -> Any:
        value_node, index = assigned[name]
        value = evaluate(module, value_node, {**bound, **lazy})
        return value if index is None else list(value)[index]

    lazy = {name: Lazy(resolve) for name in assigned if name not in bound}
    for parameter in function.args.args:
        if parameter.arg not in bound:
            local.setdefault(parameter.arg, Lazy(_unbound))
    local.update(lazy)
    return local


def _unbound(name: str) -> Any:
    raise Unsupported(f"{name} is a runtime value")


class Shape:
    def __init__(self) -> None:
        self.closed: list[tuple[frozenset[str], frozenset[str]]] = []
        self.enums: dict[str, list[str]] = {}


def _payload_access(node: ast.expr, name: str) -> str | None:
    """The field of ``name.get("f")`` / ``name["f"]``, else None."""
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "get"
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == name
        and node.args
        and isinstance(node.args[0], ast.Constant)
    ):
        return node.args[0].value
    if (
        isinstance(node, ast.Subscript)
        and isinstance(node.value, ast.Name)
        and node.value.id == name
        and isinstance(node.slice, ast.Constant)
    ):
        return node.slice.value
    return None


def collect_shape(
    ref: FunctionRef, parameter: int, bound: dict[str, Any], shape: Shape, depth: int = 0,
) -> None:
    """Records every ``_exact_fields(<the object>, required=, optional=)`` and
    every ``<the object>.get("f") in {literal set}`` reached by the object
    passed as positional [parameter] of [ref], following the calls it is
    handed to."""
    if depth > 4:
        raise Unsupported("validator call chain too deep")
    module, function = ref.module, ref.node
    name = function.args.args[parameter].arg
    local = _function_locals(module, function, bound)
    for node in ast.walk(function):
        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            field = _payload_access(node.left, name)
            if field is not None and isinstance(node.ops[0], (ast.In, ast.NotIn)):
                try:
                    values = evaluate(module, node.comparators[0], local)
                except Unsupported:
                    continue  # a runtime collection (the roster), not an enum
                if isinstance(values, (set, frozenset, tuple, list)) and all(
                    isinstance(value, str) for value in values
                ):
                    shape.enums[field] = sorted(values)
            continue
        if not isinstance(node, ast.Call):
            continue
        positions = [
            index
            for index, arg in enumerate(node.args)
            if isinstance(arg, ast.Name) and arg.id == name
        ]
        if not positions:
            continue
        callee = node.func
        callee_name = callee.attr if isinstance(callee, ast.Attribute) else getattr(callee, "id", None)
        if callee_name == "_exact_fields":
            if positions != [0]:
                raise Unsupported(f"{module.rel}:{node.lineno}: _exact_fields argument")
            keywords = {keyword.arg: keyword.value for keyword in node.keywords}
            if "required" not in keywords:
                raise Unsupported(f"{module.rel}:{node.lineno}: _exact_fields without required")
            required = frozenset(evaluate(module, keywords["required"], local))
            optional = frozenset(
                evaluate(module, keywords["optional"], local) if "optional" in keywords else ()
            )
            shape.closed.append((required, optional))
            continue
        if isinstance(callee, ast.Name) and hasattr(builtins, callee.id):
            continue
        try:
            target = evaluate(module, callee, {})
        except Unsupported as error:
            raise Unsupported(f"{module.rel}:{node.lineno}: the payload reaches {callee_name}") from error
        if not isinstance(target, FunctionRef):
            continue
        for position in positions:
            collect_shape(target, position, {}, shape, depth + 1)


def closed_shape(ref: FunctionRef, parameter: int, bound: dict[str, Any]) -> dict[str, Any]:
    shape = Shape()
    collect_shape(ref, parameter, bound, shape)
    distinct = set(shape.closed)
    if len(distinct) > 1:
        raise Unsupported(f"{ref.node.name}: conflicting exact field sets")
    out: dict[str, Any] = {}
    if distinct:
        required, optional = distinct.pop()
        out["required"] = sorted(required)
        out["optional"] = sorted(optional - required)
    # An enum test may sit behind a kind check of a shared validator
    # (``kind == "room.activity" and ...``): keep only this shape's fields.
    fields = set(out.get("required", ())) | set(out.get("optional", ()))
    enums = {field: values for field, values in shape.enums.items() if field in fields}
    if enums:
        out["enums"] = enums
    return out


def event_shapes(checkout: Checkout) -> dict[str, Any]:
    discussion = checkout.module(DISCUSSION)
    rooms = checkout.module(ROOMS)
    by_actor = rooms.constant("_EVENT_KINDS_BY_ACTOR")
    validators = discussion.constant("_EVENT_VALIDATORS")
    payloads: dict[str, Any] = {}
    for kind, ref in sorted(validators.items()):
        if not isinstance(ref, FunctionRef):
            raise Unsupported(f"validator of {kind} is not a function")
        kind_parameter = ref.node.args.args[0].arg
        payloads[kind] = closed_shape(ref, 1, {kind_parameter: kind})
    every_kind = sorted({kind for kinds in by_actor.values() for kind in kinds} | set(payloads))
    for kind in every_kind:
        # Kinds without a validator carry a payload the server never closes.
        payloads.setdefault(kind, {})
    user = payloads.get("message.user", {})
    if not {"text", "thread_id"} <= set(user.get("required", ())):
        raise Unsupported("message.user is not closed over text and thread_id")
    return {
        "actor_fields": sorted(rooms.constant("_ACTOR_FIELDS")),
        "kinds_by_actor": {actor: sorted(kinds) for actor, kinds in sorted(by_actor.items())},
        "payloads": payloads,
    }


def member_shapes(checkout: Checkout) -> dict[str, Any]:
    discussion = checkout.module(DISCUSSION)
    member = closed_shape(discussion.constant("_validate_member"), 0, {})
    if "required" not in member:
        raise Unsupported("_validate_member does not close the roster row")
    targets = discussion.constant("_TARGET_FIELDS")
    return {
        **member,
        "targets": {kind: sorted(fields) for kind, fields in sorted(targets.items())},
        "remote_fields": sorted(discussion.constant("_REMOTE_MEMBER_FIELDS")),
    }


def attachment_module(checkout: Checkout) -> Module:
    for rel in ATTACHMENTS:
        if checkout.show(rel) is None:
            continue
        module = checkout.module(rel)
        if module.defines("_ATTACHMENT_FIELDS"):
            return module
    raise Unsupported("no module defines _ATTACHMENT_FIELDS")


def schema_subset(checkout: Checkout) -> dict[str, Any]:
    source = checkout.show(OPENRPC)
    if source is None:
        raise Unsupported(f"{OPENRPC} is not in the checkout")
    contract = json.loads(source)
    schemas = contract["components"]["schemas"]
    methods = {method["name"]: method for method in contract["methods"]}
    results: dict[str, Any] = {}
    needed: set[str] = set()

    def walk(value: Any) -> None:
        if isinstance(value, dict):
            ref = value.get("$ref")
            if isinstance(ref, str):
                if not ref.startswith(REF_PREFIX):
                    raise Unsupported(f"unsupported $ref {ref}")
                name = ref[len(REF_PREFIX):]
                if name not in needed:
                    needed.add(name)
                    walk(schemas[name])
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    for name in PARSED_METHODS:
        if name not in methods:
            raise Unsupported(f"the contract has no {name}")
        results[name] = methods[name]["result"]["schema"]
        walk(results[name])
    return {"methods": results, "schemas": {name: schemas[name] for name in sorted(needed)}}


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    checkout = Path(argv[1]).resolve()
    output = Path(argv[2]) if len(argv) == 3 else DEFAULT_OUTPUT
    try:
        git(checkout, "rev-parse", "--git-dir")
    except (subprocess.CalledProcessError, FileNotFoundError):
        print(f"error: {checkout} is not a git checkout of hermes-agent", file=sys.stderr)
        return 1
    repo = Checkout(checkout)
    try:
        contract = schema_subset(repo)
        events = event_shapes(repo)
        members = member_shapes(repo)
        attachments = attachment_module(repo)
        discussion = repo.module(DISCUSSION)
        rooms = repo.module(ROOMS)
        snapshot = {
            "source": {
                "repository": REPOSITORY,
                "checkout_commit": git(checkout, "rev-parse", "HEAD").strip(),
                "files": dict(sorted(repo.files.items())),
                "license": LICENSE,
                "generator": "tool/contract/extract_room_contract.py",
            },
            **contract,
            "events": events,
            "member": members,
            "attachment": {
                "fields": sorted(attachments.constant("_ATTACHMENT_FIELDS")),
                "kinds": sorted(attachments.constant("_ATTACHMENT_KINDS")),
            },
            "limits": {
                "actor_id_chars": rooms.constant("MAX_ACTOR_ID_CHARS"),
                "actor_label_chars": rooms.constant("MAX_ACTOR_LABEL_CHARS"),
                "attachment_bytes": attachments.constant("MAX_ATTACHMENT_BYTES"),
                "attachment_mime_chars": attachments.constant("MAX_ATTACHMENT_MIME_CHARS"),
                "attachment_name_chars": attachments.constant("MAX_ATTACHMENT_NAME_CHARS"),
                "attachments_per_message": attachments.constant("MAX_ATTACHMENTS_PER_MESSAGE"),
                "message_attachment_bytes": attachments.constant("MAX_MESSAGE_ATTACHMENT_BYTES"),
                "user_text_bytes": discussion.constant("MAX_USER_TEXT_BYTES"),
            },
        }
    except Unsupported as error:
        print(f"error: cannot extract the room contract: {error}", file=sys.stderr)
        return 1
    for name, value in snapshot["limits"].items():
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            print(f"error: limit {name} is not a positive integer", file=sys.stderr)
            return 1
    text = json.dumps(snapshot, indent=1) + "\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text)
    print(f"wrote {output} from {snapshot['source']['checkout_commit']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
