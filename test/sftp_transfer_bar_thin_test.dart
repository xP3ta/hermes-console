import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/hermes_tokens.dart';
import 'package:hermes_android/core/widgets/ssh_transfer_bar.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

// the owner, Fold horizontal (APK 9708): «email-nous.txt · listo ×» took a large
// block at the foot of Files. The transfers are a thin pill now: one 48 dp
// row each, no band behind them.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
  });

  testWidgets('a finished download is one 48 dp row in a thin pill', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final service = SftpTransferService(
      SshManager(SecureStorage(), manager),
      NotificationService(prefs),
    );
    service.transfers.value = [
      SftpTransfer(
        id: 'd0',
        connectionId: 'c',
        name: 'email-nous.txt',
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
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SshTransferBar(service: service),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final row = tester.getSize(
      find.byKey(const ValueKey('sftp-transfer-row-d0')),
    );
    expect(row.height, SshTransferBar.rowHeight);
    // The pill and its margins: 4 above, 8 below, no band.
    final bar = tester.getRect(find.byKey(const ValueKey('sftp-transfer-bar')));
    expect(bar.height, SshTransferBar.rowHeight);
    expect(bar.left, 12);
    expect(bar.right, 800 - 12);
    final decoration = tester
        .widget<DecoratedBox>(find.byKey(const ValueKey('sftp-transfer-bar')))
        .decoration;
    expect(
      (decoration as ShapeDecoration).color,
      AppTheme.hermesRedDark.hermes.surfaceVariant,
    );
    // Its dismiss keeps a 48 dp target.
    final dismiss = tester.getSize(
      find.ancestor(
        of: find.byIcon(Icons.close),
        matching: find.byType(IconButton),
      ),
    );
    expect(dismiss.width, greaterThanOrEqualTo(48));
    expect(dismiss.height, greaterThanOrEqualTo(48));
  });

  // Ola 6 (audit §2.8, P3): the × of a row says «Dismiss» and dismissed
  // every finished transfer; the progress track was the pill's colour.
  testWidgets('a row\'s × dismisses that transfer only; the track shows', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final manager = await ConnectionManager.create(prefs);
    final service = SftpTransferService(
      SshManager(SecureStorage(), manager),
      NotificationService(prefs),
    );
    SftpTransfer transfer(String id, TransferStatus status) => SftpTransfer(
      id: id,
      connectionId: 'c',
      name: '$id.txt',
      direction: TransferDirection.download,
      totalBytes: 100,
      doneBytes: 40,
      status: status,
    );
    service.transfers.value = [
      transfer('d0', TransferStatus.done),
      transfer('d1', TransferStatus.done),
      transfer('d2', TransferStatus.running),
    ];
    final theme = AppTheme.hermesRedDark;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: theme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SshTransferBar(service: service),
          ),
        ),
      ),
    );

    final track = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(track.backgroundColor, HermesChrome.of(theme.hermes).line);
    expect(track.backgroundColor, isNot(theme.hermes.surfaceVariant));

    // Two finished rows, each with its ×; the running one has none.
    expect(find.byTooltip('Dismiss'), findsNWidgets(2));
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('sftp-transfer-row-d0')),
        matching: find.byTooltip('Dismiss'),
      ),
    );
    await tester.pump();
    expect(service.transfers.value.map((t) => t.id), ['d1', 'd2']);
    expect(find.byKey(const ValueKey('sftp-transfer-row-d0')), findsNothing);
    expect(find.byKey(const ValueKey('sftp-transfer-row-d1')), findsOneWidget);

    // A running transfer is never dismissed this way.
    service.dismiss(service.transfers.value.last);
    expect(service.transfers.value.map((t) => t.id), ['d1', 'd2']);
  });
}
