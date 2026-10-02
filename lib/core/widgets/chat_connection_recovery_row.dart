import 'dart:async';

import 'package:flutter/material.dart';

import '../services/active_chat_service.dart';
import '../theme/app_theme.dart';
import 'hermes_notice.dart';

@visibleForTesting
const chatConnectionActiveGrace = Duration(seconds: 3);

@visibleForTesting
const chatConnectionIdleGrace = Duration(minutes: 5);

@visibleForTesting
const chatConnectionHealthyHysteresis = Duration(seconds: 2);

/// Activity headline for the live turn. [transportLossVisible] must come from
/// [ChatTransportVisibility] so the pill only says "reconnecting" once the
/// recovery row would, never on a socket blip shorter than the grace.
String chatActivityHeadlineForTransport({
  required bool transportLossVisible,
  required bool authRequired,
  required String activityHeadline,
  required String reconnectingHeadline,
}) => !authRequired && transportLossVisible
    ? reconnectingHeadline
    : activityHeadline;

/// Single debounced view of the chat transport shared by the recovery row,
/// the activity pill headline and the companion mood.
///
/// A loss becomes visible only after it outlasts the grace (3 s with an active
/// turn, 5 min idle, measured from the original loss), and once visible it
/// clears only after the transport stayed connected for [healthyHysteresis].
/// Feeding identical inputs again never re-arms a timer, so frequent screen
/// rebuilds cannot postpone either edge.
class ChatTransportVisibility extends ChangeNotifier {
  ChatTransportVisibility({
    this.activeGrace = chatConnectionActiveGrace,
    this.idleGrace = chatConnectionIdleGrace,
    this.healthyHysteresis = chatConnectionHealthyHysteresis,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration activeGrace;
  final Duration idleGrace;
  final Duration healthyHysteresis;
  final DateTime Function() _clock;

  Timer? _enterTimer;
  Timer? _leaveTimer;
  bool _visible = false;
  bool _disposed = false;
  int _recoveries = 0;
  ChatTransportState _displayState = ChatTransportState.offline;
  ({ChatTransportStatus status, bool activeTurn, bool auth, bool foreground})?
  _inputs;

  /// Whether a transport loss is currently shown to the user.
  bool get visible => _visible;

  /// Last disconnected state, for the row's offline/reconnecting label.
  ChatTransportState get displayState => _displayState;

  /// Incremented each time a shown loss clears because the transport
  /// recovered (not for auth or background). Drives the "Reconnected" notice.
  int get recoveries => _recoveries;

  void update({
    required ChatTransportStatus status,
    required bool activeTurn,
    required bool authRequired,
    required bool appForeground,
  }) {
    if (_disposed) return;
    final previous = _inputs;
    if (previous != null &&
        previous.status.state == status.state &&
        previous.status.disconnectedSince == status.disconnectedSince &&
        previous.activeTurn == activeTurn &&
        previous.auth == authRequired &&
        previous.foreground == appForeground) {
      return;
    }
    _inputs = (
      status: status,
      activeTurn: activeTurn,
      auth: authRequired,
      foreground: appForeground,
    );
    _sync();
  }

  void _sync() {
    final inputs = _inputs;
    if (inputs == null) return;
    _enterTimer?.cancel();
    _enterTimer = null;
    _leaveTimer?.cancel();
    _leaveTimer = null;

    if (inputs.auth) {
      _setVisible(false);
      return;
    }
    if (!inputs.status.isConnected) {
      final stateChanged = _displayState != inputs.status.state;
      _displayState = inputs.status.state;
      if (_visible) {
        if (stateChanged) notifyListeners();
        return;
      }
      if (!inputs.foreground) return;
      final grace = inputs.activeTurn ? activeGrace : idleGrace;
      final since = inputs.status.disconnectedSince ?? _clock();
      final remaining = grace - _clock().difference(since);
      if (remaining <= Duration.zero) {
        _setVisible(true);
      } else {
        _enterTimer = Timer(remaining, () {
          final current = _inputs;
          if (_disposed ||
              current == null ||
              current.auth ||
              !current.foreground ||
              current.status.isConnected) {
            return;
          }
          _setVisible(true);
        });
      }
      return;
    }
    if (!_visible || !inputs.foreground) return;
    _leaveTimer = Timer(healthyHysteresis, () {
      final current = _inputs;
      if (_disposed ||
          current == null ||
          current.auth ||
          !current.foreground ||
          !current.status.isConnected) {
        return;
      }
      _recoveries += 1;
      _setVisible(false);
    });
  }

  void _setVisible(bool value) {
    if (_visible == value || _disposed) return;
    _visible = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _enterTimer?.cancel();
    _leaveTimer?.cancel();
    super.dispose();
  }
}

class ChatConnectionRecoveryRow extends StatefulWidget {
  const ChatConnectionRecoveryRow({
    required this.status,
    required this.activeTurn,
    required this.authRequired,
    required this.appForeground,
    required this.offlineLabel,
    required this.reconnectingLabel,
    required this.recoveredLabel,
    this.visibility,
    this.activeGrace = chatConnectionActiveGrace,
    this.idleGrace = chatConnectionIdleGrace,
    this.healthyHysteresis = chatConnectionHealthyHysteresis,
    this.clock,
    super.key,
  });

  final ChatTransportStatus status;
  final bool activeTurn;
  final bool authRequired;
  final bool appForeground;
  final String offlineLabel;
  final String reconnectingLabel;
  final String recoveredLabel;

  /// Shared debounced state. When omitted the row owns a private one built
  /// from the grace/hysteresis parameters below.
  final ChatTransportVisibility? visibility;
  final Duration activeGrace;
  final Duration idleGrace;
  final Duration healthyHysteresis;
  final DateTime Function()? clock;

  @override
  State<ChatConnectionRecoveryRow> createState() =>
      _ChatConnectionRecoveryRowState();
}

class _ChatConnectionRecoveryRowState extends State<ChatConnectionRecoveryRow> {
  ChatTransportVisibility? _owned;
  late ChatTransportVisibility _visibility;
  late int _seenRecoveries;

  @override
  void initState() {
    super.initState();
    _attach(listen: false);
    _feed();
    _visibility.addListener(_onVisibility);
  }

  @override
  void didUpdateWidget(ChatConnectionRecoveryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.visibility, widget.visibility)) {
      _visibility.removeListener(_onVisibility);
      _owned?.dispose();
      _owned = null;
      _attach();
    }
    _feed();
  }

