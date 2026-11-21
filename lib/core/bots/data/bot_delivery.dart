/// One unsettled `message_agent` delivery of a bot to a local teammate, as
/// `bot_delivery.list` answers it (Hermes `tui_gateway/contracts/
/// groups_bot_relay.py` `BotDeliveryRow`; Desktop `plugins/hermes-bots/
/// teammate-waits.tsx` `TeammateDelivery`).
library;

/// `BotDeliveryState`: where a delivery stands at its target.
enum BotDeliveryState {
  queued('queued'),
  claimed('claimed'),
  working('working'),
  waitingOnYou('waiting_on_you'),
  failed('failed');

  final String wire;
  const BotDeliveryState(this.wire);

  static BotDeliveryState? fromWire(Object? value) {
    for (final state in values) {
      if (state.wire == value) return state;
    }
    return null;
  }
}

/// `reason` of a failed row whose outcome is unknown: the teammate may have
/// acted already, so it is never resent (`tools/bot_failure_reasons.py`).
const botDeliveryUnknownOutcome = 'unknown_outcome';

final class BotDelivery {
  final String deliveryId;

  /// The target profile name and the handle the sender wrote.
  final String target;
  final String targetHandle;
  final BotDeliveryState state;

  /// The receipt's last write, epoch seconds.
  final double since;
  final String preview;

  /// `approval` or `clarify` for [BotDeliveryState.waitingOnYou].
  final String? waitingOn;

  /// Typed failure reason (+ the owner's own error line) of a failed row.
  final String? reason;
  final String? error;

  const BotDelivery({
    required this.deliveryId,
    required this.target,
    required this.targetHandle,
    required this.state,
    required this.since,
    required this.preview,
    this.waitingOn,
    this.reason,
    this.error,
  });

  bool get isUnknownOutcome =>
      state == BotDeliveryState.failed && reason == botDeliveryUnknownOutcome;

  /// A row this build cannot show (no id, no target, a state it has no words
  /// for) is left out, never half drawn.
  static BotDelivery? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['delivery_id'];
    final target = raw['target'];
    final state = BotDeliveryState.fromWire(raw['state']);
    final since = raw['since'];
    if (id is! String ||
        id.isEmpty ||
        target is! String ||
        target.isEmpty ||
        state == null ||
        since is! num) {
      return null;
    }
    String? text(Object? value) => value is String ? value : null;
    return BotDelivery(
      deliveryId: id,
      target: target,
      targetHandle: text(raw['target_handle']) ?? '',
      state: state,
      since: since.toDouble(),
      preview: text(raw['preview']) ?? '',
      waitingOn: text(raw['waiting_on']),
      reason: text(raw['reason']),
      error: text(raw['error']),
    );
  }
}

/// Gateway surface of the strip: [TuiGatewayClient] implements it, tests use
/// a fake.
abstract interface class BotDeliveryGateway {
  /// `bot_delivery.list {profile}`; the profile is the SENDER bot. An older
  /// gateway answers «method not found» (see [isBotDeliveryUnsupported]).
  Future<List<BotDelivery>> listBotDeliveries(String profile);
}
