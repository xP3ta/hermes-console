// ignore_for_file: curly_braces_in_flow_control_structures
import 'dart:async';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/model_catalog_cache.dart';
import 'package:hermes_android/core/services/model_picker_loader.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'support/model_catalog_budget_channel.dart';

const _catalog = <String, dynamic>{
  'model': 'synthetic-model',
  'provider': 'synthetic-provider',
  'providers': [
    {
      'slug': 'synthetic-provider',
      'name': 'Synthetic',
      'authenticated': true,
      'models': ['synthetic-model'],
    },
  ],
};

class _Dashboard extends DashboardClient {
  _Dashboard() : super(host: '127.0.0.1', port: 1, manualToken: 'synthetic');
  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'synthetic',
      );
}

class _MemoryStorage implements CompressionRestoreStorage {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async => value = next;
}

class _Fixture {
  _Fixture(
    FakeAsync clock, {
    Duration readyAfter = Duration.zero,
    Duration replyAfter = const Duration(seconds: 9),
    String result = 'success',
  }) {
    connection = SavedConnection(
      id: 'synthetic-budget',
      label: 'Synthetic',
      host: '127.0.0.1',
      port: 1,
      apiKey: 'synthetic',
      dashboardUrl: 'http://127.0.0.1:1',
    );
    cache = ModelCatalogCache(now: () => DateTime(2026).add(clock.elapsed));
    client = TuiGatewayClient(
      connection,
      dashboard: _Dashboard(),
      heartbeatInterval: Duration.zero,
      now: () => DateTime(2026).add(clock.elapsed),
      channelFactory: (_, _) {
        opens++;
        return channel = BudgetGatewayChannel(
          readyAfter: readyAfter,
          responseAfter: replyAfter,
          respond: (frame) {
            if (frame['method'] != 'model.options')
              return {'result': <String, dynamic>{}};
            if (result == 'outage') return null;
            if (result == 'unsupported')
              return {
                'error': {'code': -32601, 'message': 'Synthetic unsupported'},
              };
            if (result == 'invalid')
              return {
                'result': {'providers': false},
              };
            return {'result': _catalog};
          },
        );
      },
    );
    chat = ActiveChat(
      connection: connection,
      sessionId: 'draft-synthetic-budget',
      sessionTitle: 'Synthetic',
      sessionProfile: 'work',
      notifications: null,
      onTerminal: () {},
      desktopGateway: client,
      modelCatalogCache: cache,
      compressionRestoreStore: CompressionRestoreStore(
        storage: _MemoryStorage(),
        mutationNamespaceForTesting: 'synthetic-budget',
      ),
      api: ApiClient(
        baseUrl: 'http://127.0.0.1:1',
        apiKey: 'synthetic',
        httpClient: MockClient((_) async {
          httpCalls++;
          return http.Response('{}', 500);
        }),
      ),
    );
  }
  late SavedConnection connection;
  late TuiGatewayClient client;
  late ActiveChat chat;
  late ModelCatalogCache cache;
  late BudgetGatewayChannel channel;
  int opens = 0;
  int httpCalls = 0;
  void close(FakeAsync clock) {
    chat.dispose();
    unawaited(client.close());
    clock.elapse(const Duration(seconds: 90));
  }
}

