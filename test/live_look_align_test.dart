import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/live_turn_tokens.dart';
import 'package:hermes_android/core/widgets/chat/turn_activity_pill.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/core/widgets/message_avatar_header.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The live turn under a header with and without the profile's face: the
// connector hangs from the card's left edge (not from the screen's), and
// the face stays level with the name however tall the live block grows.

final _start = DateTime(2026, 11, 9);
const _face = 24.0;

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromMode(AppThemeMode.dark),
  builder: (context, body) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: body!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 380, child: SingleChildScrollView(child: child)),
    ),
  ),
);

Widget _turn({required bool face}) => LiveTurnScope(
  inlineActivity: true,
  status: LiveTurnStatus(
    active: true,
    startedAt: _start,
    headline: 'Pensando…',
  ),
  clock: () => _start.add(const Duration(seconds: 30)),
  child: ThinkingTraceCard(
    active: true,
    stepCards: true,
    events: [
      for (var i = 0; i < 3; i++)
        ChatTraceEvent(
          id: 't$i',
          label: const ['terminal', 'read_file', 'web_search'][i],
          status: i == 2 ? 'running' : 'completed',
          detail: 'objetivo $i',
          startedAt: _start,
        ),
    ],
    headerBuilder: (_, summary, details) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MessageAvatarHeader(
          name: 'xPeta',
          mascotSize: _face,
          mascot: face
              ? const SizedBox.square(key: ValueKey('face'), dimension: _face)
              : null,
          subtitle: summary,
        ),
        face
            ? AvatarDetailsIndent(mascotSize: _face, child: details)
            : details,
      ],
    ),
  ),
);

void main() {
  for (final face in [false, true]) {
    testWidgets(
      'the connector hangs ${HermesLiveTurn.connectorInset} dp from the '
      "card's edge ${face ? 'with' : 'without'} the face",
      (tester) async {
        await tester.pumpWidget(_host(_turn(face: face)));
        await tester.pump();
        final card = tester.getTopLeft(
          find.byType(TurnInlineActivity),
        );
        final elbow = tester.getTopLeft(
          find.byKey(const ValueKey('live-turn-elbow-t0')),
        );
        // The painter draws the line at connectorInset inside its box.
        expect(elbow.dx, card.dx);
        expect(elbow.dx, face ? avatarSlotWidthFor(_face) : 0);
      },
    );
  }

  testWidgets('the face is level with the name, not centred on the block', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_turn(face: true)));
    await tester.pump();
    final face = tester.getRect(find.byKey(const ValueKey('face')));
    final name = tester.getRect(
      find.byKey(const ValueKey('assistant-header-name')),
    );
    expect(face.top, name.top);
  });
}
