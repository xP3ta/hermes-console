// Ola 3 (AUDITORIA-PULIDO §5, T2/T3): everything that floats over the chat
// has one tone — the solid HermesChrome fill, its hairline and its shadow —
// in the dark and the light theme alike, never a translucent surfaceVariant
// or a fixed black shadow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/design/tokens.dart'
    show HermesChrome, HermesRadius;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_pinned_prompt_header.dart';
import 'package:hermes_android/core/widgets/chat_status_pill.dart';
import 'package:hermes_android/core/widgets/hermes_premium_ui.dart'
    show HermesComposerSurface;
import 'package:hermes_android/core/widgets/session_context_usage.dart';
import 'package:hermes_android/core/widgets/voice_strip.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _labels = VoiceStripLabels(
  finishListening: 'Terminar de hablar',
  pause: 'Pausar',
  resume: 'Reanudar',
  stopAndTalk: 'Parar y hablar',
  cancel: 'Cancelar tarea',
  stop: 'Detener',
  retry: 'Reintentar',
  review: 'Ver aprobación',
  close: 'Terminar modo voz',
  end: 'Terminar',
);

Widget _host(
  Widget child, {
  required ThemeData theme,
  double textScale = 1,
  double width = 390,
}) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: const Locale('es'),
  theme: theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

BoxDecoration _decoration(WidgetTester tester, Finder finder) {
  final widget = tester.widget(finder);
  final decoration = switch (widget) {
    DecoratedBox(:final decoration) => decoration,
    Container(:final decoration) => decoration,
    AnimatedContainer(:final decoration) => decoration,
    _ => null,
  };
  return decoration! as BoxDecoration;
}

void main() {
  for (final (name, theme) in [
    ('dark', AppTheme.fromMode(AppThemeMode.dark)),
    ('light', AppTheme.fromMode(AppThemeMode.light)),
  ]) {
    final colors = theme.hermes;
    final chrome = HermesChrome.of(colors);

    void expectChrome(BoxDecoration decoration, {bool line = true}) {
      expect(decoration.color, chrome.opaque);
      expect(decoration.boxShadow, chrome.shadow);
      if (line) {
        expect((decoration.border! as Border).top.color, chrome.line);
      }
    }

    group(name, () {
      testWidgets('the composer', (tester) async {
        await tester.pumpWidget(
          _host(
            const HermesComposerSurface(child: SizedBox(height: 48)),
            theme: theme,
          ),
        );
        final decoration = _decoration(
          tester,
          find.byKey(const ValueKey('hermes-composer-visible-surface')),
        );
        expectChrome(decoration);
        expect(
          decoration.borderRadius,
          BorderRadius.circular(HermesRadius.pane),
        );
      });

      testWidgets('the status pill: chrome, 48 dp zones, support type', (
        tester,
      ) async {
        final metrics = ValueNotifier(
          const SessionContextMetrics(
            contextUsed: 20,
            contextMax: 100,
            percent: 20,
          ),
        );
        addTearDown(metrics.dispose);
        await tester.pumpWidget(
          _host(
            ChatStatusPill(
              metrics: metrics,
              onOpenContext: () {},
              modelLabel: 'Sonnet 5',
              onOpenModel: () {},
            ),
            theme: theme,
          ),
        );
        expectChrome(
          _decoration(
            tester,
            find.byKey(const ValueKey('status-pill-capsule')),
          ),
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('status-pill-capsule')))
              .height,
          ChatStatusPill.capsuleHeight,
        );
        final model = find.byKey(const ValueKey('status-pill-model'));
        expect(tester.getSize(model).height, greaterThanOrEqualTo(48));
        final label = tester.widget<Text>(find.text('Sonnet 5'));
        expect(label.style?.fontSize, ChatStatusPill.labelStyle.fontSize);
      });

      testWidgets('the «Tú:» chip', (tester) async {
        await tester.pumpWidget(
          _host(
            Align(child: ChatPinnedPromptHeader(
              youLabel: 'Tú',
              text: '¿Qué tal?',
              attachmentCount: 0,
              semanticLabel: 'Tu mensaje',
              hideLabel: 'Ocultar',
              onTap: () {},
              onHide: () {},
            )),
            theme: theme,
          ),
        );
        final arrow = find.byKey(const ValueKey('chat-jump-to-prompt'));
        expect(tester.getSize(arrow), const Size(48, 48));
        final face = tester.widget<Material>(
          find.descendant(of: arrow, matching: find.byType(Material)).first,
        );
        expect(face.color, chrome.fill);
        expect((face.shape! as StadiumBorder).side.color, chrome.line);
        final shadow =
            tester
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: arrow,
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as ShapeDecoration;
        expect(shadow.shadows, chrome.shadow);
      });

      testWidgets('the voice line, radius 22', (tester) async {
        await tester.pumpWidget(
          _host(
            const VoiceStatusLine(
              state: VoiceStripState.thinking,
              statusLabel: 'Pensando…',
              labels: _labels,
            ),
            theme: theme,
          ),
        );
        final decoration = _decoration(
          tester,
          find.byKey(const ValueKey('voice-strip')),
        );
        expectChrome(decoration);
        expect(
          decoration.borderRadius,
          BorderRadius.circular(HermesRadius.card),
        );
      });
    });
  }

  test('the pill grows with large text, never past its touch height', () {
    expect(
      ChatStatusPill.visibleHeight(TextScaler.noScaling),
      ChatStatusPill.capsuleHeight,
    );
    final large = ChatStatusPill.visibleHeight(const TextScaler.linear(2));
    expect(large, greaterThan(ChatStatusPill.capsuleHeight));
    expect(large, lessThanOrEqualTo(ChatStatusPill.minTouchHeight));
  });

  // 135 v2 §4: what is heard keeps its last words; the start slips away to
  // the left and the line does not grow.
  testWidgets('a long utterance shows its end, not its start', (tester) async {
    final long = [for (var i = 0; i < 30; i++) 'palabra$i'].join(' ');
    await tester.pumpWidget(
      _host(
        VoiceStatusLine(
          state: VoiceStripState.listening,
          statusLabel: 'Escuchando…',
          labels: _labels,
          heard: () => long,
        ),
        theme: AppTheme.fromMode(AppThemeMode.dark),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final line = tester.getRect(find.byKey(const ValueKey('voice-strip')));
    final text = tester.getRect(find.text(long));
    expect(text.left, lessThan(line.left), reason: 'the start is hidden');
    expect(text.right, lessThanOrEqualTo(line.right));
    expect(text.right, greaterThan(line.left + line.width / 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short utterance stays at the start', (tester) async {
    await tester.pumpWidget(
      _host(
        VoiceStatusLine(
          state: VoiceStripState.listening,
          statusLabel: 'Escuchando…',
          labels: _labels,
          heard: () => 'hola',
        ),
        theme: AppTheme.fromMode(AppThemeMode.dark),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final line = tester.getRect(find.byKey(const ValueKey('voice-strip')));
    final text = tester.getRect(find.text('hola'));
    expect(text.left, greaterThan(line.left));
    expect(text.left, lessThan(line.left + 60));
  });
}
