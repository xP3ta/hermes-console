import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/interactive_prompt.dart';
import 'package:hermes_android/core/screens/image_viewer_screen.dart';
import 'package:hermes_android/core/screens/memory_screen.dart';
import 'package:hermes_android/core/screens/skills_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/bridge_client.dart';
import 'package:hermes_android/core/services/bridge_manager.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/interactive_prompt_reducer.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/attachment_card.dart';
import 'package:hermes_android/core/widgets/interactive_prompt_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('every IconButton in lib has a tooltip', () {
    final missing = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in files) {
      missing.addAll(
        _unlabelledIconButtons(file.path, file.readAsStringSync()),
      );
    }

    expect(
      missing,
      isEmpty,
      reason:
          'Icon-only controls need a localized tooltip:\n'
          '${missing.join('\n')}',
    );
  });

  group('icon button scanner fixtures', () {
    test('accepts a direct tooltip argument', () {
      expect(
        _unlabelledIconButtons('fixture.dart', '''
Widget build() => IconButton(
  icon: const Icon(Icons.add),
  tooltip: label,
  onPressed: () {},
);
'''),
        isEmpty,
      );
    });

    test('rejects a tooltip token hidden inside onPressed', () {
      expect(
        _unlabelledIconButtons('fixture.dart', '''
Widget build() => IconButton(
  icon: const Icon(Icons.add),
  onPressed: () {
    show(tooltip: value);
  },
);
'''),
        ['fixture.dart:1'],
      );
    });

    test('rejects a tooltip token hidden inside a nested widget', () {
      expect(
        _unlabelledIconButtons('fixture.dart', '''
Widget build() => IconButton(
  icon: Icon(Icons.add, semanticLabel: 'x'),
  onPressed: () {},
  style: Wrapper(child: Foo(tooltip: value)),
);
'''),
        ['fixture.dart:1'],
      );
    });

    test('rejects a tooltip token inside a string literal', () {
      expect(
        _unlabelledIconButtons('fixture.dart', '''
Widget build() => IconButton(
  icon: const Icon(Icons.add),
  onPressed: () => log('tooltip: none'),
);
'''),
        ['fixture.dart:1'],
      );
    });

    test('accepts a Semantics wrapper with a direct label', () {
      expect(
        _unlabelledIconButtons('fixture.dart', '''
Widget build() => Semantics(
  label: 'Add',
  child: IconButton(icon: const Icon(Icons.add), onPressed: () {}),
);
'''),
        isEmpty,
      );
    });

    test('rejects a label that belongs to a nested widget of the wrapper', () {
      expect(
        _unlabelledIconButtons('fixture.dart', '''
Widget build() => Semantics(
  child: Column(
    children: [
      Text('x', semanticsLabel: 'x'),
      Other(label: 'unrelated'),
      IconButton(icon: const Icon(Icons.add), onPressed: () {}),
    ],
  ),
);
'''),
        ['fixture.dart:6'],
      );
    });
  });

  testWidgets('sample screen controls expose localized semantics labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final manager = await _manager();
    final scope = ActiveProfileScope.of(manager, _connection.id);

    await tester.pumpWidget(
      _host(
        MemoryScreen(
          connection: _connection,
          profileScope: scope,
          dashboardClientForTesting: _dashboardClient(),
        ),
      ),
    );
    await _settle(tester);
    final refresh = find.ancestor(
      of: find.byTooltip('Refresh'),
      matching: find.byType(IconButton),
    );
    expect(refresh, findsOneWidget);
    expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
    expect(find.bySemanticsLabel('Refresh'), findsOneWidget);

    await tester.pumpWidget(
      _host(
        SkillsScreen(
          connection: _connection,
          profileScope: scope,
          dashboardClientForTesting: _dashboardClient(),
          bridgeManagerForTesting: _NoBridge(),
        ),
      ),
    );
    await _settle(tester);
    await tester.enterText(find.byType(TextField).first, 'skill');
    await tester.pump();
    expect(find.bySemanticsLabel('Clear search'), findsOneWidget);

    await tester.pumpWidget(
      _host(
        ImageViewerScreen(
          imageUrl: 'https://hermes.example.test/image.png',
          imageBytes: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Close'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('sample inline controls expose localized semantics labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        Scaffold(
          body: GeneratedAudioPlayerCard(
            file: File('/example/audio.mp3'),
            name: 'audio.mp3',
            mimeType: 'audio/mpeg',
            sizeBytes: 1,
            playback: _FakeAudioPlayback(),
            onShare: () {},
            onSave: () {},
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Play audio'), findsOneWidget);

    final key = InteractivePromptKey(
      runtimeSessionId: 'runtime-a',
      requestId: 'secret-a',
    );
    await tester.pumpWidget(
      _host(
        Scaffold(
          body: InteractivePromptCard(
            entry: InteractivePromptEntry(
              key: key,
              request: SecretPromptRequest(
                key: key,
                envVar: 'EXAMPLE_TOKEN',
                prompt: 'Enter the token',
              ),
              status: InteractivePromptStatus.pending,
            ),
            busy: false,
            onSubmit: (_) {},
            onCancel: () {},
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Show answer'), findsOneWidget);
    semantics.dispose();
  });
}

final _connection = SavedConnection(
  id: 'a11y',
  label: 'QA',
  host: 'hermes.example.test',
  port: 443,
  apiKey: 'test-key',
  useHttps: true,
);

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.fromId('dark'),
  home: child,
);

Future<ConnectionManager> _manager() async {
  SharedPreferences.setMockInitialValues({});
  final storage = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async {
          final arguments = (call.arguments as Map?) ?? const {};
          switch (call.method) {
            case 'read':
              return storage[arguments['key']];
            case 'write':
              storage[arguments['key'] as String] =
                  arguments['value'] as String;
              return null;
            case 'delete':
              storage.remove(arguments['key']);
              return null;
            case 'readAll':
              return Map<String, String>.from(storage);
            case 'containsKey':
              return storage.containsKey(arguments['key']);
          }
          return null;
        },
      );
  return ConnectionManager.create(await SharedPreferences.getInstance());
}

DashboardClient _dashboardClient() => DashboardClient(
  host: 'hermes.example.test',
  port: 443,
  manualToken: 'test-token',
  useHttps: true,
  httpClientOverride: MockClient((request) async {
    switch (request.url.path) {
      case '/api/memory':
        return http.Response(
          jsonEncode({
            'active': '',
            'providers': [],
            'builtin_files': {'MEMORY.md': 12},
          }),
          200,
        );
      case '/api/skills':
        return http.Response(
          jsonEncode([
            {'name': 'example-skill', 'enabled': true, 'category': 'test'},
          ]),
          200,
        );
      default:
        return http.Response('{"detail":"not found"}', 404);
    }
  }),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final class _NoBridge implements BridgeManagerContract {
  @override
  Future<BridgeClient?> clientFor(String connectionId) async => null;

  @override
  Future<BridgeState> probe(String connectionId) async => BridgeState.unknown;

  @override
  Future<BridgeProvisionResult> provision(String connectionId) =>
      throw UnimplementedError();

  @override
  Future<bool> tryProvision(String connectionId) async => false;
}

final class _FakeAudioPlayback implements GeneratedAudioPlayback {
  @override
  Stream<Duration> get durationChanges => const Stream.empty();

  @override
  Stream<Duration> get positionChanges => const Stream.empty();

  @override
  Stream<bool> get playingChanges => const Stream.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> play(File file) async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> seek(Duration position) async {}
}

List<String> _unlabelledIconButtons(String path, String source) {
  final missing = <String>[];
  for (final match in RegExp(
    r'\bIconButton(?:\.[A-Za-z]+)?\s*\(',
  ).allMatches(source)) {
    if (match.group(0)!.startsWith('IconButton.styleFrom')) continue;
    final open = source.indexOf('(', match.start);
    final close = _matchingParen(source, open);
    if (close == null) {
      missing.add('$path:${_lineAt(source, match.start)} (unparsed)');
      continue;
    }
    final invocation = source.substring(open + 1, close);
    if (!_hasDirectArgument(invocation, const {'tooltip'}) &&
        !_hasLabelledWrapper(source, match.start, close)) {
      missing.add('$path:${_lineAt(source, match.start)}');
    }
  }
  return missing;
}

int _lineAt(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

bool _hasLabelledWrapper(String source, int buttonStart, int buttonEnd) {
  final wrappers = RegExp(
    r'\b(?:Semantics|Tooltip)\s*\(',
  ).allMatches(source.substring(0, buttonStart)).toList().reversed;
  for (final wrapper in wrappers) {
    final open = source.indexOf('(', wrapper.start);
    final close = _matchingParen(source, open);
    if (close == null || close < buttonEnd) continue;
    final invocation = source.substring(open + 1, close);
    if (_hasDirectArgument(invocation, const {'label', 'message'})) {
      return true;
    }
  }
  return false;
}

/// True when [invocation] (the text between an argument list's parentheses)
/// passes one of [names] as a direct named argument. Names inside nested
/// calls, closures, collections or string literals do not count.
bool _hasDirectArgument(String invocation, Set<String> names) {
  var depth = 0;
  String? quote;
  var escaped = false;
  var segment = StringBuffer();

  bool matches() {
    final text = segment.toString().trimLeft();
    segment = StringBuffer();
    return names.any((name) => RegExp('^$name\\s*:').hasMatch(text));
  }

  for (var index = 0; index < invocation.length; index++) {
    final char = invocation[index];
    if (quote != null) {
      segment.write(depth == 0 ? char : ' ');
      if (escaped) {
        escaped = false;
      } else if (char == '\\') {
        escaped = true;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      segment.write(depth == 0 ? char : ' ');
      continue;
    }
    if (char == '(' || char == '[' || char == '{') depth++;
    if (char == ')' || char == ']' || char == '}') depth--;
    if (char == ',' && depth == 0) {
      if (matches()) return true;
      continue;
    }
    segment.write(depth == 0 ? char : ' ');
  }
  return matches();
}

int? _matchingParen(String source, int open) {
  var depth = 0;
  String? quote;
  var escaped = false;

  for (var index = open; index < source.length; index++) {
    final char = source[index];
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (char == '\\') {
        escaped = true;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      continue;
    }
    if (char == '(') depth++;
    if (char == ')' && --depth == 0) return index;
  }
  return null;
}
