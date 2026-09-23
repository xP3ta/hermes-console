import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/render/companion_status_indicator.dart';
import 'package:hermes_android/core/companion/render/companion_view.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_status_indicator.dart';
import 'package:hermes_android/core/widgets/hermes_spark_mascot.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/hermes_pill.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _cardHost({
  required ThinkingTraceCard card,
  double width = 800,
  double textScale = 1,
  bool disableAnimations = true,
  ThemeData? theme,
}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  home: MediaQuery(
    data: MediaQueryData(
      disableAnimations: disableAnimations,
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(body: SizedBox(width: width, child: card)),
  ),
);

void main() {
  testWidgets('actividad muestra el estado limpio sin puntos ni LIVE', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: ThinkingTraceCard(
              events: [],
              active: true,
              headline: 'Pensando…',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Pensando'), findsOneWidget);
    expect(find.text('Pensando…'), findsNothing);
    expect(find.text('LIVE'), findsNothing);
    expect(find.byKey(const ValueKey('thinking-shimmer')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-wave-indicator')), findsNothing);
    expect(find.byType(CompanionStatusIndicator), findsNothing);
    expect(find.byType(CompanionView), findsNothing);
    final icon = tester.widget<Icon>(
      find.byKey(const ValueKey('thinking-trace-state-icon')),
    );
    expect(icon.icon, Icons.psychology_alt_rounded);
    expect(icon.size, 17);
    final status = tester.widget<Text>(find.text('Pensando'));
    expect(status.style?.fontSize, 12);
    expect(status.style?.letterSpacing, 0.35);
  });

  testWidgets('estados vivos usan iconos compactos veraces', (tester) async {
    Future<void> expectState({
      required HermesSparkMood mood,
      required IconData icon,
      bool waitingForUser = false,
    }) async {
      await tester.pumpWidget(
        _cardHost(
          card: ThinkingTraceCard(
            events: const [],
            active: true,
            activeMood: mood,
            waitingForUser: waitingForUser,
          ),
        ),
      );
      await tester.pump();
      final stateIcon = tester.widget<Icon>(
        find.byKey(const ValueKey('thinking-trace-state-icon')),
      );
      expect(stateIcon.icon, icon);
      expect(stateIcon.size, 17);
      expect(find.byType(CompanionStatusIndicator), findsNothing);
    }

    await expectState(
      mood: HermesSparkMood.connecting,
      icon: Icons.cloud_queue_rounded,
    );
    await expectState(
      mood: HermesSparkMood.waiting,
      icon: Icons.cloud_queue_rounded,
    );
    await expectState(
      mood: HermesSparkMood.waiting,
      icon: Icons.help_outline_rounded,
      waitingForUser: true,
    );
    await expectState(
      mood: HermesSparkMood.offline,
      icon: Icons.cloud_off_rounded,
    );
  });

  testWidgets('solo pensamiento pulsa y respeta movimiento reducido', (
    tester,
  ) async {
    Finder stateIcon() =>
        find.byKey(const ValueKey('thinking-trace-state-icon'));
    Finder iconScale() => find.ancestor(
      of: stateIcon(),
      matching: find.byType(ScaleTransition),
    );

    await tester.pumpWidget(
      _cardHost(
        disableAnimations: false,
        card: const ThinkingTraceCard(events: [], active: true),
      ),
    );
    await tester.pump();
    expect(iconScale(), findsOneWidget);

    await tester.pumpWidget(
      _cardHost(
        disableAnimations: false,
        card: const ThinkingTraceCard(
          events: [],
          active: true,
          activeMood: HermesSparkMood.connecting,
        ),
      ),
    );
    await tester.pump();
    expect(iconScale(), findsNothing);

    await tester.pumpWidget(
      _cardHost(
        card: const ThinkingTraceCard(events: [], active: true),
      ),
    );
    await tester.pump();
    expect(iconScale(), findsNothing);
  });

  testWidgets('el shimmer sustituye el estado anterior sin duplicar texto', (
    tester,
  ) async {
    Widget host(String headline) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: false),
        child: Scaffold(
          body: ThinkingTraceCard(
            events: const [],
            active: true,
            headline: headline,
          ),
        ),
      ),
    );

    await tester.pumpWidget(host('Conectando…'));
    await tester.pump();
    expect(find.text('Conectando'), findsOneWidget);

    await tester.pumpWidget(host('Respondiendo…'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(const ValueKey('thinking-shimmer')), findsOneWidget);
    expect(find.text('Conectando'), findsNothing);
    expect(find.text('Respondiendo'), findsOneWidget);
  });

  testWidgets('una herramienta activa usa un icono compacto de terminal', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: ThinkingTraceCard(
              events: [
                ChatTraceEvent(
                  id: 'tool-1',
                  label: 'Terminal',
                  status: 'running',
                  preview: 'pwd && ls',
                ),
              ],
              active: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CompanionStatusIndicator), findsNothing);
    expect(find.byType(CompanionView), findsNothing);
    expect(find.text('Running tool'), findsOneWidget);
    expect(find.text('Terminal'), findsNothing);
    expect(find.text('TERMINAL'), findsNothing);
    expect(find.text('Running tools · 0 completed'), findsNothing);
    final icon = tester.widget<Icon>(
      find.byKey(const ValueKey('thinking-trace-state-icon')),
    );
    expect(icon.icon, Icons.terminal_rounded);
    expect(icon.size, 17);
    expect(find.text('pwd && ls'), findsNothing);

    final status = tester.widget<Text>(find.text('Running tool'));
    expect(status.style?.fontSize, 12);
    expect(status.style?.letterSpacing, 0.35);

    await tester.tap(find.text('Running tool'));
    await tester.pump(const Duration(milliseconds: 220));
    // El desplegable comparte las filas del panel en vivo («Terminal» + su
    // estado como icono, ya no «Terminal · running») y conserva la vista previa.
    expect(find.text('Terminal', findRichText: true), findsOneWidget);
    expect(find.text('pwd && ls'), findsOneWidget);
  });

  testWidgets('una skill activa usa el titular localizado', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: ThinkingTraceCard(
            events: [
              ChatTraceEvent(
                id: 'skill-1',
                label: 'review_changes',
                status: 'running',
                kind: ChatTraceEventKind.skill,
              ),
            ],
            active: true,
          ),
        ),
      ),
    );

    expect(find.text('Ejecutando skill'), findsOneWidget);
    expect(find.text('review_changes'), findsNothing);
    final icon = tester.widget<Icon>(
      find.byKey(const ValueKey('thinking-trace-state-icon')),
    );
    expect(icon.icon, Icons.auto_awesome_rounded);
    expect(icon.size, 17);
  });

  testWidgets('terminado usa un check funcional', (tester) async {
    await tester.pumpWidget(
      _cardHost(
        card: ThinkingTraceCard(
          events: [
            ChatTraceEvent(
              id: 'tool-complete',
              label: 'Terminal',
              status: 'completed',
            ),
          ],
          active: false,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CompanionStatusIndicator), findsNothing);
    expect(find.byType(CompanionView), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    final icon = tester.widget<Icon>(find.byIcon(Icons.check_circle));
    expect(
      icon.color,
      AppTheme.hermesRedDark.extension<HermesThemeColors>()!.success,
    );
    expect(icon.size, 17);
  });

  testWidgets('recuperado y fallido usan warning y error funcionales', (
    tester,
  ) async {
    await tester.pumpWidget(
      _cardHost(
        card: ThinkingTraceCard(
          events: [
            ChatTraceEvent(id: 'failed', label: 'Read', status: 'failed'),
            ChatTraceEvent(id: 'done', label: 'Retry', status: 'completed'),
          ],
          active: false,
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byType(CompanionView), findsNothing);

    await tester.pumpWidget(
      _cardHost(
        card: ThinkingTraceCard(
          events: [
            ChatTraceEvent(id: 'failed', label: 'Read', status: 'failed'),
          ],
          active: false,
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byType(CompanionView), findsNothing);
  });

  testWidgets('los iconos de actividad y terminado son independientes', (
    tester,
  ) async {
    await tester.pumpWidget(
      _cardHost(
        card: ThinkingTraceCard(
          events: const [],
          active: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CompanionView), findsNothing);
    expect(find.byType(HermesStatusPulse), findsNothing);
    expect(find.byIcon(Icons.psychology_alt_rounded), findsOneWidget);

    await tester.pumpWidget(
      _cardHost(
        card: ThinkingTraceCard(
          events: const [],
          active: false,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CompanionView), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('320dp con escala 2 no desborda el estado terminado', (
    tester,
  ) async {
    await tester.pumpWidget(
      _cardHost(
        width: 320,
        textScale: 2,
        card: ThinkingTraceCard(
          events: [
            ChatTraceEvent(
              id: 'tool-complete',
              label: 'Terminal',
              status: 'completed',
            ),
          ],
          active: false,
        ),
      ),
    );
    await tester.pump();

    // Hermes Desktop: a finished block with no measured time says "Thought".
    expect(find.text('Thought'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('estado compacto renderiza en temas claro y oscuro', (
    tester,
  ) async {
    for (final theme in [AppTheme.hermesRedLight, AppTheme.hermesRedDark]) {
      await tester.pumpWidget(
        _cardHost(
          width: 320,
          textScale: 2,
          theme: theme,
          card: const ThinkingTraceCard(
            events: [],
            active: true,
            activeMood: HermesSparkMood.connecting,
            headline: 'Connecting',
          ),
        ),
      );
      await tester.pump();

      final icon = tester.widget<Icon>(
        find.byKey(const ValueKey('thinking-trace-state-icon')),
      );
      expect(icon.icon, Icons.cloud_queue_rounded);
      expect(icon.color, theme.extension<HermesThemeColors>()!.accent);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('razonamiento terminado queda plegado en la misma tarjeta', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: ThinkingTraceCard(
            events: [
              ChatTraceEvent(
                id: 'reasoning-1',
                label: 'Razonamiento',
                status: 'completed',
                preview: 'Primero inspecciono. Luego verifico.',
                kind: ChatTraceEventKind.reasoning,
              ),
            ],
            active: false,
          ),
        ),
      ),
    );

    // Reopened from history: Hermes Desktop's plain «Thought» («Pensó»).
    expect(find.text('Pensó'), findsOneWidget);
    expect(find.text('Razonamiento'), findsNothing);
    expect(find.textContaining('Primero inspecciono'), findsNothing);

    await tester.tap(find.text('Pensó'));
    await tester.pumpAndSettle();
    expect(find.text('Primero inspecciono. Luego verifico.'), findsOneWidget);
  });

  testWidgets('duración conocida usa el resumen localizado', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: Scaffold(
          body: ThinkingTraceCard(
            events: [
              ChatTraceEvent(
                id: 'reasoning-1',
                label: 'Reasoning',
                status: 'completed',
                preview: 'Checked the inputs.',
                kind: ChatTraceEventKind.reasoning,
              ),
            ],
            active: false,
            duration: Duration(seconds: 12),
          ),
        ),
      ),
    );

    expect(find.text('Thought for 12s'), findsOneWidget);
    expect(find.text('Checked the inputs.'), findsNothing);
  });

  testWidgets('con el estado vivo en la pastilla la burbuja no pinta ninguna '
      'fila de estado y al terminar aparece la entrada plegada', (
    tester,
  ) async {
    Future<void> pump({required bool active}) => tester.pumpWidget(
      _cardHost(
        card: ThinkingTraceCard(
          events: [
            ChatTraceEvent(
              id: 't1',
              label: 'terminal',
              status: active ? 'running' : 'completed',
              detail: 'date',
              duration: active ? null : const Duration(milliseconds: 700),
            ),
          ],
          active: active,
          liveInPill: true,
        ),
      ),
    );

    await pump(active: true);
    await tester.pump();
    // Ni fila de estado, ni shimmer, ni icono, ni desplegable: nada vivo.
    expect(
      find.byKey(const ValueKey('thinking-trace-live-in-pill')),
      findsOneWidget,
    );
    expect(find.text('Running tool'), findsNothing);
    expect(find.byKey(const ValueKey('thinking-shimmer')), findsNothing);
    expect(
      find.byKey(const ValueKey('thinking-trace-state-icon')),
      findsNothing,
    );
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(tester.getSize(find.byType(ThinkingTraceCard)).height, 0);

    // Terminado: la entrada plegada «Thought ⌄» (Hermes Desktop) y, al
    // abrirla, las mismas filas que el panel en vivo.
    await pump(active: false);
    await tester.pump();
    expect(find.text('Thought'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.byKey(const ValueKey('activity-done-section')), findsNothing);
    await tester.tap(find.text('Thought'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('activity-done-title')), findsOneWidget);
    expect(find.text('terminal · date', findRichText: true), findsOneWidget);
    expect(find.text('0.7 s'), findsOneWidget);
  });

  testWidgets(
    'la etiqueta del bloque terminado: trabajo, solo razonar, parado y puente',
    (tester) async {
      Future<void> pump(
        List<ChatTraceEvent> events, {
        Duration? duration,
        bool stopped = false,
      }) => tester.pumpWidget(
        _cardHost(
          card: ThinkingTraceCard(
            events: events,
            active: false,
            duration: duration,
            stopped: stopped,
            liveInPill: true,
          ),
        ),
      );
      final tool = ChatTraceEvent(
        id: 't',
        label: 'terminal',
        status: 'completed',
      );
      final thought = ChatTraceEvent(
        id: 'r',
        label: 'Reasoning',
        status: 'completed',
        kind: ChatTraceEventKind.reasoning,
        preview: 'pienso',
      );
      // Hermes Desktop has ONE label, with or without tools: watched live
      // it reports the measured time (`formatElapsed`: 72 s -> 1:12).
      await pump([thought, tool], duration: const Duration(seconds: 72));
      await tester.pump();
      expect(find.text('Thought for 1:12'), findsOneWidget);
      // Reopened from history (no measured time): «Thought», never
      // «Completed» or «Reasoning».
      await pump([thought, tool]);
      await tester.pump();
      expect(find.text('Thought'), findsOneWidget);
      await pump([thought]);
      await tester.pump();
      expect(find.text('Thought'), findsOneWidget);
      // Under a second: «Thought briefly».
      await pump([thought], duration: const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Thought briefly'), findsOneWidget);
      await pump([thought], duration: const Duration(seconds: 4));
      await tester.pump();
      expect(find.text('Thought for 4s'), findsOneWidget);
      // Parado conserva su desenlace.
      await pump(
        [thought, tool],
        duration: const Duration(seconds: 9),
        stopped: true,
      );
      await tester.pump();
      expect(find.text('Stopped'), findsOneWidget);
      // Solo herramientas puente: no hay nada que desplegar.
      await pump([
        ChatTraceEvent(id: 'a', label: 'tool_search', status: 'completed'),
        ChatTraceEvent(id: 'b', label: 'tool_call', status: 'completed'),
      ]);
      await tester.pump();
      expect(find.byIcon(Icons.expand_more), findsNothing);
      expect(find.textContaining('tool_'), findsNothing);
    },
  );

  testWidgets('en la cabecera: resumen apagado bajo el título y detalle debajo', (
    tester,
  ) async {
    final theme = AppTheme.hermesRedDark;
    final colors = theme.hermes;
    Future<void> pump({required bool active}) => tester.pumpWidget(
      _cardHost(
        theme: theme,
        card: ThinkingTraceCard(
          events: [
            ChatTraceEvent(
              id: 't',
              label: 'terminal',
              status: active ? 'running' : 'completed',
              detail: 'sleep',
              duration: const Duration(seconds: 5),
            ),
          ],
          active: active,
          liveInPill: true,
          duration: const Duration(seconds: 72),
          headerBuilder: (context, summary, details) => Column(
            children: [
              Row(
                children: [
                  const Text('TITLE', key: ValueKey('fake-title')),
                  Expanded(child: summary),
                ],
              ),
              details,
            ],
          ),
        ),
      ),
    );

    // En vivo: una sola palabra apagada, sin icono ni spinner ni shimmer.
    await pump(active: true);
    await tester.pump();
    final working = tester.widget<Text>(
      find.byKey(const ValueKey('thinking-trace-live-in-pill')),
    );
    expect(working.data, 'Working…');
    expect(working.style!.color, colors.textSecondary);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('thinking-trace-state-icon')), findsNothing);
    expect(find.byKey(const ValueKey('thinking-shimmer')), findsNothing);

    // Terminado: «Thought for 1:12 ⌄» con el mismo tono del resto de la línea.
    await pump(active: false);
    await tester.pump();
    final label = tester.widget<Text>(find.text('Thought for 1:12'));
    expect(label.style!.color, colors.textSecondary);
    expect(label.style!.fontSize, 11.5);
    final chevron = tester.widget<Icon>(find.byIcon(Icons.expand_more));
    expect(chevron.color, colors.textSecondary);
    expect(chevron.size, lessThanOrEqualTo(16));
    expect(find.byKey(const ValueKey('thinking-trace-state-icon')), findsNothing);
    expect(find.byKey(const ValueKey('activity-done-section')), findsNothing);

    // Al tocarlo se despliega el detalle debajo, con la marca en tono apagado.
    await tester.tap(find.byKey(const ValueKey('thinking-trace-summary')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('activity-done-section')), findsOneWidget);
    expect(find.text('terminal · sleep', findRichText: true), findsOneWidget);
    final check = tester.widget<Icon>(find.byIcon(Icons.check_rounded));
    expect(check.color, isNot(colors.success));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('activity-done-section'))).dy,
      greaterThan(tester.getRect(find.byKey(const ValueKey('fake-title'))).bottom - 1),
    );
  });

  testWidgets('el cargador por defecto respeta locale=en', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        theme: AppTheme.hermesRedDark,
        home: const Scaffold(body: TuiLoader()),
      ),
    );

    expect(find.text('Loading…'), findsOneWidget);
    expect(find.text('cargando…'), findsNothing);
  });
}
