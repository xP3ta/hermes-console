// QA 9709 (the owner, maqueta 140-qa9709 voz-ajustes-modelo): the model that
// answers when you speak, first in Settings › Voice: its name large,
// «Cambiar» opening the list with the current one marked, its reasoning
// below; nothing to pick, read only and GPT-Live say so.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/hermes_design.dart'
    show HermesModelGroup;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/voice_model_block.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'support/reasoning_tap.dart';

const _groups = [
  HermesModelGroup(
    slug: 'codex',
    name: 'OpenAI Codex',
    models: ['gpt-6-luna', 'gpt-6.1-sol', 'gpt-6-mini'],
  ),
  HermesModelGroup(
    slug: 'anthropic',
    name: 'Anthropic',
    models: ['claude-haiku-5-5'],
  ),
];

class _Source implements VoiceModelSource {
  _Source(this.choice);

  VoiceModelChoice choice;
  final List<(String, String)> chosen = [];
  final List<String> efforts = [];
  bool fail = false;
  int loads = 0;

  @override
  Future<VoiceModelChoice> load() async {
    loads++;
    if (fail) throw StateError('down');
    return choice;
  }

  @override
  Future<void> choose({required String provider, required String model}) async {
    chosen.add((provider, model));
    choice = VoiceModelChoice(
      provider: provider,
      model: model,
      reasoning: choice.reasoning,
      groups: choice.groups,
      mainModel: choice.mainModel,
    );
  }

  @override
  Future<void> setReasoning(VoiceModelChoice current, String effort) async {
    efforts.add(effort);
    choice = VoiceModelChoice(
      provider: current.provider,
      model: current.model,
      reasoning: effort,
      groups: current.groups,
      mainModel: current.mainModel,
    );
  }
}

_Source _luna({List<HermesModelGroup> groups = _groups}) => _Source(
  VoiceModelChoice(
    provider: 'codex',
    model: 'gpt-6-luna',
    reasoning: 'none',
    groups: groups,
    mainModel: 'gpt-6.1-sol',
  ),
);

Widget _app(
  Widget child, {
  ThemeData? theme,
  double width = 380,
  double textScale = 1,
  bool reduceMotion = false,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reduceMotion,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(width: width, child: child),
    ),
  ),
);

Finder _key(String key) => find.byKey(ValueKey(key));

