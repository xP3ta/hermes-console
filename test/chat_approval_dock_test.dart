import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/floating.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/utils/approval_display.dart';
import 'package:hermes_android/core/services/approval_response.dart';
import 'package:hermes_android/core/widgets/chat_approval_dock.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const request = <String, dynamic>{
  'request_id': 'dock-1',
  'tool': 'terminal',
  'description': 'Run shell command',
  'command': 'echo safe',
  'choices': ['once', 'session', 'always', 'deny'],
};
Widget host({
  Map<String, dynamic> approval = request,
  Future<void> Function(String)? answer,
  Future<ApprovalSendResult> Function(ApprovalSubmission)? submit,
  bool allowAlways = true,
  String locale = 'es',
  DateTime Function()? clock,
}) => MaterialApp(
  locale: Locale(locale),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromMode(AppThemeMode.dark),
  home: Scaffold(
    body: SingleChildScrollView(
      child: ChatApprovalDock(
        approval: approval,
        allowAlways: allowAlways,
        onChoice:
            submit ??
            (submission) async {
              await answer!(submission.choice);
              return ApprovalSendResult.accepted;
            },
        clock: clock,
      ),
    ),
  ),
);

void main() {
  testWidgets('only offered scopes, opaque surface, one live mm:ss clock', (
    tester,
  ) async {
    var now = DateTime(2026);
    await tester.pumpWidget(
      host(
        approval: {
          ...request,
          'choices': ['once', 'deny'],
        },
        answer: (_) async {},
        clock: () => now,
      ),
    );
    expect(find.text('Permitir esta vez'), findsOneWidget);
    expect(find.text('Denegar'), findsOneWidget);
    expect(find.text('En esta sesión'), findsNothing);
    expect(find.text('Siempre este tipo de comando'), findsNothing);
    expect(
      tester
          .widget<HermesFloatingSurface>(find.byType(HermesFloatingSurface))
          .modal,
      isTrue,
    );
    expect(find.text('00:00'), findsOneWidget);
    now = now.add(const Duration(seconds: 65));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('01:05'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'missing/empty choices and capability flags never invent actions',
    (tester) async {
      for (final approval in [
        {...request}..remove('choices'),
        {...request, 'choices': <String>[]},
        {
          ...request,
          'choices': ['once', 'deny'],
          'allow_session': true,
          'allow_permanent': true,
        },
        {...request, 'allow_session': false, 'allow_permanent': false},
      ]) {
        await tester.pumpWidget(host(approval: approval, answer: (_) async {}));
        expect(find.byKey(const ValueKey('approval-session')), findsNothing);
        expect(find.byKey(const ValueKey('approval-always')), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('double tap sends once, shows sending, failure can retry', (
    tester,
  ) async {
    var count = 0;
    final gate = Completer<void>();
    await tester.pumpWidget(
      host(
        answer: (_) {
          count++;
          return count == 1 ? gate.future : Future.value();
        },
      ),
    );
    await tester.tap(find.text('Permitir esta vez'));
    await tester.tap(find.text('Permitir esta vez'));
    await tester.pump();
    expect(count, 1);
    expect(find.byKey(const ValueKey('approval-responding')), findsOneWidget);
    gate.completeError(StateError('SECRET_SERVER_ERROR'));
    await tester.pump();
    expect(find.textContaining('SECRET_SERVER_ERROR'), findsNothing);
    expect(find.byKey(const ValueKey('approval-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('approval-retry')));
    await tester.pump();
    expect(count, 2);
    await tester.tap(find.text('Permitir esta vez'));
    expect(count, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'always requires confirmation; cancel and remote removal send nothing',
    (tester) async {
      final choices = <String>[];
      Future<void> answer(String choice) async {
        choices.add(choice);
      }

      await tester.pumpWidget(host(answer: answer));
      await tester.tap(find.text('Siempre este tipo de comando'));
      await tester.pumpAndSettle();
      expect(choices, isEmpty);
      expect(
        find.text('Permitir siempre este tipo de comando en este perfil'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('approval-always-cancel')));
      await tester.pumpAndSettle();
      expect(choices, isEmpty);
      await tester.tap(find.text('Siempre este tipo de comando'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('approval-always-confirm')));
      await tester.pumpAndSettle();
      expect(choices, ['always']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('confirming after remote removal cannot submit the old request', (
    tester,
  ) async {
    StateSetter? change;
    var visible = true;
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.fromMode(AppThemeMode.dark),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) {
              change = update;
              return visible
                  ? ChatApprovalDock(
                      approval: request,
                      onChoice: (_) async {
                        calls++;
                        return ApprovalSendResult.accepted;
                      },
                    )
                  : const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Siempre este tipo de comando'));
    await tester.pumpAndSettle();
    change!(() => visible = false);
    await tester.pump();
    expect(find.byType(ChatApprovalDock), findsNothing);
    await tester.tap(find.byKey(const ValueKey('approval-always-confirm')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'redacted preview, semantics, full selectable sheet and clipboard',
    (tester) async {
      final semantics = tester.ensureSemantics();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const command =
          'curl https://user:PASS@host.test?token=QUERY -H "Authorization: Basic HEADER" --token FLAG github_pat_SYNTHETIC123 API_KEY="ASSIGN" sk-abcdefghijkl\necho safe';
      await tester.pumpWidget(
        host(approval: {...request, 'command': command}, answer: (_) async {}),
      );
      final ctx = tester.element(find.byType(ChatApprovalDock));
      final safe = approvalDisplayText(command, Strings.of(ctx));
      for (final secret in [
        'PASS',
        'QUERY',
        'HEADER',
        'ASSIGN',
        'FLAG',
        'github_pat_SYNTHETIC123',
        'sk-abcdefghijkl',
      ]) {
        expect(safe, isNot(contains(secret)));
      }
      expect(
        find.bySemanticsLabel(RegExp('Permiso para ejecutar · terminal')),
        findsOneWidget,
      );
      final preview = tester.widget<Text>(
        find.byKey(const ValueKey('approval-command-preview')),
      );
      expect(preview.maxLines, 1);
      expect(preview.overflow, TextOverflow.ellipsis);
      final credentials = RegExp(
        'PASS|QUERY|HEADER|ASSIGN|FLAG|github_pat_SYNTHETIC123|sk-abcdefghijkl',
      );
      expect(credentials.hasMatch(preview.data!), isFalse);
      final spoken = tester
          .getSemantics(
            find.bySemanticsLabel(RegExp('Permiso para ejecutar · terminal')),
          )
          .label;
      expect(credentials.hasMatch(spoken), isFalse);
      await tester.tap(find.text('Ver completo'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('approval-full-sheet')), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        safe,
      );
      await tester.tap(find.byKey(const ValueKey('approval-copy-command')));
      await tester.pump();
      expect(copied, safe);
      expect(copied, contains('echo safe'));
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('320dp at 2x with reduced motion keeps every action >=48dp', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1200);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(host(answer: (_) async {}));
    for (final key in ['once', 'deny', 'session', 'always', 'view-full']) {
      final action = find.byKey(ValueKey('approval-$key'));
      final rect = tester.getRect(action);
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(rect.height, greaterThanOrEqualTo(48));
      expect(rect.right, lessThanOrEqualTo(320));
    }
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Ver completo'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'absolute execution targets remain visible in preview, full sheet, copy and scope confirmation',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      for (final command in [
        'rm -rf /home/ana/proyectos',
        'chmod -R 777 /etc',
        r'rmdir C:\Users\Name\proyectos',
      ]) {
        await tester.pumpWidget(
          host(
            approval: {
              ...request,
              'command': command,
              'pattern_key':
                  'danger-class AWS_SECRET_ACCESS_KEY=PATTERN_CREDENTIAL',
              'description': 'Delete class',
            },
            answer: (_) async {},
          ),
        );
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('approval-command-preview')),
              )
              .data,
          command,
        );
        await tester.tap(find.byKey(const ValueKey('approval-view-full')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          command,
        );
        await tester.tap(find.byKey(const ValueKey('approval-copy-command')));
        await tester.pump();
        expect(copied, command);
        Navigator.of(tester.element(find.byType(SelectableText))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('approval-always')));
        await tester.pumpAndSettle();
        final scope = find.byKey(const ValueKey('approval-always-dialog'));
        expect(
          find.descendant(of: scope, matching: find.textContaining(command)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: scope,
            matching: find.textContaining('danger-class'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: scope,
            matching: find.textContaining('Delete class'),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('PATTERN_CREDENTIAL'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('approval-always-cancel')));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'ignored responses re-enable the decision instead of leaving it sending',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          submit: (submission) async {
            calls++;
            expect(submission.target.requestId, 'dock-1');
            expect(submission.target.commandHash, hasLength(64));
            return ApprovalSendResult.ignored;
          },
        ),
      );
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const ValueKey('approval-once')));
        await tester.pump();
        expect(find.byKey(const ValueKey('approval-responding')), findsNothing);
      }
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('an explicit error result enables a safe retry', (tester) async {
    await tester.pumpWidget(
      host(submit: (_) async => ApprovalSendResult.error),
    );
    await tester.tap(find.byKey(const ValueKey('approval-once')));
    await tester.pump();
    expect(find.byKey(const ValueKey('approval-responding')), findsNothing);
    expect(find.byKey(const ValueKey('approval-retry')), findsOneWidget);
    expect(find.textContaining('No se pudo enviar'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'same-id replacement clears accepted state and ignores an older in-flight completion',
    (tester) async {
      final gate = Completer<ApprovalSendResult>();
      final submissions = <ApprovalSubmission>[];
      Future<ApprovalSendResult> submit(ApprovalSubmission request) {
        submissions.add(request);
        return submissions.length == 1
            ? gate.future
            : Future.value(ApprovalSendResult.accepted);
      }

      await tester.pumpWidget(host(submit: submit));
      await tester.tap(find.byKey(const ValueKey('approval-once')));
      await tester.pump();
      final replacement = {...request, 'command': 'rm -rf /home/other'};
      await tester.pumpWidget(host(approval: replacement, submit: submit));
      gate.complete(ApprovalSendResult.accepted);
      await tester.pump();
      expect(find.byKey(const ValueKey('approval-responding')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('approval-once')));
      await tester.pump();
      expect(submissions.length, 2);
      expect(
        submissions.first.target.commandHash,
        isNot(submissions.last.target.commandHash),
      );
      expect(find.byKey(const ValueKey('approval-responding')), findsOneWidget);
      await tester.pumpWidget(host(approval: {...replacement}, submit: submit));
      expect(find.byKey(const ValueKey('approval-responding')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('approval-once')));
      await tester.pump();
      expect(submissions.length, 3);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'always obeys local policy, including a policy change during confirmation',
    (tester) async {
      var sends = 0;
      Future<void> answer(String _) async {
        sends++;
      }

      await tester.pumpWidget(host(allowAlways: false, answer: answer));
      expect(find.byKey(const ValueKey('approval-always')), findsNothing);
      await tester.pumpWidget(host(answer: answer));
      await tester.tap(find.byKey(const ValueKey('approval-always')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(allowAlways: false, answer: answer));
      await tester.tap(find.byKey(const ValueKey('approval-always-confirm')));
      await tester.pumpAndSettle();
      expect(sends, 0);
      expect(find.byKey(const ValueKey('approval-always')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'multiline commands disclose the boundary even when the first line is ellipsized',
    (tester) async {
      final command = 'echo ${'long ' * 200}\nrm -rf ~';
      await tester.pumpWidget(
        host(approval: {...request, 'command': command}, answer: (_) async {}),
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('approval-command-preview')),
            )
            .data,
        contains(' ↵ rm -rf ~'),
      );
      expect(find.text('+1 ↵').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('approval-view-full')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('approval-view-full')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        command,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  const classLabels = {
    'es': (
      'Siempre este tipo de comando',
      'Permitir siempre este tipo de comando en este perfil',
    ),
    'en': (
      'Always allow this command type',
      'Always allow this type of command in this profile',
    ),
    'pt': (
      'Sempre este tipo de comando',
      'Permitir sempre este tipo de comando neste perfil',
    ),
    'fr': (
      'Toujours ce type de commande',
      'Toujours autoriser ce type de commande dans ce profil',
    ),
    'de': (
      'Diese Art von Befehl immer erlauben',
      'Diese Art von Befehl in diesem Profil immer erlauben',
    ),
    'it': (
      'Sempre questo tipo di comando',
      'Consenti sempre questo tipo di comando in questo profilo',
    ),
    'ja': ('この種類のコマンドを常に許可', 'このプロファイルでこの種類のコマンドを常に許可'),
    'ko': ('이 유형의 명령 항상 허용', '이 프로필에서 이 유형의 명령을 항상 허용'),
    'zh': ('始终允许此类命令', '在此配置中始终允许此类命令'),
  };
  for (final entry in classLabels.entries) {
    testWidgets('persistent scope names a command class in ${entry.key}', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          locale: entry.key,
          approval: {...request, 'pattern_key': 'scope-class'},
          answer: (_) async {},
        ),
      );
      expect(find.text(entry.value.$1), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('approval-always')));
      await tester.pumpAndSettle();
      expect(find.text(entry.value.$2), findsOneWidget);
      expect(find.textContaining('scope-class'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
