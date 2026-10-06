// rt1215: secondary text (onSurfaceVariant = textSecondary) and links
// (accentText) reach WCAG AA 4.5:1 on every surface of every theme, and the
// agent-text surfaces really paint their prose in those tokens — rendered in
// every theme, not only read from the palette.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/dots_home_view.dart';
import 'package:hermes_android/core/bots/ui/roster/living_bot_face.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';
import 'package:hermes_android/core/design/content.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/mission_control.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/activity_sections.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const double _aa = 4.5;

/// Secondary must read at least this much stronger than tertiary.
const double _hierarchyStep = 1.1;

const String _reasoning =
    '**Checking the backup host**\n\n'
    'The nightly job on `nas-1` failed; see the [log](https://example.com) '
    'before retrying.';

final DateTime _t0 = DateTime(2026, 10, 6, 12);

void main() {
  test('secondary ink and links reach 4.5:1 on every surface', () {
    final fails = <String>[];
    for (final p in AppTheme.presets) {
      final c = p.colors;
      final surfaces = {
        'background': c.background,
        'surface': c.surface,
        'surfaceVariant': c.surfaceVariant,
      };
      surfaces.forEach((name, bg) {
        for (final (token, ink) in [
          ('textSecondary', c.textSecondary),
          ('accentText', c.accentText),
        ]) {
          final r = ThemeContrast.ratio(ink, bg);
          if (r < _aa) {
            fails.add('${p.id} $token/$name ${r.toStringAsFixed(2)}');
          }
        }
      });
    }
    expect(fails, isEmpty, reason: fails.join('\n'));
  });

  test('tertiary ink reaches 4.5:1 and reads below secondary', () {
    final fails = <String>[];
    for (final p in AppTheme.presets) {
      final c = p.colors;
      final surfaces = [c.background, c.surface, c.surfaceVariant];
      double worst(Color ink) =>
          surfaces.map((bg) => ThemeContrast.ratio(ink, bg)).reduce(math.min);
      final tertiary = worst(c.textTertiary);
      final secondary = worst(c.textSecondary);
      final primary = worst(c.textPrimary);
      if (tertiary < _aa) {
        fails.add('${p.id} tertiary ${tertiary.toStringAsFixed(2)}');
      }
      // Hierarchy: secondary is a visible step above tertiary, unless the
      // theme's own primary text sits so close to AA that it caps the step.
      final step = math.min(tertiary * _hierarchyStep, primary);
      if (secondary <= tertiary || secondary + 1e-9 < step) {
        fails.add(
          '${p.id} hierarchy sec ${secondary.toStringAsFixed(2)} '
          'ter ${tertiary.toStringAsFixed(2)} pri ${primary.toStringAsFixed(2)}',
        );
      }
      // Same ink family: the lift only moves textDisabled towards black or
      // white, so a tinted grey keeps its hue.
      final from = HSLColor.fromColor(c.textDisabled);
      final to = HSLColor.fromColor(c.textTertiary);
      final dh = (from.hue - to.hue).abs();
      if (from.saturation > 0.08 && math.min(dh, 360 - dh) > 6) {
        fails.add('${p.id} tertiary hue moved ${dh.toStringAsFixed(1)}');
      }
    }
    expect(fails, isEmpty, reason: fails.join('\n'));
  });

  test('any palette derives a readable tertiary from its disabled ink', () {
    const colors = HermesThemeColors(
      background: Color(0xFF101010),
      surface: Color(0xFF181818),
      surfaceVariant: Color(0xFF262626),
      accent: Color(0xFFE8821C),
      accentHover: Color(0xFFF0A848),
      onAccent: Color(0xFF0D0D0D),
      textPrimary: Color(0xFFEEEEEE),
      textSecondary: Color(0xFFAAAAAA),
      textDisabled: Color(0xFF444444),
      error: Color(0xFFFF4444),
      success: Color(0xFF22CC44),
      warning: Color(0xFFFFAA00),
      divider: Color(0xFF242424),
    );
    for (final bg in [
      colors.background,
      colors.surface,
      colors.surfaceVariant,
    ]) {
      expect(ThemeContrast.ratio(colors.textTertiary, bg), greaterThan(4.49));
    }
    // Changing the page of a preset re-derives it instead of keeping the
    // preset's dark-page tertiary.
    final light = AppTheme.presetById('amber').colors.copyWith(
      background: const Color(0xFFFFFFFF),
      surface: const Color(0xFFF6F6F6),
      surfaceVariant: const Color(0xFFEDEDED),
      textDisabled: const Color(0xFFBBBBBB),
    );
    for (final bg in [light.background, light.surface, light.surfaceVariant]) {
      expect(ThemeContrast.ratio(light.textTertiary, bg), greaterThan(4.49));
    }
  });

  testWidgets('agent-text surfaces paint readable ink in every theme', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fails = <String>[];
    for (final preset in AppTheme.presets) {
      final theme = AppTheme.fromId(preset.id);
      final c = theme.hermes;
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(preset.id),
          locale: const Locale('en'),
          localizationsDelegates: const [
            Strings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: Strings.supportedLocales,
          theme: theme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  ActivityNowSection(
                    snapshot: ActivitySnapshot(
                      turnActive: true,
                      turnStartedAt: _t0,
                      headline: 'Thinking…',
                      liveReasoning: _reasoning,
                    ),
                    now: _t0,
                  ),
                  ActivityDoneSection(
                    now: _t0,
                    steps: const [
                      ActivityStep(
                        id: 'tool',
                        kind: ActivityStepKind.tool,
                        label: 'terminal',
                        status: ActivityStepStatus.done,
                        text: 'ls -la /srv/backup',
                      ),
                      ActivityStep(
                        id: 'r',
                        kind: ActivityStepKind.reasoning,
                        label: 'reasoning',
                        status: ActivityStepStatus.done,
                        text: _reasoning,
                      ),
                    ],
                  ),
                  const HermesTextBlock(text: _reasoning),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final worstBackground = [c.background, c.surface, c.surfaceVariant];
      var checked = 0;
      for (final element in find.byType(RichText).evaluate()) {
        final widget = element.widget as RichText;
        void visit(InlineSpan span, TextStyle inherited) {
          if (span is! TextSpan) return;
          final style = inherited.merge(span.style);
          final text = span.text ?? '';
          final isIcon = (style.fontFamily ?? '').contains('MaterialIcons');
          if (text.trim().isNotEmpty && !isIcon && style.color != null) {
            final ink = ThemeContrast.composite(style.color!, c.background);
            checked++;
            for (final bg in worstBackground) {
              final r = ThemeContrast.ratio(ink, bg);
              if (r < _aa) {
                fails.add(
                  '${preset.id} "${text.trim().split('\n').first}" '
                  '${r.toStringAsFixed(2)}',
                );
                break;
              }
            }
          }
          for (final child in span.children ?? const <InlineSpan>[]) {
            visit(child, style);
          }
        }

        visit(widget.text, const TextStyle());
      }
      expect(checked, greaterThan(5), reason: preset.id);
    }
    expect(fails, isEmpty, reason: fails.join('\n'));
  });

  // Tertiary text (timestamps, separators, diff hunk headers) is read, not
  // disabled: it must reach AA on every surface in every theme too.
  testWidgets('tertiary metadata paints readable ink in every theme', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fails = <String>[];
    // The Bots home (Dots style) replaced the roster rows: its tertiary
    // metadata is the section counter ("Team 3", "Rooms 2").
    MissionAgent agent(String name, {bool main = false}) => MissionAgent(
      profile: AgentProfile(name: name, isDefault: main),
      status: MissionAgentStatus.idle,
      statusEvidence: '',
      usage: const MissionUsage(),
    );
    final bots = [
      BotRosterEntry(
        agent: agent('default', main: true),
        signal: BotFaceSignal.idle,
        preview: 'ok',
      ),
      for (final name in ['astra', 'forja', 'radar'])
        BotRosterEntry(
          agent: agent(name),
          signal: BotFaceSignal.idle,
          preview: 'ok',
        ),
    ];
    final rooms = [
      for (final id in ['r1', 'r2'])
        RoomRosterEntry(
          roomKey: 'hosted:$id',
          hostedRoomId: id,
          title: 'Design Review $id',
          members: const [RoomRosterMember('builder', null)],
          preview: 'ok',
        ),
    ];
    for (final preset in AppTheme.presets) {
      final theme = AppTheme.fromId(preset.id);
      final c = theme.hermes;
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(preset.id),
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: theme,
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: DotsHomeView(
                    bots: bots,
                    rooms: rooms,
                    avatarCache: null,
                    searchOpen: ValueNotifier(false),
                    onOpenBot: (_) {},
                    onBotActions: (_) {},
                    onOpenRoom: (_) {},
                  ),
                ),
                SizedBox(
                  height: 160,
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        const ChatMarkdownBody(data: '```diff\n$_diff\n```'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final surfaces = [c.background, c.surface, c.surfaceVariant];
      final seen = <String>{};
      final rich = find.descendant(
        of: find.byType(Scaffold),
        matching: find.byType(RichText),
      );
      final inAvatar = find
          .descendant(
            of: find.byType(LivingBotFace),
            matching: find.byType(RichText),
          )
          .evaluate()
          .toSet();
      for (final element in rich.evaluate()) {
        if (inAvatar.contains(element)) continue;
        final widget = element.widget as RichText;
        void visit(InlineSpan span, TextStyle inherited) {
          if (span is! TextSpan) return;
          final style = inherited.merge(span.style);
          final text = (span.text ?? '').trim();
          final isIcon = (style.fontFamily ?? '').contains('MaterialIcons');
          if (_tertiary.contains(text) && !isIcon && style.color != null) {
            seen.add(text);
            final ink = ThemeContrast.composite(style.color!, c.background);
            for (final bg in surfaces) {
              final r = ThemeContrast.ratio(ink, bg);
              if (r < _aa) {
                fails.add('${preset.id} "$text" ${r.toStringAsFixed(2)}');
                break;
              }
            }
          }
          for (final child in span.children ?? const <InlineSpan>[]) {
            visit(child, style);
          }
        }

        visit(widget.text, const TextStyle());
      }
      // The metadata under test really rendered in this theme.
      expect(seen, _tertiary, reason: preset.id);
    }
    expect(fails, isEmpty, reason: fails.join('\n'));
  });
}

const String _diff = '@@ -1,2 +1,2 @@\n keep\n-old\n+new';

/// Tertiary runs of the fixture: the Bots home section counters (three team
/// bots, two rooms) and the diff hunk header.
const Set<String> _tertiary = {'3', '2', '@@ -1,2 +1,2 @@'};
