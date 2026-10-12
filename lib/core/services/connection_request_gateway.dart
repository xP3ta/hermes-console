// Answers to a connection prompt raised in a chat turn. The owner is always
// the runtime session the card belongs to; the card never changes a target
// state itself (it comes back by `connection.update`).

abstract interface class HermesConnectionRequestGateway {
  /// `connection.respond` for [opId] with the exact `result` body
  /// (`{targets: [{name, status: 'skipped'}]}` or `{settled_by: 'continue'}`).
  Future<void> respondToConnection(
    String runtimeSessionId,
    String opId,
    Map<String, dynamic> result,
  );

  /// `connectors.operation.wake`: the browser leg came back, read the
  /// accounts now.
  Future<void> wakeConnectionOperation(String runtimeSessionId, String opId);
}
