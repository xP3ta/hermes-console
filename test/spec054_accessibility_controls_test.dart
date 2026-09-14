import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/screens/runs_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/run_registry.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/subagent_activity_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child, {TextScaler textScaler = TextScaler.noScaling}) {
  return MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.hermesRedDark,
    home: MediaQuery(
      data: MediaQueryData(size: const Size(390, 844), textScaler: textScaler),
      child: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('approval respeta choices y scopes prohibidos por Desktop', (
    tester,
  ) async {
    final choices = <String>[];
    await tester.pumpWidget(
      _host(
        ChatApprovalCard(
          approval: const {
            'request_id': 'approval-limited',
            'command': 'echo seguro',
            'choices': ['once', 'deny'],
            'allow_session': false,
            'allow_permanent': false,
          },
          busy: false,
          onChoice: choices.add,
        ),
      ),
    );

    expect(find.text('Permitir'), findsOneWidget);
    expect(find.text('Denegar'), findsOneWidget);
    expect(find.text('Esta sesión'), findsNothing);
    expect(find.text('Siempre'), findsNothing);
    await tester.tap(find.text('Permitir'));
    await tester.tap(find.text('Denegar'));
    expect(choices, ['once', 'deny']);
  });

  testWidgets('choices exactas no inventan permitir una vez', (tester) async {
    await tester.pumpWidget(
      _host(
        ChatApprovalCard(
          approval: const {
            'request_id': 'approval-deny-only',
            'choices': ['deny'],
          },
          busy: false,
          onChoice: (_) {},
        ),
      ),
    );

    expect(find.text('Permitir'), findsNothing);
    expect(find.text('Denegar'), findsOneWidget);
    expect(find.text('Esta sesión'), findsNothing);
    expect(find.text('Siempre'), findsNothing);
  });

  testWidgets('scope chips conservan callback, 48 dp y TalkBack con escala 2', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final choices = <String>[];

    await tester.pumpWidget(
      _host(
        ChatApprovalCard(
          approval: const {
            'command': 'echo seguro',
            'description': 'Comando de prueba',
          },
          busy: false,
          onChoice: choices.add,
        ),
        textScaler: const TextScaler.linear(2),
      ),
    );

    for (final label in ['Esta sesión', 'Siempre']) {
      final button = find.widgetWithText(TextButton, label);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        matchesSemantics(
          label: label,
          hint: 'Recordar',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
    }

    await tester.tap(find.text('Esta sesión'));
    await tester.tap(find.text('Siempre'));
    expect(choices, ['session', 'always']);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('copiar trace es localizable, enfocable y mide 48 dp', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _host(
        ThinkingTraceCard(
          events: [
            ChatTraceEvent(
              id: 'tool-1',
              label: 'Terminal',
              status: 'running',
              preview: 'pwd',
            ),
          ],
          active: true,
        ),
        textScaler: const TextScaler.linear(2),
      ),
    );

    await tester.tap(find.text('Terminal'));
    await tester.pump(const Duration(milliseconds: 220));

    final copy = find.byKey(const ValueKey('thinking-trace-copy'));
    expect(copy, findsOneWidget);
    expect(tester.getSize(copy).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(copy).width, greaterThanOrEqualTo(48));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Copiar trace')),
      matchesSemantics(
        label: 'Copiar trace',
        isButton: true,
        hasTapAction: true,
      ),
    );
    final button = tester.widget<TextButton>(copy);
    expect(
      button.style?.overlayColor?.resolve({WidgetState.focused}),
      isNotNull,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('detener subagente oculta contexto y conserva callback', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final scope = SubagentActivityScope(
      connectionId: 'connection',
      parentSessionId: 'parent',
      runtimeSessionId: 'runtime',
      turnEpoch: 1,
    );
    final activity = SubagentActivity(
      key: SubagentActivityKey(
        scope: scope,
        identityKind: SubagentIdentityKind.subagent,
        stableId: 'child',
      ),
      source: SubagentActivitySource.native,
      phase: SubagentActivityPhase.running,
      subagentId: 'child',
      childSessionId: 'child-session',
      details: const SubagentActivityDetails(goalPreview: 'Revisar proyecto'),
    );
    SubagentActivity? interrupted;

    await tester.pumpWidget(
      _host(
        SubagentActivityCard(
          activities: [activity],
          canInterrupt: (_) => true,
          onInterrupt: (value) => interrupted = value,
        ),
        textScaler: const TextScaler.linear(2),
      ),
    );

    await tester.tap(find.text('ver detalles'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('subagent-row-child')));
    await tester.pumpAndSettle();
    final stop = find.byKey(const ValueKey('subagent-stop-child'));
    expect(tester.getSize(stop).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(stop).width, greaterThanOrEqualTo(48));
    expect(find.text('Revisar proyecto'), findsNothing);
    expect(
      tester.getSemantics(stop),
      matchesSemantics(
        label: 'Detener',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasFocusAction: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(stop);
    expect(interrupted, same(activity));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('copiar respuesta de Runs conserva el texto crudo y 48 dp', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    Map<Object?, Object?>? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map).cast<Object?, Object?>();
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

    final connection = SavedConnection(
      id: 'runs-copy-test',
      label: 'Test',
      host: '127.0.0.1',
      port: 8642,
      apiKey: 'test-key',
    );
    const rawReply = '  Respuesta\nsin recortar  ';
    final client = ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({'status': 'completed', 'output': rawReply}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            textScaler: TextScaler.linear(2),
          ),
          child: RunDetailScreen(
            connection: connection,
            record: const RunRecord(
              runId: 'run-copy',
              prompt: 'Prueba',
              createdAt: 1,
              lastStatus: 'completed',
              output: rawReply,
            ),
            client: client,
          ),
        ),
      ),
    );
    await tester.pump();

    final copy = find.byKey(const ValueKey('runs-copy-reply'));
    await tester.ensureVisible(copy);
    final semantics = tester.ensureSemantics();
    expect(tester.getSize(copy), const Size(48, 48));
    expect(
      tester.getSemantics(copy),
      matchesSemantics(
        label: 'Copiar',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    expect(tester.widget<IconButton>(copy).focusColor, isNotNull);

    await tester.tap(copy);
    await tester.pump();
    expect(clipboard?['text'], rawReply);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
