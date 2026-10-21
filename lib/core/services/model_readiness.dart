import 'dart:async';

import '../models/model_identity.dart';
import 'connection_manager.dart';

/// Whether the Dashboard can answer a first message. [unknown] (network,
/// 401, an old server, a timeout) is not "none".
enum ModelReadiness { ready, needsModel, unknown }

/// A connected provider is behind the default the server reports (by id,
/// alias, or because it lists the model): the Models screen rule.
bool activeModelUsable(ModelActiveInfo info, List<ModelProvider> providers) {
  final provider = info.provider.trim().toLowerCase();
  final model = info.model.trim().toLowerCase();
  for (final p in providers) {
    if (!p.authenticated) continue;
    if (provider.isNotEmpty &&
        (p.slug.toLowerCase() == provider ||
            modelProviderMatches(p, provider))) {
      return true;
    }
    if (model.isNotEmpty && p.models.any((m) => m.toLowerCase() == model)) {
      return true;
    }
  }
  return false;
}

/// Reads `/api/model/info` and `/api/model/options` of [profile] (empty =
/// default) and applies [activeModelUsable]; a failure or [timeout] is unknown.
Future<ModelReadiness> checkModelReadiness(
  DashboardClient client, {
  String profile = '',
  Duration timeout = const Duration(seconds: 4),
}) async {
  try {
    final info = client.getModelInfo(profile: profile);
    final options = client.getModelOptions(profile: profile);
    await Future.wait<Object>([info, options]).timeout(timeout);
    return activeModelUsable(await info, await options)
        ? ModelReadiness.ready
        : ModelReadiness.needsModel;
  } catch (_) {
    return ModelReadiness.unknown;
  }
}
