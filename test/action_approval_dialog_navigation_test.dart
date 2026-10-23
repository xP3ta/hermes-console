import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/command_risk.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/widgets/action_approval.dart';
import 'package:hermes_android/core/widgets/adaptive_list_detail.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _openDetail = ValueKey('approval-open-detail');
const _requestApproval = ValueKey('approval-request');
const _draft = ValueKey('approval-draft');

class _ApprovalPage extends StatefulWidget {
  const _ApprovalPage({required this.onResult});

  final ValueChanged<bool> onResult;

  @override
  State<_ApprovalPage> createState() => _ApprovalPageState();
}

class _ApprovalPageState extends State<_ApprovalPage> {
  final draft = TextEditingController(text: 'Unsent draft');

  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextField(key: _draft, controller: draft),
        TextButton(
          key: _requestApproval,
          onPressed: () async {
            final result = await confirmMutatingAction(
              context,
              instanceId: 'approval-fixture',
              readOnlyInstance: false,
              risk: CommandRisk.medium,
              title: 'Confirm fixture action',
            );
            widget.onResult(result);
          },
          child: const Text('Request approval'),
        ),
      ],
    ),
  );
}

Future<void> _pumpApp(WidgetTester tester, List<bool> results) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final ssh = SshManager(secure, manager);
  final notifications = NotificationService(prefs);
  final activeChats = ActiveChatService(
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  addTearDown(activeChats.dispose);
  final policy = ApprovalPolicyService(prefs);
  expect(policy.effectiveMode(null), ApprovalMode.interactive);
  await tester.pumpWidget(
    HermesApp(
      connManager: manager,
      appLock: AppLockService(prefs),
      approvalPolicy: policy,
      fontSize: FontSizeService(prefs),
      sshManager: ssh,
      sftpTransfers: SftpTransferService(ssh, notifications),
      sshSessions: SshSessionService(ssh),
      notifications: notifications,
      activeChats: activeChats,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
  await tester.pump(const Duration(milliseconds: 500));
  final root = Navigator.of(tester.element(find.byType(Navigator).first));
  root.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: AdaptiveListDetail(
          placeholder: const SizedBox.shrink(),
          list: Builder(
            builder: (listContext) => Center(
              child: TextButton(
                key: _openDetail,
                onPressed: () => pushInDetailPane<void>(
                  listContext,
                  MaterialPageRoute<void>(
                    builder: (_) => _ApprovalPage(onResult: results.add),
                  ),
                ),
                child: const Text('Open detail'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'onboarding_done': true,
      'app_locale': 'es',
    });
    // Same platform fixture as soul_screen_banner_test: no real services.
    final secure = <String, String>{};
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?) ?? {};
        switch (call.method) {
          case 'read':
            return secure[args['key']];
          case 'write':
            secure[args['key'] as String] = args['value'] as String;
            return null;
          case 'delete':
            secure.remove(args['key']);
            return null;
          case 'readAll':
            return Map<String, String>.from(secure);
          case 'containsKey':
            return secure.containsKey(args['key']);
        }
        return null;
      },
    );
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/background',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
  });

  for (final width in [390.0, 700.0]) {
    for (final allow in [true, false]) {
      testWidgets('$width dp: approval $allow closes only the root dialog', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.reset);
        final results = <bool>[];
        await _pumpApp(tester, results);
        final pane = tester.state<AdaptiveListDetailState>(
          find.byType(AdaptiveListDetail),
        );
        await tester.tap(find.byKey(_openDetail));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final pageFinder = find.byType(_ApprovalPage);
        expect(pageFinder, findsOneWidget);
        final page = tester.state<_ApprovalPageState>(pageFinder);
        final callerContext = tester.element(find.byKey(_requestApproval));
        final root = Navigator.of(callerContext, rootNavigator: true);
        final nearest = Navigator.of(callerContext);
        expect(identical(nearest, root), width < 600);
        expect(pane.hasDetail, width >= 600);
        final strings = Strings.of(callerContext);

        await tester.tap(find.byKey(_requestApproval));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);
        expect(Navigator.of(tester.element(dialog)), same(root));
        expect(results, isEmpty);
        await tester.tap(
          find.descendant(
            of: dialog,
            matching: find.text(
              allow ? strings.approvalAllow : strings.commonCancel,
            ),
          ),
        );
        // Bounded pumps: a broken pop must fail, not await the unresolved dialog.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(results, [allow]);
        expect(find.byType(AlertDialog), findsNothing);
        expect(pageFinder, findsOneWidget);
        expect(tester.state<_ApprovalPageState>(pageFinder), same(page));
        expect(page.mounted, isTrue);
        expect(page.draft.text, 'Unsent draft');
        expect(find.byKey(_draft), findsOneWidget);
        expect(find.byKey(_openDetail), findsNothing);
        expect(pane.hasDetail, width >= 600);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }
}
