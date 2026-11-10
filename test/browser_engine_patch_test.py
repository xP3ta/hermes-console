"""Console's privacy patch on Hermes Desktop's agent engine (REVIEW-R4 P1-a1).

The engine's naming kit must never report the value of a password, one-time
code or payment-card field, and the patch must stop the generation instead of
silently disappearing when Desktop's source changes.
"""

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location(
        "render_preview_engine", ROOT / "tool/browser/render_preview_engine.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The four spots of Desktop's naming kit the patch rewrites, as Desktop ships
# them (apps/desktop/src/lib/preview-act/naming.ts, stringified).
DESKTOP_SNIPPET = """(function namingKit(doc) {
  const labelOf = (el) => {
    const labelledBy = el.getAttribute("aria-labelledby");
    const labelled = labelledBy ? doc.getElementById(labelledBy) : null;
    const text = ((labelled || el).textContent || "").trim().replace(/\\s+/g, " ");
    for (const attr of ["placeholder", "title", "alt", "name", "value"]) {
      const value = el.getAttribute(attr);
      if (value) {
        return clamp(value, 80);
      }
    }
  };
  const valueOf = (el) => {
    const control = el;
    if (typeof control.value === "string" && control.value) {
      return clamp(control.value, 60);
    }
    return "";
  };
})"""


class EnginePrivacyPatchTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.render = load()

    def test_patch_guards_values_and_value_labels(self):
        patched = self.render.patch(DESKTOP_SNIPPET)
        self.assertIn("const sensitiveKind = (el) =>", patched)
        self.assertIn('if (type === "password"', patched)
        self.assertIn("current-password|new-password", patched)
        self.assertIn("one-time-code|cc-[a-z-]+", patched)
        self.assertIn('" field, " + length + " characters]"', patched)
        self.assertIn(
            'attr === "value" && sensitiveKind(el) ? "" : el.getAttribute(attr)',
            patched,
        )
        # The guard runs before Desktop's own value read.
        self.assertLess(
            patched.index("const secret = sensitiveKind(el);"),
            patched.index('if (typeof control.value === "string" && control.value)'),
        )

    def test_more_secret_fields_and_typed_text_are_covered(self):
        # REVIEW-R5-B #11: what the page calls the field, wherever it says it.
        patched = self.render.patch(DESKTOP_SNIPPET)
        for name in (
            "verif(y|ication)?.?code",
            "\\b2fa\\b",
            "two.?factor",
            "\\bmfa\\b",
            "\\btotp\\b",
            "pass.?code",
            "\\bpin\\b",
            "\\botp\\b",
        ):
            self.assertIn(name, patched)
        self.assertIn('attr("aria-label")', patched)
        self.assertIn('attr("aria-labelledby")', patched)
        self.assertIn("el.labels ? Array.from(el.labels)", patched)
        # One digit of a code split across boxes.
        self.assertIn('max > 0 && max <= 1', patched)
        # A contenteditable's text is what the user typed, never its label.
        self.assertIn('const editable = !labelled && (el.isContentEditable', patched)
        self.assertIn('const text = editable ? "" :', patched)

    def test_a_changed_desktop_source_stops_the_generation(self):
        changed = DESKTOP_SNIPPET.replace("return clamp(control.value, 60);", "return control.value;")
        with self.assertRaises(SystemExit):
            self.render.patch(changed)

    def test_the_checked_in_engine_carries_the_patch(self):
        engine = (ROOT / "lib/core/browser/hermes_preview_engine.g.dart").read_text(encoding="utf-8")
        self.assertIn("Console privacy patch (REVIEW-R4 P1-a1)", engine)
        self.assertIn("const secret = sensitiveKind(el);", engine)
        self.assertIn('attr === "value" && sensitiveKind(el)', engine)
        self.assertIn("verif(y|ication)?.?code", engine)
        self.assertIn('const text = editable ? "" :', engine)


if __name__ == "__main__":
    unittest.main()
