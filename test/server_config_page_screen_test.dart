// One page of Settings › Advanced: the fields the schema brings for it,
// edited on confirm only, each write confirmed by the store's re-read.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/server_config_page_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_config_repository.dart';
import 'package:hermes_android/core/settings/server_config_pages.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _Store implements ServerConfigStore {
  _Store({required this.writable});

  final bool writable;
  Map<String, dynamic> config = {
    'agent': {'reasoning_effort': 'low', 'max_turns': 90},
    'model_context_length': 0,
    'timezone': 'UTC',
    'terminal': {
      'persistent_shell': false,
      'env_passthrough': ['A', 'B'],
    },
    'display': {'show_reasoning': false},
  };
  final List<(String, Object?)> saves = [];
  int reads = 0;
  Completer<void>? holdSave;
  ServerConfigException? saveError;
  ServerConfigException? readError;

  @override
  bool get isWritable => writable;

  @override
  Future<Map<String, dynamic>> readConfig() async {
    reads++;
    final error = readError;
    if (error != null) throw error;
    return config;
  }

  @override
  Future<Map<String, dynamic>> readSchema() async => {'fields': {}};

  @override
  Future<Object?> save(String path, Object? value) async {
    saves.add((path, value));
    final hold = holdSave;
    if (hold != null) await hold.future;
    final error = saveError;
    if (error != null) throw error;
    return value;
  }
}

Map<String, dynamic> _schema(Map<String, Map<String, Object?>> fields) => {
  'fields': fields,
};

final _mainSchema = _schema({
  'model': {'type': 'string'},
  'model_context_length': {'type': 'number'},
  'agent.reasoning_effort': {
    'type': 'select',
    'options': ['low', 'medium', 'high'],
  },
  'model.extra': {'type': 'object'},
  'model.api_key': {'type': 'string'},
});

final _shellSchema = _schema({
  'terminal.persistent_shell': {'type': 'boolean'},
  'terminal.env_passthrough': {'type': 'list'},
});

final _behaviorSchema = _schema({
  'timezone': {'type': 'string', 'description': 'Time zone'},
  'display.show_reasoning': {'type': 'boolean'},
});

final _runtimeSchema = _schema({
  'agent.max_turns': {'type': 'number'},
});

