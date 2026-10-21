// The flap scenario's judgement, apart from the wire so it can be tested
// without a gateway. [opensByWindow] maps a cut window (the number of cuts made
// before the upgrade arrived) to the WebSocket upgrades seen in it.

/// What the proxy's numbers say about one flap measure.
final class FlapVerdict {
  const FlapVerdict({this.invalid, this.misses = const []});

  /// Set when no cut tore down a live socket: nothing was measured, so the
  /// run proves nothing and must not pass.
  final String? invalid;
  final List<String> misses;

  List<String> get problems => [?invalid, ...misses];
}

/// Checks [opens] (total upgrades) and [opensByWindow] against [maxOpens] and
/// at most [opensPerWindow] per window; [severed] is how many live WebSockets
/// the cuts tore down.
FlapVerdict flapVerdict({
  required int cuts,
  required int expectedCuts,
  required int opens,
  required Map<String, int> opensByWindow,
  required int severed,
  required int maxOpens,
  bool requireSevered = true,
  int opensPerWindow = 1,
}) => FlapVerdict(
  invalid: !requireSevered || severed > 0
      ? null
      : 'INVALID: no cut severed a live WebSocket (severed=$severed), '
            'so the measure proves nothing',
  misses: [
    if (cuts != expectedCuts) 'cuts $cuts != $expectedCuts',
    if (opens > maxOpens) 'WebSocket opens $opens > $maxOpens',
    for (final e in opensByWindow.entries)
      if (e.value > opensPerWindow)
        'window ${e.key}: ${e.value} opens > $opensPerWindow',
  ],
);