  void _attach({bool listen = true}) {
    _visibility =
        widget.visibility ??
        (_owned = ChatTransportVisibility(
          activeGrace: widget.activeGrace,
          idleGrace: widget.idleGrace,
          healthyHysteresis: widget.healthyHysteresis,
          clock: widget.clock,
        ));
    _seenRecoveries = _visibility.recoveries;
    if (listen) _visibility.addListener(_onVisibility);
  }

  // A shared controller is fed by its owner outside build; feeding it here
  // could notify other listeners in the middle of a frame.
  void _feed() => _owned?.update(
    status: widget.status,
    activeTurn: widget.activeTurn,
    authRequired: widget.authRequired,
    appForeground: widget.appForeground,
  );

  void _onVisibility() {
    if (!mounted) return;
    setState(() {});
    if (_visibility.recoveries != _seenRecoveries) {
      _seenRecoveries = _visibility.recoveries;
      HermesNotice.of(context).show(
        message: widget.recoveredLabel,
        kind: HermesNoticeKind.success,
        id: 'chat-transport-reconnected',
      );
    }
  }

  @override
  void dispose() {
    _visibility.removeListener(_onVisibility);
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visibility.visible || widget.authRequired) {
      return const SizedBox.shrink(
        key: ValueKey('chat-connection-recovery-hidden'),
      );
    }
    final colors = Theme.of(context).hermes;
    final reconnecting =
        _visibility.displayState == ChatTransportState.reconnecting;
    final label = reconnecting ? widget.reconnectingLabel : widget.offlineLabel;

    return Padding(
      key: const ValueKey('chat-connection-recovery-row'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Align(
        alignment: Alignment.center,
        child: Semantics(
          container: true,
          liveRegion: true,
          label: label,
          child: Material(
            color: colors.surface,
            elevation: 6,
            shadowColor: Colors.black.withValues(alpha: 0.3),
            shape: StadiumBorder(
              side: BorderSide(color: colors.warning.withValues(alpha: 0.5)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: reconnecting
                        ? CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.warning,
                          )
                        : Icon(
                            Icons.cloud_off_outlined,
                            size: 14,
                            color: colors.warning,
                          ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
