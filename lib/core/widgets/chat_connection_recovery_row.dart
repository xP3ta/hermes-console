import 'dart:async';

import 'package:flutter/material.dart';

import '../services/active_chat_service.dart';
import '../services/connection_status.dart';
import '../theme/app_theme.dart';

@visibleForTesting
const chatConnectionActiveGrace = Duration(seconds: 3);

@visibleForTesting
const chatConnectionIdleGrace = Duration(minutes: 5);

@visibleForTesting
const chatConnectionHealthyHysteresis = Duration(seconds: 2);

/// After the app returns from the background the sockets have to be opened
/// again, which is not a loss the user needs to hear about: the grace then
/// runs from the return, not from the moment the dead socket was noticed.
@visibleForTesting
const chatConnectionResumeGrace = Duration(seconds: 6);

/// «Reconnected» at most once per this long, however often the link flaps.
@visibleForTesting
const chatConnectionRecoveredNoticeSpacing = Duration(seconds: 60);

/// The transport the chat shows: its own state, overridden by the connection
/// supervisor when that knows the socket is down (an idle chat has not
/// noticed yet). Never connected over a down socket.
///
/// conn-registry E1: only facts the user can act on are «offline» (no
/// network, a refused credential); in the chat they still wait its
/// five-minute silence, except the refused credential (REVISION-4 BAJO 2).
/// A server that does not answer or is
/// booting is a redial in progress, like Desktop's status pill, which
/// mirrors the socket's `connecting` state while it retries
/// (apps/desktop/src/app/shell/hooks/use-statusbar-items.tsx:376-407).
ChatTransportStatus chatTransportWithLink(
  ChatTransportStatus chat,
  ConnectionStatus? link,
) {
  if (link == null || link.isConnected) return chat;
  final since = chat.disconnectedSince == null
      ? link.since
      : link.since == null || chat.disconnectedSince!.isBefore(link.since!)
      ? chat.disconnectedSince
      : link.since;
  return ChatTransportStatus(
    link.kind == ConnectionStatusKind.noNetwork ||
            link.kind == ConnectionStatusKind.authRequired
        ? ChatTransportState.offline
        : ChatTransportState.reconnecting,
    disconnectedSince: since,
  );
}

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
    this.noticeSpacing = chatConnectionRecoveredNoticeSpacing,
    this.persistentAfter = connectionPersistentNoticeAfter,
    this.resumeGrace = chatConnectionResumeGrace,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration activeGrace;
  final Duration idleGrace;
  final Duration healthyHysteresis;
  final Duration noticeSpacing;
  final Duration persistentAfter;
  final Duration resumeGrace;
  final DateTime Function() _clock;

  /// When the app last came back to the foreground (null: it has not left).
  DateTime? _resumedAt;
  bool _resumedFromBackground = false;

  Timer? _enterTimer;
  Timer? _leaveTimer;
  Timer? _persistentTimer;
  bool _visible = false;
  bool _persistent = false;
  bool _disposed = false;
  int _recoveries = 0;
  int _lossEpoch = 0;
  DateTime? _lastRecoveryNoticeAt;
  ConnectionStatusKind? _linkKind;

  /// The grace the current loss waited: one as long as [persistentAfter]
  /// (the chat's five-minute silence) already is the persistent outage.
  Duration _enteredAfter = Duration.zero;

  /// The current loss was shown with no grace because of a refused credential.
  bool _enteredForAuth = false;
  ChatTransportState _displayState = ChatTransportState.offline;
  ({
    ChatTransportStatus status,
    bool activeTurn,
    bool auth,
    bool foreground,
    ConnectionStatus? link,
  })?
  _inputs;

  /// The chat has just been opened (from a notification, say) and its
  /// transport is still being opened: the resume grace counts from now.
  void markOpening() => _resumedAt = _clock();

  /// Whether a transport loss is currently shown to the user.
  bool get visible => _visible;

  /// Last disconnected state, for the row's offline/reconnecting label.
  ChatTransportState get displayState => _displayState;

  /// The connection has been failing for [persistentAfter]: one persistent
  /// notice instead of the transient state (Desktop `use-gateway-boot.ts`).
  bool get persistent => _persistent;

  /// Why the supervisor says the link is down (null: it says nothing).
  ConnectionStatusKind? get linkKind => _linkKind;

  /// Incremented when a shown loss clears because the transport recovered
  /// (not for auth or background) and the last notice is older than
  /// [noticeSpacing]: five flaps in a minute say "Reconnected" once.
  int get recoveries => _recoveries;

  /// Incremented on every shown loss that clears, notice or not.
  int get lossEpoch => _lossEpoch;

  void update({
    required ChatTransportStatus status,
    required bool activeTurn,
    required bool authRequired,
    required bool appForeground,
    ConnectionStatus? link,
  }) {
    if (_disposed) return;
    final previous = _inputs;
    if (previous != null &&
        previous.status.state == status.state &&
        previous.status.disconnectedSince == status.disconnectedSince &&
        previous.activeTurn == activeTurn &&
        previous.auth == authRequired &&
        previous.foreground == appForeground &&
        previous.link == link) {
      return;
    }
    if (previous != null && !previous.foreground && appForeground) {
      _resumedAt = _clock();
      _resumedFromBackground = true;
    }
    _inputs = (
      status: status,
      activeTurn: activeTurn,
      auth: authRequired,
      foreground: appForeground,
      link: link,
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
    _linkKind = inputs.link?.isConnected == false ? inputs.link!.kind : null;

    if (inputs.auth || !inputs.foreground) {
      _setVisible(false);
      return;
    }
    if (!inputs.status.isConnected) {
      final authLink =
          inputs.link?.isConnected == false &&
          inputs.link!.kind == ConnectionStatusKind.authRequired;
      // REVISION-4 BAJO 8: a loss shown at once only because the credential
      // was refused becomes an ordinary redial when the link says so: it
      // waits the remaining grace like any other loss.
      if (_visible && _enteredForAuth && !authLink) _setVisible(false);
      final stateChanged = _displayState != inputs.status.state;
      _displayState = inputs.status.state;
      if (_visible) {
        if (stateChanged) notifyListeners();
        return;
      }
      if (!inputs.foreground) return;
      // A supervisor that knows the socket is down needs no 5 min wait.
      final linkDown = inputs.link?.isConnected == false;
      var grace = inputs.activeTurn || linkDown ? activeGrace : idleGrace;
      // A refused credential is a fact, not a redial: no grace (Desktop:
      // the sign-out notice once its token retries are done,
      // use-gateway-boot.ts:564-585; AUDITORIA C3/C21).
      _enteredForAuth = authLink;
      if (authLink) grace = Duration.zero;
      var since = inputs.status.disconnectedSince ?? _clock();
      // A socket that died while the app was away is reopened on return:
      // count the grace from the return so a normal redial stays silent.
      final resumedAt = _resumedAt;
      if (resumedAt != null &&
          (since.isBefore(resumedAt) ||
              (_resumedFromBackground && _clock().difference(resumedAt) < resumeGrace))) {
        since = resumedAt;
        if (grace < resumeGrace) grace = resumeGrace;
      }
      _enteredAfter = grace;
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
      _lossEpoch += 1;
      final now = _clock();
      final last = _lastRecoveryNoticeAt;
      if (last == null || now.difference(last) >= noticeSpacing) {
        _lastRecoveryNoticeAt = now;
        _recoveries += 1;
      }
      _setVisible(false);
    });
  }

  void _setVisible(bool value) {
    if (_visible == value || _disposed) return;
    _visible = value;
    _persistentTimer?.cancel();
    _persistentTimer = null;
    if (value) {
      final since = _inputs?.status.disconnectedSince ?? _clock();
      final remaining = persistentAfter - _clock().difference(since);
      if (remaining <= Duration.zero || _enteredAfter >= persistentAfter) {
        _persistent = true;
      } else {
        _persistentTimer = Timer(remaining, () {
          if (_disposed || !_visible) return;
          _persistent = true;
          notifyListeners();
        });
      }
    } else {
      _persistent = false;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _enterTimer?.cancel();
    _leaveTimer?.cancel();
    _persistentTimer?.cancel();
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

  // conn-registry E2: a recovered loss says nothing (Desktop has no
  // «reconnected» notice).
  void _onVisibility() {
    if (!mounted) return;
    setState(() {});
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
