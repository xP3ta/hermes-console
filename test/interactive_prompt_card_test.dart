import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/services/interactive_prompt_reducer.dart';
import 'package:hermes_android/core/widgets/accent_card.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';
import 'package:hermes_android/core/widgets/interactive_prompt_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

InteractivePromptEntry _entry(InteractivePromptRequest request) =>
    InteractivePromptEntry(
      key: request.key,
      request: request,
      status: InteractivePromptStatus.pending,
    );

Widget _app(
  InteractivePromptEntry entry,
  void Function(String) onSubmit, {
  bool busy = false,
  VoidCallback? onCancel,
  TextScaler textScaler = TextScaler.noScaling,
  void Function(Map<String, String>)? onSubmitBatch,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(size: const Size(390, 844), textScaler: textScaler),
      child: InteractivePromptCard(
        entry: entry,
        busy: busy,
        onSubmit: onSubmit,
        onSubmitBatch: onSubmitBatch,
        onCancel: onCancel ?? () {},
      ),
    ),
  ),
);

void main() {
  testWidgets('secret se oculta y se limpia antes del callback', (
    tester,
  ) async {
    final key = InteractivePromptKey(
      runtimeSessionId: 'runtime-a',
      requestId: 'secret-a',
    );
    String? submitted;
    await tester.pumpWidget(
      _app(
        _entry(
          SecretPromptRequest(
            key: key,
            envVar: 'DEPLOY_TOKEN',
            prompt: 'Introduce el token',
          ),
        ),
        (value) => submitted = value,
      ),
    );

    expect(find.byType(HermesInlineActivity), findsOneWidget);
    expect(find.byType(AccentCard), findsNothing);
    const value = 'widget-secret-value';
    await tester.enterText(find.byType(TextField), value);
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    await tester.tap(find.text('Enviar'));
    await tester.pump();

    expect(submitted, value);
    expect(find.text(value), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    submitted = null;
  });

  testWidgets('cancelar conserva el callback y busy bloquea toda respuesta', (
    tester,
  ) async {
    final key = InteractivePromptKey(
      runtimeSessionId: 'runtime-a',
      requestId: 'busy-a',
    );
    var cancelled = false;
    String? submitted;
    await tester.pumpWidget(
      _app(
        _entry(
          ClarifyPromptRequest(
            key: key,
            question: '¿Qué rama?',
            choices: const ['main'],
          ),
        ),
        (value) => submitted = value,
        busy: true,
        onCancel: () => cancelled = true,
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Detener tarea'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Enviar'))
          .onPressed,
      isNull,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.text('main'));
    await tester.tap(find.text('Detener tarea'));
    await tester.tap(find.text('Enviar'));
    await tester.pump();

    expect(submitted, isNull);
    expect(cancelled, isFalse);
  });

  testWidgets('clarify permite responder con una opción sin escribir', (
    tester,
  ) async {
    final key = InteractivePromptKey(
      runtimeSessionId: 'runtime-a',
      requestId: 'clarify-a',
    );
    String? submitted;
    await tester.pumpWidget(
      _app(
        _entry(
          ClarifyPromptRequest(
            key: key,
            question: '¿Qué rama?',
            choices: const ['main', 'qa'],
          ),
        ),
        (value) => submitted = value,
      ),
    );

    await tester.tap(find.text('qa'));
    await tester.pump();
    expect(submitted, 'qa');
  });

  testWidgets('terminal read explica la política y reintenta vacío', (
    tester,
  ) async {
    final key = InteractivePromptKey(
      runtimeSessionId: 'runtime-a',
      requestId: 'terminal-a',
    );
    String? submitted;
    await tester.pumpWidget(
      _app(
        _entry(TerminalReadPromptRequest(key: key)),
        (value) => submitted = value,
      ),
    );

    expect(find.textContaining('no posee una terminal'), findsOneWidget);
    await tester.tap(find.text('Reintentar respuesta segura'));
    await tester.pump();
    expect(submitted, isEmpty);
  });

  testWidgets('acciones mantienen 48 dp y escala 2 no desborda', (
    tester,
  ) async {
    final key = InteractivePromptKey(
      runtimeSessionId: 'runtime-a',
      requestId: 'scale-a',
    );
    await tester.pumpWidget(
      _app(
        _entry(TerminalReadPromptRequest(key: key)),
        (_) {},
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.widgetWithText(TextButton, 'Detener tarea')).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester
          .getSize(
            find.widgetWithText(FilledButton, 'Reintentar respuesta segura'),
          )
          .height,
      greaterThanOrEqualTo(48),
    );
  });

  group('batch clarify', () {
    testWidgets('free-text batch answer preserves surrounding spaces', (
      tester,
    ) async {
      final key = InteractivePromptKey(
        runtimeSessionId: 'runtime-a',
        requestId: 'batch-literal-text',
      );
      Map<String, String>? submitted;
      await tester.pumpWidget(
        _app(
          _entry(
            ClarifyPromptRequest(
              key: key,
              questions: const [
                ClarifyQuestion(qid: 'q0', question: 'Respuesta literal'),
              ],
            ),
          ),
          (_) {},
          onSubmitBatch: (answers) => submitted = answers,
        ),
      );

      await tester.enterText(find.byType(TextField), '  respuesta literal  ');
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Confirmar y continuar'),
      );
      await tester.pump();

      expect(submitted, {'q0': '  respuesta literal  '});
    });

    testWidgets('mounted card reconciles new locked answers monotonically', (
      tester,
    ) async {
      final key = InteractivePromptKey(
        runtimeSessionId: 'runtime-a',
        requestId: 'batch-replay-mounted',
      );
      const questions = [
        ClarifyQuestion(qid: 'q0', question: '¿A?', choices: ['A0', 'A1']),
        ClarifyQuestion(qid: 'q1', question: '¿B?', choices: ['B0']),
      ];
      Map<String, String>? submitted;

      await tester.pumpWidget(
        _app(
          _entry(ClarifyPromptRequest(key: key, questions: questions)),
          (_) {},
          onSubmitBatch: (answers) => submitted = answers,
        ),
      );
      await tester.tap(find.text('A0'));
      await tester.pump();

      await tester.pumpWidget(
        _app(
          _entry(
            ClarifyPromptRequest(
              key: key,
              questions: questions,
              lockedAnswers: const {'q0': 'A1'},
            ),
          ),
          (_) {},
          onSubmitBatch: (answers) => submitted = answers,
        ),
      );
      await tester.tap(find.text('B0'));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Confirmar y continuar'),
      );
      await tester.pump();

      expect(submitted, {'q0': 'A1', 'q1': 'B0'});
    });

    testWidgets(
      'batch at 2x text scale with long text does not overflow and keeps 48 dp targets',
      (tester) async {
        final key = InteractivePromptKey(
          runtimeSessionId: 'runtime-a',
          requestId: 'batch-scale',
        );
        await tester.pumpWidget(
          _app(
            _entry(
              ClarifyPromptRequest(
                key: key,
                questions: const [
                  ClarifyQuestion(
                    qid: 'q0',
                    question:
                        '¿Cuál es tu opción preferida entre todas las '
                        'disponibles para esta operación?',
                    choices: [
                      'Opción A con un texto bastante largo',
                      'Opción B con un texto aún más largo que la anterior',
                    ],
                  ),
                  ClarifyQuestion(
                    qid: 'q1',
                    question: '¿Cuándo se debe ejecutar la tarea programada?',
                    choices: ['Mañana', 'Pasado mañana'],
                  ),
                ],
              ),
            ),
            (_) {},
            textScaler: const TextScaler.linear(2),
          ),
        );

        expect(tester.takeException(), isNull);

        final optionA = find.widgetWithText(
          OutlinedButton,
          'Opción A con un texto bastante largo',
        );
        expect(optionA, findsOneWidget);
        expect(tester.getSize(optionA).height, greaterThanOrEqualTo(48));

        final optionB = find.widgetWithText(
          OutlinedButton,
          'Opción B con un texto aún más largo que la anterior',
        );
        expect(tester.getSize(optionB).height, greaterThanOrEqualTo(48));

        final confirm = find.widgetWithText(
          FilledButton,
          'Confirmar y continuar',
        );
        expect(tester.getSize(confirm).height, greaterThanOrEqualTo(48));
      },
    );

    testWidgets(
      'async batch callback error is caught without unhandled exception',
      (tester) async {
        final key = InteractivePromptKey(
          runtimeSessionId: 'runtime-a',
          requestId: 'batch-async-error',
        );
        Object? captured;
        await tester.pumpWidget(
          _app(
            _entry(
              ClarifyPromptRequest(
                key: key,
                questions: const [
                  ClarifyQuestion(qid: 'q0', question: '¿A?', choices: ['A0']),
                ],
              ),
            ),
            (_) {},
            onSubmitBatch: (answers) async {
              await Future<void>.delayed(Duration.zero);
              captured = answers;
              throw StateError('async boom');
            },
          ),
        );

        await tester.tap(find.text('A0'));
        await tester.pump();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Confirmar y continuar'),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));

        expect(tester.takeException(), isNull);
        expect(captured, {'q0': 'A0'});
      },
    );

    testWidgets('renders all questions in one card and confirms once', (
      tester,
    ) async {
      final key = InteractivePromptKey(
        runtimeSessionId: 'runtime-a',
        requestId: 'batch-a',
      );
      Map<String, String>? submitted;
      await tester.pumpWidget(
        _app(
          _entry(
            ClarifyPromptRequest(
              key: key,
              questions: const [
                ClarifyQuestion(
                  qid: 'q0',
                  question: '¿Bebida?',
                  choices: ['Coffee', 'Tea'],
                ),
                ClarifyQuestion(
                  qid: 'q1',
                  question: '¿Momento?',
                  choices: ['Morning', 'Evening'],
                ),
              ],
            ),
          ),
          (_) {},
          onSubmitBatch: (answers) => submitted = answers,
        ),
      );

      expect(find.text('¿Bebida?'), findsOneWidget);
      expect(find.text('¿Momento?'), findsOneWidget);

      final confirm = find.widgetWithText(
        FilledButton,
        'Confirmar y continuar',
      );
      expect(confirm, findsOneWidget);
      expect(tester.widget<FilledButton>(confirm).enabled, isFalse);

      await tester.tap(find.text('Coffee'));
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).enabled, isFalse);

      await tester.tap(find.text('Morning'));
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).enabled, isTrue);

      await tester.tap(confirm);
      await tester.pump();
      expect(submitted, {'q0': 'Coffee', 'q1': 'Morning'});
    });

    testWidgets('single question inside questions renders as batch', (
      tester,
    ) async {
      final key = InteractivePromptKey(
        runtimeSessionId: 'runtime-a',
        requestId: 'batch-single',
      );
      Map<String, String>? submitted;
      await tester.pumpWidget(
        _app(
          _entry(
            ClarifyPromptRequest(
              key: key,
              questions: const [
                ClarifyQuestion(
                  qid: 'q0',
                  question: '¿Qué opción?',
                  choices: ['A', 'B'],
                ),
              ],
            ),
          ),
          (_) {},
          onSubmitBatch: (answers) => submitted = answers,
        ),
      );

      expect(find.text('¿Qué opción?'), findsOneWidget);
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Confirmar y continuar'),
      );
      await tester.pump();
      expect(submitted, {'q0': 'B'});
    });

    testWidgets('multi-select answer is JSON-encoded list', (tester) async {
      final key = InteractivePromptKey(
        runtimeSessionId: 'runtime-a',
        requestId: 'batch-multi',
      );
      Map<String, String>? submitted;
      await tester.pumpWidget(
        _app(
          _entry(
            ClarifyPromptRequest(
              key: key,
              questions: const [
                ClarifyQuestion(
                  qid: 'q0',
                  question: '¿Cuáles?',
                  choices: ['A', 'B', 'C'],
                  multiSelect: true,
                ),
              ],
            ),
          ),
          (_) {},
          onSubmitBatch: (answers) => submitted = answers,
        ),
      );

      await tester.tap(find.text('A'));
      await tester.pump();
      await tester.tap(find.text('C'));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Confirmar y continuar'),
      );
      await tester.pump();
      expect(submitted?['q0'], jsonEncode(['A', 'C']));
    });

    testWidgets('locked answers are preselected and disabled', (tester) async {
      final key = InteractivePromptKey(
        runtimeSessionId: 'runtime-a',
        requestId: 'batch-locked',
      );
      Map<String, String>? submitted;
      await tester.pumpWidget(
        _app(
          _entry(
            ClarifyPromptRequest(
              key: key,
              questions: const [
                ClarifyQuestion(
                  qid: 'q0',
                  question: '¿Bebida?',
                  choices: ['Coffee', 'Tea'],
                ),
              ],
              lockedAnswers: {'q0': 'Coffee'},
            ),
          ),
          (_) {},
          onSubmitBatch: (answers) => submitted = answers,
        ),
      );

      final confirm = find.widgetWithText(
        FilledButton,
        'Confirmar y continuar',
      );
      expect(tester.widget<FilledButton>(confirm).enabled, isTrue);
      await tester.tap(confirm);
      await tester.pump();
      expect(submitted, {'q0': 'Coffee'});
    });
  });
}
