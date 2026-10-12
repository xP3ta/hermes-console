// Regression for a degraded gateway fallback using the real loader/cache.
// Synthetic sources and fake time; this is not physical-device evidence.
// ignore_for_file: avoid_print

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/model_active_info.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/services/model_picker_loader.dart';

ModelPickerResult _result(ModelPickerSource source, List<String> models) =>
    ModelPickerResult(
      info: const ModelActiveInfo(
        model: 'gpt-5.5',
        provider: 'openai-codex',
        effectiveContextLength: 0,
      ),
      providers: [
        ModelProvider(
          slug: source == ModelPickerSource.gateway
              ? 'gateway'
              : 'openai-codex',
          name: source.name,
          isCurrent: true,
          authenticated: true,
          authType: '',
          oauthProviderId: '',
          keyEnv: '',
          warning: '',
          models: models,
        ),
      ],
      source: source,
    );

class _Src {
  _Src(this.source, this.delay, this.models);
  final ModelPickerSource source;
  Duration delay;
  final List<String> models;
  bool fails = false;
  int calls = 0;
  Future<ModelPickerResult?> call() async {
    calls++;
    await Future<void>.delayed(delay);
    if (fails) throw StateError('${source.name} failed');
    return _result(source, models);
  }
}

void main() {
  test('degraded reopen after five seconds retries once and coalesces', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026).add(async.elapsed),
      );
      final socket = _Src(
        ModelPickerSource.socket,
        const Duration(milliseconds: 90),
        ['real-model'],
      )..fails = true;
      final dashboard = _Src(
        ModelPickerSource.dashboard,
        const Duration(seconds: 5),
        ['real-model'],
      );
      final gateway = _Src(
        ModelPickerSource.gateway,
        const Duration(milliseconds: 150),
        ['hermes-agent'],
      );
      final sources = <ModelPickerSource, ModelPickerSourceLoader>{
        ModelPickerSource.socket: socket.call,
        ModelPickerSource.dashboard: dashboard.call,
        ModelPickerSource.gateway: gateway.call,
      };
      ModelPickerResult? first;
      loadModelPickerCatalog(
        cache: cache,
        key: 'k',
        sources: sources,
      ).then((r) => first = r);
      async.elapse(const Duration(milliseconds: 4240));
      expect(first?.catalogAvailability, ModelPickerAvailability.degraded);
      expect(cache.peek('k'), isNull);
      async.elapse(const Duration(seconds: 5));
      dashboard.delay = const Duration(milliseconds: 300);
      final a = loadModelPickerCatalog(
        cache: cache,
        key: 'k',
        sources: sources,
      );
      final b = loadModelPickerCatalog(
        cache: cache,
        key: 'k',
        sources: sources,
      );
      expect(a, same(b));
      ModelPickerResult? recovered;
      a.then((r) => recovered = r);
      async.elapse(const Duration(seconds: 1));
      expect(recovered?.source, ModelPickerSource.dashboard);
      expect(recovered?.catalogAvailability, ModelPickerAvailability.available);
      expect(socket.calls, 2);
      expect(dashboard.calls, 2);
      expect(gateway.calls, 1);
      expect(cache.peek('k')?.fresh, isTrue);
      async.elapse(const Duration(seconds: 75));
      socket.fails = false;
      ModelPickerResult? later;
      loadModelPickerCatalog(
        cache: cache,
        key: 'k',
        sources: sources,
      ).then((r) => later = r);
      async.elapse(const Duration(seconds: 1));
      expect(later?.source, ModelPickerSource.socket);
      expect(socket.calls, 3);
      expect(gateway.calls, 1);
    });
  });

  test('without recovery only explicit opens retry, never an idle loop', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026).add(async.elapsed),
      );
      final socket = _Src(ModelPickerSource.socket, Duration.zero, [
        'real-model',
      ])..fails = true;
      final dashboard = _Src(ModelPickerSource.dashboard, Duration.zero, [
        'real-model',
      ])..fails = true;
      final bridge = _Src(ModelPickerSource.officialGateway, Duration.zero, [
        'real-model',
      ])..fails = true;
      final gateway = _Src(ModelPickerSource.gateway, Duration.zero, [
        'hermes-agent',
      ]);
      final sources = <ModelPickerSource, ModelPickerSourceLoader>{
        ModelPickerSource.socket: socket.call,
        ModelPickerSource.dashboard: dashboard.call,
        ModelPickerSource.officialGateway: bridge.call,
        ModelPickerSource.gateway: gateway.call,
      };
      loadModelPickerCatalog(cache: cache, key: 'k', sources: sources);
      async.elapse(const Duration(seconds: 5));
      expect(socket.calls, 1);
      loadModelPickerCatalog(cache: cache, key: 'k', sources: sources);
      loadModelPickerCatalog(cache: cache, key: 'k', sources: sources);
      async.elapse(const Duration(seconds: 1));
      expect(socket.calls, 2);
      expect(dashboard.calls, 2);
      expect(bridge.calls, 1, reason: 'Bridge cooldown is retained');
      expect(gateway.calls, 2);
      async.elapse(const Duration(minutes: 2));
      expect(socket.calls, 2, reason: 'no automatic retry timer');
      expect(dashboard.calls, 2);
      expect(cache.peek('k'), isNull);
    });
  });

  test('degradation never crosses connection or profile and stale expires', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026).add(async.elapsed),
      );
      final a = ModelPickerCache.key('a', 'work');
      final b = ModelPickerCache.key('b', 'work');
      final c = ModelPickerCache.key('a', 'other');
      final prior = _result(ModelPickerSource.socket, ['valid-model']);
      cache.write(a, prior);
      cache.write(b, prior);
      cache.write(c, prior);
      cache.write(a, _result(ModelPickerSource.gateway, ['hermes-agent']));
      expect(cache.peek(a)?.fresh, isFalse);
      expect(cache.peek(b)?.fresh, isTrue);
      expect(cache.peek(c)?.fresh, isTrue);
      async.elapse(const Duration(minutes: 30));
      expect(cache.peek(a), isNull);
    });
  });

  test('all sources failing preserves valid stale inventory', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026).add(async.elapsed),
      );
      final prior = _result(ModelPickerSource.dashboard, ['valid-model']);
      cache.write('k', prior);
      cache.invalidate('k');
      ModelPickerResult? got;
      Object? error;
      loadModelPickerCatalog(
        cache: cache,
        key: 'k',
        sources: {
          ModelPickerSource.socket: () async => null,
          ModelPickerSource.dashboard: () async => null,
          ModelPickerSource.gateway: () async => null,
        },
      ).then<void>(
        (value) {
          got = value;
        },
        onError: (Object e) {
          error = e;
        },
      );
      async.flushMicrotasks();
      expect(error, isNull);
      expect(got?.providers.single.models, ['valid-model']);
      expect(got?.catalogAvailability, ModelPickerAvailability.stale);
      expect(cache.peek('k')?.fresh, isFalse);
    });
  });

  test('failed refresh preserves the last valid catalog as stale', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026).add(async.elapsed),
      );
      final prior = _result(ModelPickerSource.socket, ['valid-model']);
      cache.write('k', prior);
      cache.invalidate('k');
      ModelPickerResult? got;
      loadModelPickerCatalog(
        cache: cache,
        key: 'k',
        sources: {
          ModelPickerSource.socket: () async => null,
          ModelPickerSource.dashboard: () async => null,
          ModelPickerSource.gateway: () async =>
              _result(ModelPickerSource.gateway, ['hermes-agent']),
        },
      ).then((value) => got = value);
      async.flushMicrotasks();
      expect(got?.providers.single.models, ['valid-model']);
      expect(got?.catalogAvailability, ModelPickerAvailability.stale);
      expect(cache.peek('k')?.fresh, isFalse);
      expect(cache.peek('k')?.result, same(prior));
    });
  });

  test('one degraded load must not pin the picker to the gateway alias', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026, 10, 8).add(async.elapsed),
      );
      const key = 'conn\u0000default';
      final socket = _Src(
        ModelPickerSource.socket,
        const Duration(milliseconds: 90),
        ['gpt-5.5', 'claude'],
      );
      final dashboard = _Src(
        ModelPickerSource.dashboard,
        const Duration(seconds: 5),
        ['gpt-5.5', 'claude'],
      );
      final gateway = _Src(
        ModelPickerSource.gateway,
        const Duration(milliseconds: 150),
        ['hermes-agent'],
      );
      // Bridge deliberately omitted from the synthetic source set.
      final sources = <ModelPickerSource, ModelPickerSourceLoader>{
        ModelPickerSource.socket: socket.call,
        ModelPickerSource.dashboard: dashboard.call,
        ModelPickerSource.gateway: gateway.call,
      };

      ModelPickerResult? load() {
        final cached = cache.peek(key);
        if (cached != null && cached.fresh) {
          return cached.result; // what _showModelSheet paints
        }
        ModelPickerResult? out;
        loadModelPickerCatalog(
          cache: cache,
          key: key,
          sources: sources,
        ).then((r) => out = r);
        async.elapse(const Duration(seconds: 30));
        return out;
      }

      // 1) Synthetic degradation: socket fails and Dashboard exceeds the timeout.
      socket.fails = true;
      final first = load();
      print('PICKER first source=${first?.source.name}');
      expect(
        first?.source,
        ModelPickerSource.gateway,
        reason: 'precondition: degraded load falls to gateway',
      );

      // 2) Network recovers 5 s later; the user reopens the sheet.
      socket.fails = false;
      dashboard.delay = const Duration(milliseconds: 300);
      async.elapse(const Duration(seconds: 5));
      final second = load();
      print(
        'PICKER second source=${second?.source.name} socketCalls=${socket.calls}',
      );

      // 3) And again after the failure cooldown but within the stale window.
      async.elapse(const Duration(seconds: 70));
      final third = load();
      print(
        'PICKER third source=${third?.source.name} socketCalls=${socket.calls}',
      );

      // Desired invariant: the gateway alias is a degraded last resort, never cached as an
      // authoritative catalog that hides a healthy socket/Dashboard on the next open.
      expect(
        second?.source,
        isNot(ModelPickerSource.gateway),
        reason: 'reopen after recovery',
      );
      expect(
        third?.source,
        isNot(ModelPickerSource.gateway),
        reason: 'after cooldown',
      );
    });
  });
}
