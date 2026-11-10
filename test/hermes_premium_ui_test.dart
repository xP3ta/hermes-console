import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/design/tokens.dart' show HermesGel;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart';

Finder _semanticsWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
);

Widget _host(
  Widget child, {
  bool reduceMotion = false,
  double textScale = 1,
  ThemeData? theme,
}) {
  return MaterialApp(
    theme: theme ?? AppTheme.hermesRedDark,
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: reduceMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: child,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'HermesSegmentedControl respeta el ancho relativo de cada opción',
    (tester) async {
      await tester.pumpWidget(
        _host(
          HermesSegmentedControl<int>(
            value: 0,
            onChanged: (_) {},
            segments: const [
              HermesSegment(
                key: ValueKey('segment-short'),
                value: 0,
                label: 'Chats',
                flex: 4,
                horizontalPadding: 6,
              ),
              HermesSegment(
                key: ValueKey('segment-cron'),
                value: 1,
                label: 'Resultados cron',
                flex: 11,
                horizontalPadding: 6,
              ),
            ],
          ),
        ),
      );

      final shortWidth = tester
          .getSize(find.byKey(const ValueKey('segment-short')))
          .width;
      final cronWidth = tester
          .getSize(find.byKey(const ValueKey('segment-cron')))
          .width;
      expect(cronWidth, greaterThan(shortWidth));

      final labelFinder = find.text('Resultados cron');
      final paragraph = tester.renderObject<RenderParagraph>(labelFinder);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'HermesDecisionBlock compone disclosure controlado y acciones de 48 dp',
    (tester) async {
      var expanded = false;
      var allowed = 0;

      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => HermesDecisionBlock(
              semanticLabel: 'Solicitud de permiso',
              title: 'Permiso requerido',
              summary: 'Hermes quiere ejecutar una acción.',
              leading: const Icon(Icons.shield_outlined),
              status: const Text('Riesgo alto'),
              detail: const Text('Comando completo'),
              expanded: expanded,
              disclosureLabel: 'Detalles del comando',
              onExpansionChanged: (value) => setState(() => expanded = value),
              actions: [
                TextButton(onPressed: () {}, child: const Text('Denegar')),
                FilledButton(
                  onPressed: () => allowed += 1,
                  child: const Text('Permitir'),
                ),
              ],
            ),
          ),
        ),
      );

      expect(_semanticsWithLabel('Solicitud de permiso'), findsOneWidget);
      expect(find.text('Riesgo alto'), findsOneWidget);
      expect(find.text('Comando completo'), findsNothing);

      final disclosureSemantics = _semanticsWithLabel('Detalles del comando');
      final disclosureTarget = find
          .ancestor(
            of: find.text('Detalles del comando'),
            matching: find.byType(InkWell),
          )
          .first;
      expect(disclosureSemantics, findsOneWidget);
      expect(
        tester.widget<Semantics>(disclosureSemantics).properties.expanded,
        isFalse,
      );
      expect(tester.getSize(disclosureTarget).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Denegar')).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Denegar')).width,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Permitir')).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Permitir')).width,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(disclosureTarget);
      await tester.pumpAndSettle();
      expect(expanded, isTrue);
      expect(find.text('Comando completo'), findsOneWidget);
      expect(
        tester.widget<Semantics>(disclosureSemantics).properties.expanded,
        isTrue,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Permitir'));
      await tester.pump();
      expect(allowed, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'HermesInlineActivity soporta light, textScale 2 y reduce motion',
    (tester) async {
      await tester.pumpWidget(
        _host(
          HermesInlineActivity(
            semanticLabel: 'Actividad de subagente',
            title: 'Revisando archivos',
            summary: 'El subagente mantiene el estado real.',
            leading: const Icon(Icons.account_tree_outlined),
            status: const Text('En curso'),
            detail: const Text('Dos pasos completados'),
            expanded: true,
            disclosureLabel: 'Ocultar actividad',
            onExpansionChanged: (_) {},
            actions: [
              TextButton(onPressed: () {}, child: const Text('Detener')),
            ],
          ),
          reduceMotion: true,
          textScale: 2,
          theme: AppTheme.hermesRedLight,
        ),
      );

      expect(_semanticsWithLabel('Actividad de subagente'), findsOneWidget);
      expect(find.text('Revisando archivos'), findsOneWidget);
      expect(find.text('En curso'), findsOneWidget);
      expect(find.text('Dos pasos completados'), findsOneWidget);
      final disclosureTarget = find
          .ancestor(
            of: find.text('Ocultar actividad'),
            matching: find.byType(InkWell),
          )
          .first;
      expect(tester.getSize(disclosureTarget).height, greaterThanOrEqualTo(48));
      expect(_semanticsWithLabel('Ocultar actividad'), findsOneWidget);
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Detener')).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Detener')).width,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.widget<AnimatedSize>(find.byType(AnimatedSize)).duration,
        Duration.zero,
      );
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).duration,
        Duration.zero,
      );
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('HermesShimmerText queda estático con reducir movimiento', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const HermesShimmerText(
          'Pensando',
          key: ValueKey('shimmer-under-test'),
        ),
        reduceMotion: true,
      ),
    );

    expect(find.text('Pensando'), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('HermesTactileAction comprime, recupera y ejecuta una vez', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        HermesTactileAction(
          icon: Icons.arrow_upward_rounded,
          semanticLabel: 'Enviar',
          onPressed: () => taps += 1,
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(HermesTactileAction)),
      const Size(48, 48),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HermesTactileAction)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      HermesGel.pressScale,
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    expect(taps, 1);
  });

  testWidgets('HermesTactileAction deshabilitada no ejecuta la acción', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        HermesTactileAction(
          icon: Icons.arrow_upward_rounded,
          semanticLabel: 'Enviar',
          enabled: false,
          onPressed: () => taps += 1,
        ),
      ),
    );

    await tester.tap(find.byType(HermesTactileAction));
    await tester.pump();
    expect(taps, 0);
  });
}
