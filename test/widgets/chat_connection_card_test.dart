// The connection prompt card above the composer: one row per target, links
// only for https targets, "Not now" per target, one "Continue" for the
// operation. Fixtures are synthetic and use an example host.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection_request.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_connection_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

ConnectionRequest _request({
  bool settled = false,
  Uri? link,
  ConnectionTargetState state = ConnectionTargetState.pending,
  String? hint,
}) => ConnectionRequest(
  opId: 'op-1',
  seq: 1,
  deadlineAt: 1790000000,
  toolCallId: 'call-1',
  settled: settled,
  targets: [
    ConnectionTarget(
      name: 'gmail',
      kind: ConnectionTargetKind.connector,
      state: state,
      action: 'authorize',
      connectUrl: link,
      hint: hint,
    ),
    const ConnectionTarget(
      name: 'files',
      kind: ConnectionTargetKind.mcp,
      state: ConnectionTargetState.connected,
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  ConnectionRequest request, {
  bool canAct = true,
  List<Uri>? opened,
  List<String>? skipped,
  List<int>? continued,
  String locale = 'en',
}) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.hermesRedDark,
    locale: Locale(locale),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: Scaffold(
      body: ChatConnectionCard(
        request: request,
        canAct: canAct,
        onOpenLink: (uri) => opened?.add(uri),
        onSkip: (name) => skipped?.add(name),
        onContinue: () => continued?.add(1),
      ),
    ),
  ),
);

void main() {
  testWidgets('shows every target and its state', (tester) async {
    await _pump(tester, _request(link: Uri.parse('https://c.example.test/g')));
    expect(find.text('gmail'), findsOneWidget);
    expect(find.text('files'), findsOneWidget);
    expect(find.byKey(const ValueKey('cxn-state-gmail')), findsOneWidget);
    expect(find.byKey(const ValueKey('cxn-state-files')), findsOneWidget);
  });

  testWidgets('open link, Not now and Continue call back with the target', (
    tester,
  ) async {
    final opened = <Uri>[];
    final skipped = <String>[];
    final continued = <int>[];
    final link = Uri.parse('https://c.example.test/g');
    await _pump(
      tester,
      _request(link: link),
      opened: opened,
      skipped: skipped,
      continued: continued,
    );

    await tester.tap(find.byKey(const ValueKey('cxn-open-gmail')));
    await tester.tap(find.byKey(const ValueKey('cxn-skip-gmail')));
    await tester.tap(find.byKey(const ValueKey('cxn-continue')));

    expect(opened, [link]);
    expect(skipped, ['gmail']);
    expect(continued, [1]);
    // A connected target has nothing left to open or skip.
    expect(find.byKey(const ValueKey('cxn-open-files')), findsNothing);
    expect(find.byKey(const ValueKey('cxn-skip-files')), findsNothing);
  });

  testWidgets('a target without a link offers no open button', (tester) async {
    await _pump(tester, _request());
    expect(find.byKey(const ValueKey('cxn-open-gmail')), findsNothing);
    expect(find.byKey(const ValueKey('cxn-skip-gmail')), findsOneWidget);
  });

  testWidgets('a read-only chat shows the card without actions', (
    tester,
  ) async {
    await _pump(
      tester,
      _request(link: Uri.parse('https://c.example.test/g')),
      canAct: false,
    );
    expect(find.text('gmail'), findsOneWidget);
    expect(find.byKey(const ValueKey('cxn-open-gmail')), findsNothing);
    expect(find.byKey(const ValueKey('cxn-skip-gmail')), findsNothing);
    expect(find.byKey(const ValueKey('cxn-continue')), findsNothing);
  });

  testWidgets('a settled card keeps its final state and drops the actions', (
    tester,
  ) async {
    await _pump(
      tester,
      _request(
        settled: true,
        state: ConnectionTargetState.connected,
        link: Uri.parse('https://c.example.test/g'),
      ),
    );
    expect(find.byKey(const ValueKey('cxn-state-gmail')), findsOneWidget);
    expect(find.byKey(const ValueKey('cxn-continue')), findsNothing);
    expect(find.byKey(const ValueKey('cxn-skip-gmail')), findsNothing);
  });

  testWidgets('renders in Spanish', (tester) async {
    await _pump(tester, _request(), locale: 'es');
    expect(find.text('Ahora no'), findsOneWidget);
    expect(find.text('Continuar'), findsOneWidget);
  });
}
