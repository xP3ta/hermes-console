// A download that failed offers Retry only where a second try can end
// differently: never for a file the server no longer has or refuses, or one
// over a limit; always for a server error or a dropped connection.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.fromMode(AppThemeMode.dark),
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  group('a download that failed', () {
    Future<void> fail(WidgetTester tester, Object error) async {
      await tester.pumpWidget(
        _host(
          GeneratedMediaAttachmentCard(
            key: ValueKey(error),
            reference: const GeneratedMediaReference(
              source: '/workspace/notes.txt',
              kind: GeneratedMediaKind.file,
              sourceKind: GeneratedMediaSourceKind.serverPath,
              displayName: 'notes.txt',
              mimeType: 'text/plain',
              sizeBytes: 22,
            ),
            autoLoad: true,
            load: (onProgress, isCancelled) async => throw error,
            errorLabelBuilder: (_, _) => 'reason',
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    for (final (what, error) in [
      ('gone from the server', const DashboardHttpException(404)),
      ('refused by the server', const DashboardHttpException(403)),
      (
        'over the size limit',
        const FormatException('generated media exceeds its size limit'),
      ),
    ]) {
      testWidgets('a file $what offers no Retry', (tester) async {
        await fail(tester, error);
        expect(find.textContaining('reason'), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
      });
    }

    testWidgets('a server error and a dropped connection keep Retry', (
      tester,
    ) async {
      await fail(tester, const DashboardHttpException(503));
      expect(find.textContaining('reason'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      await fail(tester, const SocketException('reset'));
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