SavedConnection _connection({bool readOnly = false}) => SavedConnection(
  id: 'conn-adv1215',
  label: 'Adv QA',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://hermes.example.test:9119',
  readOnly: readOnly,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ConnectionManager manager;
  late _Store store;

  setUp(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
    SharedPreferences.setMockInitialValues({});
    manager = await ConnectionManager.create(
      await SharedPreferences.getInstance(),
    );
    store = _Store(writable: true);
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  Future<void> pumpPage(
    WidgetTester tester,
    ServerConfigPage page,
    Map<String, dynamic> schema, {
    bool readOnly = false,
    String? highlightPath,
    List<String>? profiles,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: ServerConfigPageScreen(
          connection: _connection(readOnly: readOnly),
          connManager: manager,
          page: page,
          schema: schema,
          highlightPath: highlightPath,
          storeFor: (profile, {required writable}) {
            profiles?.add(profile);
            return store = _Store(writable: writable)
              ..config = store.config
              ..holdSave = store.holdSave
              ..saveError = store.saveError
              ..readError = store.readError;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Strings strings(WidgetTester tester) =>
      Strings.of(tester.element(find.byType(Scaffold).first));

  Finder field(String path) => find.byKey(ValueKey('adv1215-field-$path'));

  group('what the page shows', () {
    testWidgets('exactly the fields of the table the schema brings', (
      tester,
    ) async {
      await pumpPage(tester, ServerConfigPage.main, _mainSchema);

      expect(field('model_context_length'), findsOneWidget);
      expect(field('agent.reasoning_effort'), findsOneWidget);
      expect(field('model'), findsNothing);
      expect(field('model.extra'), findsNothing);
      expect(field('model.api_key'), findsNothing);
      expect(find.text('Esfuerzo de razonamiento'), findsOneWidget);
      expect(find.text('Contexto del modelo'), findsOneWidget);
    });

    testWidgets('reads the values once, when it opens', (tester) async {
      await pumpPage(tester, ServerConfigPage.main, _mainSchema);
      await tester.pump(const Duration(minutes: 5));

      expect(store.reads, 1);
      expect(find.text('low'), findsOneWidget);
    });

    testWidgets('a field without an own title uses the schema description', (
      tester,
    ) async {
      await pumpPage(tester, ServerConfigPage.behavior, _behaviorSchema);
      expect(find.text('Zona horaria'), findsOneWidget);
    });

    testWidgets('the page failure names the cause and asks no write', (
      tester,
    ) async {
      store.readError = const ServerConfigException(
        ServerConfigFailureKind.permissionDenied,
      );
      await pumpPage(tester, ServerConfigPage.main, _mainSchema);

      expect(find.text(strings(tester).adv1215LoadDenied), findsOneWidget);
      expect(field('model_context_length'), findsNothing);
    });
  });

  group('confirmed writes', () {
    testWidgets('a switch saves on the tap, once', (tester) async {
      await pumpPage(tester, ServerConfigPage.shell, _shellSchema);

      await tester.tap(
        find.descendant(
          of: field('terminal.persistent_shell'),
          matching: find.byType(Switch),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(store.saves, [('terminal.persistent_shell', true)]);
      final toggle = tester.widget<Switch>(
        find.descendant(
          of: field('terminal.persistent_shell'),
          matching: find.byType(Switch),
        ),
      );
      expect(toggle.value, isTrue);
    });

    testWidgets('a select saves the picked option on selection', (
      tester,
    ) async {
      await pumpPage(tester, ServerConfigPage.main, _mainSchema);

      await tester.tap(field('agent.reasoning_effort'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('high'));
      await tester.pumpAndSettle();

      expect(store.saves, [('agent.reasoning_effort', 'high')]);
      expect(find.text('high'), findsOneWidget);
    });

    testWidgets('typing sends nothing until Save', (tester) async {
      await pumpPage(tester, ServerConfigPage.behavior, _behaviorSchema);

      await tester.tap(field('timezone'));
      await tester.pumpAndSettle();
      for (final text in ['E', 'Eu', 'Eur', 'Euro', 'Europe/Madrid']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
      }
      expect(store.saves, isEmpty);
      expect(store.reads, 1, reason: 'only the read of opening the page');

      await tester.tap(find.text(strings(tester).commonSave));
      await tester.pumpAndSettle();

      expect(store.saves, [('timezone', 'Europe/Madrid')]);
      expect(find.text('Europe/Madrid'), findsOneWidget);
    });

    testWidgets('cancelling the editor sends nothing', (tester) async {
      await pumpPage(tester, ServerConfigPage.behavior, _behaviorSchema);
      await tester.tap(field('timezone'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Europe/Madrid');
      await tester.tap(find.text(strings(tester).commonCancel));
      await tester.pumpAndSettle();

      expect(store.saves, isEmpty);
      expect(find.text('UTC'), findsOneWidget);
    });

    testWidgets('a number saves as a number, and a bad one cannot be saved', (
      tester,
    ) async {
      await pumpPage(tester, ServerConfigPage.runtime, _runtimeSchema);
      await tester.tap(field('agent.max_turns'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'many');
      await tester.pump();
      expect(find.text(strings(tester).adv1215NumberInvalid), findsOneWidget);
      await tester.tap(find.text(strings(tester).commonSave));
      await tester.pump();
      expect(store.saves, isEmpty);

      await tester.enterText(find.byType(TextField), '50');
      await tester.pump();
      await tester.tap(find.text(strings(tester).commonSave));
      await tester.pumpAndSettle();

      expect(store.saves, [('agent.max_turns', 50)]);
    });

    testWidgets('a whole-number field refuses a fraction', (tester) async {
      await pumpPage(tester, ServerConfigPage.runtime, _runtimeSchema);
      await tester.tap(field('agent.max_turns'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '2.5');
      await tester.pump();
      expect(find.text(strings(tester).adv1215IntegerInvalid), findsOneWidget);
    });

    testWidgets('a list saves one string per line, blanks dropped', (
      tester,
    ) async {
      await pumpPage(tester, ServerConfigPage.shell, _shellSchema);
      await tester.tap(field('terminal.env_passthrough'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'A\n\n  C  \n');
      await tester.pump();
      await tester.tap(find.text(strings(tester).commonSave));
      await tester.pumpAndSettle();

      expect(store.saves, [
        ('terminal.env_passthrough', ['A', 'C']),
      ]);
    });

    testWidgets('a value the server did not keep goes back and says so', (
      tester,
    ) async {
      store.saveError = const ServerConfigException(
        ServerConfigFailureKind.notSaved,
        serverValue: false,
      );
      await pumpPage(tester, ServerConfigPage.shell, _shellSchema);

      await tester.tap(
        find.descendant(
          of: field('terminal.persistent_shell'),
          matching: find.byType(Switch),
        ),
      );
      await tester.pump();
      await tester.pump();

      final toggle = tester.widget<Switch>(
        find.descendant(
          of: field('terminal.persistent_shell'),
          matching: find.byType(Switch),
        ),
      );
      expect(toggle.value, isFalse);
      expect(find.text(strings(tester).adv1215SaveFailed), findsWidgets);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a control is disabled while its own save is in flight', (
      tester,
    ) async {
      store.holdSave = Completer<void>();
      await pumpPage(tester, ServerConfigPage.shell, _shellSchema);

      await tester.tap(
        find.descendant(
          of: field('terminal.persistent_shell'),
          matching: find.byType(Switch),
        ),
      );
      await tester.pump();

      expect(find.text(strings(tester).adv1215Saving), findsOneWidget);
      final toggle = tester.widget<Switch>(
        find.descendant(
          of: field('terminal.persistent_shell'),
          matching: find.byType(Switch),
        ),
      );
      expect(toggle.onChanged, isNull);
      store.holdSave!.complete();
      await tester.pump();
      await tester.pump();
    });
  });

  group('read only', () {
    testWidgets('controls are disabled and the existing text is shown', (
      tester,
    ) async {
      await pumpPage(
        tester,
        ServerConfigPage.shell,
        _shellSchema,
        readOnly: true,
      );

      final toggle = tester.widget<Switch>(
        find.descendant(
          of: field('terminal.persistent_shell'),
          matching: find.byType(Switch),
        ),
      );
      expect(toggle.onChanged, isNull);
      await tester.tap(field('terminal.env_passthrough'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(store.saves, isEmpty);
      expect(
        find.text(strings(tester).chaCompressionConfigReadOnly),
        findsOneWidget,
      );
    });
  });

  group('lifecycle', () {
    testWidgets('leaving the page mid-save leaves no error behind', (
      tester,
    ) async {
      store.holdSave = Completer<void>();
      await pumpPage(tester, ServerConfigPage.shell, _shellSchema);
      await tester.tap(
        find.descendant(
          of: field('terminal.persistent_shell'),
          matching: find.byType(Switch),
        ),
      );
      await tester.pump();

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      store.holdSave!.complete();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('a profile switch reads again and drops the late save', (
      tester,
    ) async {
      store.holdSave = Completer<void>();
      final profiles = <String>[];
      await pumpPage(
        tester,
        ServerConfigPage.shell,
        _shellSchema,
        profiles: profiles,
      );
      final first = store;
      await tester.tap(
        find.descendant(
          of: field('terminal.persistent_shell'),
          matching: find.byType(Switch),
        ),
      );
      await tester.pump();

      store.holdSave = null; // the next store answers at once
      await manager.setActiveProfile('conn-adv1215', 'work');
      await tester.pump();
      await tester.pump();
      expect(profiles, ['', 'work']);
      expect(store, isNot(same(first)));
      expect(store.reads, 1);

      first.holdSave!.complete();
      await tester.pump();
      await tester.pump();

      final toggle = tester.widget<Switch>(
        find.descendant(
          of: field('terminal.persistent_shell'),
          matching: find.byType(Switch),
        ),
      );
      expect(toggle.value, isFalse, reason: 'the late answer is not applied');
      expect(tester.takeException(), isNull);
    });
  });

  group('deep link', () {
    testWidgets('highlights the row once, then lets it go', (tester) async {
      await pumpPage(
        tester,
        ServerConfigPage.main,
        _mainSchema,
        highlightPath: 'agent.reasoning_effort',
      );

      expect(
        find.byKey(const ValueKey('adv1215-highlight-agent.reasoning_effort')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(
        find.byKey(const ValueKey('adv1215-highlight-agent.reasoning_effort')),
        findsNothing,
      );
    });

    testWidgets('no highlight without a target', (tester) async {
      await pumpPage(tester, ServerConfigPage.main, _mainSchema);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'adv1215-highlight-',
              ),
        ),
        findsNothing,
      );
    });
  });
}
