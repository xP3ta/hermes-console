import 'capabilities_repository.dart';
import 'server_diagnostics_models.dart';

/// Which read-only diagnostics the server has, from three cheap reads
/// (`actions/doctor/status`, `actions/security-audit/status`, `health`).
/// Nothing is launched. Only a good answer counts as support: a 404 / 405, an
/// error status, an unreachable Dashboard or a timeout leave the route
/// unconfirmed, and nothing is advertised until one read answers.
final class DiagnosticsAvailability {
  final bool doctor;
  final bool audit;
  final bool healthExists;

  /// The health the probe read, so Diagnostics does not read it again.
  final ServerHealth? health;

  const DiagnosticsAvailability({
    required this.doctor,
    required this.audit,
    required this.healthExists,
    this.health,
  });

  /// Whether the Diagnostics row should exist at all.
  bool get any => doctor || audit || healthExists;

  Set<OpsAction> get missing => {
    if (!doctor) OpsAction.doctor,
    if (!audit) OpsAction.securityAudit,
  };
}

Future<DiagnosticsAvailability> probeDiagnostics(
  CapabilitiesRepository repo,
) async {
  Future<bool> exists(Future<Object?> read) async {
    try {
      await read;
      return true;
    } on CapabilityFailure {
      return false;
    }
  }

  ServerHealth? health;
  final results = await Future.wait([
    exists(repo.opsStatus(OpsAction.doctor)),
    exists(repo.opsStatus(OpsAction.securityAudit)),
    exists(repo.serverHealth().then((value) => health = value)),
  ]);
  return DiagnosticsAvailability(
    doctor: results[0],
    audit: results[1],
    healthExists: results[2],
    health: health,
  );
}
