"""Small fixtures corrupt each Android resource validation guard."""

from pathlib import Path
import tempfile
import unittest

from android_xml_parity import FILES, check_resources, read_resources


class AndroidXmlParityTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.valid = ('<resources><string name="hello">Hello %1$s</string>'
                      '<plurals name="items"><item quantity="one">%d item</item>'
                      '<item quantity="other">%d items</item></plurals></resources>')
        for directory in ['values', 'values-es', 'values-pt']:
            (self.root / directory).mkdir()
            for file in FILES:
                (self.root / directory / file).write_text(self.valid)
        self.path = self.root / 'values-pt' / FILES[0]

    def change(self, old, new):
        self.path.write_text(self.valid.replace(old, new))

    def rejected(self, fragment):
        self.assertTrue(any(fragment in e for e in check_resources(self.root)),
                        check_resources(self.root))

    def test_valid(self):
        self.assertEqual(check_resources(self.root), [])

    def test_missing_file(self):
        self.path.unlink()
        self.rejected('file')

    def test_missing_reference(self):
        (self.root / 'values-es' / FILES[0]).unlink()
        self.rejected('file')

    def test_xml(self):
        self.change('</string>', '</invalid>')
        self.rejected('XML')

    def test_missing_key(self):
        self.change('<string name="hello">Hello %1$s</string>', '')
        self.rejected('missing keys')

    def test_extra_key(self):
        self.change('</resources>', '<string name="extra">Extra</string></resources>')
        self.rejected('extra keys')

    def test_duplicate(self):
        self.change('</resources>', '<string name="hello">Again</string></resources>')
        self.rejected('duplicate')

    def test_type(self):
        self.change('<string name="hello">Hello %1$s</string>',
                    '<plurals name="hello"><item quantity="other">%1$s</item></plurals>')
        self.rejected('type')

    def test_placeholder_type(self):
        self.change('%1$s', '%1$d')
        self.rejected('placeholders')

    def test_placeholder_repeated(self):
        self.change('%1$s', '%1$s %1$s')
        self.rejected('placeholders')

    def test_placeholder_per_plural_branch(self):
        self.change('%d item</item>', '%s item</item>')
        self.rejected('placeholders')

    def test_other_required(self):
        self.change('quantity="other"', 'quantity="few"')
        self.rejected('other')

    def test_duplicate_quantity(self):
        self.change('quantity="one"', 'quantity="other"')
        self.rejected('quantity')

    def test_invalid_quantity(self):
        self.change('quantity="one"', 'quantity="single"')
        self.rejected('quantity')

    def test_empty(self):
        self.change('Hello %1$s', '  ')
        self.rejected('empty')

    def test_apostrophe(self):
        self.change('Hello', "Don't")
        self.rejected('apostrophe')

    def test_at(self):
        self.change('Hello', '@Hello')
        self.rejected('escape')

    def test_question(self):
        self.change('Hello', '?Hello')
        self.rejected('escape')

    def test_escaped_and_quoted(self):
        for text in [r"Don\'t", r'\@Hello', r'\?Hello', '"Don\'t"',
                     '"@Hello"', '"?Hello"', 'Who? a@b.example', 'Don’t']:
            with self.subTest(text=text):
                self.change('Hello', text)
                self.assertEqual(check_resources(self.root), [])

    def test_double_backslash_does_not_escape_apostrophe(self):
        self.change('Hello', r"Don\\'t")
        self.rejected('apostrophe')

    def test_positional_arguments_can_reorder(self):
        self.valid = self.valid.replace('Hello %1$s', '%1$s %2$d %%')
        for directory in ['values', 'values-es', 'values-pt']:
            for file in FILES:
                (self.root / directory / file).write_text(self.valid)
        self.change('%1$s %2$d %%', '%2$d %1$s %%')
        self.assertEqual(check_resources(self.root), [])

    def test_cjk_only_other_and_nonlocale_directories(self):
        (self.root / 'values-zh').mkdir()
        (self.root / 'values-night').mkdir()
        (self.root / 'values-v31').mkdir()
        for file in FILES:
            (self.root / 'values-zh' / file).write_text(self.valid.replace(
                '<item quantity="one">%d item</item>', ''))
        self.assertEqual(check_resources(self.root), [])

    def test_default_untranslatable_resource(self):
        path = self.root / 'values' / FILES[0]
        path.write_text(self.valid.replace('</resources>',
            '<string name="brand" translatable="false">Brand</string></resources>'))
        self.assertEqual(check_resources(self.root), [])

    def test_reference_also_validated(self):
        path = self.root / 'values-es' / FILES[0]
        path.write_text('<broken>')
        self.rejected('XML')

    def test_named_resources_only(self):
        self.change(' name="hello"', '')
        self.rejected('name')

    def test_root(self):
        self.path.write_text('<wrong/>')
        self.rejected('root')

    def test_unsupported_resource_type(self):
        self.change('<string name="hello">Hello %1$s</string>',
                    '<integer name="hello">42</integer>')
        self.rejected('type')

    def test_unclosed_quote(self):
        self.change('Hello', '"Hello')
        self.rejected('quote')

    def test_newline_escape_preserved(self):
        self.valid = self.valid.replace('Hello', r'Hello\n')
        for directory in ['values', 'values-es', 'values-pt']:
            for file in FILES:
                (self.root / directory / file).write_text(self.valid)
        self.change(r'Hello\n', 'Hello')
        self.rejected('placeholders')

    def test_read_resources(self):
        self.assertEqual(set(read_resources(self.path)), {'hello', 'items'})


if __name__ == '__main__':
    unittest.main()
