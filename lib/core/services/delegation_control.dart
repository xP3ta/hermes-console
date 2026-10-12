// Global delegation switch of the Hermes server: `delegation.status` and
// `delegation.pause`. The flag is process-wide (not per profile or session)
// and not persisted: a server restart clears it. Running subagents keep
// going; only NEW spawns are blocked.

abstract interface class HermesDelegationGateway {
  /// One `delegation.status` read of the current flag.
  Future<bool> delegationPaused();

  /// `delegation.pause {paused}`; returns the state the server now reports.
  Future<bool> setDelegationPaused(bool paused);
}
