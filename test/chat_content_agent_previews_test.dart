import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_content_screen.dart';
import 'package:hermes_android/core/services/chat_content_extractor.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Map<String, dynamic> _call(String id, Object arguments) => {
  'role': 'assistant',
  'content': '',
  'tool_calls': [
    {
      'id': id,
      'type': 'function',
      'function': {
        'name': 'desktop_preview',
        'arguments': jsonEncode(arguments),
      },
    },
  ],
};

Map<String, dynamic> _done(String id) => {
  'role': 'tool',
  'tool_call_id': id,
  'tool_name': 'desktop_preview',
  'content': '{"ok":true}',
};

/// What a chat holds: coalesced, newest first.
List<Map<String, dynamic>> _transcript(List<Object> calls) {
  final rows = <Map<String, dynamic>>[];
  for (var i = 0; i < calls.length; i++) {
    rows
      ..add(_call('c$i', calls[i]))
      ..add(_done('c$i'));
  }
  return coalesceAssistantTurnsNewestFirst(rows.reversed);
}

class _Harness {
  _Harness(this.transcript);

  List<Map<String, dynamic>> transcript;
  final opened = <ChatContentItem>[];
  final launched = <Uri>[];

  Widget app() => MaterialApp(
    theme: AppTheme.hermesRedDark,
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    home: ChatContentScreen(
      transcript: () => transcript,
      hasOlder: () => false,
      loadOlder: () async {},
      onOpenFile: (item) async => opened.add(item),
      launchExternal: (uri) async {
        launched.add(uri);
        return true;
      },
    ),
  );
}

Finder _tile(String label) => find.byKey(ValueKey('sa1215-preview-$label'));

void main() {
  testWidgets('lists what the agent opened with its label and URL', (
    tester,
  ) async {
    final harness = _Harness(
      _transcript([
        {'action': 'open', 'url': 'https://example.com/app', 'label': 'App'},
      ]),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.text('VISTAS PREVIAS DEL AGENTE'), findsOneWidget);
    expect(_tile('App'), findsOneWidget);
    expect(find.text('https://example.com/app'), findsOneWidget);
  });

  testWidgets('tapping a public URL opens the system browser', (tester) async {
    final harness = _Harness(
      _transcript([
        {'action': 'open', 'url': 'www.example.com/docs', 'label': 'Docs'},
      ]),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(_tile('Docs'));
    await tester.pumpAndSettle();

    expect(harness.launched, [Uri.parse('https://www.example.com/docs')]);
    expect(harness.opened, isEmpty);
  });

  testWidgets('localhost and private targets are listed but never opened', (
    tester,
  ) async {
    final targets = [
      'localhost:3000',
      'http://127.0.0.1:5173',
      'http://0.0.0.0:8000',
      'http://[::1]:3000',
      'http://192.168.1.20',
    ];
    final harness = _Harness(
      _transcript([
        for (final url in targets) {'action': 'open', 'url': url, 'label': url},
      ]),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(
      find.text('Solo accesible desde el equipo del servidor'),
      findsNWidgets(targets.length),
    );
    for (final url in targets) {
      await tester.tap(_tile(url));
      await tester.pumpAndSettle();
    }
    expect(harness.launched, isEmpty);
    expect(harness.opened, isEmpty);
  });

  testWidgets('a server file goes through the existing file flow', (
    tester,
  ) async {
    final harness = _Harness(
      _transcript([
        {'action': 'open', 'url': '/srv/site/index.html'},
      ]),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await tester.tap(_tile('index.html'));
    await tester.pumpAndSettle();

    expect(harness.opened.single.value, '/srv/site/index.html');
    expect(harness.launched, isEmpty);
  });

  testWidgets('close removes a preview, close without url removes all', (
    tester,
  ) async {
    final harness = _Harness(
      _transcript([
        {'action': 'open', 'url': 'https://example.com/a', 'label': 'A'},
        {'action': 'open', 'url': 'https://example.com/b', 'label': 'B'},
        {'action': 'close', 'url': 'https://example.com/a'},
      ]),
    );
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    expect(_tile('A'), findsNothing);
    expect(_tile('B'), findsOneWidget);

    harness.transcript = _transcript([
      {'action': 'open', 'url': 'https://example.com/a', 'label': 'A'},
      {'action': 'close'},
    ]);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();
    expect(find.text('VISTAS PREVIAS DEL AGENTE'), findsNothing);
  });

  testWidgets('a chat without previews shows no section', (tester) async {
    final harness = _Harness([
      {'role': 'assistant', 'content': 'Mira https://example.com/x'},
    ]);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    expect(find.text('VISTAS PREVIAS DEL AGENTE'), findsNothing);
  });

  testWidgets('another chat with the same stored id never shows these', (
    tester,
  ) async {
    // The list is replayed from the transcript the screen is given, so a
    // chat of another profile (its own transcript) cannot inherit it.
    final profileA = _Harness(
      _transcript([
        {'action': 'open', 'url': 'https://example.com/a', 'label': 'Solo A'},
      ]),
    );
    final profileB = _Harness([]);
    await tester.pumpWidget(profileA.app());
    await tester.pumpAndSettle();
    expect(_tile('Solo A'), findsOneWidget);

    await tester.pumpWidget(profileB.app());
    await tester.pumpAndSettle();
    expect(_tile('Solo A'), findsNothing);
  });
}
