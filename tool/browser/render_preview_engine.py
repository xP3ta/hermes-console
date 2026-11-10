"""Render lib/core/browser/hermes_preview_engine.g.dart from Desktop's engine.

Input: the JSON that generate_preview_engine.sh produces from a hermes-agent
checkout ({engine, watch, watchTag}). Output: the Dart constant, with ONE
deliberate change to Desktop's code, applied here so it survives every
regeneration:

Console privacy patch (REVIEW-R4 P1-a1). Desktop's naming kit reports the
current value of every form field in the `elements` inventory, passwords
included, and that inventory goes to the model. Console never sends the value
of a secret: a password field (type=password, autocomplete current-/new-
password, -webkit-text-security), a one-time code, or a payment-card field
(autocomplete cc-*, or a name like card number / CVC / CVV / security code)
reports only "[password field, N characters]" / "[hidden field, N
characters]", or nothing when empty, and never lends its value attribute as
a label. Every anchor must match exactly once, so a change in Desktop's
source stops the generation instead of silently dropping the patch.

Usage: render_preview_engine.py ENGINE_JSON COMMIT OUT_DART
"""

import json
import sys

SENSITIVE = r'''function namingKit(doc) {
  // Console privacy patch (REVIEW-R4 P1-a1): a secret's value never leaves
  // the page. "password", "hidden" (one-time code, payment card) or "".
  const sensitiveKind = (el) => {
    const attr = (name) => (el.getAttribute && el.getAttribute(name)) || "";
    const type = (el.type || attr("type") || "").toLowerCase();
    const auto = attr("autocomplete").toLowerCase();
    if (type === "password" || /(^|\s)(current-password|new-password)(\s|$)/.test(auto)) {
      return "password";
    }
    try {
      const view = el.ownerDocument && el.ownerDocument.defaultView;
      const masked = view && view.getComputedStyle ? view.getComputedStyle(el).webkitTextSecurity : "";
      if (masked && masked !== "none") {
        return "password";
      }
    } catch (err) {
    }
    if (/(^|\s)(one-time-code|cc-[a-z-]+)(\s|$)/.test(auto)) {
      return "hidden";
    }
    // One digit of a code split across boxes (REVIEW-R5-B #11).
    const mode = attr("inputmode").toLowerCase();
    const max = parseInt(attr("maxlength"), 10);
    if ((mode === "numeric" || mode === "decimal" || type === "tel" || type === "number") && max > 0 && max <= 1) {
      return "hidden";
    }
    // What the field is called, wherever the page says it: its attributes,
    // its <label> and its aria-labelledby (REVIEW-R5-B #11).
    const owner = el.ownerDocument;
    const labelledBy = attr("aria-labelledby").split(/\s+/).map((id) => (id && owner ? owner.getElementById(id) : null));
    const labels = el.labels ? Array.from(el.labels) : [];
    const names = [attr("name"), el.id || "", attr("aria-label"), attr("placeholder"), attr("title")]
      .concat(labelledBy.concat(labels).map((node) => (node && node.textContent) || ""))
      .join(" ")
      .toLowerCase();
    if (/card.?num|\bcc.?(num|number|csc|cvc|cvv|exp)|\bcvc\b|\bcvv\b|\bcsc\b|security.?code|\botp\b|one.?time.?(code|pass)|verif(y|ication)?.?code|\b2fa\b|two.?factor|\bmfa\b|\btotp\b|pass.?code|\bpin\b/.test(names)) {
      return "hidden";
    }
    return "";
  };'''

PATCHES = [
    ("function namingKit(doc) {", SENSITIVE),
    # A contenteditable or role=textbox element's text is what the user
    # typed, never its label (REVIEW-R5-B #11).
    (
        'const text = ((labelled || el).textContent || "").trim().replace(/\\s+/g, " ");',
        "const editable = !labelled && (el.isContentEditable || "
        '(el.getAttribute && el.getAttribute("role") === "textbox"));\n'
        '    const text = editable ? "" : ((labelled || el).textContent || "").trim().replace(/\\s+/g, " ");',
    ),
    (
        "const value = el.getAttribute(attr);",
        'const value = attr === "value" && sensitiveKind(el) ? "" : el.getAttribute(attr);',
    ),
    (
        '    if (typeof control.value === "string" && control.value) {\n'
        "      return clamp(control.value, 60);",
        "    const secret = sensitiveKind(el);\n"
        "    if (secret) {\n"
        '      const length = typeof control.value === "string" ? control.value.length : 0;\n'
        '      return length ? "[" + secret + " field, " + length + " characters]" : "";\n'
        "    }\n"
        '    if (typeof control.value === "string" && control.value) {\n'
        "      return clamp(control.value, 60);",
    ),
]


def patch(engine: str) -> str:
    for anchor, replacement in PATCHES:
        count = engine.count(anchor)
        if count != 1:
            raise SystemExit(
                f"privacy patch anchor found {count} times (want 1): {anchor[:60]!r}"
            )
        engine = engine.replace(anchor, replacement)
    return engine


def main() -> None:
    src, commit, out = sys.argv[1], sys.argv[2], sys.argv[3]
    d = json.load(open(src, encoding="utf-8"))
    engine = patch(d["engine"])
    for key, value in (("engine", engine), ("watch", d["watch"])):
        if "'''" in value:
            raise SystemExit(key + " contains a triple quote; a raw string cannot hold it")
    dart = f"""// GENERATED by tool/browser/generate_preview_engine.sh. Do not edit.
//
// Hermes Desktop's in-page act engine and overlay, as Desktop stringifies
// them (apps/desktop/src/lib/preview-act: act-in-page.ts actEngineSource(),
// watch-in-page.ts watchInPage), from hermes-agent
// {commit},
// with ONE change: Console's privacy patch (tool/browser/
// render_preview_engine.py, REVIEW-R4 P1-a1) never reports the value of a
// password, one-time-code or payment-card field.
// SPDX-FileCopyrightText: Copyright (c) 2025 Nous Research
// SPDX-License-Identifier: MIT

import 'agent_preview_act.dart';

/// Desktop's injectable sources (see the header).
const AgentPreviewEngineSource hermesPreviewEngine = AgentPreviewEngineSource(
  engine: r\'\'\'{engine}\'\'\',
  watch: r\'\'\'{d["watch"]}\'\'\',
  watchTag: {d["watchTag"]},
);
"""
    open(out, "w", encoding="utf-8").write(dart)


if __name__ == "__main__":
    main()
