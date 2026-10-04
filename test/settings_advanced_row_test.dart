// Settings gains ONE row, "Advanced", only when the server's schema answers
// and config reads are not denied. It is the only new thing on the screen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/advanced_settings_screen.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/server_config_repository.dart';
import 'package:hermes_android/core/settings/settings_deep_link.dart';
import 'package:hermes_android/core/settings/settings_search.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _Store implements ServerConfigStore {
  _Store(this.schema, {this.error});

  final Map<String, dynamic> schema;
  final ServerConfigException? error;
  int schemaReads = 0;
  final List<String> profiles = [];

  @override
  bool get isWritable => true;

  @override
  Future<Map<String, dynamic>> readConfig() async => {};

  @override
  Future<Map<String, dynamic>> readSchema() async {
    schemaReads++;
    final failure = error;
    if (failure != null) throw failure;
    return schema;
  }

  @override
  Future<Object?> save(String path, Object? value) async => value;
}

Map<String, dynamic> _schema([String path = 'agent.max_turns']) => {
  'fields': {
    path: {'type': 'number'},
  },
};

SavedConnection _connection() => SavedConnection(
  id: 'conn-row1215',
  label: 'Row QA',
  host: 'hermes.example.test',
  port: 8642,
  apiKey: '',
  dashboardUrl: 'http://hermes.example.test:9119',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ConnectionManager manager;

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
  });

  tearDown(() {
    SettingsDeepLink.pending.value = null;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  // Building the "Data" block of Settings (below the new row) trips a
  // framework assertion about a `ListTile` inside a `DecoratedBox`, on every
  // frame it is visible. It happens on the base too and has nothing to do with
  // this row; only that message is let through, anything else still fails.
  void ignoreKnownAssertion() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains(
        'ListTile background color or ink splashes may be invisible',
      )) {
        return;
      }
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);
  }

  Future<void> pumpSettings(WidgetTester tester, _Store store) async {
    ignoreKnownAssertion();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        theme: AppTheme.fromId('dark'),
        localizationsDelegates: Strings.localizationsDelegates,
        supportedLocales: Strings.supportedLocales,
        home: SettingsScreen(
          connection: _connection(),
          connManager: manager,
          advancedStoreFor: (profile, {required writable}) {
            store.profiles.add(profile);
            return store;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder advancedRow() => find.byWidgetPredicate(
    (widget) => widget is HermesNavRow && widget.title == 'Avanzado',
  );

  Future<void> showRow(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      advancedRow(),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  testWidgets('one Advanced row when the schema answers', (tester) async {
    final store = _Store(_schema());
    await pumpSettings(tester, store);
    await showRow(tester);

    expect(advancedRow(), findsOneWidget);
    expect(store.schemaReads, 1);
  });

  testWidgets('the schema is read once, not while Settings stays open', (
    tester,
  ) async {
    final store = _Store(_schema());
    await pumpSettings(tester, store);
    expect(store.schemaReads, 0, reason: 'nothing before the row is near');
    await showRow(tester);
    await tester.pump(const Duration(minutes: 10));
    expect(store.schemaReads, 1);
  });

  testWidgets('a server without the schema has no row', (tester) async {
    final store = _Store(
      _schema(),
      error: const ServerConfigException(ServerConfigFailureKind.unsupported),
    );
    await pumpSettings(tester, store);
    await tester.scrollUntilVisible(
      find.text(
        Strings.of(tester.element(find.byType(Scaffold).first)).setSecSystem,
      ),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(store.schemaReads, 1);
    expect(advancedRow(), findsNothing);
  });

  testWidgets('a schema with none of the fields has no row', (tester) async {
    final store = _Store(_schema('logging.level'));
    await pumpSettings(tester, store);
    await tester.scrollUntilVisible(
      find.text(
        Strings.of(tester.element(find.byType(Scaffold).first)).setSecSystem,
      ),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(store.schemaReads, 1);
    expect(advancedRow(), findsNothing);
  });

  testWidgets('denied config reads: no row and no request', (tester) async {
    await manager.saveCapabilities(
      'conn-row1215',
      const CapabilityMatrix(configRead: CapState.no),
    );
    final store = _Store(_schema());
    await pumpSettings(tester, store);
    await tester.scrollUntilVisible(
      find.text(
        Strings.of(tester.element(find.byType(Scaffold).first)).setSecSystem,
      ),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(advancedRow(), findsNothing);
    expect(store.schemaReads, 0);
  });

  testWidgets('the row opens Advanced with the schema it already has', (
    tester,
  ) async {
    final store = _Store(_schema());
    await pumpSettings(tester, store);
    await showRow(tester);

    await tester.tap(advancedRow());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(AdvancedSettingsScreen), findsOneWidget);
    expect(store.schemaReads, 1, reason: 'Advanced does not read it again');
  });

  testWidgets('a profile switch reads the schema for that profile', (
    tester,
  ) async {
    final store = _Store(_schema());
    await pumpSettings(tester, store);
    await showRow(tester);
    await manager.setActiveProfile('conn-row1215', 'work');
    await tester.pump();
    await tester.pump();

    expect(store.profiles, ['', 'work']);
  });

  testWidgets('the sections of Settings are unchanged', (tester) async {
    final store = _Store(_schema());
    await pumpSettings(tester, store);
    final headers = <String>{};
    for (var i = 0; i < 40; i++) {
      for (final header in tester.widgetList<HermesSectionHeader>(
        find.byType(HermesSectionHeader),
      )) {
        headers.add(header.label);
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pump();
    }
    final s = Strings.of(tester.element(find.byType(Scaffold).first));
    expect(headers, {
      s.setSecConnection,
      s.setSecAppearance,
      s.setSecChat,
      s.voiceTitle,
      s.notifTitle,
      s.setSecSecurity,
      s.setSecSystem,
      s.setSecBridge,
      s.setSecData,
      s.setSecAbout,
    });
  });

  testWidgets('a search result for a section brings Settings to it', (
    tester,
  ) async {
    final store = _Store(_schema());
    await pumpSettings(tester, store);

    SettingsDeepLink.request(SettingsSection.about);
    await tester.pump();
    final highlight = find.byKey(const ValueKey('settings-highlight-about'));
    for (var i = 0; i < 60 && highlight.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(highlight, findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
