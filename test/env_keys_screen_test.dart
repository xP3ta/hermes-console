// Keys screen and sheet: the profile's `.env` as a write-only vault.
//
// The secret used in these tests is synthetic. No test may find it in the
// widget tree, in a semantics label, in a debug log or in a framework error.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/env_keys_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _secret = 'zz-synthetic-secret-91827';
const _masked = 'zz-masked-tail-4455';

Map<String, dynamic> _row({
  required bool set,
  String category = 'provider',
  String description = '',
  bool custom = false,
  bool channel = false,
}) => {
  'is_set': set,
  'redacted_value': set ? _masked : null,
  'description': description,
  'category': category,
  'is_password': true,
  'channel_managed': channel,
  'custom': custom,
};

/// Dashboard client with an in-memory `.env` that records what it is asked.
class _FakeEnv extends DashboardClient {
  _FakeEnv({Map<String, Map<String, dynamic>>? rows})
    : rows =
          rows ??
          {
            'OPENAI_API_KEY': _row(set: true, description: 'OpenAI credential'),
            'BROWSER_SESSION_TIMEOUT': _row(
              set: false,
              category: 'tool',
              description: 'Seconds before a browser session ends',
            ),
            'MY_OWN_TOKEN': _row(set: true, category: 'custom', custom: true),
            'TELEGRAM_BOT_TOKEN': _row(
              set: true,
              category: 'messaging',
              channel: true,
            ),
          },
      super(
        host: 'keys.example.test',
        manualToken: 'token',
        httpClientOverride: MockClient((_) async => http.Response('{}', 500)),
      );

  final Map<String, Map<String, dynamic>> rows;
  final reads = <String?>[];
  final writes = <({String key, String? profile})>[];
  final deletes = <({String key, String? profile})>[];
  Object? readError;
  Object? writeError;
  bool accept = true;

  @override
  Future<Map<String, dynamic>> getEnvVars({String? profile}) async {
    reads.add(profile);
    final error = readError;
    if (error != null) throw error;
    return {for (final e in rows.entries) e.key: e.value};
  }

  @override
  Future<bool> setEnvVar(String key, String value, {String? profile}) async {
    writes.add((key: key, profile: profile));
    final error = writeError;
    if (error != null) throw error;
    if (accept) rows[key] = _row(set: true, category: 'custom', custom: true);
    return accept;
  }

  @override
  Future<void> deleteEnvVar(String key, {String? profile}) async {
    deletes.add((key: key, profile: profile));
    rows[key] = _row(set: false);
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

class _SecureProbe {
  final events = <String>[];
  int get open => events.where((e) => e == 'on').length - closed;
  int get closed => events.where((e) => e == 'off').length;

  Future<Future<void> Function()> scope() async {
    events.add('on');
    return () async => events.add('off');
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeEnv client,
  String profile = '',
  SavedConnection? connection,
  _SecureProbe? secure,
  ValueListenable<bool>? appLocked,
  TextEditingController Function()? controller,
  double scale = 1,
  Size size = const Size(390, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  final probe = secure ?? _SecureProbe();
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
        secureScope: probe.scope,
        appLocked: appLocked ?? ValueNotifier(false),
        sheetControllerFactory: controller,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<Strings> _s() => Strings.delegate.load(const Locale('es'));

Future<void> _openRow(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('env-key-$name')));
  await tester.pumpAndSettle();
}

Finder get _valueInput => find.byKey(const ValueKey('env-value-input'));

TextField _valueField(WidgetTester tester) =>
    tester.widget<TextField>(_valueInput);

Future<void> _type(WidgetTester tester, String value) async {
  await tester.enterText(_valueInput, value);
  await tester.pump();
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('env-save')));
  await tester.tap(find.byKey(const ValueKey('env-save')));
  await tester.pumpAndSettle();
}

/// What the debug log and the framework's error handler were told during the
/// running test. Both are put back before the test body returns: the binding
/// checks the foundation's debug variables right after it.
final List<String> logs = [];
final List<String> frameworkErrors = [];

void secretTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    logs.clear();
    frameworkErrors.clear();
    final originalDebugPrint = debugPrint;
    final originalOnError = FlutterError.onError;
    debugPrint = (String? message, {int? wrapWidth}) {
      logs.add(message ?? '');
    };
    FlutterError.onError = (details) {
      frameworkErrors.add(details.toString());
      originalOnError?.call(details);
    };
    try {
      await body(tester);
    } finally {
      debugPrint = originalDebugPrint;
      FlutterError.onError = originalOnError;
    }
  });
}

