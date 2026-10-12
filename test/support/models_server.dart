// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hermes Console contributors
//
// A Hermes Dashboard as the Models screen sees it, with the shapes the real
// handlers answer (hermes_cli/web_routers/models.py, config_env.py, oauth.py):
// catalog rows of connected providers carry no `auth_type`/`key_env`, a user
// endpoint's address is `api_url`, keys live in `/api/env` and accounts in
// `/api/providers/oauth`. State is per profile.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/models_screen.dart';
import 'package:hermes_android/core/services/active_profile_scope.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/model_catalog_cache.dart';
import 'package:hermes_android/core/services/model_picker_loader.dart';
import 'package:hermes_android/core/services/models_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const modelsConnectionId = 'models-fixture';

typedef ModelsRequest = ({
  String method,
  String path,
  String? profile,
  Map<String, dynamic>? body,
});

class ModelsServer {
  ModelsServer();

  /// The default server with its main model on Other: nothing runs on Acme,
  /// so Acme and its key can be removed.
  factory ModelsServer.acmeIdle() => ModelsServer()
    ..mainProvider = 'other'
    ..mainModel = 'next';

  /// Main model of the profile.
  String mainProvider = 'acme';
  String mainModel = 'acme-large';

  /// Context window the server reports for the main model, when it does.
  int? contextLength;

  /// `GET /api/model/options` rows.
  List<Map<String, dynamic>> catalog = [
    {
      'slug': 'acme',
      'name': 'Acme',
      'authenticated': true,
      'is_current': true,
      'models': ['acme-large', 'acme-small'],
    },
    {
      'slug': 'other',
      'name': 'Other',
      'authenticated': true,
      'models': ['next'],
    },
  ];

  /// `GET /api/model/auxiliary` tasks.
  List<Map<String, dynamic>> aux = [
    {'task': 'vision', 'provider': 'auto', 'model': ''},
    {'task': 'compression', 'provider': 'other', 'model': 'next'},
  ];

  /// `GET /api/env`: provider key variables and whether each is set.
  Map<String, bool> keys = {'ACME_API_KEY': true, 'ZETA_API_KEY': false};

  /// Second key variables of a provider card (Kimi's `KIMI_CODING_API_KEY`):
  /// alias -> the card's primary variable.
  Map<String, String> keyAliases = {};

  /// The key variables that keep a catalog provider connected. A provider
  /// named here is in the catalog only while one of them is set, an account
  /// of its id is signed in, or [ambient] names it; any other provider is
  /// always in the catalog.
  Map<String, List<String>> credentials = {};

  /// Providers connected by a credential that is not Hermes' to clear (the
  /// login of another program on the server).
  Set<String> ambient = {};

  /// `GET /api/providers/custom-endpoints` rows.
  List<Map<String, dynamic>> endpoints = [];

  /// `GET /api/providers/oauth` rows.
  List<Map<String, dynamic>> accounts = [];

  /// `GET /api/config`.
  Map<String, dynamic> config = {
    'fallback_providers': <Object>[],
    'agent': {'reasoning_effort': 'medium', 'service_tier': 'normal'},
  };

  /// `POST /api/providers/validate` verdict per key variable.
  Map<String, Map<String, dynamic>> verdicts = {};

  /// Writes that answer success without changing anything.
  bool ignoreKeySave = false;
  bool ignoreKeyDelete = false;
  bool ignoreDisconnect = false;
  bool ignoreConfigSave = false;

  /// What `POST /api/model/set` answers before it is acknowledged.
  Map<String, dynamic>? confirmFirst;

  Completer<void>? optionsGate;

  /// Status of the catalog read; anything but 200 is a failed inventory.
  int optionsStatus = 200;
  final requests = <ModelsRequest>[];

  List<ModelsRequest> get writes => [
    for (final request in requests)
      if (request.method != 'GET') request,
  ];

  List<ModelsRequest> of(String method, String path) => [
    for (final request in requests)
      if (request.method == method && request.path == path) request,
  ];

  static String _label(String key) {
    final name = key.split('_').first.toLowerCase();
    return name[0].toUpperCase() + name.substring(1);
  }

