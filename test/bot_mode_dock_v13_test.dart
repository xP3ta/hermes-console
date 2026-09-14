import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/bot_mode_dock.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host({
  required int selectedIndex,
  required ValueChanged<int> onDestination,
  VoidCallback? onCreateBot,
  VoidCallback? onCreateRoom,
  double textScale = 1,
  bool disableAnimations = false,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: disableAnimations,
      viewInsets: viewInsets,
    ),
    child: child!,
  ),
  home: Scaffold(
    resizeToAvoidBottomInset: true,
    body: BotModeDock(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestination,
      onCreateBot: onCreateBot,
      onCreateRoom: onCreateRoom,
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in const [Size(360, 800), Size(390, 844)]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      testWidgets('floating dock fits $size at ${scale}x with 48dp targets', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          _host(selectedIndex: 0, onDestination: (_) {}, textScale: scale),
        );
        await tester.pumpAndSettle();

        final dock = find.byKey(const ValueKey('bot-mode-floating-dock'));
        expect(tester.getSize(dock).height, 48);
        expect(tester.getSize(dock).width, lessThanOrEqualTo(size.width - 32));
        for (final key in const ['bots', 'create', 'work']) {
          final target = find.byKey(ValueKey('bot-mode-dock-$key'));
          expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('create actions originate at plus and close by action', (
    tester,
  ) async {
    var botCreates = 0;
    var roomCreates = 0;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        selectedIndex: 0,
        onDestination: (_) {},
        onCreateBot: () => botCreates++,
        onCreateRoom: () => roomCreates++,
      ),
    );
    await tester.pump();
    final baselineModalBarriers = find.byType(ModalBarrier).evaluate().length;

    final plus = find.byKey(const ValueKey('bot-mode-dock-create'));
    await tester.tap(plus);
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      find.byKey(const ValueKey('bot-mode-create-actions')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('bot-mode-create-bot')), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-mode-create-room')), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(ModalBarrier), findsNWidgets(baselineModalBarriers));
    expect(
      tester.getCenter(find.byKey(const ValueKey('bot-mode-create-bot'))).dy,
      lessThan(tester.getCenter(plus).dy),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bot-mode-create-bot')));
    await tester.pumpAndSettle();
    expect(botCreates, 1);
    expect(roomCreates, 0);
    expect(find.byKey(const ValueKey('bot-mode-create-actions')), findsNothing);
  });

  testWidgets('outside tap, Back, destination and lifecycle close actions', (
    tester,
  ) async {
    var destination = 0;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        selectedIndex: destination,
        onDestination: (value) => destination = value,
      ),
    );
    await tester.pumpAndSettle();

    Future<void> open() async {
      await tester.tap(find.byKey(const ValueKey('bot-mode-dock-create')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('bot-mode-create-actions')),
        findsOneWidget,
      );
    }

    await open();
    await tester.tapAt(const Offset(10, 100));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-mode-create-actions')), findsNothing);

    await open();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-mode-create-actions')), findsNothing);

    await open();
    await tester.tap(find.byKey(const ValueKey('bot-mode-dock-work')));
    await tester.pumpAndSettle();
    expect(destination, 1);
    expect(find.byKey(const ValueKey('bot-mode-create-actions')), findsNothing);

    await open();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bot-mode-create-actions')), findsNothing);
  });

  testWidgets('reduced motion and IME commit final geometry immediately', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        selectedIndex: 0,
        onDestination: (_) {},
        disableAnimations: true,
        viewInsets: const EdgeInsets.only(bottom: 300),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('bot-mode-dock-create')));
    await tester.pump();

    final dockBottom = tester
        .getBottomLeft(find.byKey(const ValueKey('bot-mode-floating-dock')))
        .dy;
    expect(dockBottom, lessThanOrEqualTo(800 - 300 - 10));
    expect(
      find.byKey(const ValueKey('bot-mode-create-actions')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('create orbs expose labels and return focus to Crear', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        selectedIndex: 0,
        onDestination: (_) {},
        onCreateBot: () {},
        onCreateRoom: () {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bot-mode-dock-create')));
    await tester.pumpAndSettle();

    final semantics = tester.ensureSemantics();
    final botData = tester
        .getSemantics(find.byKey(const ValueKey('bot-mode-create-bot')))
        .getSemanticsData();
    final roomData = tester
        .getSemantics(find.byKey(const ValueKey('bot-mode-create-room')))
        .getSemanticsData();
    expect(botData.label, 'Nuevo bot');
    expect(roomData.label, 'Nueva sala');
    expect(botData.flagsCollection.isButton, isTrue);
    expect(roomData.flagsCollection.isButton, isTrue);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Create bot');

    await tester.tapAt(const Offset(10, 100));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Bot Mode create');
    semantics.dispose();
  });
}
