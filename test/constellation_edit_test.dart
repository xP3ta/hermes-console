// Editing a memory node from the constellation: the detail card offers
// "Edit" only for memory entries the server placed in a file, and a saved
// edit reads the map again.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/memory/constellation_graph.dart';
import 'package:hermes_android/core/memory/constellation_view.dart';
import 'package:hermes_android/core/screens/constellation_screen.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Map<String, dynamic> _one(Map<String, Object?> node) => {
  'nodes': [node],
  'edges': const <Object?>[],
};

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> graph,
  Future<bool> Function(ConstellationNode)? onEdit,
  void Function() onLoad,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.fromId('dark'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: ConstellationScreen(
        loadGraph: () async {
          onLoad();
          return graph;
        },
        onEditNode: onEdit,
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tapAt(tester.getCenter(find.byType(ConstellationView)));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('a memory node offers Edit and a saved edit reloads the map', (
    tester,
  ) async {
    var loads = 0;
    ConstellationNode? edited;
    await _pump(
      tester,
      _one({
        'id': 'memory:memory:0:abc',
        'label': 'Prefers short answers',
        'kind': 'memory',
        'memorySource': 'memory',
      }),
      (node) async {
        edited = node;
        return true;
      },
      () => loads++,
    );
    expect(find.text('Prefers short answers'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('constellation-edit-node')));
    await tester.pump(const Duration(seconds: 2));
    expect(edited?.id, 'memory:memory:0:abc');
    expect(edited?.source, 'memory');
    expect(loads, 2);
  });

  testWidgets('no Edit for skills or without an editor', (tester) async {
    await _pump(
      tester,
      _one({'id': 'skill:deploy', 'label': 'deploy', 'kind': 'skill'}),
      (node) async => true,
      () {},
    );
    expect(find.text('deploy'), findsOneWidget);
    expect(find.byKey(const ValueKey('constellation-edit-node')), findsNothing);
  });
}