  Map<String, dynamic> _env() => {
    for (final entry in keys.entries)
      entry.key: {
        'is_set': entry.value,
        'redacted_value': entry.value ? '…test' : null,
        'category': 'provider',
        'is_password': true,
        'advanced': false,
        'provider': (keyAliases[entry.key] ?? entry.key)
            .split('_')
            .first
            .toLowerCase(),
        'provider_label': _label(keyAliases[entry.key] ?? entry.key),
        'provider_primary': !keyAliases.containsKey(entry.key),
        'provider_profiles': <Object>[],
      },
  };

  /// `model_catalog.excluded_providers` of the profile, lower-cased.
  Set<String> get _excluded {
    final catalog = config['model_catalog'];
    final list = catalog is Map ? catalog['excluded_providers'] : null;
    return {
      if (list is List)
        for (final slug in list) '$slug'.trim().toLowerCase(),
    };
  }

  /// The catalog as Hermes builds it: without the providers the profile
  /// excludes (a user endpoint, the local runtime and MoA are not subject to
  /// that list) and without those whose credential is gone.
  List<Map<String, dynamic>> _options() {
    final excluded = _excluded;
    final named = catalog.any((row) => row['slug'] == mainProvider);
    bool listed(Map<String, dynamic> row) {
      final slug = row['slug'] as String;
      final fixed =
          row['is_user_defined'] == true ||
          const {'virtual', 'local-runtime'}.contains(row['source']);
      if (!fixed && excluded.contains(slug.toLowerCase())) return false;
      final vars = credentials[slug];
      if (vars == null) return true;
      return vars.any((key) => keys[key] == true) ||
          ambient.contains(slug) ||
          accounts.any(
            (account) =>
                account['id'] == slug &&
                (account['status'] as Map?)?['logged_in'] == true,
          );
    }

    return [
      for (final row in catalog)
        if (listed(row))
          {...row, if (named) 'is_current': row['slug'] == mainProvider},
    ];
  }

