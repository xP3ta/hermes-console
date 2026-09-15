enum DesktopGatewayCapability {
  sessionActivate,
  sessionActiveList,
  modelOptions,
  sessionContextBreakdown,
  subagentInterrupt,
  recoveryCenter,
  extensionsCenter,
  agentCenter,
  projectsCenter,
  profileAssets,
  profilePets,
  sessionControl,
}

enum DesktopGatewayCapabilityState { unknown, supported, unsupported, invalid }

/// Connection-scoped, expiring knowledge learned through authenticated RPCs.
///
/// It is intentionally memory-only: a server update, reconnect or TTL expiry
/// returns optional methods to `unknown` instead of persisting stale claims.
final class DesktopGatewayCapabilityCache {
  final Duration ttl;
  final DateTime Function() _now;
  final Map<DesktopGatewayCapability, _CapabilityEntry> _entries = {};

  DesktopGatewayCapabilityCache({
    this.ttl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  DesktopGatewayCapabilityState state(DesktopGatewayCapability capability) {
    final entry = _entries[capability];
    if (entry == null) return DesktopGatewayCapabilityState.unknown;
    if (!_now().isBefore(entry.expiresAt)) {
      _entries.remove(capability);
      return DesktopGatewayCapabilityState.unknown;
    }
    return entry.state;
  }

  bool canAttempt(DesktopGatewayCapability capability) {
    final value = state(capability);
    return value != DesktopGatewayCapabilityState.unsupported &&
        value != DesktopGatewayCapabilityState.invalid;
  }

  void mark(
    DesktopGatewayCapability capability,
    DesktopGatewayCapabilityState state,
  ) {
    if (state == DesktopGatewayCapabilityState.unknown) {
      _entries.remove(capability);
      return;
    }
    _entries[capability] = _CapabilityEntry(state, _now().add(ttl));
  }

  void resetForReconnect() => _entries.clear();
}

final class _CapabilityEntry {
  final DesktopGatewayCapabilityState state;
  final DateTime expiresAt;

  const _CapabilityEntry(this.state, this.expiresAt);
}
