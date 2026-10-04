import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/foreign_session.dart';
import 'package:hermes_android/core/screens/foreign_session_import_screen.dart';
import 'package:hermes_android/core/services/desktop_control_gateway.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

final class _Gateway implements HermesForeignSessionGateway {
  final List<String> calls = [];
  String? alreadyImported;
  bool unsupported = false;

  @override
  Future<ForeignSessionPage> foreignList({
    String? profile,
    ForeignSource? source,
    int? offset,
  }) async {
    calls.add('list');
    if (unsupported) {
      throw const DesktopControlFailure(
        DesktopControlFailureKind.unsupported,
        code: -32601,
      );
    }
    return const ForeignSessionPage(
      sessions: [
        ForeignSessionRow(
          id: 'opaque-secret-handle',
          source: ForeignSource.claude,
          label: 'Claude Code',
          title: 'Fix the parser',
          cwd: '/work/app',
          turnCount: 3,
        ),
      ],
      host: 'srv.example.test',
      unreadable: 1,
    );
  }

  @override
  Future<ForeignPreview> foreignPreview(String id, {String? profile}) async {
    calls.add('preview');
    return ForeignPreview(
      messages: const [ForeignMessage(role: 'user', content: 'hello there')],
      total: 1,
      alreadyImported: alreadyImported,
    );
  }

  @override
  Future<ForeignImportResult> foreignImport(
    String id, {
    String? profile,
  }) async {
    calls.add('import');
    return const ForeignImportResult(sessionId: 'local-1');
  }
}

Widget _app(_Gateway gateway, ValueChanged<String> onOpen) => MaterialApp(
  theme: AppTheme.fromId('dark'),
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => ForeignSessionImportScreen(
              gateway: gateway,
              profile: 'work',
              onOpenSession: onOpen,
            ),
          ),
        ),
        child: const Text('open'),
      ),
    ),
  ),
);

Future<void> _openScreen(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists rows, host and the unreadable note, never the id', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_Gateway(), (_) {}));
    await _openScreen(tester);
    expect(find.text('Fix the parser'), findsOneWidget);
    expect(find.text('Reading from srv.example.test'), findsOneWidget);
    expect(
      find.text('Some logs were empty, unreadable, or too large to preview.'),
      findsOneWidget,
    );
    expect(find.textContaining('opaque-secret-handle'), findsNothing);
    expect(find.textContaining('/work/app'), findsOneWidget);
  });

  testWidgets('preview then one import opens the returned session', (
    tester,
  ) async {
    final gateway = _Gateway();
    String? opened;
    await tester.pumpWidget(_app(gateway, (id) => opened = id));
    await _openScreen(tester);
    await tester.tap(find.text('Fix the parser'));
    await tester.pumpAndSettle();
    expect(find.text('hello there'), findsOneWidget);
    expect(find.text('Continue in Hermes'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('foreign-import-primary')));
    await tester.pumpAndSettle();
    expect(gateway.calls.where((c) => c == 'import').length, 1);
    expect(opened, 'local-1');
  });

  testWidgets('already imported offers Open and sends no import', (
    tester,
  ) async {
    final gateway = _Gateway()..alreadyImported = 'local-7';
    String? opened;
    await tester.pumpWidget(_app(gateway, (id) => opened = id));
    await _openScreen(tester);
    await tester.tap(find.text('Fix the parser'));
    await tester.pumpAndSettle();
    expect(find.text('Open in Hermes'), findsOneWidget);
    expect(find.text('Continue in Hermes'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('foreign-import-primary')));
    await tester.pumpAndSettle();
    expect(gateway.calls.contains('import'), isFalse);
    expect(opened, 'local-7');
  });

  testWidgets('an unsupported server closes the page', (tester) async {
    await tester.pumpWidget(_app(_Gateway()..unsupported = true, (_) {}));
    await _openScreen(tester);
    expect(find.byType(ForeignSessionImportScreen), findsNothing);
  });
}
