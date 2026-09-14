import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/compression_config.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/compression_config_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _initial = CompressionConfig(
  enabled: true,
  threshold: 0.5,
  targetRatio: 0.2,
  protectLastN: 20,
);

const _agent020Initial = CompressionConfig(
  enabled: true,
  threshold: 0.5,
  targetRatio: 0.2,
  protectLastN: 20,
  thresholdTokens: null,
  minTailUserMessages: 2,
  progressNotices: false,
);

const _agent020Fields = CompressionConfigOptionalFields(
  thresholdTokens: true,
  minTailUserMessages: true,
  progressNotices: true,
);

CompressionConfigSnapshot _snapshot([CompressionConfig value = _initial]) =>
    CompressionConfigSnapshot.supported(
      profile: 'qa',
      configuration: value,
      limits: CompressionConfigLimits.native,
      recordHandle: CompressionConfigRecordHandle.fromRedactedRecord({
        'compression': value.toDashboardPatch(),
      }),
      fetchedAt: DateTime.utc(2026, 7, 22),
    );

CompressionConfigSnapshot _agent020Snapshot([
  CompressionConfig value = _agent020Initial,
]) => CompressionConfigSnapshot.supported(
  profile: 'qa',
  configuration: value,
  limits: CompressionConfigLimits.native,
  optionalFields: _agent020Fields,
  recordHandle: CompressionConfigRecordHandle.fromRedactedRecord({
    'compression': {
      ...value.toDashboardPatch(),
      'threshold_tokens': value.thresholdTokens,
      'min_tail_user_messages': value.minTailUserMessages,
      'progress_notices': value.progressNotices,
    },
  }),
  fetchedAt: DateTime.utc(2026, 8, 3),
);

