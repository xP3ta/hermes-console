import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../models/agent_profile.dart';
import '../../screen/screen_controller.dart';
import '../../screens/screen_peek_screen.dart'
    show displayHasDesktop, displayMethodMissing;

/// What the bot list knows about a bot's desktop.
enum BotScreenState {
  /// Not asked yet, or the question failed (network): the list stays quiet
  /// and the long-press action still lets the person try.
  unknown,

  /// `display.status` answered and the display stack is installed.
  available,

  /// No display stack, or a Hermes without `display.*`.
  none,
}

/// Answer of one probe. [instanceNone] means the whole instance lacks
/// `display.*`, so no other bot needs asking.
enum BotScreenProbeResult { available, none, instanceNone }

/// Asks whether the bot [profile] has a desktop. Throws on a transient
/// failure, which leaves the bot [BotScreenState.unknown].
typedef BotScreenProbe = Future<BotScreenProbeResult> Function(String profile);

/// The profile name `display.*` takes for [profile]: the default bot is the
/// gateway's own, which is the empty name.
String botScreenProfile(AgentProfile profile) =>
    profile.isDefault || profile.name == 'default' ? '' : profile.name;

/// Per-bot "has a desktop" cache for the bot list and the profile.
///
/// Nothing is asked from `build`: the list calls [ensure] when it appears
/// and after a refresh, each bot is asked once, and at most [maxInFlight]
/// questions run at a time. Listeners hear every answer.
class BotScreenAccess extends ChangeNotifier {
  /// Creates a cache that asks through [probe].
  BotScreenAccess({required this.probe, this.maxInFlight = 3});

  /// A probe over a gateway's `display.status` (the peek's own rule).
  factory BotScreenAccess.overRpc(DisplayRpc rpc, {int maxInFlight = 3}) =>
      BotScreenAccess(
        maxInFlight: maxInFlight,
        probe: (profile) async {
          try {
            final controller = ScreenController(
              rpc: rpc,
              leasePayloads: const Stream<Map<String, dynamic>>.empty(),
              dashboardBase: Uri.new,
            );
            final status = await controller.peekStatus(profile: profile);
            return displayHasDesktop(status)
                ? BotScreenProbeResult.available
                : BotScreenProbeResult.none;
          } catch (error) {
            if (displayMethodMissing(error)) {
              return BotScreenProbeResult.instanceNone;
            }
            rethrow;
          }
        },
      );

  /// Asks about one bot.
  final BotScreenProbe probe;

  /// Questions allowed at once.
  final int maxInFlight;

  final Map<String, BotScreenState> _known = {};
  final Set<String> _asked = {};
  final Queue<String> _queue = Queue();
  var _inFlight = 0;
  var _instanceNone = false;
  var _generation = 0;
  var _disposed = false;

  /// What is known about [profile] (the [botScreenProfile] name).
  BotScreenState stateOf(String profile) => _instanceNone
      ? BotScreenState.none
      : _known[profile] ?? BotScreenState.unknown;

  /// Asks about the bots in [profiles] that were never asked.
  void ensure(Iterable<String> profiles) {
    if (_disposed || _instanceNone) return;
    for (final profile in profiles) {
      if (_asked.add(profile)) _queue.add(profile);
    }
    _pump();
  }

  /// Forgets failures and asks again about [profiles]; known answers stay
  /// on screen until the new one arrives.
  void refresh(Iterable<String> profiles) {
    if (_disposed) return;
    _generation++;
    _queue.clear();
    _asked.clear();
    _instanceNone = false;
    ensure(profiles);
  }

  void _pump() {
    while (_inFlight < maxInFlight && _queue.isNotEmpty) {
      final profile = _queue.removeFirst();
      _inFlight++;
      final generation = _generation;
      probe(profile)
          .then<void>(
            (result) {
              if (_disposed || generation != _generation) return;
              switch (result) {
                case BotScreenProbeResult.available:
                  _set(profile, BotScreenState.available);
                case BotScreenProbeResult.none:
                  _set(profile, BotScreenState.none);
                case BotScreenProbeResult.instanceNone:
                  _instanceNone = true;
                  _queue.clear();
                  notifyListeners();
              }
            },
            onError: (Object _) {
              // A transient failure leaves the bot unknown until a refresh.
            },
          )
          .whenComplete(() {
            _inFlight--;
            if (!_disposed) _pump();
          });
    }
  }

  void _set(String profile, BotScreenState state) {
    if (_known[profile] == state) return;
    _known[profile] = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    super.dispose();
  }
}
