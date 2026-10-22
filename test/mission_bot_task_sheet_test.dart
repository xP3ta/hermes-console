import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/mission_bot_task_sheet.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host({
  required MissionBotTaskSubmit onSubmit,
  Locale locale = const Locale('es'),
  double textScale = 1,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: ThemeData.dark(useMaterial3: true),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: MissionBotTaskSheet(
      displayName: 'Infra Bot',
      profileName: 'infra',
      onSubmit: onSubmit,
    ),
  ),
);

Future<void> _scrollToSubmit(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('mission-bot-task-submit')),
    220,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('mission-bot-task-sheet')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
}

void main() {
  testWidgets('keeps the target bot fixed and asks only for task details', (
    tester,
  ) async {
    await tester.pumpWidget(_host(onSubmit: (_) async {}));

    expect(find.text('Encargar tarea'), findsNWidgets(2));
    expect(find.text('Infra Bot'), findsOneWidget);
    expect(find.text('@infra'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mission-avatar-geometry-infra')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
    expect(find.text('Qué'), findsOneWidget);
    expect(find.text('Para qué (opcional)'), findsOneWidget);
    expect(find.text('Baja'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('Alta'), findsOneWidget);
    expect(find.textContaining('Kanban'), findsNothing);
    expect(find.textContaining('plantilla'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing);
  });

  testWidgets('requires Qué and submits a trimmed public DTO', (tester) async {
    MissionBotTaskDraft? submitted;
    var calls = 0;
    await tester.pumpWidget(
      _host(
        onSubmit: (draft) async {
          calls++;
          submitted = draft;
        },
      ),
    );

    await _scrollToSubmit(tester);
    await tester.tap(find.byKey(const ValueKey('mission-bot-task-submit')));
    await tester.pump();
    expect(find.text('Describe la tarea.'), findsOneWidget);
    expect(calls, 0);

    await tester.enterText(
      find.byKey(const ValueKey('mission-bot-task-title')),
      '  Revisar copias  ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mission-bot-task-body')),
      '  Confirmar la restauración  ',
    );
    await tester.tap(
      find.byKey(const ValueKey('mission-bot-task-priority-high')),
    );
    await _scrollToSubmit(tester);
    await tester.tap(find.byKey(const ValueKey('mission-bot-task-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(calls, 1);
    expect(submitted?.title, 'Revisar copias');
    expect(submitted?.body, 'Confirmar la restauración');
    expect(submitted?.priority, MissionBotTaskPriority.high);
  });

  testWidgets('blocks a second submit while the callback is pending', (
    tester,
  ) async {
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      _host(
        onSubmit: (_) {
          calls++;
          return pending.future;
        },
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('mission-bot-task-title')),
      'Revisar copias',
    );
    await _scrollToSubmit(tester);

    final submit = find.byKey(const ValueKey('mission-bot-task-submit'));
    await tester.tap(submit);
    await tester.pump();
    expect(calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(submit);
    await tester.pump();
    expect(calls, 1);

    pending.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('shows a generic in-place error and allows retry', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _host(
        onSubmit: (_) async {
          calls++;
          throw StateError('backend-secret-detail');
        },
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('mission-bot-task-title')),
      'Revisar copias',
    );
    await _scrollToSubmit(tester);
    await tester.tap(find.byKey(const ValueKey('mission-bot-task-submit')));
    await tester.pumpAndSettle();

    expect(
      find.text('No se pudo encargar la tarea. Inténtalo de nuevo.'),
      findsOneWidget,
    );
    expect(find.textContaining('backend-secret-detail'), findsNothing);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('mission-bot-task-submit')),
    );
    expect(button.onPressed, isNotNull);
    expect(calls, 1);
  });

  testWidgets('fits 320 dp at 200 percent text without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(onSubmit: (_) async {}, textScale: 2));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mission-bot-task-fixed-bot')),
      findsOneWidget,
    );
    await _scrollToSubmit(tester);
    expect(
      find.byKey(const ValueKey('mission-bot-task-submit')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('publishes the same simple labels in English', (tester) async {
    await tester.pumpWidget(
      _host(onSubmit: (_) async {}, locale: const Locale('en')),
    );

    expect(find.text('Assign task'), findsNWidgets(2));
    expect(find.text('What'), findsOneWidget);
    expect(find.text('Why (optional)'), findsOneWidget);
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
  });

  testWidgets('publishes the same simple labels in Brazilian Portuguese', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(onSubmit: (_) async {}, locale: const Locale('pt')),
    );

    expect(find.text('Atribuir tarefa'), findsNWidgets(2));
    expect(find.text('O quê'), findsOneWidget);
    expect(find.text('Por quê (opcional)'), findsOneWidget);
    expect(find.text('Baixa'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('Alta'), findsOneWidget);
  });
}
