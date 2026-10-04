// `hermes://plugin/install?catalog=NAME` and `hermes://skill/install?
// identifier=ID` — catalog deep links.
//
// Ported from Hermes Desktop (`deeplink-routes.ts`): a link only ever names a
// catalog entry or a hub identifier. It never picks a destination profile, a
// force flag or a scan override, and it never installs on its own: the
// resolver yields an action, the app shows the catalog detail with its install
// confirmation, and only a tap there sends anything.
import '../services/pairing_link_delivery_gate.dart';
import 'capabilities_repository.dart';
import 'capability_models.dart';

/// Desktop's `PLUGIN_CATALOG_NAME_RE`.
final RegExp pluginCatalogNameRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');

sealed class CatalogDeepLinkAction {
  const CatalogDeepLinkAction();
}

/// Install the reviewed pin of a catalog entry of the connected server.
final class PluginCatalogInstallLink extends CatalogDeepLinkAction {
  final String name;

  const PluginCatalogInstallLink(this.name);
}

/// Open a hub skill by identifier.
final class SkillInstallLink extends CatalogDeepLinkAction {
  final String identifier;

  const SkillInstallLink(this.identifier);
}

enum CatalogLinkNoticeKind { invalidName, gitRepository }

/// A catalog-family link that must not install anything: it only explains.
final class CatalogLinkNotice extends CatalogDeepLinkAction {
  final CatalogLinkNoticeKind kind;

  const CatalogLinkNotice(this.kind);
}

/// Resolves a catalog link, or `null` when [uri] is not one (pairing and any
/// other link stay with their owners).
CatalogDeepLinkAction? resolveCatalogDeepLink(Uri uri) {
  if (uri.scheme.toLowerCase() != 'hermes') return null;
  final host = uri.host.toLowerCase();
  switch (host) {
    case 'plugin-agent':
    case 'plugin-desktop':
      return const CatalogLinkNotice(CatalogLinkNoticeKind.gitRepository);
    case 'plugin':
      if (uri.path != '/install') return null;
      final params = uri.queryParametersAll;
      // `catalog` claims the link outright: a `repo` that rides along, or an
      // empty / bogus name, is the catalog lookup's verdict, never a git
      // install.
      if (params.containsKey('catalog')) {
        final name = params['catalog']!.first;
        return pluginCatalogNameRe.hasMatch(name)
            ? PluginCatalogInstallLink(name)
            : const CatalogLinkNotice(CatalogLinkNoticeKind.invalidName);
      }
      if (params.containsKey('repo')) {
        return const CatalogLinkNotice(CatalogLinkNoticeKind.gitRepository);
      }
      return null;
    case 'skill':
      if (uri.path != '/install') return null;
      final identifier = uri.queryParameters['identifier'];
      if (identifier == null ||
          identifier.isEmpty ||
          identifier != identifier.trim()) {
        return null;
      }
      return SkillInstallLink(identifier);
    default:
      return null;
  }
}

/// Where an install would land: the active server and profile.
final class CatalogDestination {
  final String connectionId;
  final String profile;

  const CatalogDestination({required this.connectionId, this.profile = ''});

  String get _profileKey {
    final value = profile.trim();
    return value.isEmpty ? 'default' : value;
  }

  /// A link must never follow a changed destination: re-check before sending.
  bool sameAs(CatalogDestination other) =>
      connectionId == other.connectionId && _profileKey == other._profileKey;
}

/// Holds at most one catalog link until the app can show it: never while App
/// Lock is locked, onboarding runs or no server is connected, and a link
/// delivered twice (initial link + stream) is queued once.
final class CatalogDeepLinkInbox {
  CatalogDeepLinkInbox({PairingLinkDeliveryGate? gate})
    : _gate = gate ?? PairingLinkDeliveryGate();

  final PairingLinkDeliveryGate _gate;
  CatalogDeepLinkAction? _pending;
  String _pendingKey = '';

  bool get hasPending => _pending != null;

  /// Returns `true` when [uri] is a catalog link (claimed, queued or dropped
  /// as a duplicate), `false` when it belongs to someone else.
  bool offer(Uri uri) {
    final action = resolveCatalogDeepLink(uri);
    if (action == null) return false;
    final key = uri.toString();
    if (!_gate.shouldHandle(uri)) return true;
    if (_pending != null && _pendingKey == key) return true;
    _pending = action;
    _pendingKey = key;
    return true;
  }

  CatalogDeepLinkAction? take({
    required bool locked,
    required bool onboarding,
    required bool connected,
  }) {
    if (locked || onboarding || !connected) return null;
    final action = _pending;
    _pending = null;
    _pendingKey = '';
    return action;
  }
}

sealed class CatalogLinkTarget {
  const CatalogLinkTarget();
}

/// Open this entry's detail (disclosure + install confirmation).
final class CatalogLinkShow extends CatalogLinkTarget {
  final CapabilityItem item;

  const CatalogLinkShow(this.item);
}

enum CatalogLinkLeaveReason { unknown, alreadyInstalled, unavailable }

/// Nothing to install: say why and leave.
final class CatalogLinkLeave extends CatalogLinkTarget {
  final CatalogLinkLeaveReason reason;
  final String name;

  const CatalogLinkLeave(this.reason, {this.name = ''});
}

/// Resolves a catalog name against the connected server's own catalog (one
/// read; never the docs host). Unknown names are a hard `unknown`: a link
/// never turns an arbitrary string into a git identifier.
Future<CatalogLinkTarget> resolveCatalogLinkTarget(
  CapabilitiesRepository repository,
  PluginCatalogInstallLink link,
) async {
  final List<CapabilityItem> catalog;
  try {
    catalog = await repository.pluginCatalog();
  } catch (_) {
    return const CatalogLinkLeave(CatalogLinkLeaveReason.unavailable);
  }
  final matches = catalog.where((item) => item.installId == link.name);
  if (matches.isEmpty) {
    return CatalogLinkLeave(CatalogLinkLeaveReason.unknown, name: link.name);
  }
  var item = matches.first;
  List<InstalledPluginRow>? rows;
  try {
    rows = await repository.installedPluginsRpc();
  } catch (_) {
    rows = null;
  }
  if (rows == null && !repository.usesDefaultProfile) {
    // Installed state of a named profile is unknown: never use REST flags.
    return const CatalogLinkLeave(CatalogLinkLeaveReason.unavailable);
  }
  if (rows != null) {
    final row = rows.match(
      catalogName: item.installId,
      name: item.installedName,
    );
    if (row == null) {
      // The REST flags describe the launch profile, not the hub's.
      item = item.copyWith(
        installed: false,
        enabled: false,
        updateAvailable: false,
      );
    } else {
      item = item.copyWith(
        installed: true,
        enabled: row.enabled,
        updateAvailable: row.updateAvailable,
        installedName: row.name,
        installedKey: row.key,
        canRemove: true,
      );
    }
  }
  if (item.installed && !item.updateAvailable && !item.disclosure.isRemoved) {
    return CatalogLinkLeave(
      CatalogLinkLeaveReason.alreadyInstalled,
      name: item.name,
    );
  }
  return CatalogLinkShow(item);
}
