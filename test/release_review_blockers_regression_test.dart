import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat_surface_coordinator.dart';
import 'package:hermes_android/core/widgets/dock.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _host(ChatSurfaceCoordinator coordinator) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: MediaQuery(
    data: const MediaQueryData(
      size: Size(390, 844),
      padding: EdgeInsets.only(bottom: 24),
      viewPadding: EdgeInsets.only(bottom: 24),
      viewInsets: EdgeInsets.only(bottom: 280),
    ),
    child: Scaffold(
      resizeToAvoidBottomInset: true,
      // Montado igual que en Mission Control: perfil Bots, el coordinador de
      // la superficie y su mismo inset inferior.
      body: Dock(
        profileId: DockProfileId.bots,
        coordinator: coordinator,
        bottomInset: coordinator.bottomInset,
        actions: const {
          DockItemId.home: DockItemAction(),
          DockItemId.bots: DockItemAction(selected: true),
          DockItemId.work: DockItemAction(),
          DockItemId.create: DockItemAction(),
        },
        createOrbits: [
          DockCreateOrbit(
            controlKey: const ValueKey('bot-mode-create-bot'),
            label: 'Nuevo bot',
            icon: Icons.smart_toy_outlined,
            onTap: () {},
          ),
          DockCreateOrbit(
            controlKey: const ValueKey('bot-mode-create-room'),
            label: 'Nueva sala',
            icon: Icons.groups_2_outlined,
            onTap: () {},
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('owning dock clears safe bottom in IME-resized viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final coordinator = ChatSurfaceCoordinator(routeOwner: 'review-red');
    addTearDown(coordinator.dispose);
    coordinator.updateViewport(
      postLayoutSize: const Size(390, 564),
      safePadding: const EdgeInsets.only(bottom: 24),
      viewInsets: const EdgeInsets.only(bottom: 280),
      textScale: 1,
      reducedMotion: false,
    );
    await tester.pumpWidget(_host(coordinator));
    await tester.pumpAndSettle();
    final dock = tester.getRect(
      find.byKey(const ValueKey('bot-mode-floating-dock')),
    );
    expect(564 - dock.bottom, 34, reason: '24dp safe bottom + 10dp gap');
    expect(coordinator.scrollReservation, 94);
  });

  test('owning screen declares no sub-48 interactive constraints', () {
    final source = File(
      'lib/core/screens/mission_control_screen.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('minimumSize: const Size.square(44)')));
    expect(source, isNot(contains('minimumSize: const Size(44, 40)')));
    expect(source, isNot(contains('minWidth: 44')));
    expect(source, isNot(contains('minHeight: 44')));
  });

  testWidgets('owning create orbs paint exterior labels', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final coordinator = ChatSurfaceCoordinator(routeOwner: 'review-red');
    addTearDown(coordinator.dispose);
    coordinator.updateViewport(
      postLayoutSize: const Size(390, 564),
      safePadding: const EdgeInsets.only(bottom: 24),
      viewInsets: const EdgeInsets.only(bottom: 280),
      textScale: 1,
      reducedMotion: false,
    );
    await tester.pumpWidget(_host(coordinator));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bot-mode-dock-create')));
    await tester.pumpAndSettle();
    expect(find.text('Nuevo bot'), findsOneWidget);
    expect(find.text('Nueva sala'), findsOneWidget);
  });
}
