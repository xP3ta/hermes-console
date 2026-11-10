import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/voice_disclosure_dialog.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// The direct-voice consent is a decision dialog: it goes through
/// `showHermesDialog` (design-system contract, spec 080), whose actions stay
/// pinned outside the scrolling text, so declining is as reachable as
/// accepting on any screen.
void main() {
  const accept = ValueKey('voice_client_direct_accept');
  const decline = ValueKey('voice_client_direct_decline');

  Future<({bool? Function() result, bool Function() closed})> open(
    WidgetTester tester, {
    Size view = const Size(800, 600),
    double textScale = 1,
  }) async {
    tester.view
      ..physicalSize = view
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (textScale != 1) {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    bool? result;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showClientDirectVoiceConsentDialog(context);
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (result: () => result, closed: () => closed);
  }

  testWidgets('it is the Hermes dialog, not an AlertDialog', (tester) async {
    await open(tester);
    final s = lookupStrings(const Locale('es'));
    expect(find.byKey(const ValueKey('hermes-dialog')), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(s.voz132DirectConsentTitle), findsOneWidget);
    expect(find.text(s.voz132DirectConsentBody), findsOneWidget);
    expect(find.text(s.voz132DirectConsentAccept), findsOneWidget);
    expect(find.text(s.voz132DirectConsentDecline), findsOneWidget);
  });

  for (final (view, scale) in const [
    (Size(800, 600), 1.0),
    (Size(360, 640), 1.0),
    (Size(360, 640), 2.0),
  ]) {
    final label = '${view.width.toInt()}x${view.height.toInt()} @${scale}x';

    testWidgets('$label: both choices are tappable without scrolling', (
      tester,
    ) async {
      await open(tester, view: view, textScale: scale);
      expect(tester.takeException(), isNull);
      expect(find.byKey(accept).hitTestable(), findsOneWidget);
      expect(find.byKey(decline).hitTestable(), findsOneWidget);
    });

    testWidgets('$label: declining answers false', (tester) async {
      final dialog = await open(tester, view: view, textScale: scale);
      await tester.tap(find.byKey(decline));
      await tester.pumpAndSettle();
      expect(dialog.closed(), isTrue);
      expect(dialog.result(), isFalse);
    });

    testWidgets('$label: accepting answers true', (tester) async {
      final dialog = await open(tester, view: view, textScale: scale);
      await tester.tap(find.byKey(accept));
      await tester.pumpAndSettle();
      expect(dialog.closed(), isTrue);
      expect(dialog.result(), isTrue);
    });
  }

  testWidgets('closing without a choice answers null', (tester) async {
    final dialog = await open(tester);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(dialog.closed(), isTrue);
    expect(dialog.result(), isNull);
  });
}
