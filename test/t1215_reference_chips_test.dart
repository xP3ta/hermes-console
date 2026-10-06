import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/composer_reference.dart';
import 'package:hermes_android/core/models/reference_directive.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/user_message_text.dart';
import 'package:hermes_android/core/widgets/inline_message_editor.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

TextEditingValue _caretAtEnd(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

String? _typeSpace(String before) => promoteTypedReferenceOnSpace(
  _caretAtEnd(before),
  _caretAtEnd('$before '),
)?.text;

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

/// Every painted text run under [root], chips included.
String _paintedText(WidgetTester tester, Finder root) => tester
    .widgetList<RichText>(
      find.descendant(of: root, matching: find.byType(RichText)),
    )
    .map((r) => r.text.toPlainText())
    .join('|');

void main() {
  group('typed links stay links', () {
    test('a bare link followed by a space is left as typed', () {
      expect(_typeSpace('go https://x.io/a'), isNull);
      expect(_typeSpace('https://x.com/someuser/status/2107'), isNull);
      expect(_typeSpace('go https://x.io/a.'), isNull);
      final formatter = ComposerReferenceFormatter(enabled: () => true);
      expect(
        formatter
            .formatEditUpdate(
              _caretAtEnd('mira https://x.io/a'),
              _caretAtEnd('mira https://x.io/a '),
            )
            .text,
        'mira https://x.io/a ',
      );
    });

    test('an explicit @url still becomes the reference directive', () {
      expect(_typeSpace('@url:https://x.io/a'), '@url:`https://x.io/a` ');
      final starter = PathCompletionItem(
        kind: ComposerReferenceKind.url,
        value: '',
        display: '@url:',
        meta: '',
      );
      final value = _caretAtEnd('read @ur');
      expect(
        applyReferencePick(value, composerReferenceQuery(value)!, starter).text,
        'read @url:',
      );
      // @file / @folder promotion is unchanged.
      expect(_typeSpace('see @lib/a.dart'), 'see @file:`lib/a.dart` ');
      expect(_typeSpace('@src/'), '@folder:`src` ');
    });
  });

  group('reference labels', () {
    test('links read as host plus a short path', () {
      expect(
        referenceChipLabel(ComposerReferenceKind.url, 'https://x.com/a/b'),
        'x.com/a/b',
      );
      expect(
        referenceChipLabel(
          ComposerReferenceKind.url,
          'https://x.com/someuser/status/2107123456789',
        ),
        'x.com/someuser/…',
      );
      expect(
        referenceChipLabel(
          ComposerReferenceKind.url,
          'https://www.example.com/',
        ),
        'example.com',
      );
    });

    test('paths read as their basename with the line range', () {
      final refs = findReferenceDirectives(
        'see @file:`lib/core/main.dart`:3-9 and @folder:`apps/desktop/` '
        'and @file:pubspec.yaml:12',
      ).toList();
      expect(refs.map((r) => r.label), [
        'main.dart:3-9',
        'desktop',
        'pubspec.yaml:12',
      ]);
      expect(refs.first.value, 'lib/core/main.dart');
      expect(refs.first.raw, '@file:`lib/core/main.dart`:3-9');
    });

    test('a reference glued to a word is not a reference', () {
      expect(findReferenceDirectives('mail me@url:x'), isEmpty);
    });

    test('previews strip directives to host and basename', () {
      expect(
        plainReferencePreview(
          'mira @url:`https://x.com/a/b` y @file:`lib/a b.dart`, gracias',
        ),
        'mira x.com/a/b y a b.dart, gracias',
      );
      expect(plainReferencePreview('sin referencias'), 'sin referencias');
      final session = Session.fromJson({
        'id': 's-ref',
        'title': 't',
        'preview': 'abre @url:`https://x.com/a/b` ya',
        'source': 'mobile',
      });
      expect(session.cleanPreview, 'abre x.com/a/b ya');
    });
  });

  group('user message text', () {
    testWidgets('a quoted @url renders as a clean link chip', (tester) async {
      final taps = <String?>[];
      await tester.pumpWidget(
        _host(
          UserMessageText(
            data: 'mira @url:`https://x.com/a/b` ahora',
            onTapLink: taps.add,
          ),
        ),
      );
      final chip = find.byKey(const ValueKey('user-reference-chip-url'));
      expect(chip, findsOneWidget);
      expect(
        find.descendant(of: chip, matching: find.byIcon(Icons.link_rounded)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: chip, matching: find.text('x.com/a/b')),
        findsOneWidget,
      );
      final painted = _paintedText(tester, find.byType(UserMessageText));
      expect(painted, isNot(contains('`')));
      expect(painted, isNot(contains('@url')));
      expect(painted, contains('mira '));
      expect(painted, contains(' ahora'));
      await tester.tap(chip);
      expect(taps, ['https://x.com/a/b']);
    });

    testWidgets('@file and @folder render as named chips', (tester) async {
      await tester.pumpWidget(
        _host(
          const UserMessageText(
            data: 'lee @file:`lib/core/main.dart`:3-9 y @folder:`apps/web/`',
          ),
        ),
      );
      final file = find.byKey(const ValueKey('user-reference-chip-file'));
      final folder = find.byKey(const ValueKey('user-reference-chip-folder'));
      expect(
        find.descendant(of: file, matching: find.text('main.dart:3-9')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: folder, matching: find.text('web')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: folder,
          matching: find.byIcon(Icons.folder_outlined),
        ),
        findsOneWidget,
      );
      final painted = _paintedText(tester, find.byType(UserMessageText));
      expect(painted, isNot(contains('`')));
      expect(painted, isNot(contains('@file')));
      expect(painted, isNot(contains('@folder')));
    });

    testWidgets('a plain link stays a tappable link', (tester) async {
      final taps = <String?>[];
      await tester.pumpWidget(
        _host(
          UserMessageText(data: 'see https://x.io/a now', onTapLink: taps.add),
        ),
      );
      expect(
        find.byKey(const ValueKey('user-reference-chip-url')),
        findsNothing,
      );
      TextSpan? link;
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((span) {
          if (span is TextSpan &&
              span.text == 'https://x.io/a' &&
              span.recognizer is TapGestureRecognizer) {
            link = span;
          }
          return true;
        });
      }
      expect(link, isNotNull);
      (link!.recognizer! as TapGestureRecognizer).onTap!();
      expect(taps, ['https://x.io/a']);
    });

    testWidgets('inline code that is not a reference stays code', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const UserMessageText(data: 'run `ls -la`')),
      );
      expect(
        find.byKey(const ValueKey('user-reference-chip-url')),
        findsNothing,
      );
      expect(
        _paintedText(tester, find.byType(UserMessageText)),
        contains('ls -la'),
      );
    });
  });

  testWidgets('the edit composer accents references and keeps the raw text', (
    tester,
  ) async {
    const raw = 'abre @url:`https://x.com/a/b` ya';
    await tester.pumpWidget(
      _host(
        InlineMessageEditor(initialText: raw, onCancel: () {}, onSave: (_) {}),
      ),
    );
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, raw);
    final span = field.controller!.buildTextSpan(
      context: tester.element(find.byType(TextField)),
      withComposing: false,
    );
    final accent = AppTheme.fromId('dark').hermes.accent;
    final accented = <String>[];
    span.visitChildren((child) {
      if (child is TextSpan && child.style?.color == accent) {
        accented.add(child.text ?? '');
      }
      return true;
    });
    expect(accented, ['@url:`https://x.com/a/b`']);
  });
}
