import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/activity_panel.dart';
import 'package:hermes_android/core/widgets/activity_side_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

// The activity panel on tablets: in an expanded window whose chat has room
// for it, the pill opens a persistent ~360dp side panel on the right instead
// of the modal that grows out of the pill. The composer and the approval
// area stay beside it, never under it. Phones and medium windows keep the
// modal.

final DateTime _t0 = DateTime(2026, 9, 21, 12);

ActivityStep _step(String label, ActivityStepStatus status) => ActivityStep(
  id: 'id-$label',
  kind: ActivityStepKind.tool,
  label: label,
  status: status,
  startedAt: _t0,
  duration: status == ActivityStepStatus.running
      ? null
      : const Duration(milliseconds: 700),
);

ActivitySnapshot _live(String current) => ActivitySnapshot(
  turnActive: true,
  turnStartedAt: _t0,
  current: _step(current, ActivityStepStatus.running),
  done: [_step('read_file', ActivityStepStatus.done)],
);

class _Chat extends StatefulWidget {
  final ActivitySnapshot initial;
  final double? width;
  const _Chat({required this.initial, this.width, super.key});
  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  late ActivitySnapshot snapshot = widget.initial;
  void set(ActivitySnapshot next) => setState(() => snapshot = next);

  @override
  Widget build(BuildContext context) {
    final chat = ActivitySidePanelHost(
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              key: const ValueKey('transcript'),
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: const SizedBox.expand(),
            ),
          ),
          ActivityPillHost(
            snapshot: snapshot,
            clock: () => _t0.add(const Duration(seconds: 10)),
            revealAfter: Duration.zero,
          ),
          const SizedBox(
            key: ValueKey('approval'),
            height: 64,
            child: Text('approve?'),
          ),
          const SizedBox(
            key: ValueKey('composer'),
            height: 56,
            child: TextField(),
          ),
        ],
      ),
    );
    return Scaffold(
      body: widget.width == null
          ? chat
          : Align(
              alignment: Alignment.centerRight,
              child: SizedBox(width: widget.width, child: chat),
            ),
    );
  }
}

Finder get _pill => find.byKey(const ValueKey('activity-pill'));
Finder get _modal => find.byKey(const ValueKey('activity-panel'));
Finder get _side => find.byKey(const ValueKey('activity-side-panel'));
Finder get _close => find.byKey(const ValueKey('activity-side-panel-close'));

Future<GlobalKey<_ChatState>> _pump(
  WidgetTester tester,
  Size size, {
  double? width,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<_ChatState>();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        Strings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.hermesRedDark,
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: home!,
      ),
      home: _Chat(key: key, initial: _live('terminal'), width: width),
    ),
  );
  await tester.pump();
  return key;
}

Future<void> _tapPill(WidgetTester tester) async {
  await tester.tap(_pill);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _expectBeside(WidgetTester tester) {
  final panel = tester.getRect(_side);
  for (final key in const ['composer', 'approval']) {
    final rect = tester.getRect(find.byKey(ValueKey(key)));
    expect(rect.overlaps(panel), isFalse, reason: '$key under the panel');
    expect(rect.right, lessThanOrEqualTo(panel.left), reason: key);
  }
  expect(tester.getRect(_pill).overlaps(panel), isFalse, reason: 'pill');
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  for (final size in const [Size(1280, 800), Size(1024, 768)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$label: the pill opens a 360dp side panel, not the modal', (
      tester,
    ) async {
      await _pump(tester, size);
      await _tapPill(tester);

      expect(_side, findsOneWidget);
      expect(_modal, findsNothing);
      final panel = tester.getRect(_side);
      expect(panel.width, closeTo(360, 1));
      expect(panel.right, size.width);
      expect(panel.top, 0);
      expect(panel.bottom, size.height);
      _expectBeside(tester);
      expect(
        find.descendant(of: _side, matching: find.textContaining('terminal')),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });

    testWidgets('$label: the side panel is persistent and closable', (
      tester,
    ) async {
      await _pump(tester, size);
      await _tapPill(tester);

      // A tap in the conversation does not dismiss it (it is not modal) and
      // the composer keeps working beside it.
      await tester.tap(find.byKey(const ValueKey('transcript')));
      await tester.pump();
      expect(_side, findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'still typing');
      await tester.pump();
      expect(find.text('still typing'), findsOneWidget);
      expect(_side, findsOneWidget);

      await tester.tap(_close);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_side, findsNothing);
      expect(_modal, findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('composer'))).right,
        size.width,
        reason: 'the chat takes the width back',
      );

      // The pill toggles it as well.
      await _tapPill(tester);
      expect(_side, findsOneWidget);
      await _tapPill(tester);
      expect(_side, findsNothing);
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });
  }

  testWidgets('the side panel follows the live activity', (tester) async {
    final chat = await _pump(tester, const Size(1280, 800));
    await _tapPill(tester);

    chat.currentState!.set(_live('web_search'));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(of: _side, matching: find.textContaining('web_search')),
      findsWidgets,
    );

    // Nothing live any more: the panel retires, like the modal.
    chat.currentState!.set(const ActivitySnapshot());
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_side, findsNothing);
    expect(tester.takeException(), isNull);
    await _dispose(tester);
  });

  testWidgets('phone 411x915 keeps the modal panel', (tester) async {
    await _pump(tester, const Size(411, 915));
    await _tapPill(tester);

    expect(_modal, findsOneWidget);
    expect(_side, findsNothing);
    expect(tester.takeException(), isNull);
    await _dispose(tester);
  });

  testWidgets('medium 700x1000 keeps the modal panel', (tester) async {
    await _pump(tester, const Size(700, 1000));
    await _tapPill(tester);

    expect(_modal, findsOneWidget);
    expect(_side, findsNothing);
    await _dispose(tester);
  });

  testWidgets('expanded window but a narrow chat (list pane beside it) keeps '
      'the modal', (tester) async {
    await _pump(tester, const Size(1024, 768), width: 580);
    await _tapPill(tester);

    expect(_modal, findsOneWidget);
    expect(_side, findsNothing);
    await _dispose(tester);
  });

  testWidgets('rotation 1280x800 -> 800x1280 -> back keeps it open', (
    tester,
  ) async {
    await _pump(tester, const Size(1280, 800));
    await _tapPill(tester);
    expect(_side, findsOneWidget);

    await _resize(tester, const Size(800, 1280));
    expect(_side, findsNothing, reason: 'no room: the chat gets the width');
    expect(tester.getRect(find.byKey(const ValueKey('composer'))).right, 800);
    expect(tester.takeException(), isNull);

    await _resize(tester, const Size(1280, 800));
    expect(_side, findsOneWidget);
    _expectBeside(tester);
    expect(tester.takeException(), isNull);
    await _dispose(tester);
  });

  testWidgets('a medium window opens the modal and forgets a docked panel', (
    tester,
  ) async {
    await _pump(tester, const Size(1280, 800));
    await _tapPill(tester);
    await _resize(tester, const Size(800, 1280));

    await _tapPill(tester);
    expect(_modal, findsOneWidget);
    Navigator.of(tester.element(_modal)).pop();
    await tester.pump(const Duration(milliseconds: 400));

    await _resize(tester, const Size(1280, 800));
    expect(_side, findsNothing, reason: 'one panel at a time');
    expect(_modal, findsNothing);
    await _dispose(tester);
  });
}
