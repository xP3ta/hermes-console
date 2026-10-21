// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/model_readiness.dart';
import 'package:hermes_android/core/services/onboarding_arrival.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ModelProvider _provider(
  String slug, {
  bool authenticated = true,
  List<String> models = const [],
  String name = '',
}) => ModelProvider.fromJson({
  'slug': slug,
  'name': name.isEmpty ? slug : name,
  'authenticated': authenticated,
  'models': models,
});

ModelActiveInfo _info(String model, String provider) => ModelActiveInfo(
  model: model,
  provider: provider,
  effectiveContextLength: 0,
);

DashboardClient _client(Future<http.Response> Function(http.Request) handler) =>
    DashboardClient(
      host: '192.168.1.20',
      manualToken: 'synthetic-token',
      httpClientOverride: MockClient(handler),
    );

void main() {
  tearDown(OnboardingArrival.reset);

  group('OnboardingArrival (RED 6)', () {
    test('is taken once, for its own connection', () {
      OnboardingArrival.request('a');
      expect(OnboardingArrival.take('a'), isTrue);
      expect(OnboardingArrival.take('a'), isFalse);
    });

    test('another connection id drops the request', () {
      OnboardingArrival.request('a');
      expect(OnboardingArrival.take('b'), isFalse);
      expect(OnboardingArrival.take('a'), isFalse);
    });

    test('a request older than 30 s is dropped', () {
      var now = DateTime(2026, 10, 18, 12);
      OnboardingArrival.now = () => now;
      OnboardingArrival.request('a');
      now = now.add(const Duration(seconds: 31));
      expect(OnboardingArrival.take('a'), isFalse);
      OnboardingArrival.request('a');
      now = now.add(const Duration(seconds: 29));
      expect(OnboardingArrival.take('a'), isTrue);
    });

    test('a new request replaces the pending one', () {
      OnboardingArrival.request('a');
      OnboardingArrival.request('b');
      expect(OnboardingArrival.take('a'), isFalse);
    });
  });

  group('activeModelUsable (RED 7: the Models screen rule, moved)', () {
    test('no provider is signed in', () {
      expect(
        activeModelUsable(_info('gpt-x', 'openai'), [
          _provider('openai', authenticated: false),
        ]),
        isFalse,
      );
      expect(activeModelUsable(_info('gpt-x', 'openai'), const []), isFalse);
    });

    test('matches by slug, alias, name or by listing the model', () {
      expect(
        activeModelUsable(_info('x', 'OpenAI'), [_provider('openai')]),
        isTrue,
      );
      expect(
        activeModelUsable(_info('x', 'nous'), [_provider('p', name: 'Nous')]),
        isTrue,
      );
      expect(
        activeModelUsable(_info('GPT-X', ''), [
          _provider('other', models: ['gpt-x']),
        ]),
        isTrue,
      );
      expect(activeModelUsable(_info('', ''), [_provider('openai')]), isFalse);
      expect(
        activeModelUsable(_info('gpt-y', 'anthropic'), [
          _provider('openai', models: ['gpt-x']),
        ]),
        isFalse,
      );
    });

    test('a user-defined endpoint is matched through its alias', () {
      final custom = ModelProvider.fromJson({
        'slug': 'ollama',
        'name': 'Ollama',
        'authenticated': true,
        'aliases': ['custom:ollama'],
      });
      expect(activeModelUsable(_info('m', 'custom:ollama'), [custom]), isTrue);
    });
  });

  group('checkModelReadiness', () {
    String body(String path) => path == '/api/model/info'
        ? jsonEncode({'model': 'gpt-x', 'provider': 'openai'})
        : jsonEncode({
            'providers': [
              {
                'slug': 'openai',
                'name': 'OpenAI',
                'authenticated': true,
                'models': ['gpt-x'],
              },
            ],
          });

    test('ready, and both reads carry the profile', () async {
      final seen = <Uri>[];
      final result = await checkModelReadiness(
        _client((r) async {
          seen.add(r.url);
          return http.Response(body(r.url.path), 200);
        }),
        profile: 'work',
      );
      expect(result, ModelReadiness.ready);
      expect(seen.map((u) => u.path).toSet(), {
        '/api/model/info',
        '/api/model/options',
      });
      expect(seen.every((u) => u.queryParameters['profile'] == 'work'), isTrue);
    });

    test('the default profile sends no profile', () async {
      final seen = <Uri>[];
      await checkModelReadiness(
        _client((r) async {
          seen.add(r.url);
          return http.Response(body(r.url.path), 200);
        }),
      );
      expect(seen, hasLength(2));
      expect(
        seen.every((u) => !u.queryParameters.containsKey('profile')),
        isTrue,
      );
    });

    test('an empty default and no signed-in provider needs a model', () async {
      final result = await checkModelReadiness(
        _client((r) async {
          return http.Response(
            r.url.path == '/api/model/info'
                ? jsonEncode({'model': '', 'provider': ''})
                : jsonEncode({'providers': []}),
            200,
          );
        }),
      );
      expect(result, ModelReadiness.needsModel);
    });

    test('an error, a 401 or an old server is unknown, not "none"', () async {
      for (final status in [401, 404, 500]) {
        expect(
          await checkModelReadiness(
            _client((_) async => http.Response('{}', status)),
          ),
          ModelReadiness.unknown,
          reason: 'HTTP $status',
        );
      }
      expect(
        await checkModelReadiness(
          _client((_) async => throw const FormatException('down')),
        ),
        ModelReadiness.unknown,
      );
    });

    test('a read that outlasts 4 s is unknown', () async {
      final never = Completer<http.Response>();
      final result = await checkModelReadiness(
        _client((_) => never.future),
        timeout: const Duration(milliseconds: 50),
      );
      expect(result, ModelReadiness.unknown);
    });
  });
}
