import 'desktop_model_catalog.dart';
import 'model_provider.dart';

/// Recognition of the configured default model in the Models settings.
///
/// `/api/model/info` reports the provider exactly as `config.yaml` stores it.
/// For user-defined endpoints (Ollama, LM Studio, vLLM…) that is the
/// canonical `custom:<key>`, while the `/api/model/options` row carries the
/// bare key as `slug` plus every accepted spelling in `aliases`
/// (Hermes `inventory._apply_custom_aliases`, #87035). Desktop resolves the
/// row by slug → name → alias (`catalogProviderMatches`); this mirrors it.

/// True when [provider] is the row Hermes means by [current].
bool modelProviderMatches(ModelProvider provider, String current) {
  if (current.isEmpty) return false;
  if (provider.slug == current) return true;
  final wanted = current.trim().toLowerCase();
  if (wanted.isEmpty) return false;
  return provider.name.toLowerCase() == wanted ||
      provider.aliases.contains(wanted);
}

/// The row of [providers] that serves [current]. When the REST payload lacks
/// `aliases` (older Bridge/Dashboard), the gateway catalog the chat already
/// cached ([catalog]) can still translate `custom:<key>` to the row slug.
ModelProvider? findActiveModelProvider(
  List<ModelProvider> providers,
  String current, {
  DesktopModelCatalog? catalog,
}) {
  for (final provider in providers) {
    if (modelProviderMatches(provider, current)) return provider;
  }
  final slug = catalog?.providerFor(current)?.slug;
  if (slug == null || slug == current) return null;
  for (final provider in providers) {
    if (provider.slug == slug) return provider;
  }
  return null;
}

/// On a server running on this phone (localhost instance) the active card is
/// shown only for local endpoints, so a fresh agent that still names a cloud
/// default without credentials does not look like a working model. Local
/// endpoints are the bare/canonical custom provider, Ollama, LM Studio and
/// the Hermes-managed llama.cpp runtime.
bool isLocalModelProviderId(String provider) {
  final p = provider.trim().toLowerCase();
  return p == 'custom' ||
      p.startsWith('custom:') ||
      p == 'ollama' ||
      p == 'lmstudio' ||
      p == 'lm-studio' ||
      // Hermes-managed llama.cpp server (Desktop local mode).
      p == 'llamacpp' ||
      p == 'llama.cpp' ||
      p == 'llama-cpp';
}
