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

String chatActivityHeadlineForTransport({
  required ChatTransportStatus status,
  required bool authRequired,
  required String activityHeadline,
  required String reconnectingHeadline,
}) => !authRequired && !status.isConnected
    ? reconnectingHeadline
    : activityHeadline;

class ChatConnectionRecoveryRow extends StatefulWidget {
  const ChatConnectionRecoveryRow({
    required this.status,
    required this.activeTurn,
    required this.authRequired,
    required this.appForeground,
    required this.offlineLabel,
    required this.reconnectingLabel,
    required this.recoveredLabel,
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
  final Duration activeGrace;
  final Duration idleGrace;
  final Duration healthyHysteresis;
  final DateTime Function()? clock;

  @override
  State<ChatConnectionRecoveryRow> createState() =>
      _ChatConnectionRecoveryRowState();
}

class _ChatConnectionRecoveryRowState extends State<ChatConnectionRecoveryRow> {
  Timer? _enterTimer;
  Timer? _leaveTimer;
  bool _visible = false;
  ChatTransportState _displayState = ChatTransportState.offline;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _syncVisibility();
  }

  @override
  void didUpdateWidget(ChatConnectionRecoveryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncVisibility();
  }

  @override
  void dispose() {
    _enterTimer?.cancel();
    _leaveTimer?.cancel();
    super.dispose();
  }

  void _syncVisibility() {
    _enterTimer?.cancel();
    _enterTimer = null;
    _leaveTimer?.cancel();
    _leaveTimer = null;

    if (widget.authRequired) {
      if (_visible) _setVisible(false);
      return;
    }
    if (!widget.status.isConnected) {
      _displayState = widget.status.state;
      if (_visible || !widget.appForeground) return;
      final grace = widget.activeTurn ? widget.activeGrace : widget.idleGrace;
      final since = widget.status.disconnectedSince ?? _now;
      final remaining = grace - _now.difference(since);
      if (remaining <= Duration.zero) {
        _setVisible(true);
      } else {
        _enterTimer = Timer(remaining, () {
          if (!mounted ||
              widget.authRequired ||
              !widget.appForeground ||
              widget.status.isConnected) {
            return;
          }
          _setVisible(true);
        });
      }
      return;
    }
    if (!_visible || !widget.appForeground) return;
    _leaveTimer = Timer(widget.healthyHysteresis, () {
      if (!mounted ||
          widget.authRequired ||
          !widget.appForeground ||
          !widget.status.isConnected) {
        return;
      }
      _setVisible(false);
      HermesNotice.of(context).show(
        message: widget.recoveredLabel,
        kind: HermesNoticeKind.success,
        id: 'chat-transport-reconnected',
      );
    });
  }

  void _setVisible(bool value) {
    if (_visible == value || !mounted) return;
    setState(() => _visible = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible || widget.authRequired) {
      return const SizedBox.shrink(
        key: ValueKey('chat-connection-recovery-hidden'),
      );
    }
    final colors = Theme.of(context).hermes;
    final reconnecting = _displayState == ChatTransportState.reconnecting;
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
