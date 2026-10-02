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

class _RecordingNotifications extends NotificationService {
  _RecordingNotifications(super.prefs);

  final titles = <String>[];
  final bodies = <String>[];

  @override
  Future<void> transferDone({
    required int id,
    required String title,
    required String body,
    required bool ok,
  }) async {
    titles.add(title);
    bodies.add(body);
  }
}

Future<(SftpTransferService, _RecordingNotifications)> _service(
  String locale,
) async {
  SharedPreferences.setMockInitialValues({'app_locale': locale});
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final notifications = _RecordingNotifications(prefs);
  return (
    SftpTransferService(SshManager(SecureStorage(), manager), notifications),
    notifications,
  );
}

SftpTransfer _transfer(String id, {TransferStatus? status}) => SftpTransfer(
  id: id,
  connectionId: 'c',
  name: 'notes-$id.txt',
  direction: TransferDirection.download,
  totalBytes: 10,
  status: status ?? TransferStatus.running,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  for (final (locale, cancelled, failedTitle) in const [
    ('en', 'Cancelled by user', 'Download failed · notes.txt'),
    ('es', 'Cancelado por el usuario', 'Falló la descarga · notes.txt'),
  ]) {
    test('transfer texts follow the $locale app language', () async {
      final (service, notifications) = await _service(locale);

      service.transfers.value = [_transfer('a')];
      service.cancelAll();
      expect(service.transfers.value.single.error, cancelled);

      await service.download(
        connectionId: 'missing',
        remotePath: '/tmp/notes.txt',
        fileName: 'notes.txt',
        totalBytes: 10,
      );
      expect(notifications.titles, [failedTitle]);
    });
  }

  for (final (locale, done, error) in const [
    ('en', 'done', 'error'),
    ('es', 'listo', 'error'),
  ]) {
    testWidgets('transfer bar status words follow the $locale UI language', (
      tester,
    ) async {
      final (service, _) = await _service(locale);
      service.transfers.value = [
        _transfer('ok', status: TransferStatus.done),
        _transfer('ko', status: TransferStatus.error),
      ];
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          theme: AppTheme.fromId('dark'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: Scaffold(body: SshTransferBar(service: service)),
        ),
      );
      expect(find.text(done), findsOneWidget);
      expect(find.text(error), findsOneWidget);
    });
  }
}