void main() {
  /// A text on screen that carries [needle]. The value typed into the field
  /// lives in its controller, not in a `Text`, so it is not what this finds.
  Finder shownText(String needle) => find.byWidgetPredicate(
    (w) =>
        w is Text &&
        ((w.data ?? w.textSpan?.toPlainText() ?? '').contains(needle)),
  );

  void expectNoSecretAnywhere(WidgetTester tester) {
    expect(shownText(_secret), findsNothing);
    expect(shownText(_masked), findsNothing);
    bool leaks(String line) => line.contains(_secret) || line.contains(_masked);
    expect(logs.where(leaks), isEmpty);
    expect(frameworkErrors.where(leaks), isEmpty);
  }

  group('list', () {
    secretTest('shows names, SET chips, counts and the profile', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      final s = await _s();

      expect(find.text('OPENAI_API_KEY'), findsOneWidget);
      expect(find.text('BROWSER_SESSION_TIMEOUT'), findsOneWidget);
      expect(find.text('MY_OWN_TOKEN'), findsOneWidget);
      // Messaging credentials stay on the Messaging page.
      expect(find.text('TELEGRAM_BOT_TOKEN'), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('env-count-available')))
            .data,
        '3',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('env-count-configured')))
            .data,
        '2',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('env-summary-profile')))
            .data,
        s.kluProfileDefault,
      );
      expect(find.text(s.kluStatusSet), findsWidgets);
      expectNoSecretAnywhere(tester);
    });

    secretTest('the masked value of the server is never drawn or announced', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'OPENAI_API_KEY');

      expectNoSecretAnywhere(tester);
      final row = tester.getSemantics(
        find.byKey(const ValueKey('env-key-OPENAI_API_KEY')),
      );
      expect(row.label, contains('OPENAI_API_KEY'));
      expect(row.label, isNot(contains(_masked)));
      semantics.dispose();
    });

    secretTest('search narrows by name and description', (tester) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      final s = await _s();

      await tester.enterText(
        find.byKey(const ValueKey('env-search')),
        'browser',
      );
      await tester.pump();
      expect(find.text('BROWSER_SESSION_TIMEOUT'), findsOneWidget);
      expect(find.text('OPENAI_API_KEY'), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('env-search')), 'zzzz');
      await tester.pump();
      expect(find.text(s.kluKeysNoMatches), findsOneWidget);
    });

    secretTest('status and category filters', (tester) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);

      await tester.tap(find.byKey(const ValueKey('env-filter-unset')));
      await tester.pump();
      expect(find.text('BROWSER_SESSION_TIMEOUT'), findsOneWidget);
      expect(find.text('OPENAI_API_KEY'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('env-filter-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('env-filter-set')));
      await tester.pump();
      expect(find.text('OPENAI_API_KEY'), findsOneWidget);
      expect(find.text('BROWSER_SESSION_TIMEOUT'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('env-filter-all')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('env-filter-cat-tool')),
      );
      await tester.tap(find.byKey(const ValueKey('env-filter-cat-tool')));
      await tester.pump();
      expect(find.text('BROWSER_SESSION_TIMEOUT'), findsOneWidget);
      expect(find.text('MY_OWN_TOKEN'), findsNothing);
    });

    secretTest('empty profile', (tester) async {
      final client = _FakeEnv(rows: {});
      await _pump(tester, client: client);
      expect(find.text((await _s()).kluKeysEmpty), findsOneWidget);
    });

    secretTest('a failed read shows the error and retry reads again', (
      tester,
    ) async {
      final client = _FakeEnv()
        ..readError = const DashboardHttpException(500, body: _secret);
      await _pump(tester, client: client);
      final s = await _s();

      expect(find.text(s.kluKeysLoadError), findsOneWidget);
      expect(find.text(s.apiErrorServer), findsOneWidget);
      expectNoSecretAnywhere(tester);

      client.readError = null;
      await tester.tap(find.text(s.commonRetry));
      await tester.pumpAndSettle();
      expect(find.text('OPENAI_API_KEY'), findsOneWidget);
      expect(client.reads, hasLength(2));
    });

    secretTest('loading state is shown while the list is read', (tester) async {
      final gate = Completer<void>();
      final client = _SlowEnv(gate.future);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: EnvKeysScreen(
            connection: _connection(),
            profile: '',
            clientOverride: client,
            secureScope: _SecureProbe().scope,
            appLocked: ValueNotifier(false),
          ),
        ),
      );
      await tester.pump();
      expect(find.text((await _s()).kluKeysLoading), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('OPENAI_API_KEY'), findsOneWidget);
    });
  });

  group('profile', () {
    secretTest('a secondary profile is read, shown and written explicitly', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client, profile: 'work');

      expect(client.reads, ['work']);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('env-summary-profile')))
            .data,
        'work',
      );

      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('env-sheet-profile')))
            .data,
        (await _s()).kluTargetProfile('work'),
      );
      await _type(tester, _secret);
      await _tapSave(tester);

      expect(client.writes.single.key, 'BROWSER_SESSION_TIMEOUT');
      expect(client.writes.single.profile, 'work');
      expect(client.reads.every((p) => p == 'work'), isTrue);
    });

    secretTest('delete carries the profile too', (tester) async {
      final client = _FakeEnv();
      await _pump(tester, client: client, profile: 'work');
      await _openRow(tester, 'MY_OWN_TOKEN');
      await tester.tap(find.byKey(const ValueKey('env-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('env-confirm-ok')));
      await tester.pumpAndSettle();
      expect(client.deletes.single, (key: 'MY_OWN_TOKEN', profile: 'work'));
    });

    test('over the wire: profile in the query and in the body', () async {
      final requests = <http.Request>[];
      final client = DashboardClient(
        host: 'keys.example.test',
        manualToken: 'token',
        httpClientOverride: MockClient((request) async {
          requests.add(request);
          return http.Response('{"ok":true}', 200);
        }),
      );
      await client.getEnvVars(profile: 'work');
      await client.setEnvVar('MY_KEY', 'v', profile: 'work');
      await client.deleteEnvVar('MY_KEY', profile: 'work');
      client.close();

      final get = requests.firstWhere((r) => r.method == 'GET');
      expect(get.url.path, '/api/env');
      expect(get.url.queryParameters['profile'], 'work');
      final put = requests.firstWhere((r) => r.method == 'PUT');
      expect(jsonDecode(put.body)['profile'], 'work');
      final del = requests.firstWhere((r) => r.method == 'DELETE');
      expect(del.url.queryParameters['profile'], 'work');
      expect(jsonDecode(del.body)['profile'], 'work');
    });
  });

  group('secure screen', () {
    secretTest('FLAG_SECURE is held while the page is open and released', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final calls = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('hermes/security'), (
            call,
          ) async {
            if (call.method == 'setSecureScreen') {
              calls.add(call.arguments as bool);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('hermes/security'),
              null,
            ),
      );
      final client = _FakeEnv();
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          theme: AppTheme.fromId('dark'),
          home: EnvKeysScreen(
            connection: _connection(),
            profile: '',
            clientOverride: client,
            appLocked: ValueNotifier(false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, isNotEmpty);
      expect(calls.last, isTrue);

      await _openRow(tester, 'OPENAI_API_KEY');
      expect(calls.last, isTrue, reason: 'the sheet is covered too');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(calls.last, isFalse);
    });

    secretTest('the scope is acquired once and released once', (tester) async {
      final probe = _SecureProbe();
      await _pump(tester, client: _FakeEnv(), secure: probe);
      expect(probe.events, ['on']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(probe.events, ['on', 'off']);
    });
  });

  group('the value field', () {
    secretTest('is obscured with no suggestions, learning or autofill', (
      tester,
    ) async {
      await _pump(tester, client: _FakeEnv());
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      final field = _valueField(tester);
      expect(field.obscureText, isTrue);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.autofillHints, isNull);
      expect(field.keyboardType, TextInputType.visiblePassword);
    });

    secretTest('the eye shows what was typed and focus loss hides it', (
      tester,
    ) async {
      await _pump(tester, client: _FakeEnv());
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, _secret);

      await tester.tap(find.byKey(const ValueKey('env-value-eye')));
      await tester.pump();
      expect(_valueField(tester).obscureText, isFalse);

      // Another field takes the focus: what was typed is hidden again.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(_valueField(tester).obscureText, isTrue);
      expectNoSecretAnywhere(tester);
    });

    secretTest('the menu offers no way out, hidden or revealed', (
      tester,
    ) async {
      await _pump(tester, client: _FakeEnv());
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, _secret);

      Set<ContextMenuButtonType> offered() {
        final editable = find.descendant(
          of: _valueInput,
          matching: find.byType(EditableText),
        );
        final state = tester.state<EditableTextState>(editable);
        state.widget.controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _secret.length,
        );
        final menu = _valueField(tester).contextMenuBuilder!(
          tester.element(editable),
          state,
        );
        return (menu as AdaptiveTextSelectionToolbar).buttonItems!
            .map((item) => item.type)
            .toSet();
      }

      const outward = {
        ContextMenuButtonType.copy,
        ContextMenuButtonType.cut,
        ContextMenuButtonType.share,
        ContextMenuButtonType.searchWeb,
        ContextMenuButtonType.lookUp,
        ContextMenuButtonType.liveTextInput,
        ContextMenuButtonType.custom,
      };
      expect(offered().intersection(outward), isEmpty);

      await tester.tap(find.byKey(const ValueKey('env-value-eye')));
      await tester.pump();
      expect(_valueField(tester).obscureText, isFalse);
      // With the value showing, the platform itself offers more.
      final editable = find.descendant(
        of: _valueInput,
        matching: find.byType(EditableText),
      );
      final raw = tester
          .state<EditableTextState>(editable)
          .contextMenuButtonItems
          .map((item) => item.type)
          .toSet();
      expect(raw, contains(ContextMenuButtonType.copy));
      expect(
        offered().difference({
          ContextMenuButtonType.paste,
          ContextMenuButtonType.selectAll,
        }),
        isEmpty,
      );
      expectNoSecretAnywhere(tester);
    });

    secretTest('the copy and cut shortcuts do nothing', (tester) async {
      final clipboard = <String?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String?);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pump(tester, client: _FakeEnv());
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, _secret);
      await tester.tap(find.byKey(const ValueKey('env-value-eye')));
      await tester.pump();
      final editable = find.descendant(
        of: _valueInput,
        matching: find.byType(EditableText),
      );
      final state = tester.state<EditableTextState>(editable);
      state.widget.controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _secret.length,
      );
      final context = tester.element(editable);
      Actions.maybeInvoke(context, CopySelectionTextIntent.copy);
      Actions.maybeInvoke(
        context,
        CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(clipboard, isEmpty);
      expect(state.widget.controller.text, _secret);
    });

    secretTest('leaving the app hides it again', (tester) async {
      await _pump(tester, client: _FakeEnv());
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, _secret);
      await tester.tap(find.byKey(const ValueKey('env-value-eye')));
      await tester.pump();
      expect(_valueField(tester).obscureText, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(_valueField(tester).obscureText, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(_valueField(tester).obscureText, isTrue);
    });

    secretTest('the eye is a 48 dp target with a label', (tester) async {
      await _pump(tester, client: _FakeEnv());
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      final size = tester.getSize(find.byKey(const ValueKey('env-value-eye')));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(find.byTooltip((await _s()).kluRevealValue), findsOneWidget);
    });
  });

  group('validation', () {
    secretTest('a control character in the value is refused, nothing sent', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, 'ab\u0000cd');
      await _tapSave(tester);
      expect(find.text((await _s()).kluValueInvalid), findsOneWidget);
      expect(client.writes, isEmpty);
    });

    secretTest('a pasted line break is dropped by the single-line field', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, 'one\ntwo');
      expect(
        tester.widget<TextField>(_valueInput).controller!.text.contains('\n'),
        isFalse,
      );
    });

    secretTest('an empty value and edge spaces are refused', (tester) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      final s = await _s();
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _tapSave(tester);
      expect(find.text(s.kluValueEmpty), findsOneWidget);
      await _type(tester, ' padded ');
      await _tapSave(tester);
      expect(find.text(s.kluValueInvalid), findsOneWidget);
      expect(client.writes, isEmpty);
    });

    secretTest('a new key needs a valid name; the name is upper-cased', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      final s = await _s();
      await tester.tap(find.byKey(const ValueKey('env-add')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('env-name-input')),
        '1bad name!',
      );
      await _type(tester, 'ok-value');
      await _tapSave(tester);
      expect(find.text(s.kluNameInvalid), findsOneWidget);
      expect(client.writes, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('env-name-input')),
        'my_new_key',
      );
      await tester.pump();
      await _tapSave(tester);
      expect(client.writes.single.key, 'MY_NEW_KEY');
    });
  });

  group('confirmations', () {
    secretTest('replacing a key that is set asks first', (tester) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      final s = await _s();
      await _openRow(tester, 'OPENAI_API_KEY');
      await _type(tester, _secret);
      await _tapSave(tester);

      expect(find.text(s.kluOverwriteTitle('OPENAI_API_KEY')), findsOneWidget);
      expect(client.writes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('env-confirm-cancel')));
      await tester.pumpAndSettle();
      expect(client.writes, isEmpty);
      expect(_valueInput, findsOneWidget, reason: 'the sheet stays open');

      await _tapSave(tester);
      await tester.tap(find.byKey(const ValueKey('env-confirm-ok')));
      await tester.pumpAndSettle();
      expect(client.writes.single.key, 'OPENAI_API_KEY');
      expect(_valueInput, findsNothing);
      expectNoSecretAnywhere(tester);
    });

    secretTest('a key that is not set is written without asking', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, '30');
      await _tapSave(tester);
      expect(find.byKey(const ValueKey('env-confirm-ok')), findsNothing);
      expect(client.writes.single.key, 'BROWSER_SESSION_TIMEOUT');
    });

    secretTest('typing the name of a key that is set asks to replace it', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await tester.tap(find.byKey(const ValueKey('env-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('env-name-input')),
        'OPENAI_API_KEY',
      );
      await _type(tester, 'ok-value');
      await _tapSave(tester);
      expect(find.byKey(const ValueKey('env-confirm-ok')), findsOneWidget);
      expect(client.writes, isEmpty);
    });

    secretTest('a messaging variable that is set cannot be replaced unasked', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      await tester.tap(find.byKey(const ValueKey('env-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('env-name-input')),
        'TELEGRAM_BOT_TOKEN',
      );
      await _type(tester, 'ok-value');
      await _tapSave(tester);
      expect(find.byKey(const ValueKey('env-confirm-ok')), findsOneWidget);
      expect(client.writes, isEmpty);
    });

    secretTest('deleting asks first and only a set key can be deleted', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(tester, client: client);
      final s = await _s();

      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      expect(find.byKey(const ValueKey('env-delete')), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await _openRow(tester, 'MY_OWN_TOKEN');
      await tester.tap(find.byKey(const ValueKey('env-delete')));
      await tester.pumpAndSettle();
      expect(find.text(s.kluDeleteTitle('MY_OWN_TOKEN')), findsOneWidget);
      expect(client.deletes, isEmpty);

      await tester.tap(find.byKey(const ValueKey('env-confirm-cancel')));
      await tester.pumpAndSettle();
      expect(client.deletes, isEmpty);

      await tester.tap(find.byKey(const ValueKey('env-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('env-confirm-ok')));
      await tester.pumpAndSettle();
      expect(client.deletes.single.key, 'MY_OWN_TOKEN');
    });
  });

  group('the typed value', () {
    secretTest('the controller is emptied and disposed when the sheet closes', (
      tester,
    ) async {
      final recorder = _RecordingController();
      final client = _FakeEnv();
      await _pump(tester, client: client, controller: () => recorder);
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, _secret);
      expect(recorder.text, _secret);

      // Closed without saving.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(recorder.text, isEmpty);
      expect(recorder.disposed, isTrue);
      expect(client.writes, isEmpty);
    });

    secretTest('after saving the controller is cleared and disposed', (
      tester,
    ) async {
      final recorder = _RecordingController();
      final client = _FakeEnv();
      await _pump(tester, client: client, controller: () => recorder);
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, _secret);
      await _tapSave(tester);

      expect(client.writes, hasLength(1));
      expect(recorder.text, isEmpty);
      expect(recorder.disposed, isTrue);
      expectNoSecretAnywhere(tester);
    });

    secretTest('App Lock empties the field and closes the sheet', (
      tester,
    ) async {
      final recorder = _RecordingController();
      final locked = ValueNotifier(false);
      await _pump(
        tester,
        client: _FakeEnv(),
        controller: () => recorder,
        appLocked: locked,
      );
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, _secret);
      locked.value = true;
      await tester.pumpAndSettle();
      expect(recorder.text, isEmpty);
      expect(_valueInput, findsNothing);
    });

    secretTest('a failed save keeps the sheet and never echoes the value', (
      tester,
    ) async {
      final client = _FakeEnv()
        ..writeError = Exception('boom while saving $_secret');
      await _pump(tester, client: client);
      final s = await _s();
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, _secret);
      await _tapSave(tester);

      expect(find.byKey(const ValueKey('env-sheet-error')), findsOneWidget);
      expect(find.textContaining(s.kluSaveFailed), findsOneWidget);
      expectNoSecretAnywhere(tester);
    });

    secretTest('a network error is described without the value', (
      tester,
    ) async {
      final client = _FakeEnv()
        ..writeError = SocketException('lost connection sending $_secret');
      await _pump(tester, client: client);
      final s = await _s();
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, _secret);
      await _tapSave(tester);
      expect(find.textContaining(s.apiErrorNetwork), findsOneWidget);
      expectNoSecretAnywhere(tester);
    });

    secretTest(
      'a server that echoes the value in its error body is not shown',
      (tester) async {
        final client = _FakeEnv()
          ..writeError = const DashboardHttpException(
            400,
            body: '{"detail":"bad value $_secret"}',
          );
        await _pump(tester, client: client);
        final s = await _s();
        await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
        await _type(tester, _secret);
        await _tapSave(tester);
        expect(find.textContaining(s.apiErrorBadRequest), findsOneWidget);
        expectNoSecretAnywhere(tester);
      },
    );

    secretTest('a server that refuses the write is reported as not saved', (
      tester,
    ) async {
      final client = _FakeEnv()..accept = false;
      await _pump(tester, client: client);
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, 'value-1');
      await _tapSave(tester);
      expect(find.byKey(const ValueKey('env-sheet-error')), findsOneWidget);
    });
  });

  group('who may write', () {
    secretTest('a read-only connection sends nothing', (tester) async {
      final client = _FakeEnv();
      await _pump(
        tester,
        client: client,
        connection: _connection(readOnly: true),
      );
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      await _type(tester, 'value-1');
      await _tapSave(tester);
      expect(client.writes, isEmpty);
      expect(find.text((await _s()).readOnlyNotice), findsWidgets);
    });

    secretTest('plain HTTP on a public host blocks writing and says why', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(
        tester,
        client: client,
        connection: _connection(https: false, host: 'public.example.org'),
      );
      final s = await _s();
      expect(find.text(s.kluCleartextBlocked), findsOneWidget);
      await _openRow(tester, 'MY_OWN_TOKEN');
      expect(find.text(s.kluCleartextBlocked), findsNWidgets(2));
      final save = tester.widget<FilledButton>(
        find
            .descendant(
              of: find.byKey(const ValueKey('env-save')),
              matching: find.byType(FilledButton),
            )
            .first,
      );
      expect(save.onPressed, isNull);
      expect(client.writes, isEmpty);
      expect(client.deletes, isEmpty);
    });

    secretTest('plain HTTP on a private network says nothing and allows', (
      tester,
    ) async {
      final client = _FakeEnv();
      await _pump(
        tester,
        client: client,
        connection: _connection(https: false, host: 'hermes.local'),
      );
      await _openRow(tester, 'BROWSER_SESSION_TIMEOUT');
      final s = await _s();
      // A private network (LAN, Tailscale) gets no "unencrypted" notice.
      expect(find.text(s.kluCleartextPrivate), findsNothing);
      expect(find.text(s.kluCleartextBlocked), findsNothing);
      await _type(tester, 'value-1');
      await _tapSave(tester);
      expect(client.writes, hasLength(1));
    });
  });

  group('layout', () {
    secretTest('twice the text size does not overflow list or sheet', (
      tester,
    ) async {
      await _pump(
        tester,
        client: _FakeEnv(),
        scale: 2,
        size: const Size(360, 780),
      );
      expect(tester.takeException(), isNull);
      // The controls fill the screen at this size: the rows are further down.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('env-key-OPENAI_API_KEY')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('env-key-OPENAI_API_KEY')),
      );
      await tester.pump();
      await _openRow(tester, 'OPENAI_API_KEY');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('env-save')), findsOneWidget);
    });

    secretTest('targets are at least 48 dp', (tester) async {
      await _pump(tester, client: _FakeEnv());
      for (final key in const [
        'env-add',
        'env-filter-all',
        'env-filter-set',
        'env-key-OPENAI_API_KEY',
      ]) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
        expect(size.width, greaterThanOrEqualTo(48), reason: key);
      }
    });
  });
}

class _SlowEnv extends _FakeEnv {
  _SlowEnv(this.gate);

  final Future<void> gate;

  @override
  Future<Map<String, dynamic>> getEnvVars({String? profile}) async {
    await gate;
    return super.getEnvVars(profile: profile);
  }
}

class _RecordingController extends TextEditingController {
  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
