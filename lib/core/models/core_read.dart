/// Typed, body-free failures for passive CORE-READ operations.
enum CoreReadErrorKind {
  auth,
  forbidden,
  profileUnavailable,
  notFound,
  malformed,
  unsupported,
  temporarilyUnavailable,
  paginationStalled,
}

enum CoreReadSource { gatewayApi, dashboardRest, tuiRpc }

enum CoreReadCoverage {
  full,
  tipOnly,
  metadataPartial,
  aggregateOnly,
  unsupported,
}

final class CoreReadScope {
  final String connectionId;
  final String profileOwner;

  const CoreReadScope({required this.connectionId, required this.profileOwner})
    : assert(connectionId != ''),
      assert(profileOwner != '');

  String cacheKey(String resourceIdentity) =>
      '$connectionId\u001f$profileOwner\u001f$resourceIdentity';
}

final class SessionIdentity {
  final String logicalRootId;
  final String storedId;
  final String? resolvedTipId;
  final String? runtimeId;

  const SessionIdentity({
    required this.logicalRootId,
    required this.storedId,
    this.resolvedTipId,
    this.runtimeId,
  }) : assert(logicalRootId != ''),
       assert(storedId != '');

  SessionIdentity withResolvedTip(String resolvedTipId) => SessionIdentity(
    logicalRootId: logicalRootId,
    storedId: storedId,
    resolvedTipId: resolvedTipId,
    runtimeId: runtimeId,
  );

  SessionIdentity withStored(String storedId) => SessionIdentity(
    logicalRootId: logicalRootId,
    storedId: storedId,
    runtimeId: runtimeId,
  );

  SessionIdentity withRuntime(String runtimeId) => SessionIdentity(
    logicalRootId: logicalRootId,
    storedId: storedId,
    resolvedTipId: resolvedTipId,
    runtimeId: runtimeId,
  );

  SessionIdentity withoutRuntime() => SessionIdentity(
    logicalRootId: logicalRootId,
    storedId: storedId,
    resolvedTipId: resolvedTipId,
  );
}

final class CoreReadException implements Exception {
  final CoreReadErrorKind kind;
  final int? statusCode;

  const CoreReadException(this.kind, {this.statusCode});

  @override
  String toString() =>
      'CoreReadException(${kind.name}${statusCode == null ? '' : ', HTTP $statusCode'})';
}
