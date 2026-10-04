// Shared fakes for the Capabilities widget tests (no network, no server).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/capabilities/capabilities_repository.dart';
import 'package:hermes_android/core/services/connection_manager.dart'
    show DashboardHttpException;
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

class ScriptedRest implements CapabilitiesRest {
  final Map<String, Object> gets = {};
  final Map<String, Object> posts = {};
  final Map<String, Object> puts = {};
  final List<String> calls = [];
  final List<Map<String, dynamic>> statusQueue = [];
  Object? deleteError;

  Object _resolve(Map<String, Object> table, String endpoint) {
    final path = endpoint.split('?').first;
    return table[endpoint] ??
        table[path] ??
        (throw const DashboardHttpException(404));
  }

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    calls.add('GET $endpoint');
    if (endpoint.startsWith('actions/') && statusQueue.isNotEmpty) {
      return statusQueue.removeAt(0);
    }
    final value = _resolve(gets, endpoint);
    if (value is Exception) throw value;
    if (value is List) return {'data': value};
    return Map<String, dynamic>.from(value as Map);
  }

  @override
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic>? body,
    Duration? timeout,
  }) async {
    calls.add('POST $endpoint');
    final value = _resolve(posts, endpoint);
    if (value is Exception) throw value;
    return Map<String, dynamic>.from(value as Map);
  }

  @override
  Future<Map<String, dynamic>> put(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    calls.add('PUT $endpoint');
    final value = _resolve(puts, endpoint);
    if (value is Exception) throw value;
    return Map<String, dynamic>.from(value as Map);
  }

  @override
  Future<void> delete(String endpoint) async {
    calls.add('DELETE $endpoint');
    if (deleteError is Exception) throw deleteError!;
  }

  List<String> get mutations =>
      calls.where((c) => !c.startsWith('GET ')).toList(growable: false);
}

/// A server with official skills, a plugin catalog and one MCP server.
ScriptedRest populatedServer() => ScriptedRest()
  ..gets['skills'] = [
    {
      'name': 'arxiv',
      'description': 'Search and summarise research papers',
      'category': 'research',
      'enabled': true,
      'provenance': 'hub',
    },
    {
      'name': 'notes',
      'description': 'Hand-made note helper',
      'enabled': false,
      'provenance': 'agent',
    },
  ]
  ..gets['skills/hub/official'] = {
    'skills': [
      {
        'name': 'arxiv',
        'identifier': 'official/research/arxiv',
        'description': 'Search and summarise research papers',
        'category': 'research',
        'installed': true,
      },
      {
        'name': 'docker',
        'identifier': 'official/devops/docker',
        'description': 'Manage containers and compose stacks',
        'category': 'devops',
        'installed': false,
      },
    ],
  }
  ..gets['dashboard/plugins/catalog'] = {
    'entries': [
      {
        'name': 'weather',
        'title': 'Weather',
        'description': 'Forecasts for any city',
        'tier': 'community',
        'maintainer': 'Example Labs',
        'version': '1.2.0',
        'installed': true,
        'runtime_status': 'enabled',
        'update_available': true,
        'capabilities': {
          'provides_tools': ['weather_now'],
          'requires_env': ['WEATHER_KEY'],
        },
      },
    ],
  }
  ..gets['dashboard/plugins/hub'] = {
    'plugins': [
      {
        'name': 'weather',
        'runtime_status': 'enabled',
        'source': 'community',
        'can_remove': true,
      },
    ],
  }
  ..gets['mcp/catalog'] = {'entries': <Object>[]}
  ..gets['mcp/servers'] = {
    'servers': [
      {
        'name': 'docs',
        'transport': 'http',
        'url': 'https://mcp.example.com/docs',
        'enabled': true,
      },
    ],
  };

Future<void> setPhone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget spanishApp(Widget home) => MaterialApp(
  debugShowCheckedModeBanner: false,
  locale: const Locale('es'),
  theme: AppTheme.fromId('dark'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  home: home,
);

CapabilitiesRepository repoOf(ScriptedRest rest) => CapabilitiesRepository(
  rest: rest,
  sleep: (_) async {},
  actionPollInterval: Duration.zero,
);

/// A Dashboard whose launches are held until [releasePost]; once launched the
/// action reads as running for a few reads, then finishes.
final class RacingOpsRest implements CapabilitiesRest {
  final Map<String, Completer<void>> _gates = {};
  final Set<String> _running = {};
  final Map<String, int> _reads = {};
  int posts = 0;
  bool failNextPost = false;

  Completer<void> _gate(String name) =>
      _gates.putIfAbsent(name, () => Completer<void>());

  void releasePost() {
    for (final name in ['doctor', 'security-audit']) {
      final gate = _gate(name);
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  Future<Map<String, dynamic>> get(String endpoint) async {
    final path = endpoint.split('?').first.split('/');
    // Anything that is not an action read (health, usage...) just answers.
    if (path.first != 'actions') {
      return {'ok': true, 'version': '1', 'idle': true};
    }
    final name = path[1];
    if (_running.contains(name)) {
      final reads = _reads[name] = (_reads[name] ?? 0) + 1;
      if (reads > 100) _running.remove(name);
      return {
        'name': name,
        'running': reads <= 100,
        'exit_code': reads <= 100 ? null : 0,
        'lines': <String>[],
      };
    }
    return {
      'name': name,
      'running': false,
      'exit_code': null,
      'lines': <String>[],
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic>? body,
    Duration? timeout,
  }) async {
    final name = endpoint.split('?').first.split('/').last;
    posts++;
    if (failNextPost) {
      failNextPost = false;
      throw const DashboardHttpException(500);
    }
    await _gate(name).future;
    _running.add(name);
    return {'ok': true, 'name': name};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
