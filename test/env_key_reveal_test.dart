// Keys: showing a stored value ("Show value"), on request and nothing else.
//
// Every value here is synthetic. The revealed one must never reach the
// semantics tree, the debug log or the framework's error handler, and it must
// disappear from the controller as well as from the screen.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/keys/env_key.dart';
import 'package:hermes_android/core/screens/env_key_sheet.dart';
import 'package:hermes_android/core/screens/env_keys_screen.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/sensitive_clipboard.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _revealed = 'zz-synthetic-revealed-60417';
const _masked = 'zz-masked-tail-4455';

Map<String, dynamic> _row({
  required bool set,
  String category = 'provider',
  bool custom = false,
}) => {
  'is_set': set,
  'redacted_value': set ? _masked : null,
  'description': '',
  'category': category,
  'is_password': true,
  'channel_managed': false,
  'custom': custom,
};

class _FakeEnv extends DashboardClient {
  _FakeEnv()
    : super(
        host: 'keys.example.test',
        manualToken: 'token',
        httpClientOverride: MockClient((_) async => http.Response('{}', 500)),
      );

  final reveals = <({String key, String? profile})>[];
  int reads = 0;
  Object? revealError;
  Completer<String?>? gate;

  @override
  Future<Map<String, dynamic>> getEnvVars({String? profile}) async {
    reads++;
    return {
      'OPENAI_API_KEY': _row(set: true),
      'BROWSER_SESSION_TIMEOUT': _row(set: false, category: 'tool'),
      'MY_OWN_TOKEN': _row(set: true, category: 'custom', custom: true),
    };
  }

  @override
  Future<String?> revealEnvVar(String key, {String? profile}) async {
    reveals.add((key: key, profile: profile));
    final error = revealError;
    if (error != null) throw error;
    final pending = gate;
    if (pending != null) return pending.future;
    return _revealed;
  }
}

SavedConnection _connection({
  bool readOnly = false,
  bool https = true,
  String host = 'keys.example.test',
}) => SavedConnection(
  id: 'env-keys',
  label: 'QA',
  host: host,
  port: 8642,
  apiKey: '',
  useHttps: https,
  readOnly: readOnly,
);

/// The system clipboard as the platform channel sees it.
class _Clip {
  String? text;
  final writes = <String>[];
  final sensitiveWrites = <String>[];
  bool nativeFlag = false;

  void install(WidgetTester tester, {bool native = false}) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          text = (call.arguments as Map)['text'] as String?;
          writes.add(text ?? '');
          return null;
        case 'Clipboard.getData':
          return text == null ? null : <String, dynamic>{'text': text};
      }
      return null;
    });
    // The native side is mocked either way: an unmocked channel never answers
    // under the test clock.
    messenger.setMockMethodCallHandler(SensitiveClipboard.channel, (
      call,
    ) async {
      if (!native) throw MissingPluginException();
      if (call.method != 'setSensitiveText') return null;
      final value = (call.arguments as Map)['text'] as String;
      sensitiveWrites.add(value);
      text = value;
      nativeFlag = true;
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(SensitiveClipboard.channel, null);
    });
  }
}

final List<String> _logs = [];
final List<String> _errors = [];

void revealTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    _logs.clear();
    _errors.clear();
    EnvRevealSession.reset();
    SensitiveClipboard.reset();
    SharedPreferences.setMockInitialValues({});
    final originalDebugPrint = debugPrint;
    final originalOnError = FlutterError.onError;
    debugPrint = (String? message, {int? wrapWidth}) {
      _logs.add(message ?? '');
    };
    FlutterError.onError = (details) {
      _errors.add(details.toString());
      originalOnError?.call(details);
    };
    try {
      await body(tester);
    } finally {
      SensitiveClipboard.reset();
      debugPrint = originalDebugPrint;
      FlutterError.onError = originalOnError;
    }
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeEnv client,
  String profile = '',
  SavedConnection? connection,
  AppLockService? lock,
  Size size = const Size(390, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      theme: AppTheme.fromId('dark'),
      home: EnvKeysScreen(
        connection: connection ?? _connection(),
        profile: profile,
        clientOverride: client,
        secureScope: () async => () async {},
        appLocked: ValueNotifier(false),
        appLockService: lock,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<AppLockService> _lock({required bool enabled}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('app_lock_enabled', enabled);
  return AppLockService(prefs);
}

Future<Strings> _s() => Strings.delegate.load(const Locale('es'));

final _button = find.byKey(const ValueKey('env-reveal'));
final _field = find.byKey(const ValueKey('env-revealed-input'));
final _confirmOk = find.byKey(const ValueKey('env-confirm-ok'));
final _confirmCancel = find.byKey(const ValueKey('env-confirm-cancel'));

Future<void> _openRow(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('env-key-$name')));
  await tester.pumpAndSettle();
}

