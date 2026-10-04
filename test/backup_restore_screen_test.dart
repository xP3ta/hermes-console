import 'dart:async';
// The backup page as the user meets it: a notice when App Lock is off, the
// warning before a backup, the summary and checkbox before a restore, the
// server's own words when it fails, and FLAG_SECURE for as long as it shows.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/backup_restore_screen.dart';
import 'package:hermes_android/core/services/action_follower.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backup_gateway.dart';

final _connection = SavedConnection(
  id: 'bk-screen',
  label: 'Test',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: 'k',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <bool>[];
  late Directory dir;
  late FakeBackupGateway gateway;
  late List<File> shared;
  late int refreshes;

  setUp(() async {
    secure.clear();
    dir = await Directory.systemTemp.createTemp('bk-screen-');
    gateway = FakeBackupGateway();
    shared = [];
    refreshes = 0;
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hermes/security'), (
          call,
        ) async {
          if (call.method == 'setSecureScreen') {
            secure.add(call.arguments as bool);
          }
          return null;
        });
  });

  tearDown(() async => dir.delete(recursive: true));

  Future<AppLockService> lock({required bool enabled}) async {
    SharedPreferences.setMockInitialValues({'app_lock_enabled': enabled});
    return AppLockService(await SharedPreferences.getInstance());
  }

  Future<File> zip() async {
    final archive = Archive()
      ..addFile(ArchiveFile('config.yaml', 3, Uint8List(3)))
      ..addFile(ArchiveFile('state.db', 5, Uint8List(5)))
      ..addFile(ArchiveFile('gateway.pid', 1, Uint8List(1)));
    final file = File('${dir.path}/pick.zip');
    file.writeAsBytesSync(ZipEncoder().encode(archive));
    return file;
  }

  Widget app(
    AppLockService appLock, {
    Future<bool> Function(BuildContext, AppLockService, String)? verify,
    Future<File?> Function()? pick,
  }) => MaterialApp(
    theme: AppTheme.fromId('dark'),
    locale: const Locale('en'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: BackupRestoreScreen(
      connection: _connection,
      profile: 'default',
      gateway: gateway,
      appLock: appLock,
      verifyLock: verify ?? (_, _, _) async => true,
      pickZip: pick ?? () async => null,
      saveToPhone: (file) async => shared.add(file),
      tempDirectory: () async => dir,
      refresh: () async => refreshes++,
      followerFor: (read) => ActionFollower(read: read, delay: (_) async {}),
    ),
  );

  Future<void> open(WidgetTester tester, Widget widget) async {
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  // Reading the picked zip is real file I/O, which the fake clock never
  // completes; give it real time before settling the frames.
  Future<void> pickZipAndWait(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('backup-restore-pick')));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('App Lock off: one notice, nothing is sent', (tester) async {
    await open(tester, app(await lock(enabled: false)));
    expect(find.text('Turn on App Lock to use backups'), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-create')), findsNothing);
    expect(gateway.calls, isEmpty);
  });

  testWidgets('a failed verify shows the locked state and sends nothing', (
    tester,
  ) async {
    await open(
      tester,
      app(await lock(enabled: true), verify: (_, _, _) async => false),
    );
    expect(find.byKey(const ValueKey('backup-unlock')), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-create')), findsNothing);
    expect(gateway.calls, isEmpty);
  });

  testWidgets('a server without backups shows a notice and no actions', (
    tester,
  ) async {
    gateway.isAvailable = false;
    await open(tester, app(await lock(enabled: true)));
    expect(find.text('This server has no backups'), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-create')), findsNothing);
    expect(gateway.calls, ['probe']);
  });

  testWidgets('a probe that cannot tell leaves the page without actions', (
    tester,
  ) async {
    gateway.availableError = StateError('timeout');
    await open(tester, app(await lock(enabled: true)));
    expect(find.byKey(const ValueKey('backup-create')), findsNothing);
    expect(find.byKey(const ValueKey('backup-restore-pick')), findsNothing);
    expect(find.byKey(const ValueKey('backup-retry')), findsOneWidget);
    expect(gateway.calls, ['probe']);
    gateway.availableError = null;
    await tester.tap(find.byKey(const ValueKey('backup-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('backup-create')), findsOneWidget);
    expect(gateway.calls, ['probe', 'probe']);
  });

  testWidgets('create: the warning comes first and cancel sends nothing', (
    tester,
  ) async {
    await open(tester, app(await lock(enabled: true)));
    await tester.tap(find.byKey(const ValueKey('backup-create')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The backup contains your keys, logins, vault and conversation '
        'history. Anyone with the file can use them.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(gateway.calls, ['probe']);
  });

  testWidgets('create then save to phone', (tester) async {
    await open(tester, app(await lock(enabled: true)));
    await tester.tap(find.byKey(const ValueKey('backup-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-create-confirm')));
    await tester.pumpAndSettle();
    expect(gateway.calls, contains('create:default'));
    expect(find.text('Backup ready'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('backup-save')));
    await tester.pumpAndSettle();
    expect(shared, hasLength(1));
    expect(
      dir.listSync().whereType<File>().where(
        (f) => f.path.contains('hermes-backup'),
      ),
      isEmpty,
    );
  });

  testWidgets('restore: summary, default-on safety backup, then the result', (
    tester,
  ) async {
    final file = await zip();
    await open(tester, app(await lock(enabled: true), pick: () async => file));
    await pickZipAndWait(tester);
    expect(find.text('Will be replaced'), findsOneWidget);
    expect(find.text('Settings (config.yaml)'), findsOneWidget);
    expect(find.text('Conversations (state.db)'), findsOneWidget);
    expect(find.text('Kept'), findsOneWidget);
    expect(find.text('gateway.pid'), findsOneWidget);
    expect(
      find.text(
        'Files in default will be replaced. Conversations recorded after '
        'this backup was made will be lost.',
      ),
      findsOneWidget,
    );
    final checkbox = tester.widget<Switch>(
      find.byKey(const ValueKey('backup-safety-switch')),
    );
    expect(checkbox.value, isTrue);
    expect(gateway.calls.where((c) => c.startsWith('upload')), isEmpty);

    await tester.tap(find.byKey(const ValueKey('backup-restore-confirm')));
    await tester.pumpAndSettle();
    expect(gateway.calls.where((c) => !c.startsWith('status')).toList(), [
      'probe',
      'create:default',
      'upload:default:force=true',
    ]);
    expect(refreshes, 1);
    expect(find.text('Restore finished'), findsOneWidget);
  });

  testWidgets('a failed import shows the server lines and the recovery hint', (
    tester,
  ) async {
    gateway.importExit = 1;
    gateway.importLines = ['incomplete restore: 2 files failed'];
    final file = await zip();
    await open(tester, app(await lock(enabled: true), pick: () async => file));
    await pickZipAndWait(tester);
    await tester.tap(find.byKey(const ValueKey('backup-restore-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('incomplete restore: 2 files failed'), findsOneWidget);
    expect(
      find.text(
        'Your safety backup is still on the server. You can save it to your phone.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a file that is not a backup is refused without a request', (
    tester,
  ) async {
    final bad = File('${dir.path}/bad.zip')..writeAsStringSync('nope');
    await open(tester, app(await lock(enabled: true), pick: () async => bad));
    await pickZipAndWait(tester);
    expect(find.text('That file is not a valid backup'), findsOneWidget);
    expect(gateway.calls, ['probe']);
    expect(bad.existsSync(), isFalse, reason: 'the picked copy is deleted');
  });

  testWidgets('backgrounding the app stops following the server', (
    tester,
  ) async {
    gateway.runningReads = 50;
    await open(tester, app(await lock(enabled: true)));
    await tester.tap(find.byKey(const ValueKey('backup-create')));
    await tester.pumpAndSettle();
    final confirm = tester.tap(
      find.byKey(const ValueKey('backup-create-confirm')),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await confirm;
    await tester.pumpAndSettle();
    final reads = gateway.calls.where((c) => c == 'status:backup').length;
    await tester.pump(const Duration(seconds: 5));
    expect(gateway.calls.where((c) => c == 'status:backup').length, reads);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('FLAG_SECURE is on while visible and restored on leave', (
    tester,
  ) async {
    await open(tester, app(await lock(enabled: true)));
    expect(secure.last, isTrue);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(secure.last, isFalse);
  });

  testWidgets('FLAG_SECURE also covers the App Lock notice', (tester) async {
    await open(tester, app(await lock(enabled: false)));
    expect(secure.last, isTrue);
  });

  testWidgets('nothing is verified or shown before FLAG_SECURE is applied', (
    tester,
  ) async {
    final applied = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hermes/security'), (
          call,
        ) async {
          if (call.method == 'setSecureScreen') {
            await applied.future;
            secure.add(call.arguments as bool);
          }
          return null;
        });
    var verified = 0;
    await tester.pumpWidget(
      app(
        await lock(enabled: true),
        verify: (_, _, _) async {
          verified++;
          return true;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(verified, 0);
    expect(gateway.calls, isEmpty);
    expect(find.byKey(const ValueKey('backup-create')), findsNothing);
    applied.complete();
    await tester.pumpAndSettle();
    expect(verified, 1);
    expect(find.byKey(const ValueKey('backup-create')), findsOneWidget);
  });
}