  DashboardClient client() => DashboardClient(
    host: '127.0.0.1',
    manualToken: 'synthetic-fixture-token',
    httpClientOverride: MockClient((request) async {
      final path = request.url.path;
      final body = request.body.isEmpty
          ? null
          : (jsonDecode(request.body) as Map).cast<String, dynamic>();
      requests.add((
        method: request.method,
        path: path,
        profile: request.url.queryParameters['profile'],
        body: body,
      ));
      http.Response json(Object value, [int status = 200]) =>
          http.Response.bytes(
            utf8.encode(jsonEncode(value)),
            status,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
      const endpointsPath = '/api/providers/custom-endpoints/';
      if (path.startsWith(endpointsPath) && request.method == 'DELETE') {
        final id = Uri.decodeComponent(path.substring(endpointsPath.length));
        endpoints.removeWhere((endpoint) => endpoint['id'] == id);
        catalog.removeWhere((row) => row['slug'] == id);
        return json({'ok': true, 'endpoints': endpoints});
      }
      if (path.startsWith('/api/providers/oauth/')) {
        final id = path.split('/').last;
        if (request.method == 'DELETE') {
          if (!ignoreDisconnect) {
            for (final account in accounts) {
              if (account['id'] == id) {
                account['status'] = {'logged_in': false};
              }
            }
          }
          return json({'ok': true, 'provider': id});
        }
        return json({}, 404);
      }
      switch (path) {
        case '/api/model/info':
          return json({
            'model': mainModel,
            'provider': mainProvider,
            'effective_context_length': ?contextLength,
          });
        case '/api/model/options':
          await optionsGate?.future;
          return optionsStatus == 200
              ? json({'providers': _options()})
              : json({'detail': 'busy'}, optionsStatus);
        case '/api/model/auxiliary':
          return json({
            'tasks': aux,
            'main': {'provider': mainProvider, 'model': mainModel},
          });
        case '/api/model/set':
          final ask = confirmFirst;
          if (ask != null && body?['confirm_expensive_model'] != true) {
            return json(ask);
          }
          if (body?['scope'] == 'main') {
            mainProvider = body!['provider'] as String;
            mainModel = body['model'] as String;
          } else if (body?['task'] == '__reset__') {
            for (final task in aux) {
              task
                ..['provider'] = 'auto'
                ..['model'] = '';
            }
          } else {
            for (final task in aux) {
              if (task['task'] == body?['task']) {
                task
                  ..['provider'] = body!['provider']
                  ..['model'] = body['model'];
              }
            }
          }
          return json({'ok': true});
        case '/api/providers/oauth':
          return json({'providers': accounts});
        case '/api/providers/custom-endpoints':
          return json({'endpoints': endpoints});
        case '/api/providers/validate':
          return json(
            verdicts[body?['key']] ??
                {'ok': true, 'reachable': false, 'message': ''},
          );
        case '/api/env':
          final key = body?['key'] as String?;
          if (request.method == 'PUT') {
            if (!ignoreKeySave) keys[key!] = true;
            return json({'ok': true});
          }
          if (request.method == 'DELETE') {
            if (keys[key] != true) return json({'detail': 'not found'}, 404);
            if (!ignoreKeyDelete) keys[key!] = false;
            return json({'ok': true, 'found': true});
          }
          return json(_env());
        case '/api/config':
          if (request.method == 'PUT') {
            if (ignoreConfigSave) return json({'ok': true});
            final patch = (body!['config'] as Map).cast<String, dynamic>();
            for (final entry in patch.entries) {
              final current = config[entry.key];
              config[entry.key] = current is Map && entry.value is Map
                  ? {...current, ...entry.value as Map}
                  : entry.value;
            }
            return json({'ok': true});
          }
          return json(config);
      }
      return json({}, 404);
    }),
  );
}

/// The profile the fixture screen is opened on.
Future<ActiveProfileScope> modelsScope([String profile = 'ana']) async {
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
  final manager = await ConnectionManager.create(
    await SharedPreferences.getInstance(),
  );
  await manager.setActiveProfile(modelsConnectionId, profile);
  return ActiveProfileScope.of(manager, modelsConnectionId);
}

Future<void> pumpModels(
  WidgetTester tester,
  ModelsServer server,
  ActiveProfileScope scope, {
  bool readOnly = false,
  ModelsSnapshotCache? cache,
  DashboardClient? client,
  ({ModelPickerCache picker, ModelCatalogCache catalog})? chatCatalogs,
}) async {
  tester.view.physicalSize = const Size(412, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.hermesRedDark,
      localizationsDelegates: Strings.localizationsDelegates,
      supportedLocales: Strings.supportedLocales,
      home: ModelsScreen(
        key: UniqueKey(),
        connection: SavedConnection(
          id: modelsConnectionId,
          label: 'Fixture',
          host: '127.0.0.1',
          port: 8642,
          apiKey: 'synthetic-connection-token',
          readOnly: readOnly,
          // A remote server: an instance on this phone only shows a local
          // model as its active one.
          kind: InstanceKind.vps,
        ),
        dashboardClientForTesting: client ?? server.client(),
        profileScope: scope,
        gatewayCatalogForTesting: () => null,
        snapshotCache: cache,
        chatCatalogsForTesting: chatCatalogs,
      ),
    ),
  );
}

/// Scrolls [target] into view, taps it and lets the screen settle.
Future<void> tapOn(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Finder modelsKey(String key) => find.byKey(ValueKey(key));

Finder inDialog(String label) => find.descendant(
  of: find.byKey(const ValueKey('hermes-dialog')),
  matching: find.text(label),
);

/// Opens a collapsible block of the page unless it already is: [inside] is
/// something only its open state shows.
Future<void> openBlock(WidgetTester tester, String key, Finder inside) async {
  if (inside.evaluate().isNotEmpty) return;
  await tapOn(tester, modelsKey(key));
}

bool _keyStartsWith(Widget widget, String prefix) {
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith(prefix);
}

/// "Unconfigured providers": what can still be connected.
Future<void> openUnconfigured(WidgetTester tester) => openBlock(
  tester,
  'models-unconfigured',
  find.descendant(
    of: modelsKey('models-unconfigured'),
    matching: find.byType(TextButton),
  ),
);

/// "Models by function": the auxiliary tasks.
Future<void> openAux(WidgetTester tester) =>
    openBlock(tester, 'models-aux', find.byIcon(Icons.route_outlined));

/// The group of one connected provider, with its models.
Future<void> openProvider(WidgetTester tester, String slug) => openBlock(
  tester,
  'models-provider-$slug',
  find.byWidgetPredicate(
    (widget) => _keyStartsWith(widget, 'models-model-$slug-'),
  ),
);

/// The row of [model] inside the open group of provider [slug].
Finder modelRow(String slug, String model) =>
    modelsKey('models-model-$slug-$model');