void main() {
  for (final (name, theme) in [
    ('dark', AppTheme.hermesRedDark),
    ('light', AppTheme.hermesRedLight),
  ]) {
    for (final width in const [196.0, 236.0, 288.0, 360.0]) {
      testWidgets('$name, $width dp, text at 134 %: the name and «Cambiar» '
          'fit, 48 dp', (tester) async {
        await tester.pumpWidget(
          _app(
            VoiceModelBlock(source: _luna()),
            theme: theme,
            width: width,
            textScale: 1.34,
            reduceMotion: true,
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('gpt-6-luna'), findsOneWidget);
        final block = tester.getRect(_key('voice-model-block'));
        final change = tester.getRect(_key('voice-model-change'));
        expect(block.width, width);
        expect(change.height, greaterThanOrEqualTo(48));
        expect(change.width, greaterThanOrEqualTo(48));
        expect(change.right, lessThanOrEqualTo(block.right));
        expect(_key('voice-model-reasoning'), findsOneWidget);
      });
    }
  }

  testWidgets('«Cambiar» opens the list with the current one marked; '
      'picking one sets it', (tester) async {
    final semantics = tester.ensureSemantics();
    final source = _luna();
    await tester.pumpWidget(_app(VoiceModelBlock(source: source)));
    await tester.pump();
    expect(
      tester.getSemantics(_key('voice-model-current')),
      isSemantics(
        label: 'Modelo de la voz: gpt-6-luna',
        isButton: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(_key('voice-model-change'));
    await tester.pumpAndSettle();
    expect(_key('voice-model-picker'), findsOneWidget);
    expect(find.text('Modelo de la voz'), findsWidgets);
    expect(
      find.text(
        'El que responde cuando hablas, en este perfil. Se aplica en tu '
        'próximo turno.',
      ),
      findsOneWidget,
    );
    expect(find.text('El principal: gpt-6.1-sol'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('voice-model-codex-gpt-6-luna'),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _key('voice-model-codex-gpt-6.1-sol'),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsNothing,
    );

    await tester.tap(_key('voice-model-codex-gpt-6.1-sol'));
    await tester.pumpAndSettle();
    expect(source.chosen, [('codex', 'gpt-6.1-sol')]);
    expect(find.text('gpt-6.1-sol'), findsOneWidget);

    // «Automático» follows the main model again.
    await tester.tap(_key('voice-model-change'));
    await tester.pumpAndSettle();
    await tester.tap(_key('voice-model-default'));
    await tester.pumpAndSettle();
    expect(source.chosen.last, ('auto', ''));
    expect(find.text('Automático'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('its reasoning is chosen below it', (tester) async {
    final source = _luna();
    await tester.pumpWidget(_app(VoiceModelBlock(source: source)));
    await tester.pump();
    await tester.tap(_key('voice-model-reasoning'));
    // The squares blink while the sheet is open: no settling.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tapReasoningValue(
      tester,
      find.byKey(const ValueKey('reasoning-pill')),
      'high',
    );
    await tester.pumpAndSettle();
    expect(source.efforts, ['high']);
  });

  testWidgets('nothing to pick: «Automático», and why, with «Abrir Modelos»', (
    tester,
  ) async {
    var opened = 0;
    final source = _Source(
      const VoiceModelChoice(
        provider: 'auto',
        model: '',
        reasoning: '',
        groups: [],
      ),
    );
    await tester.pumpWidget(
      _app(VoiceModelBlock(source: source, onOpenModels: () => opened++)),
    );
    await tester.pump();
    expect(find.text('Automático'), findsOneWidget);
    await tester.tap(_key('voice-model-change'));
    await tester.pumpAndSettle();
    expect(_key('voice-model-empty'), findsOneWidget);
    expect(find.text('No hay modelos listos'), findsOneWidget);
    expect(_key('voice-model-picker'), findsNothing);
    await tester.tap(_key('voice-model-open-models'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(source.chosen, isEmpty);
  });

  testWidgets('read only: the model is read, with a lock; nothing opens', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final source = _luna();
    await tester.pumpWidget(
      _app(VoiceModelBlock(source: source, readOnly: true)),
    );
    await tester.pump();
    expect(find.text('gpt-6-luna'), findsOneWidget);
    expect(_key('voice-model-read-only'), findsOneWidget);
    expect(find.text('Solo lectura'), findsOneWidget);
    expect(_key('voice-model-change'), findsNothing);
    expect(
      tester.getSemantics(_key('voice-model-current')),
      isSemantics(
        label: 'Modelo de la voz: gpt-6-luna',
        hint: 'Solo lectura',
        isButton: false,
        hasTapAction: false,
      ),
    );
    await tester.tap(_key('voice-model-current'));
    await tester.tap(_key('voice-model-reasoning'));
    await tester.pumpAndSettle();
    expect(_key('voice-model-picker'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    semantics.dispose();
  });

  testWidgets('GPT-Live: dimmed, and it says why', (tester) async {
    await tester.pumpWidget(
      _app(VoiceModelBlock(source: _luna(), liveEngine: true)),
    );
    await tester.pump();
    expect(_key('voice-model-live-note'), findsOneWidget);
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: _key('voice-model-current'),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, lessThan(1));
  });

  testWidgets('the server does not answer: it says so and tries again', (
    tester,
  ) async {
    final source = _luna()..fail = true;
    await tester.pumpWidget(_app(VoiceModelBlock(source: source)));
    await tester.pump();
    expect(find.text('No se pudo leer el modelo de la voz.'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
    source.fail = false;
    await tester.tap(_key('voice-model-change'));
    await tester.pump();
    await tester.pump();
    expect(source.loads, 2);
    expect(find.text('gpt-6-luna'), findsOneWidget);
  });
}
