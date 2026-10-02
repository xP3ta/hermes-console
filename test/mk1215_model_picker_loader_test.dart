import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/model_active_info.dart';
import 'package:hermes_android/core/models/model_provider.dart';
import 'package:hermes_android/core/services/model_picker_loader.dart';

// mk1215: the chat model picker opens from whichever source answers, caches
// it per connection/profile, races the read-only fallbacks with a short
// timeout instead of waiting for them in series, and remembers a failing
// source for a while. Latencies are measured in fake time with the costs the
// audit measured on the host (socket model.options ≈ 90 ms warm, Dashboard
// ≈ 150 ms per round trip, Bridge 500 in 60 ms or a hang).

ModelPickerResult _result(ModelPickerSource source, {bool empty = false}) =>
    ModelPickerResult(
      info: const ModelActiveInfo(
        model: 'm',
        provider: 'p',
        effectiveContextLength: 0,
      ),
      providers: [
        ModelProvider(
          slug: 'p',
          name: 'P',
          isCurrent: true,
          authenticated: true,
          authType: '',
          oauthProviderId: '',
          keyEnv: '',
          warning: '',
          models: empty ? const [] : const ['m'],
        ),
      ],
      source: source,
    );

class _Source {
  _Source(this.source, this.delay, {this.fails = false, this.hangs = false});

  final ModelPickerSource source;
  final Duration delay;
  bool fails;
  bool hangs;
  int calls = 0;

  Future<ModelPickerResult?> call() async {
    calls++;
    if (hangs) return Completer<ModelPickerResult?>().future;
    await Future<void>.delayed(delay);
    if (fails) throw StateError('${source.name} failed');
    return _result(source);
  }
}

class _Sources {
  _Sources({
    bool socketFails = false,
    bool bridgeFails = false,
    bool bridgeHangs = false,
  }) : socket = _Source(
         ModelPickerSource.socket,
         const Duration(milliseconds: 90),
         fails: socketFails,
       ),
       bridge = _Source(
         ModelPickerSource.bridge,
         const Duration(milliseconds: 60),
         fails: bridgeFails,
         hangs: bridgeHangs,
       ),
       dashboard = _Source(
         ModelPickerSource.dashboard,
         const Duration(milliseconds: 300),
       ),
       gateway = _Source(
         ModelPickerSource.gateway,
         const Duration(milliseconds: 150),
       );

  final _Source socket, bridge, dashboard, gateway;

  Map<ModelPickerSource, ModelPickerSourceLoader> get map => {
    ModelPickerSource.socket: socket.call,
    ModelPickerSource.bridge: bridge.call,
    ModelPickerSource.dashboard: dashboard.call,
    ModelPickerSource.gateway: gateway.call,
  };
}

/// Fake-time latency of one picker load (or of a cached paint).
({Duration latency, ModelPickerResult? result, Object? error}) _measure(
  FakeAsync async,
  ModelPickerCache cache,
  _Sources sources, {
  String key = 'conn\u0000work',
}) {
  final start = async.elapsed;
  final cached = cache.peek(key);
  if (cached != null) {
    // Painted at once; a stale entry refreshes in the background.
    if (!cached.fresh) {
      unawaited(
        loadModelPickerCatalog(
          cache: cache,
          key: key,
          sources: sources.map,
        ).then<void>((_) {}, onError: (Object _) {}),
      );
    }
    return (latency: Duration.zero, result: cached.result, error: null);
  }
  ModelPickerResult? result;
  Object? error;
  Duration? done;
  loadModelPickerCatalog(cache: cache, key: key, sources: sources.map).then(
    (value) {
      result = value;
      done = async.elapsed;
    },
    onError: (Object e) {
      error = e;
      done = async.elapsed;
    },
  );
  async.elapse(const Duration(seconds: 30));
  return (latency: done! - start, result: result, error: error);
}