Future<void> _tapReveal(WidgetTester tester) async {
  await tester.ensureVisible(_button);
  await tester.tap(_button);
  await tester.pumpAndSettle();
}

/// Taps "Show value" and confirms the first-time question.
Future<void> _reveal(WidgetTester tester) async {
  await _tapReveal(tester);
  if (_confirmOk.evaluate().isNotEmpty) {
    await tester.tap(_confirmOk);
    await tester.pumpAndSettle();
  }
}

TextEditingController _shownController(WidgetTester tester) =>
    tester.widget<TextField>(_field).controller!;

String _semanticsTree(WidgetTester tester) => RendererBinding
    .instance
    .renderViews
    .single
    .owner!
    .semanticsOwner!
    .rootSemanticsNode!
    .toStringDeep();

/// The app goes out of sight the way the system does it, step by step.
void _background(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _foreground(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _expectNeverLogged() {
  bool leaks(String line) => line.contains(_revealed);
  expect(_logs.where(leaks), isEmpty);
  expect(_errors.where(leaks), isEmpty);
}

void main() {
  group('on request only', () {
    revealTest('listing and opening the sheet never ask for a value', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      expect(client.reads, greaterThan(0));
      expect(client.reveals, isEmpty);
      await _openRow(tester, 'OPENAI_API_KEY');
      expect(_button, findsOneWidget);
      expect(client.reveals, isEmpty);
      expect(_field, findsNothing);
      // A key that is not set has no stored value to show.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      expect(_button, findsNothing);
      _expectNeverLogged();
    });

    revealTest('asks once confirmed, not before; cancel asks nothing', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      final s = await _s();
      await _openRow(tester, 'OPENAI_API_KEY');

      await _tapReveal(tester);
      expect(find.text(s.krhRevealConfirmBody), findsOneWidget);
      expect(client.reveals, isEmpty);
      await tester.tap(_confirmCancel);
      await tester.pumpAndSettle();
      expect(client.reveals, isEmpty);
      expect(_field, findsNothing);

      await _tapReveal(tester);
      await tester.tap(_confirmOk);
      await tester.pumpAndSettle();
      expect(client.reveals, hasLength(1));
      expect(client.reveals.single.key, 'OPENAI_API_KEY');
      expect(_shownController(tester).text, _revealed);
      // Monospace and selectable, not an obscured field.
      final field = tester.widget<TextField>(_field);
      expect(field.readOnly, isTrue);
      expect(field.obscureText, isFalse);
      expect(field.style?.fontFamily, contains('JetBrainsMono'));
      expect(field.enableInteractiveSelection, isNot(false));
      _expectNeverLogged();
    });

    revealTest('the confirmation is asked once per session', (tester) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      await tester.tap(find.byKey(const ValueKey('env-reveal-hide')));
      await tester.pumpAndSettle();
      expect(_field, findsNothing);

      await _tapReveal(tester);
      expect(_confirmOk, findsNothing);
      expect(client.reveals, hasLength(2));
      expect(_field, findsOneWidget);
    });

    revealTest('failures say why without a value; 429 and 404 are fixed text', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      final s = await _s();
      await _openRow(tester, 'OPENAI_API_KEY');

      client.revealError = const DashboardHttpException(
        429,
        body: 'secret-in-body-must-not-show',
      );
      await _reveal(tester);
      expect(find.text(s.krhRevealTooMany), findsOneWidget);
      expect(find.textContaining('secret-in-body'), findsNothing);
      expect(_field, findsNothing);

      client.revealError = const DashboardHttpException(404);
      await _tapReveal(tester);
      expect(find.text(s.krhRevealNotFound), findsOneWidget);

      client.revealError = StateError('boom $_revealed');
      await _tapReveal(tester);
      expect(find.textContaining(_revealed), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('env-reveal-error')))
            .data,
        startsWith(s.krhRevealFailed),
      );
    });
  });

  group('how long it stays', () {
    revealTest('hides itself after 15 s and empties the controller', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      final s = await _s();
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      final controller = _shownController(tester);
      expect(find.text(s.krhRevealCountdown(15)), findsOneWidget);

      await tester.pump(const Duration(seconds: 7));
      expect(find.text(s.krhRevealCountdown(8)), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      expect(_field, findsOneWidget);
      expect(controller.text, _revealed);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(_field, findsNothing);
      expect(controller.text, isEmpty);
      expect(_button, findsOneWidget);
      _expectNeverLogged();
    });

    revealTest('the window and the clock are injectable on the sheet', (
      tester,
    ) async {
      late void Function(Timer) tick;
      late Timer spent;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: Scaffold(
            body: EnvKeyValueSheet(
              entry: const EnvKeyEntry(name: 'OPENAI_API_KEY', isSet: true),
              setNames: const {'OPENAI_API_KEY'},
              profileName: 'default',
              onSave: (_, _) async => null,
              onDelete: (_) async => null,
              onReveal: (_) async => const EnvKeyRevealOutcome.value(_revealed),
              revealWindow: const Duration(seconds: 3),
              revealTicker: (onTick) {
                tick = onTick;
                // A timer that is already spent: the test is the clock.
                return spent = Timer(Duration.zero, () {});
              },
            ),
          ),
        ),
      );
      EnvRevealSession.confirmed = true;
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_field, findsOneWidget);
      tick(spent);
      await tester.pump();
      tick(spent);
      await tester.pump();
      expect(_field, findsOneWidget);
      tick(spent);
      await tester.pump();
      expect(_field, findsNothing);
    });

    revealTest('going to the background hides it', (tester) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      final controller = _shownController(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(_field, findsNothing);
      expect(controller.text, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      _foreground(tester);
      await tester.pump();
      // Coming back does not bring it back.
      expect(_field, findsNothing);
      expect(_button, findsOneWidget);
    });

    revealTest('leaving while it is still being asked drops the answer', (
      tester,
    ) async {
      final client = _FakeEnv()..gate = Completer<String?>();
      await _pump(tester, client: client);
      await _openRow(tester, 'OPENAI_API_KEY');
      await _tapReveal(tester);
      await tester.tap(_confirmOk);
      await tester.pump();
      await tester.pump();
      expect(client.reveals, hasLength(1));

      _background(tester);
      _foreground(tester);
      client.gate!.complete(_revealed);
      await tester.pumpAndSettle();
      expect(_field, findsNothing);
      expect(_button, findsOneWidget);
    });

    revealTest('closing the sheet empties it', (tester) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      final controller = _shownController(tester);

      Navigator.of(tester.element(_field)).pop();
      await tester.pumpAndSettle();
      expect(_field, findsNothing);
      expect(controller.text, isEmpty);
      // Nothing is left running that would ask again or fail later.
      await tester.pump(const Duration(seconds: 30));
      expect(tester.takeException(), isNull);
    });

    revealTest('turning the screen hides it', (tester) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      final controller = _shownController(tester);

      tester.view.physicalSize = const Size(900, 390);
      await tester.pumpAndSettle();
      expect(_field, findsNothing);
      expect(controller.text, isEmpty);
    });

    revealTest('losing the focus hides it; pressing Copy does not', (
      tester,
    ) async {
      final clip = _Clip()..install(tester);
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      expect(
        FocusManager.instance.primaryFocus,
        tester.widget<TextField>(_field).focusNode,
      );

      await tester.tap(find.byKey(const ValueKey('env-reveal-copy')));
      await tester.pump();
      expect(_field, findsOneWidget);
      expect(clip.text, _revealed);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(_field, findsNothing);
      SensitiveClipboard.reset();
    });
  });

  group('nothing leaks', () {
    revealTest('not in semantics, logs or errors; says only hidden/visible', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final client = _FakeEnv();
      await _pump(tester, client: client);
      final s = await _s();
      await _openRow(tester, 'OPENAI_API_KEY');
      expect(_semanticsTree(tester), contains(s.krhRevealHiddenHint));

      await _reveal(tester);
      final tree = _semanticsTree(tester);
      expect(tree, isNot(contains(_revealed)));
      expect(tree, contains(s.krhRevealVisibleLabel));
      // Not in any visible text either: it lives in the field only.
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').contains(_revealed),
        ),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 20));
      _expectNeverLogged();
      semantics.dispose();
    });

    revealTest('the field menu offers no copy, share or search', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      final field = tester.widget<TextField>(_field);
      final builder = field.contextMenuBuilder!;
      expect(builder, isNotNull);
      // The same filter as the typed field's menu.
      final kept = pasteOnlyMenuItems([
        for (final type in ContextMenuButtonType.values)
          ContextMenuButtonItem(type: type, onPressed: () {}),
      ]).map((e) => e.type).toSet();
      expect(kept, {
        ContextMenuButtonType.paste,
        ContextMenuButtonType.selectAll,
      });
    });

    test(
      'over the wire: POST /api/env/reveal, profile only when not default',
      () async {
        final requests = <http.Request>[];
        final client = DashboardClient(
          host: 'keys.example.test',
          manualToken: 'token',
          httpClientOverride: MockClient((request) async {
            requests.add(request);
            return http.Response(
              jsonEncode({'key': 'OPENAI_API_KEY', 'value': _revealed}),
              200,
            );
          }),
        );
        expect(await client.revealEnvVar('OPENAI_API_KEY'), _revealed);
        expect(
          await client.revealEnvVar('OPENAI_API_KEY', profile: 'default'),
          _revealed,
        );
        expect(
          await client.revealEnvVar('OPENAI_API_KEY', profile: 'work'),
          _revealed,
        );
        client.close();

        expect(requests, hasLength(3));
        for (final r in requests) {
          expect(r.method, 'POST');
          expect(r.url.path, '/api/env/reveal');
          expect(jsonDecode(r.body)['key'], 'OPENAI_API_KEY');
        }
        expect(jsonDecode(requests[0].body).containsKey('profile'), isFalse);
        expect(jsonDecode(requests[1].body).containsKey('profile'), isFalse);
        expect(jsonDecode(requests[2].body)['profile'], 'work');
      },
    );
  });

  group('copy', () {
    revealTest('copies on the button, flags it, and clears after 30 s', (
      tester,
    ) async {
      final clip = _Clip()..install(tester, native: true);
      final client = _FakeEnv();
      await _pump(tester, client: client);
      final s = await _s();
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      expect(clip.text, isNull);

      await tester.tap(find.byKey(const ValueKey('env-reveal-copy')));
      await tester.pump();
      expect(clip.sensitiveWrites, [_revealed]);
      expect(clip.nativeFlag, isTrue);
      expect(find.text(s.krhRevealCopied), findsOneWidget);

      await tester.pump(const Duration(seconds: 29));
      expect(clip.text, _revealed);
      await tester.pump(const Duration(seconds: 1));
      expect(clip.text, isEmpty);
      _expectNeverLogged();
    });

    revealTest('without the native flag it still copies and clears', (
      tester,
    ) async {
      final clip = _Clip()..install(tester);
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      await tester.tap(find.byKey(const ValueKey('env-reveal-copy')));
      await tester.pump();
      expect(clip.writes, [_revealed]);
      await tester.pump(const Duration(seconds: 30));
      expect(clip.text, isEmpty);
    });

    revealTest('the clearing outlives the sheet', (tester) async {
      final clip = _Clip()..install(tester);
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      await tester.tap(find.byKey(const ValueKey('env-reveal-copy')));
      await tester.pump();
      Navigator.of(tester.element(_field)).pop();
      await tester.pumpAndSettle();
      expect(clip.text, _revealed);
      await tester.pump(const Duration(seconds: 30));
      expect(clip.text, isEmpty);
    });

    revealTest('two copies on the wire at once: the later one keeps its 30 s', (
      tester,
    ) async {
      String? text;
      final gates = <Completer<void>>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            text = (call.arguments as Map)['text'] as String?;
          case 'Clipboard.getData':
            return text == null ? null : <String, dynamic>{'text': text};
        }
        return null;
      });
      messenger.setMockMethodCallHandler(SensitiveClipboard.channel, (
        call,
      ) async {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        text = (call.arguments as Map)['text'] as String;
        return true;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        messenger.setMockMethodCallHandler(SensitiveClipboard.channel, null);
      });

      final first = SensitiveClipboard.copy('first-secret');
      final second = SensitiveClipboard.copy('second-secret');
      await tester.pump();
      expect(gates, hasLength(2));
      gates[0].complete();
      await first;
      await tester.pump(const Duration(seconds: 10));
      gates[1].complete();
      await second;
      expect(text, 'second-secret');

      // The first copy's 30 s are over; the second one's are not.
      await tester.pump(const Duration(seconds: 21));
      expect(text, 'second-secret');
      await tester.pump(const Duration(seconds: 10));
      expect(text, isEmpty);
    });

    revealTest('does not clear what the user copied meanwhile', (tester) async {
      final clip = _Clip()..install(tester);
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      await tester.tap(find.byKey(const ValueKey('env-reveal-copy')));
      await tester.pump();
      clip.text = 'something the user copied later';
      final writesBefore = clip.writes.length;
      await tester.pump(const Duration(seconds: 31));
      expect(clip.text, 'something the user copied later');
      expect(clip.writes.length, writesBefore);
    });
  });

  group('who may look', () {
    revealTest('without App Lock nothing is asked of the user', (tester) async {
      final client = _FakeEnv();
      final lock = await _lock(enabled: false);
      await _pump(tester, client: client, lock: lock);
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      // No lock screen was pushed (its Cancel button is the tell).
      expect(find.text('Cancelar'), findsNothing);
      expect(client.reveals, hasLength(1));
      expect(_field, findsOneWidget);
    });

    revealTest('with App Lock on and the check failed, nothing is shown', (
      tester,
    ) async {
      final client = _FakeEnv();
      final lock = await _lock(enabled: true);
      await _pump(tester, client: client, lock: lock);
      final s = await _s();
      await _openRow(tester, 'OPENAI_API_KEY');
      await _tapReveal(tester);
      await tester.tap(_confirmOk);
      await tester.pumpAndSettle();
      // The lock screen is up, before anything is requested.
      expect(find.text('Cancelar'), findsOneWidget);
      expect(client.reveals, isEmpty);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(client.reveals, isEmpty);
      expect(_field, findsNothing);
      expect(find.text(s.krhRevealAuthFailed), findsOneWidget);
      _expectNeverLogged();
    });

    revealTest('http in the clear towards a public host blocks it', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(
        tester,
        client: client,
        connection: _connection(https: false, host: 'public.example.org'),
      );
      final s = await _s();
      await _openRow(tester, 'MY_OWN_TOKEN');
      expect(_button, findsNothing);
      expect(find.byKey(const ValueKey('env-reveal-blocked')), findsOneWidget);
      expect(find.text(s.krhRevealBlocked), findsOneWidget);
      expect(client.reveals, isEmpty);
    });

    revealTest('a private network (LAN, Tailscale) and https are allowed', (
      tester,
    ) async {
      for (final connection in [
        _connection(https: false, host: '192.168.1.20'),
        _connection(https: false, host: '100.101.102.103'),
        _connection(https: false, host: 'box.tail1234.ts.net'),
        _connection(https: true, host: 'keys.example.test'),
      ]) {
        final client = _FakeEnv();
        await _pump(tester, client: client, connection: connection);
        await _openRow(tester, 'OPENAI_API_KEY');
        expect(_button, findsOneWidget, reason: connection.host);
        await _reveal(tester);
        expect(client.reveals, hasLength(1), reason: connection.host);
        await tester.pumpWidget(const SizedBox.shrink());
        EnvRevealSession.reset();
      }
    });

    revealTest('a secondary profile reveals from its own .env', (tester) async {
      final client = _FakeEnv();
      await _pump(tester, client: client, profile: 'work');
      await _openRow(tester, 'OPENAI_API_KEY');
      await _reveal(tester);
      expect(client.reveals.single, (key: 'OPENAI_API_KEY', profile: 'work'));
    });

    revealTest('a read-only connection has no Show value', (tester) async {
      final client = _FakeEnv();
      await _pump(
        tester,
        client: client,
        connection: _connection(readOnly: true),
      );
      await _openRow(tester, 'OPENAI_API_KEY');
      expect(_button, findsNothing);
      expect(client.reveals, isEmpty);
    });
  });
}
