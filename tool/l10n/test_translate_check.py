"""Contract tests and one corrupt catalog per validation guard."""

import copy
from pathlib import Path
import tempfile
import unittest

from translate_check import IcuParser, load_catalog, validate_catalog


class TranslationCheckTest(unittest.TestCase):
    def setUp(self):
        self.source = {
            "@@locale": "es",
            "hello": "Hermes Console · {name}\n`code`",
            "items": "{n, plural, =1{1 item} other{{n} items}}",
            "state": "{s, select, ready{Ready} other{Unknown}}",
        }
        self.target = copy.deepcopy(self.source)
        self.target["@@locale"] = "de"

    def check(self, target=None):
        return validate_catalog(self.source, target or self.target)

    def assertRejected(self, code):
        self.assertTrue(any(code in error for error in self.check()), self.check())

    def test_valid_catalog(self):
        self.assertEqual(self.check(), [])

    def test_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app_de.arb"
            path.write_text('{"@@locale":"de","x":"a","x":"b"}')
            with self.assertRaisesRegex(ValueError, "duplicate"):
                load_catalog(path)

    def test_non_object_catalog(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app_de.arb"
            path.write_text('[]')
            with self.assertRaisesRegex(ValueError, "object"):
                load_catalog(path)

    def test_missing_key(self):
        del self.target["hello"]
        self.assertRejected("missing keys")

    def test_extra_key(self):
        self.target["obsolete"] = "Old"
        self.assertRejected("extra keys")

    def test_missing_locale(self):
        del self.target["@@locale"]
        self.assertRejected("locale")

    def test_invalid_locale(self):
        self.target["@@locale"] = "../../invalid"
        self.assertRejected("locale")

    def test_filename_locale(self):
        self.assertTrue(validate_catalog(self.source, self.target, "fr"))

    def test_non_string_message(self):
        self.target["hello"] = 1
        self.assertRejected("string")

    def test_placeholder_renamed(self):
        self.target["hello"] = "Hermes Console · {user}\n`code`"
        self.assertRejected("arguments")

    def test_unbalanced_icu(self):
        self.target["items"] = "{n, plural, other{{n} items}"
        self.assertRejected("ICU")

    def test_invalid_icu_type(self):
        self.target["items"] = "{n, invalid, other{{n} items}}"
        self.assertRejected("ICU")

    def test_parser_rejects_unknown_type_directly(self):
        with self.assertRaisesRegex(ValueError, "unsupported ICU type"):
            IcuParser("{n, invalid, other{items}}").parse()

    def test_parser_reports_an_unclosed_branch(self):
        with self.assertRaisesRegex(ValueError, "unclosed ICU branch"):
            IcuParser("{n, plural, other{items").parse()

    def test_missing_other(self):
        self.target["items"] = "{n, plural, one{1 item}}"
        self.assertRejected("other")

    def test_duplicate_selector(self):
        self.target["items"] = "{n, plural, other{{n}} other{{n}}}"
        self.assertRejected("duplicate")

    def test_invalid_plural_category(self):
        self.target["items"] = "{n, plural, singular{1} other{{n}}}"
        self.assertRejected("category")

    def test_argument_type_changed(self):
        self.target["items"] = "{n}"
        self.assertRejected("arguments")

    def test_duplicated_plural_structure(self):
        self.target["items"] = "{n, plural, other{{n, plural, other{{n} items}}}}"
        self.assertRejected("arguments")

    def test_select_cases_preserved(self):
        self.target["state"] = "{s, select, other{Unknown}}"
        self.assertRejected("select cases")

    def test_chinese_only_other(self):
        self.target["@@locale"] = "zh"
        self.assertRejected("only other")
        self.target["items"] = "{n, plural, other{{n} 项}}"
        self.assertEqual(self.check(), [])

    def test_newlines_preserved(self):
        self.target["hello"] = self.target["hello"].replace("\n", " ")
        self.assertRejected("newlines")

    def test_backticks_preserved(self):
        self.target["hello"] = self.target["hello"].replace("`", "")
        self.assertRejected("backticks")

    def test_brands_preserved(self):
        self.target["hello"] = self.target["hello"].replace("Hermes", "Brand")
        self.assertRejected("brand Hermes")

    def test_brand_next_to_cjk(self):
        self.target["hello"] = "使用Hermes Console · {name}\n`code`"
        self.assertEqual(self.check(), [])

    def test_nested_plural_and_select(self):
        value = "{n, plural, other{{s, select, ok{{name}} other{{name}}}}}"
        self.source["nested"] = value
        self.target["nested"] = value
        self.assertEqual(self.check(), [])


if __name__ == "__main__":
    unittest.main()