void main() {
  test('mk1215: frío por socket, caliente desde caché', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026).add(async.elapsed),
      );
      final sources = _Sources();

      final cold = _measure(async, cache, sources);
      expect(cold.result!.source, ModelPickerSource.socket);
      expect(cold.latency, const Duration(milliseconds: 90));
      expect(sources.bridge.calls + sources.dashboard.calls, 0);

      final warm = _measure(async, cache, sources);
      expect(warm.latency, Duration.zero);
      expect(sources.socket.calls, 1, reason: 'fresh cache, no request');
      // ignore: avoid_print
      print(
        'mk1215 picker open: cold socket ${cold.latency.inMilliseconds} ms, '
        'warm cache ${warm.latency.inMilliseconds} ms',
      );
    });
  });

  test(
    'mk1215: caché caducada pinta al instante y refresca en segundo plano',
    () {
      fakeAsync((async) {
        final cache = ModelPickerCache(
          now: () => DateTime(2026).add(async.elapsed),
        );
        final sources = _Sources();
        _measure(async, cache, sources);
        async.elapse(const Duration(seconds: 61));

        final stale = _measure(async, cache, sources);
        expect(stale.latency, Duration.zero);
        expect(stale.result, isNotNull);
        async.elapse(const Duration(seconds: 1));
        expect(sources.socket.calls, 2, reason: 'one background revalidation');
        expect(cache.peek('conn\u0000work')!.fresh, isTrue);

        cache.invalidate('conn\u0000work');
        final afterChange = cache.peek('conn\u0000work');
        expect(
          afterChange,
          isNotNull,
          reason: 'a model change keeps the paint',
        );
        expect(afterChange!.fresh, isFalse);
      });
    },
  );

  test('mk1215: sin socket, Bridge roto y Dashboard compiten en paralelo y se '
      'cachea el Dashboard', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026).add(async.elapsed),
      );
      final sources = _Sources(socketFails: true, bridgeFails: true);

      final cold = _measure(async, cache, sources);
      expect(cold.result!.source, ModelPickerSource.dashboard);
      // Socket failure (90 ms) + Dashboard (300 ms), not Bridge + Dashboard.
      expect(cold.latency, const Duration(milliseconds: 390));
      expect(sources.gateway.calls, 0);

      final warm = _measure(async, cache, sources);
      expect(warm.result!.source, ModelPickerSource.dashboard);
      expect(warm.latency, Duration.zero);
      // ignore: avoid_print
      print(
        'mk1215 picker open, bridge failing: cold '
        '${cold.latency.inMilliseconds} ms, warm '
        '${warm.latency.inMilliseconds} ms',
      );
    });
  });

  test('mk1215: un Bridge colgado no retiene el selector más de 4 s', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026).add(async.elapsed),
      );
      final sources = _Sources(socketFails: true, bridgeHangs: true)
        ..dashboard.fails = true;

      final cold = _measure(async, cache, sources);
      expect(cold.result!.source, ModelPickerSource.gateway);
      // Socket 90 ms + raced fallbacks capped at 4 s + gateway 150 ms.
      expect(cold.latency, const Duration(milliseconds: 4240));
    });
  });

  test(
    'mk1215: una fuente que falla se recuerda y no se reintenta en bucle',
    () {
      fakeAsync((async) {
        final cache = ModelPickerCache(
          now: () => DateTime(2026).add(async.elapsed),
        );
        final sources = _Sources(socketFails: true, bridgeFails: true);
        _measure(async, cache, sources);
        expect(sources.bridge.calls, 1);
        expect(sources.socket.calls, 1);

        // Explicit reloads while the failing sources are still cooling down.
        final key = 'conn\u0000work';
        for (var i = 0; i < 5; i++) {
          loadModelPickerCatalog(cache: cache, key: key, sources: sources.map);
          async.elapse(const Duration(seconds: 1));
        }
        expect(sources.bridge.calls, 1, reason: 'no retry storm');
        expect(sources.socket.calls, 1);
        expect(sources.dashboard.calls, 6);

        // After the cooldown the source is tried again.
        async.elapse(const Duration(seconds: 60));
        loadModelPickerCatalog(cache: cache, key: key, sources: sources.map);
        async.elapse(const Duration(seconds: 1));
        expect(sources.socket.calls, 2);
        expect(sources.bridge.calls, 2);
      });
    },
  );

  test('mk1215: aperturas simultáneas comparten una sola carga', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026).add(async.elapsed),
      );
      final sources = _Sources();
      final a = loadModelPickerCatalog(
        cache: cache,
        key: 'k',
        sources: sources.map,
      );
      final b = loadModelPickerCatalog(
        cache: cache,
        key: 'k',
        sources: sources.map,
      );
      expect(identical(a, b), isTrue);
      async.elapse(const Duration(seconds: 1));
      expect(sources.socket.calls, 1);
    });
  });

  test('mk1215: si nada responde, el error llega al selector', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026).add(async.elapsed),
      );
      final sources = _Sources(socketFails: true, bridgeFails: true)
        ..dashboard.fails = true
        ..gateway.fails = true;
      final run = _measure(async, cache, sources);
      expect(run.error, isA<StateError>());
      expect(cache.peek('conn\u0000work'), isNull);
    });
  });

  test('mk1215: catálogo vacío no se cachea ni gana a uno con modelos', () {
    fakeAsync((async) {
      final cache = ModelPickerCache(
        now: () => DateTime(2026).add(async.elapsed),
      );
      ModelPickerResult? got;
      loadModelPickerCatalog(
        cache: cache,
        key: 'k',
        sources: {
          ModelPickerSource.socket: () async =>
              _result(ModelPickerSource.socket, empty: true),
          ModelPickerSource.dashboard: () async =>
              _result(ModelPickerSource.dashboard),
        },
      ).then((value) => got = value);
      async.elapse(const Duration(seconds: 1));
      expect(got!.source, ModelPickerSource.dashboard);
    });
  });

  test(
    'mk1215: referencia del camino anterior (Bridge y Dashboard en serie, sin '
    'caché)',
    () {
      // Old `_loadModelOptionsRaw` without a runtime: Bridge provision + call,
      // then the Dashboard's two calls in series, on every open.
      fakeAsync((async) {
        final sources = _Sources(bridgeFails: true);
        Duration serialOpen() {
          final start = async.elapsed;
          Duration? done;
          () async {
            await Future<void>.delayed(const Duration(milliseconds: 150));
            try {
              await sources.bridge.call();
            } catch (_) {}
            await sources.dashboard.call();
          }().then((_) => done = async.elapsed);
          async.elapse(const Duration(seconds: 30));
          return done! - start;
        }

        final first = serialOpen();
        final second = serialOpen();
        // ignore: avoid_print
        print(
          'mk1215 legacy picker open, bridge failing: '
          '${first.inMilliseconds} ms, reopen ${second.inMilliseconds} ms',
        );
        expect(second, first, reason: 'nothing was cached before');
      });
    },
  );
}
