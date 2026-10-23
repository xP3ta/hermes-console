"""The literal ratchet and adversarial lexer / new-copy regressions."""
import hashlib
import json
from pathlib import Path
import unittest

from literal_ratchet import DartStrings, check, inventory


class LiteralRatchetTest(unittest.TestCase):
    def test_production_allowlist(self):
        allowed = json.loads(Path('tool/l10n/literal_allowlist.json').read_text())
        added, stale = check(inventory(), allowed)
        self.assertFalse(bool(added), f'Unreviewed literals: {list(added.items())[:20]}')
        self.assertFalse(bool(stale), f'Remove stale allowlist entries: {list(stale.items())[:20]}')

    def test_nested_interpolation_raw_strings_comments_and_adjacent_literals(self):
        source = '''// Text('not code')
/* outer /* 'nested comment' */ still comment */
Text("Hello ${who ?? 'world'} ${f({'key': "inner ${x}"})}");
final raw = r'\\$untouched';
return 'one' 'two';
'''
        rows = DartStrings(source).scan()
        self.assertEqual([r['literal'] for r in rows], [
            '"Hello ${who ?? \'world\'} ${f({\'key\': "inner ${x}"})}"',
            "'world'", "'key'", '"inner ${x}"', "r'\\$untouched'", "'one'", "'two'",
        ])
        self.assertEqual(rows[0]['text'], 'Hello {…} {…}')
        self.assertEqual(rows[0]['line'], 3)

    def test_triple_quotes_and_escaped_delimiters(self):
        source = 'final x = """first\n${f(\'nested\')}\nlast"""; final y = \'can\\\'t\';'
        rows = DartStrings(source).scan()
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0]['text'], 'first\n{…}\nlast')
        self.assertEqual(rows[2]['literal'], "'can\\'t'")

    def test_every_new_surface_and_helper_literal_requires_review(self):
        surfaces = [
            "Text('New copy')", "label: 'New copy'", "title: 'New copy'",
            "hint: 'New copy'", "tooltip: 'New copy'", "subtitle: 'New copy'",
            "content: 'New copy'", "semanticLabel: 'New copy'",
            "SnackBar(content: Text('New copy'))", "return 'New copy';",
            "String get label => 'New copy';", "final names = ['New copy'];",
            "final x = flag ? 'New copy' : dynamicText;",
            "Text('${flag ? 'New copy' : name}')",
            "CustomWidget(description: 'New copy')",
        ]
        for source in surfaces:
            with self.subTest(source=source):
                rows = [{'path': 'lib/new.dart', **r} for r in DartStrings(source).scan()]
                self.assertTrue(check(rows, {})[0])

    def test_duplicate_spelling_at_a_new_site_is_not_grandfathered(self):
        allowed = {'lib/a.dart': [{'literal': "'Hermes'", 'count': 1, 'reason': 'Product name'}]}
        rows = [{'path': 'lib/a.dart', **r} for r in DartStrings("Text('Hermes'); Text('Hermes');").scan()]
        self.assertEqual(check(rows, allowed)[0][('lib/a.dart', "'Hermes'")], 1)
        self.assertTrue(check([], allowed)[1])
        rows[0]['path'] = 'lib/b.dart'
        self.assertTrue(check(rows, allowed)[0])

    def test_drawer_and_nine_language_soul_names_use_the_catalogs(self):
        drawer = Path('lib/core/widgets/hermes_drawer.dart').read_text()
        self.assertIn('label: strings.missionBotsLabel,', drawer)
        self.assertNotIn("label: 'Bots',", drawer)
        soul = Path('lib/core/screens/soul_screen.dart').read_text()
        for key in ('Tech', 'Homelab', 'Minimal', 'Empty'):
            self.assertIn(f's.soulTpl{key}Name', soul)
        self.assertIn('_soulTplLabel(Strings.of(context), template)', soul)
        self.assertNotIn('final String label;', soul)
        self.assertNotIn('final String description;', soul)
        names = ['soulTplTechName', 'soulTplHomelabName', 'soulTplMinimalName', 'soulTplEmptyName']
        for lang in 'es en pt de fr it ja ko zh'.split():
            data = json.loads(Path(f'lib/l10n/app_{lang}.arb').read_text())
            self.assertTrue(all(data[key] for key in names), lang)
            if lang != 'en':
                self.assertNotEqual(data[names[0]], 'Technical assistant', lang)
            expected = {'ja': 'カンバン', 'ko': '칸반', 'zh': '看板'}.get(lang, 'Kanban')
            self.assertEqual(data['drawerKanban'], expected, lang)
        # The template payload is a document written to SOUL.md, never UI copy.
        bodies = [r['literal'] for r in DartStrings(soul).scan() if r['literal'].startswith("'''# Identidad")]
        self.assertEqual(hashlib.sha256('\n'.join(bodies).encode()).hexdigest(), '817e3486317f8c3f7a5dd6cb61c28c71a89ee181f3855f651139deb7a1cb70d3')

    def test_bot_chat_remains_the_canonical_session_identity(self):
        source = Path('lib/core/bots/state/bot_chat_target.dart').read_text()
        self.assertIn("const botChatTitle = 'Bot Chat';", source)
        gateway = Path('lib/core/services/tui_gateway_client.dart').read_text()
        self.assertIn("'title': 'Bot Chat'", gateway)
        self.assertIn("title['title'] != 'Bot Chat'", gateway)


if __name__ == '__main__':
    unittest.main()
