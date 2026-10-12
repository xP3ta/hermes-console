import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_presence_level.dart';
import 'package:hermes_android/core/companion/render/companion_status_indicator.dart';
import 'package:hermes_android/core/companion/render/companion_view.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/companion/models/companion_mood.dart';
import 'package:hermes_android/core/widgets/hermes_status_indicator.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  CompanionController? companion, {
  CompanionMood mood = CompanionMood.thinking,
  bool? animate,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: CompanionStatusIndicator(
            companion: companion,
            mood: mood,
            animate: animate,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('sin controller → cae al pulso cuadrado (sin mascota)', (
    tester,
  ) async {
    await _pump(tester, null);
    expect(find.byType(HermesStatusPulse), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(CompanionView), findsNothing);
  });

  testWidgets('presencia off → cae al pulso cuadrado', (tester) async {
    final companion = await _build();
    await companion.setPresenceLevel(CompanionPresenceLevel.off);
    await _pump(tester, companion);
    expect(find.byType(HermesStatusPulse), findsOneWidget);
    expect(find.byType(CompanionView), findsNothing);
  });

  testWidgets('Companion deshabilitado → cae al pulso cuadrado', (
    tester,
  ) async {
    final companion = await _build();
    await companion.setEnabled(false);
    await _pump(tester, companion);
    expect(find.byType(HermesStatusPulse), findsOneWidget);
    expect(find.byType(CompanionView), findsNothing);
  });

  testWidgets('presence on, no pet of its own → conserva el pulso cuadrado', (
    tester,
  ) async {
    // What everybody has until he chooses a pet (and the old "Mínima").
    final companion = await _build(stored: null);
    await _pump(tester, companion);
    expect(find.byType(HermesStatusPulse), findsOneWidget);
    expect(find.byType(CompanionView), findsNothing);
  });

  testWidgets('presencia full → muestra la mascota (no el pulso)', (
    tester,
  ) async {
    final companion = await _build();
    await companion.setPresenceLevel(CompanionPresenceLevel.full);
    await _pump(tester, companion);
    expect(find.byType(CompanionView), findsOneWidget);
    expect(find.byType(HermesStatusPulse), findsNothing);
  });

  testWidgets('resultado histórico conserva mood en un fotograma estático', (
    tester,
  ) async {
    final companion = await _build();
    await companion.setPresenceLevel(CompanionPresenceLevel.full);
    await _pump(tester, companion, mood: CompanionMood.success, animate: false);

    final view = tester.widget<CompanionView>(find.byType(CompanionView));
    expect(view.mood, CompanionMood.success);
    expect(view.animate, isFalse);
  });

  testWidgets('mood de resultado → conserva el indicador clásico', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: CompanionStatusIndicator(
              companion: null,
              mood: CompanionMood.error,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(HermesStatusIndicator), findsOneWidget);
    expect(find.byType(HermesStatusPulse), findsNothing);
  });
}