void main() {
  test(
    'RPC response after 30 s stays degraded and never populates either cache',
    () {
      fakeAsync((clock) {
        final f = _Fixture(clock, replyAfter: const Duration(seconds: 31));
        final pickerCache = ModelPickerCache(
          now: () => DateTime(2026).add(clock.elapsed),
        );
        final key = ModelPickerCache.key(f.connection.id, 'work');
        Future<ModelPickerResult?> socket() async {
          final catalog = await f.chat.loadDesktopModelCatalog();
          if (catalog == null) return null;
          return ModelPickerResult(
            info: const ModelActiveInfo(
              model: 'synthetic-model',
              provider: 'synthetic-provider',
              effectiveContextLength: 0,
            ),
            providers: const [
              ModelProvider(
                slug: 'synthetic-provider',
                name: 'Synthetic',
                isCurrent: true,
                authenticated: true,
                authType: '',
                oauthProviderId: '',
                keyEnv: '',
                warning: '',
                models: ['synthetic-model'],
              ),
            ],
            source: ModelPickerSource.socket,
            desktopCatalog: catalog,
          );
        }

        Future<ModelPickerResult?> alias() async => const ModelPickerResult(
          info: ModelActiveInfo(
            model: 'synthetic-alias',
            provider: '',
            effectiveContextLength: 0,
          ),
          providers: [
            ModelProvider(
              slug: 'alias',
              name: 'Synthetic alias',
              isCurrent: true,
              authenticated: true,
              authType: '',
              oauthProviderId: '',
              keyEnv: '',
              warning: '',
              models: ['synthetic-alias'],
            ),
          ],
          source: ModelPickerSource.gateway,
        );
        ModelPickerResult? result;
        loadModelPickerCatalog(
          cache: pickerCache,
          key: key,
          sources: {
            ModelPickerSource.socket: socket,
            ModelPickerSource.gateway: alias,
          },
        ).then((value) => result = value);
        clock.elapse(const Duration(milliseconds: 29999));
        expect(result, isNull);
        clock.elapse(const Duration(milliseconds: 1));
        expect(result?.catalogAvailability, ModelPickerAvailability.degraded);
        expect(result?.source, ModelPickerSource.gateway);
        clock.elapse(const Duration(seconds: 2));
        expect(result?.catalogAvailability, ModelPickerAvailability.degraded);
        expect(pickerCache.peek(key), isNull);
        expect(f.cache.read(f.connection.id, 'work'), isNull);
        f.close(clock);
      });
    },
  );

  test('Desktop parity: default catalog RPC can answer at 9 s', () {
    fakeAsync((clock) {
      final f = _Fixture(clock);
      DesktopModelCatalog? catalog;
      Object? error;
      f.client
          .globalModelOptions(profile: 'work')
          .then<void>(
            (value) {
              catalog = value;
            },
            onError: (Object e) {
              error = e;
            },
          );
      clock.elapse(const Duration(seconds: 6));
      expect(
        error,
        isNull,
        reason: 'catalog RPC has the Desktop budget, not handshake budget',
      );
      expect(catalog, isNull);
      clock.elapse(const Duration(seconds: 3));
      expect(catalog?.providers.length, 1);
      expect(error, isNull);
      expect(
        f.channel.methods.where((m) => m == 'model.options'),
        hasLength(1),
      );
      f.close(clock);
    });
  });

  test('transport noReady still expires at 6 s without a catalog request', () {
    fakeAsync((clock) {
      final f = _Fixture(clock, readyAfter: const Duration(seconds: 9));
      Object? error;
      Duration? settledAt;
      f.client.globalModelOptions().then<void>(
        (_) {},
        onError: (Object e) {
          error = e;
          settledAt = clock.elapsed;
        },
      );
      clock.elapse(const Duration(milliseconds: 5999));
      expect(error, isNull);
      clock.elapse(const Duration(milliseconds: 1));
      expect(error, isA<TimeoutException>());
      expect(settledAt, const Duration(seconds: 6));
      expect(f.channel.methods.where((m) => m == 'model.options'), isEmpty);
      f.close(clock);
    });
  });

  test(
    'explicit 6 s override keeps original combined handshake/RPC budget',
    () {
      fakeAsync((clock) {
        final f = _Fixture(
          clock,
          readyAfter: const Duration(seconds: 5),
          result: 'outage',
        );
        Object? error;
        Duration? settledAt;
        f.client
            .globalModelOptions(timeout: const Duration(seconds: 6))
            .then<void>(
              (_) {},
              onError: (Object e) {
                error = e;
                settledAt = clock.elapsed;
              },
            );
        clock.elapse(const Duration(milliseconds: 5999));
        expect(error, isNull);
        clock.elapse(const Duration(milliseconds: 1));
        expect(
          error,
          isA<TuiGatewayRpcError>().having(
            (e) => e.failureKind,
            'kind',
            TuiGatewayRpcFailureKind.timeout,
          ),
        );
        expect(settledAt, const Duration(seconds: 6));
        f.close(clock);
      });
    },
  );

  test('default request receives full 30 s after a 5 s handshake', () {
    fakeAsync((clock) {
      final f = _Fixture(
        clock,
        readyAfter: const Duration(seconds: 5),
        replyAfter: const Duration(seconds: 29),
      );
      DesktopModelCatalog? catalog;
      Object? error;
      f.client.globalModelOptions().then<void>(
        (value) {
          catalog = value;
        },
        onError: (Object e) {
          error = e;
        },
      );
      clock.elapse(const Duration(seconds: 30));
      expect(error, isNull);
      expect(catalog, isNull);
      clock.elapse(const Duration(seconds: 4));
      expect(catalog?.providers.length, 1);
      expect(error, isNull);
      f.close(clock);
    });
  });

  test(
    'catalog outage is bounded to 30 s after readiness and degrades without cache',
    () {
      fakeAsync((clock) {
        final f = _Fixture(
          clock,
          readyAfter: const Duration(seconds: 5),
          result: 'outage',
        );
        bool settled = false;
        Duration? settledAt;
        DesktopModelCatalog? catalog;
        f.chat.loadDesktopModelCatalog().then((value) {
          catalog = value;
          settled = true;
          settledAt = clock.elapsed;
        });
        clock.elapse(const Duration(seconds: 34));
        expect(settled, isFalse);
        clock.elapse(const Duration(seconds: 1));
        expect(settled, isTrue);
        expect(settledAt, const Duration(seconds: 35));
        expect(catalog, isNull);
        expect(f.cache.read(f.connection.id, 'work'), isNull);
        expect(f.httpCalls, 0);
        f.close(clock);
      });
    },
  );

  for (final failure in ['disconnect', 'unsupported', 'invalid']) {
    test(
      'real owning ActiveChat degrades on $failure without caching availability',
      () {
        fakeAsync((clock) {
          final f = _Fixture(
            clock,
            replyAfter: Duration.zero,
            result: failure == 'disconnect' ? 'outage' : failure,
          );
          DesktopModelCatalog? catalog;
          bool settled = false;
          f.chat.loadDesktopModelCatalog().then((value) {
            catalog = value;
            settled = true;
          });
          clock.flushMicrotasks();
          if (failure == 'disconnect') {
            f.channel.drop();
            clock.flushMicrotasks();
          }
          expect(settled, isTrue);
          expect(catalog, isNull);
          expect(f.cache.read(f.connection.id, 'work'), isNull);
          expect(f.httpCalls, 0);
          if (failure == 'unsupported') {
            f.chat.loadDesktopModelCatalog().then((_) {});
            clock.flushMicrotasks();
            expect(
              f.channel.methods.where((m) => m == 'model.options'),
              hasLength(1),
            );
          }
          f.close(clock);
        });
      },
    );
  }

  test(
    'real owning loader waits for 9 s socket catalog and coalesces without falling back to alias',
    () {
      fakeAsync((clock) {
        final f = _Fixture(clock);
        final pickerCache = ModelPickerCache(
          now: () => DateTime(2026).add(clock.elapsed),
        );
        int socketCalls = 0;
        int fallbacks = 0;
        Future<ModelPickerResult?> socket() async {
          socketCalls++;
          final catalog = await f.chat.loadDesktopModelCatalog();
          if (catalog == null) return null;
          return ModelPickerResult(
            info: const ModelActiveInfo(
              model: 'synthetic-model',
              provider: 'synthetic-provider',
              effectiveContextLength: 0,
            ),
            providers: [
              ModelProvider(
                slug: 'synthetic-provider',
                name: 'Synthetic',
                isCurrent: true,
                authenticated: true,
                authType: '',
                oauthProviderId: '',
                keyEnv: '',
                warning: '',
                models: catalog.providers.single.models,
              ),
            ],
            source: ModelPickerSource.socket,
            desktopCatalog: catalog,
          );
        }

        Future<ModelPickerResult?> fallback() async {
          fallbacks++;
          return null;
        }

        final sources = {
          ModelPickerSource.socket: socket,
          ModelPickerSource.dashboard: fallback,
          ModelPickerSource.gateway: fallback,
        };
        final a = loadModelPickerCatalog(
          cache: pickerCache,
          key: ModelPickerCache.key(f.connection.id, 'work'),
          sources: sources,
        );
        final b = loadModelPickerCatalog(
          cache: pickerCache,
          key: ModelPickerCache.key(f.connection.id, 'work'),
          sources: sources,
        );
        expect(a, same(b));
        ModelPickerResult? result;
        Object? error;
        a.then<void>(
          (value) {
            result = value;
          },
          onError: (Object e) {
            error = e;
          },
        );
        clock.elapse(const Duration(seconds: 6));
        expect(error, isNull);
        expect(result, isNull);
        expect(fallbacks, 0);
        clock.elapse(const Duration(seconds: 3));
        expect(result?.catalogAvailability, ModelPickerAvailability.available);
        expect(result?.source, ModelPickerSource.socket);
        expect(result?.providers.length, 1);
        expect(socketCalls, 1);
        expect(fallbacks, 0);
        expect(f.opens, 1);
        expect(f.httpCalls, 0);
        expect(f.cache.read(f.connection.id, 'work')?.providers.length, 1);
        expect(f.cache.read(f.connection.id, 'other'), isNull);
        f.close(clock);
      });
    },
  );

  test(
    'disposing owner while delayed RPC is pending cannot cache a late catalog',
    () {
      fakeAsync((clock) {
        final f = _Fixture(clock);
        DesktopModelCatalog? catalog;
        f.chat.loadDesktopModelCatalog().then((value) => catalog = value);
        clock.elapse(const Duration(seconds: 7));
        f.chat.dispose();
        clock.elapse(const Duration(seconds: 3));
        expect(catalog, isNull);
        expect(f.cache.read(f.connection.id, 'work'), isNull);
        f.close(clock);
      });
    },
  );
}
