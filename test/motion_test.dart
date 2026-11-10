import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/motion_prefs.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_tree_rows.dart';
import 'package:hermes_android/core/widgets/hermes_shiny_text.dart';
import 'package:hermes_android/core/widgets/hermes_streaming_cursor.dart';
import 'package:hermes_android/core/widgets/hermes_theme_reveal.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
  locale: const Locale('en'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: child!,
  ),
  home: Scaffold(body: child),
);

Future<MotionPrefs> _prefs([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return MotionPrefs.load(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HermesShinyText', () {
    const shiny = HermesShinyText(child: Text('Thinking'));

    testWidgets('runs and keeps its text', (tester) async {
      await tester.pumpWidget(_host(shiny));
      await tester.pump();
      expect(find.text('Thinking'), findsOneWidget);
      expect(tester.hasRunningAnimations, isTrue);
    });

    testWidgets('does not start with reduced motion, and resumes', (
      tester,
    ) async {
      await tester.pumpWidget(_host(shiny, disableAnimations: true));
      await tester.pump();
      expect(find.text('Thinking'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(_host(shiny));
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
    });

    testWidgets('stays still when it is not active', (tester) async {
      await tester.pumpWidget(
        _host(const HermesShinyText(active: false, child: Text('Done'))),
      );
      await tester.pump();
      expect(find.text('Done'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('MotionPrefs', () {
    test('the cursor starts off and persists', () async {
      final prefs = await _prefs();
      expect(prefs.cursor, StreamingCursorStyle.off);

      await prefs.setCursor(StreamingCursorStyle.block);
      final reloaded = await MotionPrefs.load(
        await SharedPreferences.getInstance(),
      );
      expect(reloaded.cursor, StreamingCursorStyle.block);
    });

    test('an unknown stored cursor reads as off', () async {
      final prefs = await _prefs({MotionPrefs.cursorKey: 'sparkles'});
      expect(prefs.cursor, StreamingCursorStyle.off);
    });
  });

  group('HermesStreamingCursor', () {
    Widget answer(MotionPrefs prefs) => Column(
      children: [
        const Text('Hello world'),
        HermesStreamingCursor(prefs: prefs),
      ],
    );

    testWidgets('draws nothing by default', (tester) async {
      final prefs = await _prefs();
      await tester.pumpWidget(_host(answer(prefs)));
      await tester.pump();
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.byKey(const ValueKey('streaming-cursor-line')), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    for (final style in [
      StreamingCursorStyle.line,
      StreamingCursorStyle.block,
      StreamingCursorStyle.underscore,
    ]) {
      testWidgets('${style.name} blinks beside the untouched text', (
        tester,
      ) async {
        final prefs = await _prefs({MotionPrefs.cursorKey: style.name});
        await tester.pumpWidget(_host(answer(prefs)));
        await tester.pump();
        expect(find.text('Hello world'), findsOneWidget);
        expect(
          find.byKey(ValueKey('streaming-cursor-${style.name}')),
          findsOneWidget,
        );
        expect(tester.hasRunningAnimations, isTrue);
      });
    }

    testWidgets('is static for reduced motion and follows the setting', (
      tester,
    ) async {
      final prefs = await _prefs();
      await tester.pumpWidget(_host(answer(prefs), disableAnimations: true));
      await prefs.setCursor(StreamingCursorStyle.line);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('streaming-cursor-line')),
        findsOneWidget,
      );
      expect(tester.hasRunningAnimations, isFalse);

      await prefs.setCursor(StreamingCursorStyle.off);
      await tester.pump();
      expect(find.byKey(const ValueKey('streaming-cursor-line')), findsNothing);
    });
  });

  group('file tree', () {
    test('folders come first, then by name without case', () {
      final names =
          <(bool, String)>[
            (false, 'b.txt'),
            (true, 'src'),
            (false, 'A.md'),
            (true, 'Assets'),
          ]..sort(
            (a, b) => compareFileTreeNames(
              aIsDirectory: a.$1,
              aName: a.$2,
              bIsDirectory: b.$1,
              bName: b.$2,
            ),
          );
      expect(names.map((e) => e.$2), ['Assets', 'src', 'A.md', 'b.txt']);
    });

    List<FileTreeRow<(bool, String)>> flatten(
      Set<String> expanded,
      Map<String, List<(bool, String)>> children,
    ) => flattenFileTree<(bool, String)>(
      roots: const [(true, 'lib'), (false, 'README.md')],
      rootPath: '/p',
      isDirectory: (e) => e.$1,
      nameOf: (e) => e.$2,
      expanded: expanded,
      children: children,
      join: (base, name) => '$base/$name',
    );

    test('opening a folder lists its children right under it', () {
      final children = {
        '/p/lib': const [(true, 'core'), (false, 'main.dart')],
      };
      expect(flatten({}, children).map((r) => r.path), [
        '/p/lib',
        '/p/README.md',
      ]);
      final open = flatten({'/p/lib'}, children);
      expect(open.map((r) => r.path), [
        '/p/lib',
        '/p/lib/core',
        '/p/lib/main.dart',
        '/p/README.md',
      ]);
      expect(open.map((r) => r.depth), [0, 1, 1, 0]);
      expect(open.first.expanded, isTrue);
      expect(open.last.expanded, isFalse);
    });

    test('a folder not listed yet shows nothing under it', () {
      expect(flatten({'/p/lib'}, {}).map((r) => r.path), [
        '/p/lib',
        '/p/README.md',
      ]);
    });

    testWidgets('the toggle folds and unfolds, and names its action', (
      tester,
    ) async {
      var expanded = false;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => HermesTreeToggle(
              expanded: expanded,
              onTap: () => setState(() => expanded = !expanded),
            ),
          ),
        ),
      );
      expect(find.bySemanticsLabel('Expand folder'), findsOneWidget);
      await tester.tap(find.byType(HermesTreeToggle));
      await tester.pumpAndSettle();
      expect(expanded, isTrue);
      expect(find.bySemanticsLabel('Collapse folder'), findsOneWidget);
    });

    testWidgets('the toggle turns without animating for reduced motion', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          HermesTreeToggle(expanded: true, onTap: () {}),
          disableAnimations: true,
        ),
      );
      final rotation = tester.widget<AnimatedRotation>(
        find.byType(AnimatedRotation),
      );
      expect(rotation.duration, Duration.zero);
      expect(rotation.turns, 0.25);
    });

    testWidgets('guides draw only below the first level', (tester) async {
      await tester.pumpWidget(
        _host(
          const Column(
            children: [
              HermesTreeGuide(depth: 0, child: SizedBox(height: 20)),
              HermesTreeGuide(depth: 2, child: SizedBox(height: 20)),
            ],
          ),
        ),
      );
      final guides = find.descendant(
        of: find.byType(HermesTreeGuide),
        matching: find.byType(CustomPaint),
      );
      expect(guides, findsNWidgets(1));
    });
  });

  group('theme reveal', () {
    test('the circle math covers the screen and clips its hole', () {
      const size = Size(100, 200);
      expect(
        themeRevealMaxRadius(size, Offset.zero),
        closeTo(const Offset(100, 200).distance, 0.001),
      );
      final path = themeRevealClipPath(size, const Offset(50, 100), 20);
      expect(path.contains(const Offset(50, 100)), isFalse);
      expect(path.contains(const Offset(5, 5)), isTrue);
      expect(
        themeRevealClipPath(
          size,
          const Offset(50, 100),
          0,
        ).contains(const Offset(50, 100)),
        isTrue,
      );
    });

    testWidgets('it is always on, even over a stored "off" from an old build', (
      tester,
    ) async {
      // Older builds had a switch and saved it under this key; it no longer
      // counts: the host has no setting at all.
      await _prefs({'motion_theme_reveal': false});
      var changed = 0;
      late BuildContext inside;
      await tester.pumpWidget(
        _host(
          HermesThemeRevealHost(
            child: Builder(
              builder: (context) {
                inside = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      final host = tester.state<HermesThemeRevealHostState>(
        find.byType(HermesThemeRevealHost),
      );
      late Future<void> running;
      await tester.runAsync(() async {
        running = HermesThemeReveal.run(inside, () async => changed++);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(changed, 1);
      expect(host.revealing, isTrue, reason: 'the circle is on screen');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.runAsync(() => running);
      await tester.pump();
      expect(host.revealing, isFalse);
    });

    testWidgets('reduced motion skips it: the change just runs', (
      tester,
    ) async {
      var changed = 0;
      late BuildContext inside;
      await tester.pumpWidget(
        _host(
          HermesThemeRevealHost(
            child: Builder(
              builder: (context) {
                inside = context;
                return const SizedBox.expand();
              },
            ),
          ),
          disableAnimations: true,
        ),
      );
      await HermesThemeReveal.run(inside, () async => changed++);
      expect(changed, 1);
      expect(
        tester
            .state<HermesThemeRevealHostState>(
              find.byType(HermesThemeRevealHost),
            )
            .revealing,
        isFalse,
      );
    });

    testWidgets('without a host the change still runs', (tester) async {
      late BuildContext inside;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              inside = context;
              return const SizedBox();
            },
          ),
        ),
      );
      var changed = 0;
      await HermesThemeReveal.run(inside, () async => changed++);
      expect(changed, 1);
    });
  });
}
