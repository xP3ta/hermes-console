import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_presence_level.dart';
import 'package:hermes_android/core/companion/render/companion_message_presence.dart';
import 'package:hermes_android/core/companion/render/companion_view.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/companion/models/companion_mood.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Repo sin IO real: sin importadas, catálogo vacío → CompanionView cae a
// la cara del perfil (procedural, sin IO).
class _Repo extends CompanionRepository {
  @override
  Future<Directory?> importedRoot() async => null;
  @override
  Future<List<Companion>> loadAll() async => const [];
}

/// No pet in the catalogue, so nothing can be chosen. [stored] is what the
/// device has for "Presencia": by default the "Completa" of 1.2.14 and
/// earlier, the one stored value that makes a chat show the profile's own
/// face in the pet's place.
Future<CompanionController> _build({String? stored = 'full'}) async {
  SharedPreferences.setMockInitialValues({
    CompanionPreferences.presenceLevelKey: ?stored,
  });
  final prefs = CompanionPreferences(await SharedPreferences.getInstance());
  final companion = CompanionController(_Repo(), prefs);
  await companion.init();
  return companion;
}

Future<void> _pump(
  WidgetTester tester,
  CompanionController companion,
  CompanionMood mood, {
  bool animateIdle = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: CompanionMessagePresence(
            companion: companion,
            mood: mood,
            animateIdle: animateIdle,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('presence on, no pet of its own: nothing stands in for it', (
    tester,
  ) async {
    // What everybody has until he chooses a pet: the chat keeps the face
    // it always had.
    final companion = await _build(stored: null);
    expect(companion.presence, CompanionPresenceLevel.full);
    await _pump(tester, companion, CompanionMood.thinking);
    expect(find.byType(CompanionView), findsNothing);
  });

  testWidgets('nivel full → renderiza la mascota del turno', (tester) async {
    final companion = await _build();
    await companion.setPresenceLevel(CompanionPresenceLevel.full);
    await _pump(tester, companion, CompanionMood.thinking);
    expect(find.byType(CompanionView), findsOneWidget);
  });

  testWidgets('el estado vacío puede mantener el reposo animado', (
    tester,
  ) async {
    final companion = await _build();
    await companion.setPresenceLevel(CompanionPresenceLevel.full);
    await _pump(tester, companion, CompanionMood.idle, animateIdle: true);

    expect(
      tester.widget<CompanionView>(find.byType(CompanionView)).animate,
      true,
    );
  });

  testWidgets('deshabilitado → invisible (shrink)', (tester) async {
    final companion = await _build();
    await companion.setEnabled(false);
    await _pump(tester, companion, CompanionMood.thinking);
    expect(find.byType(CompanionView), findsNothing);
  });

  testWidgets('nivel off → invisible', (tester) async {
    final companion = await _build();
    await companion.setPresenceLevel(CompanionPresenceLevel.off);
    await _pump(tester, companion, CompanionMood.idle);
    expect(find.byType(CompanionView), findsNothing);
  });

  testWidgets('the old "Mínima" without a pet → invisible dentro de Chat', (
    tester,
  ) async {
    final companion = await _build(stored: 'minimal');
    await _pump(tester, companion, CompanionMood.idle);
    expect(find.byType(CompanionView), findsNothing);
  });

  testWidgets('no intercepta gestos: sin GestureDetector propio', (
    tester,
  ) async {
    final companion = await _build();
    await companion.setPresenceLevel(CompanionPresenceLevel.full);
    await _pump(tester, companion, CompanionMood.thinking);
    // La presencia por mensaje es decorativa: no debe envolver en un
    // GestureDetector que robe taps de selección/copy/voz del mensaje.
    expect(
      find.descendant(
        of: find.byType(CompanionMessagePresence),
        matching: find.byType(GestureDetector),
      ),
      findsNothing,
    );
  });

  testWidgets('reduce-motion: monta sin excepción', (tester) async {
    final companion = await _build();
    await companion.setPresenceLevel(CompanionPresenceLevel.full);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Center(
              child: CompanionMessagePresence(
                companion: companion,
                mood: CompanionMood.thinking,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CompanionView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
