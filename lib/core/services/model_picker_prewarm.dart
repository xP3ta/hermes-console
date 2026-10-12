import 'dart:async';

import '../models/connection.dart';
import '../models/model_active_info.dart';
import 'active_chat_service.dart';
import 'model_picker_loader.dart';
import 'shared_gateway_pool.dart';
import 'tui_gateway_client.dart';

/// A borrowed, already connected catalog socket and how to give it back.
typedef ModelPickerSocket = ({
  HermesDesktopGlobalModelCatalogGateway client,
  void Function() release,
});

typedef ModelPickerLeaseSource =
    ModelPickerSocket? Function(SavedConnection connection);

ModelPickerSocket? _sharedSocket(SavedConnection connection) {
  final lease = SharedGatewayPool.instance.acquireIfConnected(connection);
  if (lease == null) return null;
  return (client: lease.client, release: lease.release);
}

/// Reads the chat model picker's catalog once Home is idle, so the first
/// picker open after a cold start paints at once instead of waiting for the
/// server to build `model.options` (seconds when a provider key comes from a
/// helper). Desktop loads the same catalog at startup for its model menu.
///
/// It only rides the shared socket Home already holds open
/// ([SharedGatewayPool.acquireIfConnected]): it never opens a connection or a
/// session. The answer lands in the same caches the picker reads, as if the
/// picker had loaded it sessionless; the picker still revalidates a stale
/// entry and every model change goes to the server.
final class ModelPickerPrewarm {
  ModelPickerPrewarm({
    ModelPickerLeaseSource? leaseSource,
    this.idleDelay = const Duration(seconds: 3),
  }) : _leaseSource = leaseSource ?? _sharedSocket;

  static final shared = ModelPickerPrewarm();

  final ModelPickerLeaseSource _leaseSource;
  final Duration idleDelay;

  final Set<String> _done = {};
  final Set<String> _running = {};
  Timer? _timer;
  String? _timerKey;

  /// Arms the one-shot idle timer for ([connection], [profileOwner]).
  void schedule({
    required ActiveChatService chats,
    required SavedConnection connection,
    required String profileOwner,
    required bool Function() stillIdle,
  }) {
    // A read-only connection never opens the picker.
    if (connection.readOnly) return;
    final key = ModelPickerCache.key(connection.id, profileOwner);
    if (_done.contains(key) || _running.contains(key)) return;
    if (_timerKey == key && _timer != null) return;
    if (chats.modelPickerCache.peek(key) != null) return;
    cancel();
    _timerKey = key;
    _timer = Timer(idleDelay, () {
      _timer = null;
      _timerKey = null;
      if (!stillIdle()) return;
      unawaited(_read(chats, connection, profileOwner, key));
    });
  }

  /// App went to background or the active connection changed.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _timerKey = null;
  }

  Future<void> _read(
    ActiveChatService chats,
    SavedConnection connection,
    String profileOwner,
    String key,
  ) async {
    if (_done.contains(key) || _running.contains(key)) return;
    if (chats.modelPickerCache.peek(key) != null) {
      _done.add(key);
      return;
    }
    // No open socket yet: try again on the next idle schedule.
    final lease = _leaseSource(connection);
    if (lease == null) return;
    _running.add(key);
    try {
      final catalog = await lease.client.globalModelOptions(
        profile: profileOwner,
        connectedOnly: true,
      );
      // The picker answered first: its read is as fresh and already shown.
      if (chats.modelPickerCache.peek(key) != null) return;
      final providers = modelPickerProviders(catalog);
      if (providers.isEmpty) return;
      chats.modelCatalogCache.write(connection.id, profileOwner, catalog);
      chats.modelPickerCache.write(
        key,
        ModelPickerResult(
          info: ModelActiveInfo(
            model: catalog.currentModel ?? '',
            provider: catalog.currentProvider ?? '',
            effectiveContextLength: 0,
          ),
          providers: providers,
          source: ModelPickerSource.socket,
          desktopCatalog: catalog,
        ),
      );
    } catch (_) {
      // Dropped: the picker reads on open as before.
    } finally {
      // One attempt per app run and profile: a server that fails or times
      // out is not asked again on every idle Home; the picker reads on open.
      _done.add(key);
      _running.remove(key);
      lease.release();
    }
  }
}
