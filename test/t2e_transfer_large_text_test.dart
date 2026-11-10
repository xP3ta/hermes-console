// Wave 8, round 2 (after T2-D): a transfer's name was cut to a few letters
// at 200 % text. From 1.3× on it may take a second line, and the row (a
// least height, not a fixed one) grows with it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/ssh_transfer_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
  });

  for (final (scale, lines) in [(1.0, 1), (2.0, 2)]) {
    testWidgets('at ×$scale a transfer name takes $lines line(s)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final manager = await ConnectionManager.create(prefs);
      final service = SftpTransferService(
        SshManager(SecureStorage(), manager),
        NotificationService(prefs),
      );
      const name = 'informe-trimestral-de-copias-nocturnas-del-nas.tar.gz';
      service.transfers.value = [
        SftpTransfer(
          id: 'd0',
          connectionId: 'c',
          name: name,
          direction: TransferDirection.download,
          totalBytes: 1500,
          status: TransferStatus.done,
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('console-light'),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: SshTransferBar(service: service),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(find.text(name)).maxLines, lines);
      final row = tester.getSize(
        find.byKey(const ValueKey('sftp-transfer-row-d0')),
      );
      expect(row.height, greaterThanOrEqualTo(SshTransferBar.rowHeight));
    });
  }
}
