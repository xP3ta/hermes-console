// The list of installed skills: no card, bold name over two lines of
// description at most, a hairline between rows, the switch in one place. And
// the hand-off to the chat: the real launcher pushes a NEW chat of the profile
// with the request already written.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_screen.dart';
import 'package:hermes_android/core/capabilities/capability_plain_rows.dart';
import 'package:hermes_android/core/capabilities/las_chat.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/chat_screen.dart' show ChatScreen;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_row_switch.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import '../support/inter_font.dart';
import 'capabilities_fakes.dart';

ScriptedRest _server() => ScriptedRest()
  ..gets['skills'] = [
    {
      'name': 'docx',
      'description': 'Create, read and edit Word files.',
      'enabled': true,
      'provenance': 'bundled',
    },
    {
      'name': 'flutter-projection-identity-diagnostics-for-streaming-rows',
      'description':
          'Use when Flutter streaming loses a projected row identity and '
          'the list shows the same message twice after a reconnect, which '
          'needs a long careful look at keys and ids.',
      'enabled': false,
      'provenance': 'agent',
    },
    {'name': 'quiet', 'enabled': true, 'provenance': 'agent'},
  ]
  ..gets['skills/hub/official'] = {'skills': <Object>[]};

Future<void> _open(WidgetTester tester, {double scale = 1}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: CapabilitiesScreen(
        repository: repoOf(_server()),
        initialSegment: CapabilitiesSegment.installed,
        searchDebounce: Duration.zero,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadInterFont);

  group('the list', () {
    testWidgets('rows without a card, bold name, two lines at most', (
      tester,
    ) async {
      await _open(tester);
      expect(find.byType(CapabilityPlainList), findsOneWidget);
      expect(find.byType(CapabilityPlainRow), findsNWidgets(3));
      // One hairline between rows, none after the last.
      expect(
        find.descendant(
          of: find.byType(CapabilityPlainList),
          matching: find.byType(Divider),
        ),
        findsNWidgets(2),
      );
      final long = find.widgetWithText(
        CapabilityPlainRow,
        'flutter-projection-identity-diagnostics-for-streaming-rows',
      );
      final texts = tester.widgetList<Text>(
        find.descendant(of: long, matching: find.byType(Text)),
      );
      final title = texts.first;
      expect(title.style?.fontWeight, FontWeight.w700);
      expect(title.maxLines, 2);
      expect(title.overflow, TextOverflow.ellipsis);
      final description = texts.elementAt(1);
      expect(description.maxLines, 2);
      expect(description.overflow, TextOverflow.ellipsis);
      // A row with no description says where the skill comes from instead.
      expect(
        find.descendant(
          of: find.widgetWithText(CapabilityPlainRow, 'quiet'),
          matching: find.text('Usuario'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('every switch sits on the same line, whatever the text', (
      tester,
    ) async {
      await _open(tester);
      final slots = find.byType(HermesRowSwitch);
      expect(slots, findsNWidgets(3));
      final right = [
        for (final element in slots.evaluate())
          tester.getTopRight(find.byWidget(element.widget)).dx,
      ];
      expect(right.toSet().length, 1, reason: '$right');
      // The hairline is inset by exactly the text's own margin: it starts
      // where the text starts.
      final textLeft = tester
          .getTopLeft(
            find.descendant(
              of: find.widgetWithText(CapabilityPlainRow, 'docx'),
              matching: find.text('docx'),
            ),
          )
          .dx;
      final dividerLeft = tester
          .getTopLeft(
            find
                .descendant(
                  of: find.byType(CapabilityPlainList),
                  matching: find.byType(Divider),
                )
                .first,
          )
          .dx;
      expect(dividerLeft + 12, textLeft);
    });

    testWidgets('a long name and description fit at double text', (
      tester,
    ) async {
      await _open(tester, scale: 2);
      expect(tester.takeException(), isNull);
      final box = tester.getRect(
        find.widgetWithText(
          CapabilityPlainRow,
          'flutter-projection-identity-diagnostics-for-streaming-rows',
        ),
      );
      expect(box.width, lessThanOrEqualTo(390));
    });
  });

  group('the chat hand-off', () {
    testWidgets('pushes a new chat of the profile with the request typed in', (
      tester,
    ) async {
      final pushed = <Route<dynamic>>[];
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          navigatorObservers: [_Spy(pushed)],
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final connection = SavedConnection(
        id: 'c1',
        label: 'Home',
        host: 'hermes.local',
        port: 8642,
        apiKey: 'k',
      );
      final launch = lasChatFor(connection, 'ana')!;
      // Not awaited and not pumped: the chat itself is not built here.
      final done = launch(context, 'the request');
      final route = pushed.last as MaterialPageRoute<dynamic>;
      final chat = route.builder(context) as ChatScreen;
      expect(chat.initialPrompt, 'the request');
      expect(chat.session.profile, 'ana');
      expect(chat.session.title, 'Learn a skill');
      expect(chat.session.messageCount, 0);
      expect(chat.connection.id, 'c1');
      route.navigator!.pop();
      await done;
    });

    testWidgets('without a profile it is the default one', (tester) async {
      final pushed = <Route<dynamic>>[];
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          navigatorObservers: [_Spy(pushed)],
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final connection = SavedConnection(
        id: 'c1',
        label: 'Home',
        host: 'hermes.local',
        port: 8642,
        apiKey: 'k',
      );
      final done = lasChatFor(connection, '  ')!(context, 'x');
      final route = pushed.last as MaterialPageRoute<dynamic>;
      final chat = route.builder(context) as ChatScreen;
      expect(chat.session.profile, anyOf(isNull, isEmpty));
      route.navigator!.pop();
      await done;
    });
  });
}

class _Spy extends NavigatorObserver {
  final List<Route<dynamic>> pushed;
  _Spy(this.pushed);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);
}
