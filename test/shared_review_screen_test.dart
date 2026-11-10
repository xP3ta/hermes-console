// The "review what was shared" screen: it shows what arrived through the
// share sheet, lets the user drop items and pick the instance, and only then
// hands back what is left. Backing out hands back nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/shared_review_screen.dart';
import 'package:hermes_android/core/services/android_share_inbox.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

SavedConnection _conn(String id, String label) => SavedConnection(
  id: id,
  label: label,
  host: 'h$id.example.net',
  port: 8642,
  apiKey: 'k',
);

AttachmentDraft _file(String name) => AttachmentDraft(
  type: AttachmentType.document,
  name: name,
  mimeType: 'text/plain',
  sizeBytes: 2048,
  localPath: '/tmp/$name',
);

Future<void> _open(WidgetTester tester, AndroidSharedContent content) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: SharedReviewScreen(
        content: content,
        connections: [_conn('a', 'Alpha'), _conn('b', 'Beta')],
        initialConnectionId: 'a',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final content = AndroidSharedContent(
    id: 'share-1',
    text: 'Look at this link',
    attachments: [_file('a.txt'), _file('b.txt')],
  );

  testWidgets('shows every item and removing one leaves the rest', (
    tester,
  ) async {
    await _open(tester, content);
    expect(find.text('Look at this link'), findsOneWidget);
    expect(find.text('a.txt'), findsOneWidget);
    expect(find.text('b.txt'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('share-remove-attachment-0')));
    await tester.pumpAndSettle();
    expect(find.text('a.txt'), findsNothing);
    expect(find.text('b.txt'), findsOneWidget);
  });

  testWidgets('continue returns what is left and the chosen destination', (
    tester,
  ) async {
    SharedReviewResult? result;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<SharedReviewResult>(
                MaterialPageRoute(
                  builder: (_) => SharedReviewScreen(
                    content: content,
                    connections: [_conn('a', 'Alpha'), _conn('b', 'Beta')],
                    initialConnectionId: 'a',
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('share-remove-text')));
    await tester.tap(find.byKey(const ValueKey('share-remove-attachment-1')));
    await tester.tap(find.byKey(const ValueKey('share-target-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-send')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.connection.id, 'b');
    expect(result!.content.id, 'share-1');
    expect(result!.content.text, isEmpty);
    expect(result!.content.attachments.map((a) => a.name), ['a.txt']);
  });

  testWidgets('with everything removed there is nothing to send', (
    tester,
  ) async {
    await _open(
      tester,
      AndroidSharedContent(id: 'share-2', text: 'Only text', attachments: []),
    );
    await tester.tap(find.byKey(const ValueKey('share-remove-text')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('share-nothing-left')), findsOneWidget);
    final send = tester.widget<FilledButton>(
      find.byKey(const ValueKey('share-send')),
    );
    expect(send.onPressed, isNull);
  });
}