Widget _app({
  required CompressionConfigLoader load,
  required CompressionConfigSaver save,
  bool canRead = true,
  bool canWrite = true,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: Scaffold(
    body: SingleChildScrollView(
      child: CompressionConfigCard(
        profile: 'qa',
        canRead: canRead,
        canWrite: canWrite,
        load: load,
        save: save,
      ),
    ),
  ),
);

void main() {
  testWidgets('no guarda al cargar y agrupa cambios durante 550 ms', (
    tester,
  ) async {
    final saved = <CompressionConfig>[];
    await tester.pumpWidget(
      _app(
        load: () async => _snapshot(),
        save: (base, value) async {
          saved.add(value);
          return _snapshot(value);
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(saved, isEmpty);
    tester
        .widget<SwitchListTile>(
          find.byKey(const ValueKey('compression-config-enabled')),
        )
        .onChanged!(false);
    await tester.pump(const Duration(milliseconds: 300));
    tester
        .widget<Slider>(
          find.byKey(const ValueKey('compression-config-threshold')),
        )
        .onChanged!(0.65);

    await tester.pump(const Duration(milliseconds: 549));
    expect(saved, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.enabled, isFalse);
    expect(saved.single.threshold, 0.65);
    expect(
      find.byKey(const ValueKey('compression-config-saved')),
      findsOneWidget,
    );
  });

  testWidgets('muestra guardado en curso y revierte si Hermes rechaza', (
    tester,
  ) async {
    final gate = Completer<CompressionConfigSnapshot>();
    await tester.pumpWidget(
      _app(load: () async => _snapshot(), save: (_, _) => gate.future),
    );
    await tester.pumpAndSettle();

    tester
        .widget<Slider>(
          find.byKey(const ValueKey('compression-config-threshold')),
        )
        .onChanged!(0.75);
    await tester.pump(const Duration(milliseconds: 550));
    expect(
      find.byKey(const ValueKey('compression-config-saving')),
      findsOneWidget,
    );

    gate.completeError(
      const CompressionConfigException(CompressionConfigFailureCode.rejected),
    );
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<Slider>(
            find.byKey(const ValueKey('compression-config-threshold')),
          )
          .value,
      _initial.threshold,
    );
    expect(
      find.byKey(const ValueKey('compression-config-save-failed')),
      findsOneWidget,
    );
  });

  testWidgets('muestra y guarda los tres controles guiados de Agent 0.20', (
    tester,
  ) async {
    final saved = <CompressionConfig>[];
    await tester.pumpWidget(
      _app(
        load: () async => _agent020Snapshot(),
        save: (base, value) async {
          saved.add(value);
          return _agent020Snapshot(value);
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('compression-config-advanced')));
    await tester.pump();

    expect(find.text('Límite absoluto de tokens'), findsOneWidget);
    expect(find.text('Avisos de progreso'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('compression-config-threshold-tokens')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('compression-config-min-tail-users')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('compression-config-progress-notices')),
      findsOneWidget,
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('compression-config-min-tail-users-increase')),
    );
    await tester.pump();
    final increase = tester.widget<IconButton>(
      find.byKey(const ValueKey('compression-config-min-tail-users-increase')),
    );
    expect(increase.onPressed, isNotNull);
    increase.onPressed!();
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('compression-config-threshold-tokens')),
      '120000',
    );
    tester
        .widget<IconButton>(
          find.byKey(
            const ValueKey('compression-config-threshold-tokens-apply'),
          ),
        )
        .onPressed!();
    await tester.pump();
    tester
        .widget<SwitchListTile>(
          find.byKey(const ValueKey('compression-config-progress-notices')),
        )
        .onChanged!(true);

    await tester.pump(const Duration(milliseconds: 550));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.thresholdTokens, 120000);
    expect(saved.single.minTailUserMessages, 3);
    expect(saved.single.progressNotices, isTrue);
  });

  testWidgets('legacy no muestra controles que schema/config no publican', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        load: () async => _snapshot(),
        save: (_, value) async => _snapshot(value),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('compression-config-advanced')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('compression-config-threshold-tokens')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('compression-config-min-tail-users')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('compression-config-progress-notices')),
      findsNothing,
    );
  });

  testWidgets('cerrar antes del debounce conserva el cambio pendiente', (
    tester,
  ) async {
    final saved = <CompressionConfig>[];
    await tester.pumpWidget(
      _app(
        load: () async => _snapshot(),
        save: (base, value) async {
          saved.add(value);
          return _snapshot(value);
        },
      ),
    );
    await tester.pumpAndSettle();

    tester
        .widget<Slider>(
          find.byKey(const ValueKey('compression-config-threshold')),
        )
        .onChanged!(0.72);
    await tester.pump(const Duration(milliseconds: 100));
    expect(saved, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(saved, hasLength(1));
    expect(saved.single.threshold, 0.72);
  });

  testWidgets('sliders exponen etiqueta y valor localizados en un unico nodo', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        load: () async => _snapshot(),
        save: (_, value) async => _snapshot(value),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('compression-config-advanced')));
    await tester.pump();

    final expectations = <(Key, String, String)>[
      (
        const ValueKey('compression-config-threshold'),
        'Umbral de inicio',
        '50%',
      ),
      (
        const ValueKey('compression-config-target-ratio'),
        'Objetivo de reducción',
        '20%',
      ),
      (
        const ValueKey('compression-config-protect-last-n'),
        'Mensajes protegidos',
        '20',
      ),
    ];

    for (final (key, label, value) in expectations) {
      final data = tester.getSemantics(find.byKey(key)).getSemanticsData();
      expect(data.label, label);
      expect(data.value, value);
      expect(data.flagsCollection.isSlider, isTrue);
      expect(
        find.bySemanticsLabel(RegExp('^${RegExp.escape(label)}\$')),
        findsOne,
      );
    }
    for (final duplicate in <String>[
      'Empezar al 50%',
      'Reducir hasta el 20% del umbral',
      'Conservar intactos los últimos 20 mensajes',
    ]) {
      expect(
        find.bySemanticsLabel(RegExp('^${RegExp.escape(duplicate)}\$')),
        findsNothing,
      );
    }
    semantics.dispose();
  });

  testWidgets('toggles exponen una sola semantica localizada', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        load: () async => _agent020Snapshot(),
        save: (_, value) async => _agent020Snapshot(value),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('compression-config-advanced')));
    await tester.pump();

    const expectations = <(Key, String, String)>[
      (
        ValueKey('compression-config-enabled'),
        'Comprimir automáticamente',
        'Hermes inicia la compresión al alcanzar el umbral configurado.',
      ),
      (
        ValueKey('compression-config-progress-notices'),
        'Avisos de progreso',
        'Muestra el progreso rutinario de la compresión en los canales de chat compatibles.',
      ),
    ];

    for (final (key, title, hint) in expectations) {
      final data = tester.getSemantics(find.byKey(key)).getSemanticsData();
      expect(data.label, contains(title));
      expect(data.label, contains(hint));
      expect(RegExp(RegExp.escape(title)).allMatches(data.label), hasLength(1));
      expect(find.bySemanticsLabel(RegExp(RegExp.escape(title))), findsOne);
    }
    semantics.dispose();
  });

  testWidgets('solo lectura carga datos pero desactiva todas las mutaciones', (
    tester,
  ) async {
    var saves = 0;
    await tester.pumpWidget(
      _app(
        canWrite: false,
        load: () async => _snapshot(),
        save: (base, value) async {
          saves++;
          return _snapshot(value);
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('compression-config-enabled')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<Slider>(
            find.byKey(const ValueKey('compression-config-threshold')),
          )
          .onChanged,
      isNull,
    );
    expect(
      find.byKey(const ValueKey('compression-config-read-only')),
      findsOneWidget,
    );
    expect(saves, 0);
  });

  testWidgets(
    'sin lectura muestra no disponible y no inicia carga ni guardado',
    (tester) async {
      var loads = 0;
      var saves = 0;
      await tester.pumpWidget(
        _app(
          canRead: false,
          canWrite: false,
          load: () async {
            loads += 1;
            return _snapshot();
          },
          save: (_, value) async {
            saves += 1;
            return _snapshot(value);
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('compression-config-unavailable')),
        findsOneWidget,
      );
      expect(loads, 0);
      expect(saves, 0);
    },
  );

  testWidgets('distingue contrato no soportado de fallo de carga', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        load: () async => CompressionConfigSnapshot.unsupported(
          profile: null,
          fetchedAt: DateTime.utc(2026, 7, 22),
        ),
        save: (_, _) => throw UnimplementedError(),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('compression-config-unsupported')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      _app(
        load: () async => throw const CompressionConfigException(
          CompressionConfigFailureCode.transport,
        ),
        save: (_, _) => throw UnimplementedError(),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('compression-config-load-failed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('compression-config-retry')),
      findsOneWidget,
    );
  });
}
