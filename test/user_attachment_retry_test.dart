// A user's attachment kept on the server: one failed fetch used to mark it
// unavailable for the whole session, whatever the reason, with nothing to
// tap. Only an answer that will not change is remembered now; a timeout or
// a moment offline can be tried again with a tap.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/user_server_attachment_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  setUp(UserServerAttachmentCard.clearCachesForTesting);

  Future<void> pump(
    WidgetTester tester,
    UserServerAttachmentLoader loader, {
    String path = '/home/u/.hermes/uploads/report.docx',
  }) => tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: Scaffold(
        body: Center(
          child: UserServerAttachmentCard(
            name: 'report.docx',
            sizeLabel: '12 KB',
            serverRef: UserServerAttachmentRef(isImage: false, path: path),
            cacheScope: 'c1\u0000default',
            loader: loader,
          ),
        ),
      ),
    ),
  );

  Future<void> tapCard(WidgetTester tester) async {
    await tester.tap(find.text('report.docx'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('a fetch that timed out can be tried again with a tap', (
    tester,
  ) async {
    var calls = 0;
    await pump(tester, (_) async {
      calls++;
      throw TimeoutException('no answer');
    });
    final strings = Strings.of(tester.element(find.byType(Scaffold)));

    await tapCard(tester);
    expect(calls, 1);
    // The card joins it to the file's badge («DOCX · Not available»).
    expect(
      find.textContaining(strings.cm1215AttachmentUnavailable),
      findsOneWidget,
    );

    await tapCard(tester);
    expect(calls, 2, reason: 'the card is still a button');
    await tapCard(tester);
    expect(calls, 3);
  });

  testWidgets('offline and a busy server are tried again too', (tester) async {
    final failures = <Object>[
      const SocketException('network is unreachable'),
      const DashboardHttpException(503),
      const DashboardHttpException(429),
    ];
    var calls = 0;
    await pump(tester, (_) async => throw failures[calls++]);
    for (var i = 0; i < failures.length; i++) {
      await tapCard(tester);
      expect(calls, i + 1);
    }
  });

  testWidgets('a file the server no longer has stays unavailable', (
    tester,
  ) async {
    var calls = 0;
    await pump(tester, (_) async {
      calls++;
      throw const DashboardHttpException(404);
    });
    await tapCard(tester);
    expect(calls, 1);
    await tapCard(tester);
    await tapCard(tester);
    expect(calls, 1, reason: 'a definite answer is not asked for again');
  });
}
