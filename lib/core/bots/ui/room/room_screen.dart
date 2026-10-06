import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../models/attachment_draft.dart';
import '../../../models/hosted_groups.dart';
import '../../../services/attachment_uploader.dart';
import '../../../services/tui_gateway_client.dart' show TuiGatewayRpcError;
import '../../../theme/app_theme.dart';
import '../../../utils/unread_rules.dart';
import '../../../widgets/anchored_transcript_scroll.dart';
import '../../../widgets/attachment_source_sheet.dart';
import '../../../widgets/chat/composer_pasted_image.dart';
import '../../../widgets/chat/console_composer.dart';
import '../../../widgets/hermes_app_bar.dart';
import '../../../widgets/hermes_notice.dart';
import '../../../widgets/hermes_premium_ui.dart';
import '../../../widgets/mission_profile_avatar.dart';
import '../../data/room_log_cursor.dart';
import 'room_dictation.dart';
import 'room_gateway.dart';
import 'room_header.dart';
import 'room_mentions.dart';
import 'room_models.dart';
import 'room_prefs.dart';
import 'room_sheets.dart';
import 'room_widgets.dart';

/// Composer draft persistence for one room (Mission Control adapts the
/// encrypted `ChatDraftStore`).
abstract interface class RoomDraftStore {
  /// [preparedId] is set while the stored text is a send still waiting for
  /// the server's acknowledgement; [preparedText] is the leading part of the
  /// text that is that send (null: all of it).
  Future<RoomDraft> load();
  Future<void> save(
    String text, {
    String? threadId,
    String? preparedId,
    String? preparedText,
  });

  /// Retires the send [preparedId]: only its own text, never what was typed
  /// after it.
  Future<void> clear({required String preparedId});
}

typedef RoomDraft = ({
  String text,
  String? threadId,
  String? preparedId,
  String? preparedText,
});

/// A stored draft bound to a send: [sent] is that send's own text, the
/// leading part of [text]; whatever follows it was typed later.
/// One transcript item: stable identity, what it is for the unread rules,
/// its log sequence (0 when it has none) and how to build it.
typedef _RoomItem = ({
  String key,
  UnreadRowKind kind,
  int seq,
  Widget Function() build,
});

typedef _HeldDraft = ({
  String text,
  String sent,
  String? threadId,
  String preparedId,
});

/// The part of [held] typed after its send, without the separator.
String _typedAfterSend(_HeldDraft held) {
  if (held.text.length <= held.sent.length ||
      !held.text.startsWith(held.sent)) {
    return '';
  }
  final rest = held.text.substring(held.sent.length);
  return rest.startsWith('\n') ? rest.substring(1) : rest;
}

String _joinDraft(String a, String b) => a.trim().isEmpty
    ? b
    : b.trim().isEmpty
    ? a
    : '$a\n$b';

/// Which call failed and how, without any message content: the error type,
/// the RPC method for gateway errors (`groups.state`, `groups.log`,
/// `groups.capabilities`) with its code and failure kind, and the text of
/// local errors only when it is one of the client's own constants below.
/// Any other message may carry remote text and is never logged.
String roomRefreshFailureKind(Object error) {
  if (error is TuiGatewayRpcError) {
    return 'TuiGatewayRpcError method=${error.method} code=${error.code} '
        'kind=${error.failureKind?.name} reason=${error.reason}';
  }
  final message = switch (error) {
    StateError(:final message) => message,
    FormatException(:final message) => message,
    _ => null,
  };
  if (message != null && _roomRefreshLocalFailures.contains(message)) {
    return '${error.runtimeType} $message';
  }
  return error.runtimeType.toString();
}

/// Constant failure texts of the room read path (this screen, Mission
/// Control's repository and the gateway client), safe to log.
const _roomRefreshLocalFailures = {
  'room refresh authority changed',
  'room refresh unavailable',
  'incoherent hosted room mutation readback',
  'hosted group capability unavailable',
  'hosted groups unsupported',
  'MissionControlRepository is closed',
  'Hermes Desktop WebSocket is not connected',
};

/// The hosted Room screen (spec 070 S3): group-chat layout, round panel,
/// approvals/retry/stop, activity, shared composer and attachments.
class RoomScreen extends StatefulWidget {
  final HostedGroupRoom room;
  final HostedGroupLogPage? log;
  final RoomDriverStatus? driverStatus;
  final RoomGateway gateway;
  final RoomCapabilities capabilities;
  final RoomProfileResolver profileFor;
  final MissionProfileAvatarCache? avatarCache;
  final RoomLocalPrefs prefs;
  final RoomDraftStore? drafts;
  final RoomAttachmentUploader? uploader;
  final RoomAttachmentActions? attachmentActions;
  final RoomDictation? dictation;

  /// Room title/picture as Desktop shows them (`ui_meta` identity).
  final String? displayName;
  final Widget? roomAvatar;
  final void Function(HostedGroupMember member)? onOpenMember;

  /// Reads and answers prompts open in members' own sessions (clarify,
  /// approvals the room driver does not report). Null: not available.
  final RoomMemberPromptSource? memberPrompts;
  final GatewayRoomMemberCompressor? memberCompressor;

  /// Opens a member's room session as a chat ([storedSessionId] is its
  /// durable id), where the full request UI is available.
  final void Function(HostedGroupMember member, String storedSessionId)?
  onOpenMemberChat;

  /// Poll timer seam for tests (defaults to [Timer.new]).
  final RoomPollTimerFactory? pollTimer;
  final DateTime Function()? clock;

  const RoomScreen({
    super.key,
    required this.room,
    required this.gateway,
    required this.capabilities,
    required this.profileFor,
    required this.prefs,
    this.log,
    this.driverStatus,
    this.avatarCache,
    this.drafts,
    this.uploader,
    this.attachmentActions,
    this.dictation,
    this.displayName,
    this.roomAvatar,
    this.onOpenMember,
    this.memberPrompts,
    this.memberCompressor,
    this.onOpenMemberChat,
    this.pollTimer,
    this.clock,
  });

  @override
  State<RoomScreen> createState() => RoomScreenState();
}

class RoomScreenState extends State<RoomScreen> with WidgetsBindingObserver {
  late HostedGroupRoom _room = widget.room;
  late HostedGroupLogPage? _log = widget.log;
  late RoomDriverStatus? _driver = widget.driverStatus;
  late final RoomLogPoller _poller;
  final TextEditingController _composer = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// Focus scope of the transcript. Tapping a message gives focus to its
  /// selection region; when that row later leaves the lazy list (scrolled
  /// away or rebuilt) the framework hands focus back to the scope's
  /// previously focused child. Without a scope of its own that child is the
  /// composer, and the keyboard opens by itself mid-scroll.
  final FocusScopeNode _transcriptFocus = FocusScopeNode(
    debugLabel: 'room-transcript',
  );
  late final AnchoredTranscriptScrollController _transcriptScroll =
      AnchoredTranscriptScrollController(following: () => _reading == null);
  final GlobalKey _transcriptKey = GlobalKey(debugLabel: 'room-transcript');
  bool _openAnchored = false;

  /// Reading anchor. The transcript is two slivers around a center: the
  /// history up to a boundary row (center sliver, growing up) and every
  /// item after it (growing down). While following, the boundary is the
  /// newest history row and only volatile rows (own pending sends, cards,
  /// "is replying") sit below it, so they come and go without moving the
  /// history. While reading ([_reading]) the boundary stays where the
  /// reader left the bottom (or where they landed on the divider): new
  /// content grows below it and what they read never moves. Back at the
  /// bottom everything merges again, pinned by the scroll controller.
  final GlobalKey _centerKey = GlobalKey(debugLabel: 'room-center');

  /// Last history row kept in the center while reading, and the newest log
  /// sequence at that moment: the pill counts only news after it.
  ({String boundary, int ceiling})? _reading;

  /// Unread rules (unread_rules.dart): whether the room is on screen, the
  /// newest sequence when it was hidden, a pending "came back after
  /// leaving", and what was already there when the reader arrived.
  late final UnreadPresence _presence = UnreadPresence(clock: () => _now);
  bool _coverVisible = true;
  int? _awaySeq;
  int? _returnFrom;
  bool _rebasePending = false;
  int? _arrivedThroughSeq;
  bool _landPending = false;
  bool _programmaticScroll = false;

  /// Context kept above the divider when landing on it.
  static const double _landingContext = 56;
  Set<String> _dismissedTasks = const {};
  bool _localLoaded = false;
  bool _detailOpen = false;

  /// Header shows only the name while the reader is up in the history.
  bool _headerCollapsed = false;
  bool _userScrolling = false;
  final List<AttachmentDraft> _attachments = [];
  Future<void> _pasteTail = Future<void>.value();
  final Set<String> _answering = {};

  /// Prompts open in members' sessions (latest probe), and the ones being
  /// answered. [_promptEpoch] discards a probe that started before an
  /// answer landed, so an answered card never comes back from a stale read.
  List<RoomMemberPrompt> _prompts = const [];
  final Set<String> _promptBusy = {};
  int _promptEpoch = 0;
  bool _probing = false;
  bool _probeAgain = false;

  /// A member whose turn cannot start because its room session has no live
  /// runtime (latest probe), and the single in-flight resume of it.
  RoomMemberStall? _stall;
  bool _stallProbing = false;
  bool _stallAgain = false;
  bool _resuming = false;
  bool _compressing = false;
  final Set<String> _retrying = {};
  Animation<double>? _coverAnimation;
  bool _stopping = false;
  bool _pickerOpen = false;
  String? _threadId;

  /// When the room was last read successfully, or when polling (re)started.
  /// The room counts as stale only once this is [roomStaleAfter] old and a
  /// read failed; a single failed poll never shows anything.
  late DateTime _freshAt;
  bool _stale = false;
  int? _lastSeenSeq;
  bool _lastSeenLoaded = false;
  RoomNotificationLevel _notifications = RoomNotificationLevel.all;

  /// Messages sent from this screen that the server has not acknowledged
  /// yet, in the order the user sent them. They show at once as local
  /// bubbles; one worker delivers them strictly in order.
  final List<_OutgoingMessage> _outbox = [];
  int _outboxVersion = 0;
  bool _draining = false;
  Timer? _draftTimer;
  bool _draftDirty = false;
  bool _restoringDraft = false;
  bool _foreground = true;

  /// Sends of this app still waiting for the server, by attempt id. They
  /// outlive the screen that started them, so re-entering the room waits
  /// for their outcome instead of reading a log that predates them.
  static final Map<String, Future<bool>> _inFlightSends = {};

  /// A stored draft bound to a send attempt, kept out of the composer until
  /// the room proves whether that send landed: a sent text must never come
  /// back as a draft, and an unsent one must never be lost.
  _HeldDraft? _heldDraft;

  /// Composer text typed while [_heldDraft] was unresolved and the screen
  /// closed; written once the held draft is settled.
  String? _typedWhileHeld;
  bool _sentWhileHeld = false;
  bool _settlingHeld = false;

  String get _roomKey => roomPrefsKey(_room);
  DateTime get _now => (widget.clock ?? DateTime.now)();
  List<HostedGroupEvent> get _events => _log?.events ?? const [];

  @visibleForTesting
  RoomLogPoller get poller => _poller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _freshAt = _now;
    _poller = RoomLogPoller(
      tick: _tick,
      onDelta: (_) {},
      onError: (error) => _refreshFailed(error, via: 'poll'),
      timer: widget.pollTimer,
      backoff: RoomPollBackoff(clock: () => _now),
    );
    // Text, focus and dictation rebuild only the composer area (a
    // ListenableBuilder in build), never the whole screen.
    _composer.addListener(_onComposerChanged);
    unawaited(_loadLocal());
    unawaited(_restoreDraft());
    unawaited(_probePrompts());
    unawaited(_probeStall());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pause polling while another route covers the room.
    final animation = ModalRoute.of(context)?.secondaryAnimation;
    if (!identical(animation, _coverAnimation)) {
      _coverAnimation?.removeStatusListener(_onCoverChanged);
      _coverAnimation = animation;
      animation?.addStatusListener(_onCoverChanged);
      _poller.setVisible(animation == null || animation.isDismissed);
      _coverVisible = animation == null || animation.isDismissed;
      _syncPresence();
    }
  }

  void _onCoverChanged(AnimationStatus status) {
    final visible = status == AnimationStatus.dismissed;
    if (visible && !_poller.active) _restartStaleClock();
    _poller.setVisible(visible);
    _syncAgoTick();
    _coverVisible = visible;
    _syncPresence();
  }

  /// The room is present only on screen with the app in the foreground
  /// (another route, the App Lock or the background hide it). Coming back
  /// after a long enough absence arms the divider for what arrived
  /// meanwhile; it is applied by the next read while present.
  void _syncPresence() {
    final visible = _foreground && _coverVisible;
    final wasPresent = _presence.present;
    if (!visible) {
      if (wasPresent) _awaySeq = _log?.latestSeq;
      _presence.hide();
    } else if (!wasPresent) {
      // What arrives while hidden is never "while you read": the next read
      // moves the pill's baseline past it.
      _rebasePending = true;
      if (_presence.show()) _returnFrom = _awaySeq;
    }
    if (wasPresent != _presence.present && mounted) setState(() {});
  }

  /// Back after leaving: what other members wrote meanwhile gets the
  /// divider (and the landing when the reader was following); it is never
  /// counted by the pill.
  void _applyReturn() {
    if (!_presence.present || !mounted) return;
    final rebase = _rebasePending;
    _rebasePending = false;
    final from = _returnFrom;
    _returnFrom = null;
    final reading = _reading;
    if (from == null) {
      if (rebase && reading != null) {
        final latest = _log?.latestSeq ?? 0;
        if (latest != reading.ceiling) {
          setState(
            () => _reading = (boundary: reading.boundary, ceiling: latest),
          );
        }
      }
      return;
    }
    final latest = _log?.latestSeq ?? 0;
    final news = _events.any(
      (e) =>
          e.sequence > from &&
          e.sequence <= latest &&
          unreadCounts(roomEventUnreadKind(e)),
    );
    if (!news) return;
    setState(() {
      _lastSeenSeq = from;
      _lastSeenLoaded = true;
      _arrivedThroughSeq = latest;
      if (reading == null) {
        _landPending = true;
      } else {
        _reading = (boundary: reading.boundary, ceiling: latest);
      }
    });
  }

  /// Start of the idle status line's relative age ("… · 8 min ago"), as
  /// last painted; null when the line shows no age.
  DateTime? _agoSince;
  DateTime? _agoTimerSince;
  Timer? _agoTimer;

  /// Whether the relative-age repaint is scheduled.
  @visibleForTesting
  bool get ageTickArmed => _agoTimer?.isActive ?? false;

  Duration? _agoTickDelay;
  int _agoTicks = 0;

  /// Delay of the last armed repaint (null before the first).
  @visibleForTesting
  Duration? get ageTickDelay => _agoTickDelay;

  /// Age repaints fired so far.
  @visibleForTesting
  int get ageTicks => _agoTicks;

  /// Repaints the relative age when its label next changes (a minute, an
  /// hour or a day later), only while the room is on screen: no timer runs
  /// in the background or under another route.
  void _armAgoTick() {
    final since = _agoSince;
    if (since == null || !_poller.active) {
      _agoTimer?.cancel();
      _agoTimer = null;
      return;
    }
    if (_agoTimer != null && _agoTimerSince == since) return;
    _agoTimer?.cancel();
    _agoTimerSince = since;
    final delay = _agoTickDelay = roomAgoNextChange(_now.difference(since));
    _agoTimer = Timer(delay, () {
      _agoTimer = null;
      _agoTicks += 1;
      if (mounted && _poller.active) setState(() {});
    });
  }

  /// Visibility changed: stop the age timer, or repaint a fresh age (which
  /// arms it again) when the room is back on screen.
  void _syncAgoTick() {
    if (!_poller.active) {
      _agoTimer?.cancel();
      _agoTimer = null;
    } else if (_agoSince != null && mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) _restartStaleClock();
    _poller.setForeground(foreground);
    _syncAgoTick();
    _syncPresence();
    if (!foreground) {
      _flushDraft();
      _markSeen();
    }
  }

  Future<void> _loadLocal() async {
    final seen = await widget.prefs.lastSeenSeq(_roomKey);
    final level = await widget.prefs.notificationLevel(_roomKey);
    if (!mounted) return;
    setState(() {
      _lastSeenSeq = seen;
      _lastSeenLoaded = true;
      _notifications = level;
      _arrivedThroughSeq ??= _log?.latestSeq;
      _landPending = true;
    });
    Set<String> dismissed = const {};
    try {
      dismissed = await widget.prefs.dismissedTasks(_roomKey);
    } catch (_) {
      // Unreadable local state only means nothing is dismissed.
    }
    if (!mounted) return;
    setState(() {
      _dismissedTasks = {..._dismissedTasks, ...dismissed};
      _localLoaded = true;
    });
  }

  /// Dismisses a failed-task card on this device. Keyed by the exact task,
  /// so a later failure (new task id) always shows again.
  void _dismissTask(String taskId) {
    final next = {..._dismissedTasks, taskId};
    setState(() => _dismissedTasks = next);
    unawaited(
      widget.prefs
          .setDismissedTasks(_roomKey, next)
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  /// Retries the server is still recovering by itself: not failures yet.
  Set<String> get _recoveringRetries =>
      roomRecoveringRetryTasks(_driver, _events);

  List<RoomRetryAction> get _visibleRetries {
    final recovering = _recoveringRetries;
    return [
      for (final r in _driver?.retries ?? const <RoomRetryAction>[])
        if (!_dismissedTasks.contains(r.taskId) &&
            !recovering.contains(r.taskId))
          r,
    ];
  }

  void _markSeen() {
    final latest = _log?.latestSeq;
    if (latest != null && latest > 0) {
      unawaited(widget.prefs.setLastSeenSeq(_roomKey, latest));
    }
  }

  Future<({RoomLogDelta delta, bool working})> _tick() async {
    final previous = _room;
    final previousLatest = _log?.latestSeq ?? 0;
    final result = await widget.gateway.read(previous);
    final log = result.log;
    if (!mounted ||
        log == null ||
        result.room.roomId != previous.roomId ||
        result.room.authorityGatewayId != previous.authorityGatewayId ||
        result.room.authorityEpoch != previous.authorityEpoch ||
        result.room.revision < previous.revision) {
      throw const FormatException('room refresh authority changed');
    }
    final added = [
      for (final e in log.events)
        if (e.sequence > previousLatest) e,
    ];
    final reset = log.latestSeq < previousLatest;
    if (reset) {
      _reading = null;
      _transcriptScroll.releaseLanding();
    }
    final driverChanged = !_sameDriver(_driver, result.driverStatus);
    _freshAt = _now;
    if (added.isNotEmpty ||
        reset ||
        driverChanged ||
        result.room.revision != previous.revision ||
        _stale) {
      setState(() {
        _room = result.room;
        _log = log;
        _driver = result.driverStatus ?? _driver;
        _stale = false;
        _answering.removeWhere(
          (id) => !(_driver?.approvals.any((a) => a.requestId == id) ?? false),
        );
      });
    } else if (_driver?.working ?? false) {
      // Working timers (elapsed) still tick visually; an idle room schedules
      // no frame on a quiet poll.
      setState(() {});
    }
    if ((added.isNotEmpty || reset || driverChanged) && _reading == null) {
      // Following: what just arrived pins the list to the bottom.
      _transcriptScroll.requestFollow();
    }
    if (added.isNotEmpty || reset) _retirePublishedOutbox();
    _applyReturn();
    _settleHeldDraftFromLog();
    unawaited(_probePrompts());
    unawaited(_probeStall());
    if (result.room.disbanded && mounted) Navigator.of(context).maybePop();
    return (
      delta: RoomLogDelta(added: added, log: log, reset: reset),
      working: result.driverStatus?.working ?? false,
    );
  }

  static bool _sameDriver(RoomDriverStatus? a, RoomDriverStatus? b) {
    if (a == null || b == null) return a == b;
    if (a.working != b.working ||
        a.blocked != b.blocked ||
        a.running != b.running ||
        a.pendingActions.length != b.pendingActions.length) {
      return false;
    }
    for (var i = 0; i < a.pendingActions.length; i++) {
      if (a.pendingActions[i] != b.pendingActions[i]) return false;
    }
    if (a.counts.length != b.counts.length) return false;
    for (final entry in a.counts.entries) {
      if (b.counts[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<void> refresh() async {
    try {
      await _tick();
    } catch (error) {
      _refreshFailed(error, via: 'refresh');
    }
  }

  /// Silence tolerated before the room shows itself as reconnecting:
  /// time since the last successful read, not a count of failed polls.
  ///
  /// * The idle poll cadence tops out at 15 s (`RoomPollBackoff.slow`), so
  ///   one lost idle tick plus the retry that succeeds already lands ~30 s
  ///   after the last good read; anything shorter flags a single blip.
  /// * 45 s is the silence the client already tolerates before calling the
  ///   socket half-open (`TuiGatewayClient.defaultHeartbeatDeadline`, the
  ///   same as Desktop, sized against the server's 30 s send deadline). The
  ///   room never looks less healthy than the connection itself does.
  static const roomStaleAfter = Duration(seconds: 45);

  void _restartStaleClock() {
    // A stale room stays flagged until a read succeeds; otherwise paused
    // time (background, covered by another route) is not silence.
    if (!_stale) _freshAt = _now;
  }

  void _refreshFailed(Object error, {required String via}) {
    if (!mounted) return;
    // Which call failed and how, for device logs; never any content.
    debugPrint('room refresh failed ($via): ${roomRefreshFailureKind(error)}');
    final stale = _now.difference(_freshAt) >= roomStaleAfter;
    if (stale != _stale) setState(() => _stale = stale);
  }

  // ── Draft ────────────────────────────────────────────────────────────

  Future<void> _restoreDraft() async {
    final store = widget.drafts;
    if (store == null) return;
    try {
      final draft = await store.load();
      if (!mounted) return;
      // A draft bound to a send attempt is that send's text, kept until the
      // server acknowledged it. The log this screen opened with may predate
      // the send (or the send may still be in flight from the screen the
      // user just left), so it stays out of the composer until the room
      // proves the send did not land.
      final prepared = draft.preparedId;
      if (prepared != null && draft.text.isNotEmpty) {
        _heldDraft = (
          text: draft.text,
          sent: draft.preparedText ?? draft.text,
          threadId: draft.threadId,
          preparedId: prepared,
        );
        await _settleHeldDraft();
        return;
      }
      if (_draftDirty) return;
      _restoringDraft = true;
      _threadId = draft.threadId;
      _composer.text = draft.text;
      _restoringDraft = false;
    } catch (_) {
      // Never overwrite an unreadable draft.
    }
  }

  String? _heldDurableEventId(String preparedId) {
    try {
      return HostedGroupSendAttempt.forClientEvent(preparedId).durableEventId;
    } catch (_) {
      return null;
    }
  }

  /// Decides the held draft: first from a send of this app still in flight,
  /// then from a fresh read of the room. Runs on even after the screen
  /// closed. An unreadable room keeps it held (and stored) for a later poll.
  Future<void> _settleHeldDraft() async {
    if (_settlingHeld) return;
    _settlingHeld = true;
    try {
      await _settleHeldDraftOnce();
    } finally {
      _settlingHeld = false;
    }
  }

  Future<void> _settleHeldDraftOnce() async {
    final held = _heldDraft;
    if (held == null) return;
    final durable = _heldDurableEventId(held.preparedId);
    if (durable == null) return _resolveHeldDraft(held, published: false);
    final inFlight = _inFlightSends[held.preparedId];
    if (inFlight != null && await inFlight) {
      return _resolveHeldDraft(held, published: true);
    }
    if (_isPublished(durable)) {
      return _resolveHeldDraft(held, published: true);
    }
    if (mounted) {
      // A refresh shows the room as it is now and settles the draft from it.
      try {
        await _tick();
      } catch (_) {
        // Still held; the next poll decides while the room stays open.
      }
      if (mounted || !identical(_heldDraft, held)) return;
    }
    final HostedGroupWorkspaceReadback result;
    try {
      result = await widget.gateway.read(_room);
    } catch (_) {
      return _keepTypedWithHeldDraft(held);
    }
    final log = result.log;
    if (log == null || result.room.roomId != _room.roomId) {
      return _keepTypedWithHeldDraft(held);
    }
    _resolveHeldDraft(
      held,
      published: log.events.any((e) => e.eventId == durable),
    );
  }

  /// The room closed and could not be read: keep what was typed next to the
  /// still-unproven send, bound to it, so the next visit decides both.
  void _keepTypedWithHeldDraft(_HeldDraft held) {
    final typed = _typedWhileHeld;
    final store = widget.drafts;
    if (!identical(_heldDraft, held) ||
        store == null ||
        typed == null ||
        typed.trim().isEmpty) {
      return;
    }
    _heldDraft = null;
    // Still bound to the unproven send, which is only the leading part: if
    // the send turns out to have landed, the text typed after it stays.
    unawaited(
      store
          .save(
            '${held.text}\n$typed',
            threadId: held.threadId,
            preparedId: held.preparedId,
            preparedText: held.sent,
          )
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  /// A fresh log from a poll or a send settles the held draft too.
  void _settleHeldDraftFromLog() {
    final held = _heldDraft;
    if (held == null || _inFlightSends.containsKey(held.preparedId)) return;
    final durable = _heldDurableEventId(held.preparedId);
    _resolveHeldDraft(
      held,
      published: durable != null && _isPublished(durable),
    );
  }

  void _resolveHeldDraft(_HeldDraft held, {required bool published}) {
    if (!identical(_heldDraft, held)) return;
    _heldDraft = null;
    final store = widget.drafts;
    if (store == null) return;
    if (published) {
      // Only the send landed; text typed after it on an earlier visit is
      // still unsent and stays a draft.
      final earlier = _typedAfterSend(held);
      unawaited(
        store
            .clear(preparedId: held.preparedId)
            .then<void>((_) {}, onError: (Object _) {}),
      );
      if (mounted) {
        if (earlier.trim().isNotEmpty) {
          final typed = _draftDirty ? _composer.text : '';
          _restoringDraft = true;
          _composer.text = _joinDraft(earlier, typed);
          _restoringDraft = false;
          _draftDirty = true;
        }
        _flushDraft();
      } else {
        final kept = _joinDraft(earlier, _typedWhileHeld ?? '');
        if (kept.trim().isNotEmpty) {
          unawaited(
            store
                .save(kept, threadId: _threadId)
                .then<void>((_) {}, onError: (Object _) {}),
          );
        }
      }
      return;
    }
    if (!mounted) {
      final typed = _typedWhileHeld;
      if (typed != null && typed.trim().isNotEmpty) {
        unawaited(
          store
              .save('${held.text}\n$typed', threadId: held.threadId)
              .then<void>((_) {}, onError: (Object _) {}),
        );
      }
      return;
    }
    final typed = _draftDirty ? _composer.text : '';
    _restoringDraft = true;
    _threadId ??= held.threadId;
    _composer.text = typed.trim().isEmpty ? held.text : '${held.text}\n$typed';
    _restoringDraft = false;
    // The stored slot may hold newer text now; keep both in the store.
    if (typed.trim().isNotEmpty || _sentWhileHeld) {
      _draftDirty = true;
      _flushDraft();
    }
  }

  void _onComposerChanged() {
    if (!_restoringDraft && widget.drafts != null) {
      _draftDirty = true;
      _draftTimer?.cancel();
      _draftTimer = Timer(const Duration(milliseconds: 350), _flushDraft);
    }
  }

  void _flushDraft() {
    _draftTimer?.cancel();
    final store = widget.drafts;
    // Never overwrite a held draft before it is settled.
    if (!_draftDirty || store == null || _heldDraft != null) return;
    unawaited(
      store
          .save(_composer.text, threadId: _threadId)
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _coverAnimation?.removeStatusListener(_onCoverChanged);
    _agoTimer?.cancel();
    _poller.dispose();
    if (_heldDraft != null && _draftDirty) {
      _typedWhileHeld = _composer.text;
      // Settles in the background so the typed text is written.
      unawaited(_settleHeldDraft());
    }
    _flushDraft();
    _markSeen();
    _composer.removeListener(_onComposerChanged);
    _composer.dispose();
    _focus.dispose();
    _transcriptFocus.dispose();
    _transcriptScroll.dispose();
    super.dispose();
  }

  // ── Actions ──────────────────────────────────────────────────────────

  void _notice(String text, {HermesNoticeKind kind = HermesNoticeKind.error}) {
    HermesNotice.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text)), kind: kind);
  }

  void _apply(HostedGroupWorkspaceReadback result) {
    if (!mounted) return;
    setState(() {
      _room = result.room;
      if (result.log != null) _log = result.log;
      if (result.driverStatus != null) _driver = result.driverStatus;
      if (result.log != null) {
        _freshAt = _now;
        _stale = false;
      }
    });
    if (result.log != null) {
      _retirePublishedOutbox();
      _settleHeldDraftFromLog();
    }
  }

  bool _isPublished(String durableEventId) =>
      _events.any((e) => e.eventId == durableEventId);

  /// A send whose acknowledgement failed but whose event is in the log did
  /// land: drop its local bubble and retire its stored draft, exactly once.
  void _retirePublishedOutbox() {
    if (_outbox.isEmpty) return;
    final published = {for (final e in _events) e.eventId};
    final landed = [
      for (final m in _outbox)
        if (published.contains(m.attempt.durableEventId)) m,
    ];
    if (landed.isEmpty) return;
    for (final m in landed) {
      _outbox.remove(m);
      unawaited(
        widget.drafts
                ?.clear(preparedId: m.attempt.clientEventId)
                .then<void>((_) {}, onError: (Object _) {}) ??
            Future<void>.value(),
      );
    }
    // Messages held back only behind a send that did land may go now.
    for (final m in _outbox) {
      m.failed = false;
    }
    _outboxVersion++;
    if (mounted) setState(() {});
    if (_outbox.isNotEmpty) unawaited(_drain());
  }

  Future<void> _stop() async {
    if (_stopping || !widget.capabilities.canStop) return;
    final s = Strings.of(context);
    final ok = await showHermesConfirmDialog(
      context: context,
      title: s.roomStopConfirmTitle,
      message: s.roomStopConfirmBody,
      confirmLabel: s.roomStopConfirm,
      cancelLabel: s.roomCancel,
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _stopping = true);
    try {
      _apply(await widget.gateway.stop(_room));
      await refresh();
    } catch (_) {
      if (mounted) _notice(s.roomActionFailed);
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  Future<void> _approve(RoomApprovalAction action, String choice) async {
    // Idempotent per request_id: one answer in flight, only offered choices.
    if (!action.offers(choice) || _answering.contains(action.requestId)) return;
    final s = Strings.of(context);
    setState(() => _answering.add(action.requestId));
    try {
      await widget.gateway.approve(_room, action: action, choice: choice);
      await refresh();
      // The answer landed: never leave the card disabled if the server still
      // lists the request (a quiet poll does not clear [_answering]).
      if (mounted) setState(() => _answering.remove(action.requestId));
    } catch (_) {
      await refresh();
      final stillPending =
          _driver?.approvalFor(
            taskId: action.taskId,
            requestId: action.requestId,
          ) !=
          null;
      if (mounted) {
        setState(() => _answering.remove(action.requestId));
        // Answered elsewhere (Desktop, notification) counts as success.
        if (stillPending) _notice(s.roomActionFailed);
      }
    }
  }

  // ── Member prompts ───────────────────────────────────────────────────

  /// Reads members' open prompts while the room works (a blocked member
  /// keeps the driver working) or while a prompt is still shown. An idle
  /// room sends nothing.
  Future<void> _probePrompts() async {
    final source = widget.memberPrompts;
    if (source == null || !mounted) return;
    if (!(_driver?.working ?? false) && _prompts.isEmpty) return;
    if (_probing) {
      _probeAgain = true;
      return;
    }
    _probing = true;
    try {
      do {
        _probeAgain = false;
        final epoch = _promptEpoch;
        List<RoomMemberPrompt> found;
        try {
          found = await source.probe(
            _room,
            skipApprovalIds: {
              for (final a
                  in _driver?.approvals ?? const <RoomApprovalAction>[])
                a.requestId,
            },
          );
        } catch (_) {
          // Unknown is not "nobody waits": keep what is shown.
          continue;
        }
        if (!mounted || epoch != _promptEpoch) continue;
        _setPrompts(found);
      } while (_probeAgain && mounted);
    } finally {
      _probing = false;
    }
  }

  void _setPrompts(List<RoomMemberPrompt> next) {
    final same =
        next.length == _prompts.length &&
        [
          for (var i = 0; i < next.length; i++)
            next[i].key == _prompts[i].key &&
                next[i].runtimeSessionId == _prompts[i].runtimeSessionId,
        ].every((v) => v);
    if (same) return;
    setState(() {
      _prompts = List.unmodifiable(next);
      _promptBusy.removeWhere((k) => !_prompts.any((p) => p.key == k));
    });
  }

  /// One answer in flight per prompt; on success the card goes at once and
  /// the room is read again.
  Future<void> _answerPrompt(
    RoomMemberPrompt prompt,
    Future<void> Function(RoomMemberPromptSource source) send, {
    required String failure,
  }) async {
    final source = widget.memberPrompts;
    if (source == null ||
        !widget.capabilities.canAnswerPrompts ||
        _promptBusy.contains(prompt.key)) {
      return;
    }
    setState(() => _promptBusy.add(prompt.key));
    try {
      await send(source);
      if (!mounted) return;
      _promptEpoch++;
      setState(() {
        _promptBusy.remove(prompt.key);
        _prompts = List.unmodifiable(
          _prompts.where((p) => p.key != prompt.key),
        );
      });
      await refresh();
    } catch (_) {
      if (!mounted) return;
      setState(() => _promptBusy.remove(prompt.key));
      _notice(failure);
      unawaited(_probePrompts());
    }
  }

  Future<void> _cancelWait(RoomMemberPrompt prompt) async {
    final s = Strings.of(context);
    final member = roomMemberById(prompt.memberId, _room.members);
    final name = member == null
        ? prompt.memberId
        : roomSpeakerName(member, null, widget.profileFor(member));
    final ok = await showHermesConfirmDialog(
      context: context,
      title: s.rq1215CancelWaitTitle(name),
      message: s.rq1215CancelWaitBody(name),
      confirmLabel: s.rq1215CancelWait,
      cancelLabel: s.rq1215KeepWaiting,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _answerPrompt(
      prompt,
      (source) => source.cancelWait(
        prompt,
        expectedTaskId: _openTaskOf(prompt.memberId),
      ),
      failure: s.rq1215CancelWaitFailed,
    );
  }

  // ── Stalled member ───────────────────────────────────────────────────

  /// How long the room log must stay quiet while the driver works before a
  /// member without a live runtime counts as stalled (the driver retries an
  /// unavailable member every 1-30 s, so a healthy turn never waits this
  /// long without the log moving or a runtime appearing).
  static const roomStallAfter = Duration(minutes: 2);

  /// The member the driver is due to run, when the room may be stalled:
  /// working, not blocked or waiting on a human, and the log quiet for
  /// [roomStallAfter]. Same order as upstream `plan_next_task`: the round's
  /// members rotated by the round index, first one without a terminal turn.
  HostedGroupMember? _stallCandidate() {
    final driver = _driver;
    if (driver == null ||
        !driver.working ||
        driver.blocked ||
        driver.needsUser ||
        _prompts.isNotEmpty) {
      return null;
    }
    final events = _events;
    if (events.isEmpty) return null;
    var latest = events.first;
    for (final e in events) {
      if (e.createdAt > latest.createdAt) latest = e;
    }
    if (_now.difference(roomEventTime(latest)) < roomStallAfter) return null;
    final rows = _roundView()?.rows;
    if (rows == null || rows.isEmpty) return null;
    final round = (_roundView()?.round ?? 1) - 1;
    final shift = round % rows.length;
    for (final row in [...rows.skip(shift), ...rows.take(shift)]) {
      if (row.state == RoomTurnState.queued ||
          row.state == RoomTurnState.working) {
        return row.member;
      }
    }
    return null;
  }

  /// Reads (never writes) whether the due member has a live runtime. One
  /// probe at a time; a request during a probe runs once more after it.
  Future<void> _probeStall() async {
    final source = widget.memberPrompts;
    if (source == null || !mounted) return;
    if (_stallProbing) {
      _stallAgain = true;
      return;
    }
    _stallProbing = true;
    try {
      do {
        _stallAgain = false;
        if (_resuming) return;
        final member = _stallCandidate();
        RoomMemberStall? found;
        if (member != null) {
          try {
            found = await source.findStall(_room, member);
          } catch (_) {
            // Unknown is not "stalled": keep what is shown.
            continue;
          }
        }
        if (!mounted) return;
        if (found?.key != _stall?.key) setState(() => _stall = found);
      } while (_stallAgain && mounted);
    } finally {
      _stallProbing = false;
    }
  }

  /// Re-opens only that member's room session after the user confirms,
  /// then re-reads the room. Never runs on its own.
  Future<void> _resumeStall(RoomMemberStall stall) async {
    final source = widget.memberPrompts;
    if (source == null || !widget.capabilities.canAnswerPrompts || _resuming) {
      return;
    }
    final s = Strings.of(context);
    final member = roomMemberById(stall.memberId, _room.members);
    final name = member == null
        ? stall.memberId
        : roomSpeakerName(member, null, widget.profileFor(member));
    final ok = await showHermesConfirmDialog(
      context: context,
      title: s.rr1215ResumeTitle(name),
      message: s.rr1215ResumeBody(name),
      confirmLabel: s.rr1215Resume,
      cancelLabel: s.rr1215KeepAsIs,
    );
    if (!ok || !mounted || _resuming) return;
    setState(() => _resuming = true);
    try {
      await source.resumeStalled(stall);
    } catch (_) {
      if (!mounted) return;
      setState(() => _resuming = false);
      _notice(s.rr1215ResumeFailed(name));
      return;
    }
    if (!mounted) return;
    setState(() => _resuming = false);
    _notice(s.rr1215Resumed(name), kind: HermesNoticeKind.success);
    // The re-read probes again (`_tick`), clearing the banner once the
    // member's runtime is listed.
    await refresh();
  }

  /// Task of the member's open room turn (`turn.started` without a
  /// terminal event), so the interrupt is fenced to that exact turn.
  String? _openTaskOf(String memberId) {
    String? open;
    for (final e in _events) {
      if (e.activity.memberId != memberId) continue;
      if (e.kind == 'turn.started') {
        open = e.activity.taskId;
      } else if (const {
        'turn.settled',
        'turn.failed',
        'turn.cancelled',
        'turn.deferred',
      }.contains(e.kind)) {
        open = null;
      }
    }
    return open;
  }

  Future<void> _retry(String taskId) async {
    if (_retrying.contains(taskId) ||
        !widget.capabilities.canRetry ||
        !(_driver?.offersRetry(taskId) ?? false)) {
      return;
    }
    final s = Strings.of(context);
    setState(() => _retrying.add(taskId));
    try {
      await widget.gateway.retry(_room, taskId: taskId);
      await refresh();
    } catch (_) {
      if (mounted) _notice(s.roomActionFailed);
    } finally {
      if (mounted) setState(() => _retrying.remove(taskId));
    }
  }

  RoomAttachBlock get _attachBlock {
    if (!widget.capabilities.canSend) return RoomAttachBlock.readOnly;
    if (widget.uploader == null) return RoomAttachBlock.noUploader;
    // G1 interim: the staged path is only readable by members running on
    // the room's own gateway.
    final crossGateway = _room.members.any(
      (m) => m.owner.connectionId != _room.authorityGatewayId,
    );
    return crossGateway ? RoomAttachBlock.crossGateway : RoomAttachBlock.none;
  }

  /// Optimistic send: the message shows as a local bubble and the composer
  /// is free again in the same frame; delivery (upload, `groups.send` and
  /// its verified readback) runs behind it, strictly in order.
  void _send(String raw, List<AttachmentDraft> drafts) {
    final text = raw.trim();
    if ((text.isEmpty && drafts.isEmpty) || !widget.capabilities.canSend) {
      return;
    }
    if (RegExp(r'^/[a-z][\w-]*(?:\s|$)', caseSensitive: false).hasMatch(text)) {
      _notice(
        Strings.of(context).roomSlashUnsupported,
        kind: HermesNoticeKind.warning,
      );
      return;
    }
    final thread = _threadId;
    final message = _OutgoingMessage(
      attempt: HostedGroupSendAttempt.forClientEvent(
        const Uuid().v4(),
        threadId: thread,
      ),
      text: text,
      attachments: List.unmodifiable(drafts),
    );
    // Until the server acknowledges it, the sent text stays in the stored
    // draft bound to this attempt; the acknowledgement retires exactly it.
    _draftTimer?.cancel();
    _draftDirty = false;
    if (_heldDraft != null) _sentWhileHeld = true;
    unawaited(
      widget.drafts
              ?.save(
                raw,
                threadId: thread,
                preparedId: message.attempt.clientEventId,
              )
              .then<void>((_) {}, onError: (Object _) {}) ??
          Future<void>.value(),
    );
    setState(() {
      _outbox.add(message);
      _outboxVersion++;
      _attachments.clear();
      _threadId = null;
      _restoringDraft = true;
      _composer.clear();
      _restoringDraft = false;
    });
    _toBottom();
    unawaited(_drain());
  }

  void _retrySend(_OutgoingMessage message) {
    if (!message.failed || !_outbox.contains(message)) return;
    setState(() {
      message.failed = false;
      _outboxVersion++;
    });
    unawaited(_drain());
  }

  /// Delivers queued messages one at a time, oldest first. Keeps running
  /// after the screen closes so nothing already sent is dropped.
  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (true) {
        final message = _outbox.where((m) => !m.failed).firstOrNull;
        if (message == null) return;
        final id = message.attempt.clientEventId;
        final outcome = Completer<bool>();
        _inFlightSends[id] = outcome.future;
        try {
          final HostedGroupWorkspaceReadback result;
          try {
            result = await _deliver(message);
            outcome.complete(true);
          } catch (_) {
            outcome.complete(false);
            rethrow;
          } finally {
            if (identical(_inFlightSends[id], outcome.future)) {
              _inFlightSends.remove(id);
            }
          }
          // The acknowledged send never waits on draft storage.
          unawaited(
            widget.drafts
                    ?.clear(preparedId: message.attempt.clientEventId)
                    .then<void>((_) {}, onError: (Object _) {}) ??
                Future<void>.value(),
          );
          _outbox.remove(message);
          _outboxVersion++;
          if (!mounted) continue;
          _apply(result);
          _poller.setVisible(true);
        } catch (_) {
          // Later messages never overtake one that did not go out.
          final from = _outbox.indexOf(message);
          for (final m in _outbox.skip(from < 0 ? 0 : from)) {
            m.failed = true;
          }
          _outboxVersion++;
          if (mounted) setState(() {});
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<HostedGroupWorkspaceReadback> _deliver(
    _OutgoingMessage message,
  ) async {
    final refs = <RoomAttachmentRef>[];
    for (final draft in message.attachments) {
      final path = await widget.uploader?.upload(draft);
      if (path == null) {
        if (mounted) _notice(Strings.of(context).roomAttachFailed(draft.name));
        throw StateError('attachment upload failed');
      }
      refs.add(RoomAttachmentRef(name: draft.name, path: path));
    }
    return widget.gateway.send(
      _room,
      text: appendRoomAttachmentSuffix(message.text, refs),
      attempt: message.attempt,
    );
  }

  /// Local bubbles still to show: an attempt whose durable event is already
  /// in the log (e.g. a refresh saw it first) is shown once, from the log.
  List<_OutgoingMessage> _visibleOutbox() {
    if (_outbox.isEmpty) return const [];
    final published = {for (final e in _events) e.eventId};
    return [
      for (final m in _outbox)
        if (!published.contains(m.attempt.durableEventId)) m,
    ];
  }

  Future<void> _pick(AttachmentSourceChoice source) async {
    if (_pickerOpen || _attachBlock != RoomAttachBlock.none) return;
    _pickerOpen = true;
    try {
      final picked = <({String? path, String name, AttachmentType type})>[];
      final blocked = <String>[];
      switch (source) {
        case AttachmentSourceChoice.camera:
        case AttachmentSourceChoice.photos:
          final picker = ImagePicker();
          final files = source == AttachmentSourceChoice.camera
              ? [
                  ?await picker.pickImage(
                    source: ImageSource.camera,
                    imageQuality: 82,
                    maxWidth: 2048,
                    maxHeight: 2048,
                  ),
                ]
              : await picker.pickMultiImage(imageQuality: 90);
          for (final f in files) {
            picked.add((
              path: f.path,
              name: f.name,
              type: AttachmentType.image,
            ));
          }
        case AttachmentSourceChoice.files:
          final result = await FilePicker.platform.pickFiles(
            allowMultiple: true,
          );
          for (final f in result?.files ?? const <PlatformFile>[]) {
            if (!AttachmentUploader.isAllowedDocumentName(f.name)) {
              blocked.add(f.name);
              continue;
            }
            picked.add((
              path: f.path,
              name: f.name,
              type: AttachmentType.document,
            ));
          }
      }
      // Same caps as the main chat (8 MB per file, 24 MB per message), but
      // every room file is uploaded, never embedded as text: a large .html
      // or .md must not hit the 256 KB inline-text cap and vanish.
      var batchBytes = _attachments.fold<int>(0, (sum, a) => sum + a.sizeBytes);
      int? tooBig;
      var batchFull = false;
      var unreadable = false;
      for (final f in picked) {
        final path = f.path;
        int size;
        try {
          size = path == null ? 0 : await File(path).length();
        } catch (_) {
          size = 0;
        }
        switch (pendingAttachmentLimitViolation(
          sizeBytes: size,
          itemLimit: AttachmentUploader.maxBytes,
          currentBatchBytes: batchBytes,
        )) {
          case PendingAttachmentLimitViolation.invalid:
            unreadable = true;
            continue;
          case PendingAttachmentLimitViolation.item:
            tooBig = AttachmentUploader.maxBytes;
            continue;
          case PendingAttachmentLimitViolation.batch:
            batchFull = true;
            continue;
          case null:
            break;
        }
        final draft = await AttachmentUploader.materializeForDraft(
          AttachmentDraft(
            localId: const Uuid().v4(),
            type: f.type,
            name: f.name,
            mimeType: _mime(f.name, f.type),
            sizeBytes: size,
            localPath: path!,
          ),
          itemLimit: AttachmentUploader.maxBytes,
        );
        if (draft == null) {
          unreadable = true;
          continue;
        }
        if (!mounted) {
          await AttachmentUploader.deletePrivateDraftCopy(draft);
          continue;
        }
        batchBytes += draft.sizeBytes;
        setState(() => _attachments.add(draft));
      }
      if (!mounted) return;
      final s = Strings.of(context);
      if (blocked.isNotEmpty) {
        _notice(
          s.roomAttachTypeBlocked(blocked.join(', ')),
          kind: HermesNoticeKind.warning,
        );
      } else if (tooBig != null) {
        _notice(
          s.chaFileTooBig('${tooBig ~/ (1024 * 1024)} MB'),
          kind: HermesNoticeKind.warning,
        );
      } else if (batchFull) {
        _notice(
          s.chaAttachmentBatchTooBig(
            '${AttachmentUploader.maxBatchBytes ~/ (1024 * 1024)} MB',
          ),
          kind: HermesNoticeKind.warning,
        );
      } else if (unreadable) {
        _notice(s.chaAttachmentPreparationFailed);
      }
    } catch (_) {
      if (mounted) _notice(Strings.of(context).roomActionFailed);
    } finally {
      _pickerOpen = false;
    }
  }

  /// Pastes from the keyboard are serialized so two quick pastes cannot
  /// both pass the batch limits checked against the same strip.
  Future<void> _insertKeyboardContent(KeyboardInsertedContent content) {
    final run = _pasteTail.then((_) => _insertKeyboardContentNow(content));
    _pasteTail = run.catchError((Object _) {});
    return run;
  }

  Future<void> _insertKeyboardContentNow(
    KeyboardInsertedContent content,
  ) async {
    if (!mounted) return;
    final s = Strings.of(context);
    switch (_attachBlock) {
      case RoomAttachBlock.none:
        break;
      case RoomAttachBlock.crossGateway:
        _notice(s.roomAttachCrossGateway, kind: HermesNoticeKind.warning);
        return;
      case RoomAttachBlock.noUploader:
      case RoomAttachBlock.readOnly:
        _notice(s.roomAttachUnavailable, kind: HermesNoticeKind.warning);
        return;
    }
    if (composerPasteRejection(content, pending: _attachments) != null) {
      _notice(s.chaAttachmentPreparationFailed);
      return;
    }
    try {
      final draft = await stageComposerPastedImage(
        content,
        materialize: AttachmentUploader.materializeForDraft,
      );
      if (draft == null) {
        if (mounted) _notice(s.chaAttachmentPreparationFailed);
        return;
      }
      if (!mounted) {
        await AttachmentUploader.deletePrivateDraftCopy(draft);
        return;
      }
      setState(() => _attachments.add(draft));
    } catch (_) {
      if (mounted) _notice(s.chaAttachmentPreparationFailed);
    }
  }

  static String _mime(String name, AttachmentType type) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'pdf' => 'application/pdf',
      'txt' || 'md' => 'text/plain',
      'json' => 'application/json',
      _ =>
        type == AttachmentType.image
            ? 'image/jpeg'
            : 'application/octet-stream',
    };
  }

  /// Targets [threadId] with the next send. Only an explicit reply action
  /// ([focus]) opens the keyboard; the small reply icon beside every message
  /// sits where a scroll is stopped, so it only shows the thread banner and
  /// the user taps the composer to type.
  void _setThread(String? threadId, {bool focus = false}) {
    setState(() => _threadId = threadId);
    _draftDirty = true;
    _flushDraft();
    if (threadId != null && focus) _focus.requestFocus();
  }

  void _replyInThread(RoomMessageEntry entry) {
    final member = entry.member;
    if (!entry.isUser &&
        member != null &&
        _room.members.any((current) => current.memberId == member.memberId)) {
      final handle = member.handle;
      final duplicate = RegExp(
        '(^|[^A-Za-z0-9._:-])@${RegExp.escape(handle)}'
        r'(?=$|[^A-Za-z0-9._:-])',
        caseSensitive: false,
      ).hasMatch(_composer.text);
      if (!duplicate) {
        final prefix = '@$handle ';
        _composer.value = TextEditingValue(
          text: '$prefix${_composer.text}',
          selection: TextSelection.collapsed(offset: prefix.length),
        );
      }
    }
    _setThread(entry.event.threadId, focus: true);
  }

  void _insertMention(String handle) {
    final value = _composer.value;
    final text = value.text;
    final cursor = value.selection.isValid
        ? value.selection.baseOffset
        : text.length;
    final before = text.substring(0, cursor);
    final at = before.lastIndexOf('@');
    final replaceFrom = _mentionQuery() != null && at >= 0 ? at : cursor;
    final prefix = text.substring(0, replaceFrom);
    final spacer =
        prefix.isEmpty || prefix.endsWith(' ') || prefix.endsWith('\n')
        ? ''
        : ' ';
    final inserted = '$spacer@$handle ';
    final next = '$prefix$inserted${text.substring(cursor)}';
    _composer.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: prefix.length + inserted.length,
      ),
    );
    _focus.requestFocus();
  }

  String? _mentionQuery() {
    final value = _composer.value;
    if (!value.selection.isValid || !value.selection.isCollapsed) return null;
    final cursor = value.selection.baseOffset;
    if (cursor < 0 || cursor > value.text.length) return null;
    final match = RegExp(
      r'(^|\s)@([A-Za-z0-9._:-]*)$',
    ).firstMatch(value.text.substring(0, cursor));
    return match?.group(2);
  }

  // ── Overflow ─────────────────────────────────────────────────────────

  Future<void> _openActivity() =>
      showRoomActivitySheet(context, events: _events, members: _room.members);

  Future<void> _openMembers() => showRoomMembersSheet(
    context,
    room: _room,
    unavailable: roomUnavailableMembers(_events),
    round: deriveRoomRound(
      events: _events,
      members: _room.members,
      driverStatus: _driver,
      now: _now,
    ),
    profileFor: widget.profileFor,
    avatarCache: widget.avatarCache,
    onOpenMember: widget.onOpenMember,
  );

  Future<void> _compressMemberHistory(HostedGroupMember member) async {
    final compressor = widget.memberCompressor;
    if (compressor == null ||
        !widget.capabilities.canCompressMembers ||
        _compressing ||
        (_driver?.working ?? false) ||
        (_driver?.running ?? false)) {
      return;
    }
    setState(() => _compressing = true);
    try {
      final result = await compressor.compress(_room, member);
      if (!mounted) return;
      final s = Strings.of(context);
      switch (result.kind) {
        case RoomMemberCompressionKind.pending:
          _notice(s.roomCompressPending, kind: HermesNoticeKind.info);
        case RoomMemberCompressionKind.nothing:
          _notice(
            result.detail ?? s.roomCompressNothing,
            kind: HermesNoticeKind.info,
          );
        case RoomMemberCompressionKind.compressed:
          _notice(
            s.roomCompressSuccess(result.detail ?? ''),
            kind: HermesNoticeKind.success,
          );
      }
    } on TuiGatewayRpcError catch (error) {
      if (!mounted) return;
      final s = Strings.of(context);
      if (error.code == 4009) {
        _notice(
          s.roomCompressBusy(member.handle),
          kind: HermesNoticeKind.warning,
        );
      } else if (error.code == 4007) {
        _notice(s.roomCompressNothing, kind: HermesNoticeKind.info);
      } else {
        _notice(s.roomActionFailed);
      }
    } catch (_) {
      if (mounted) _notice(Strings.of(context).roomActionFailed);
    } finally {
      if (mounted) setState(() => _compressing = false);
    }
  }

  Future<void> _openThread(String threadId) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _RoomThreadPage(
        messages: roomThreadMessages(_events, threadId),
        members: _room.members,
        profileFor: widget.profileFor,
        avatarCache: widget.avatarCache,
        attachmentActions: widget.attachmentActions,
        canReply: widget.capabilities.canSend,
        mentionHandles: _openableHandles(),
        onMention: _openMention,
        onReply: () {
          Navigator.of(context).pop();
          _setThread(threadId, focus: true);
        },
      ),
    ),
  );

  Future<void> _openMenu() async {
    final action = await showRoomOverflowMenu(
      context,
      memberCount: _room.members.length,
      threadCount: roomThreads(_events).length,
      fileCount: roomFiles(_events).length,
      notifications: _notifications,
      canStop: widget.capabilities.canStop,
      canDisband: widget.capabilities.canDisband,
      readOnly: !widget.capabilities.canSend && !widget.capabilities.canRename,
    );
    if (action == null || !mounted) return;
    final s = Strings.of(context);
    switch (action) {
      case RoomMenuAction.members:
        await _openMembers();
      case RoomMenuAction.threads:
        final thread = await showRoomThreadsSheet(
          context,
          events: _events,
          members: _room.members,
        );
        if (thread != null && mounted) await _openThread(thread);
      case RoomMenuAction.files:
        await showRoomFilesSheet(
          context,
          events: _events,
          actions: widget.attachmentActions,
        );
      case RoomMenuAction.activity:
        await _openActivity();
      case RoomMenuAction.notifications:
        final level = await showRoomNotificationsSheet(
          context,
          current: _notifications,
        );
        if (level != null && mounted) {
          setState(() => _notifications = level);
          await widget.prefs.setNotificationLevel(_roomKey, level);
        }
      case RoomMenuAction.settings:
        final name = await showRoomSettingsSheet(
          context,
          name: _room.name,
          canRename: widget.capabilities.canRename,
          room: _room,
          localMembers: [
            for (final member in _room.members)
              if (member.owner.connectionId == _room.authorityGatewayId) member,
          ],
          profileFor: widget.profileFor,
          avatarCache: widget.avatarCache,
          onCompress:
              widget.memberCompressor == null ||
                  !widget.capabilities.canCompressMembers
              ? null
              : _compressMemberHistory,
          compressDisabled:
              _compressing ||
              (_driver?.working ?? false) ||
              (_driver?.running ?? false),
        );
        if (name != null && mounted) {
          try {
            _apply(await widget.gateway.rename(_room, name: name));
          } catch (_) {
            if (mounted) _notice(s.roomActionFailed);
          }
        }
      case RoomMenuAction.stop:
        await _stop();
      case RoomMenuAction.disband:
        final ok = await showHermesConfirmDialog(
          context: context,
          title: s.roomDisbandConfirmTitle,
          message: s.roomDisbandConfirmBody,
          confirmLabel: s.roomDisbandConfirm,
          cancelLabel: s.roomCancel,
          destructive: true,
        );
        if (!ok || !mounted) return;
        try {
          final result = await widget.gateway.disband(_room);
          if (!mounted) return;
          if (result.room.disbanded) Navigator.of(context).pop();
        } catch (_) {
          if (mounted) _notice(s.roomActionFailed);
        }
    }
  }

  // ── Open anchor ──────────────────────────────────────────────────────

  /// The transcript opens at the newest content (reverse list), so whatever
  /// message straddles the list's top edge is cut arbitrarily; when that is
  /// a speaker run's first message its face/name/time header ends up half
  /// hidden under the status line (spec 070). Once, after the first layout,
  /// shift the list just enough to show that header in full.
  void _anchorOnOpen() {
    if (!mounted || _openAnchored) return;
    final list = _transcriptKey.currentContext;
    if (list == null || !_transcriptScroll.hasClients) return;
    _openAnchored = true;
    // Landed on the divider: that position is the one to keep.
    if (_reading != null || _transcriptScroll.landingPending) return;
    final viewport = list.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    double? shift;
    void visit(Element element) {
      if (shift != null) return;
      final key = element.widget.key;
      if (key is ValueKey<String> && key.value.startsWith('room-message-')) {
        final box = element.renderObject;
        if (box is RenderBox && box.attached && box.hasSize) {
          final tileTop = box.localToGlobal(Offset.zero).dy;
          final tileBottom = tileTop + box.size.height;
          if (tileTop < top && tileBottom > top) {
            final id = key.value.substring('room-message-'.length);
            Element? header;
            void find(Element e) {
              if (header != null) return;
              final k = e.widget.key;
              if (k is ValueKey<String> && k.value == 'room-run-header-$id') {
                header = e;
                return;
              }
              e.visitChildElements(find);
            }

            element.visitChildElements(find);
            // Tile top already includes the run's top padding; aligning the
            // tile (not the bare header) keeps the face's breathing room.
            shift = header == null ? 0 : top - tileTop;
          }
        }
        return;
      }
      element.visitChildElements(visit);
    }

    (list as Element).visitChildElements(visit);
    final delta = shift;
    if (delta == null || delta <= 0) return;
    // The newest row (e.g. a member's typing row) stays on screen: when the
    // shift would push it below the list, opening at the live bottom wins.
    final newestKey = _lastItemKeys.isEmpty ? null : _lastItemKeys.last;
    double? newestTop;
    void findNewest(Element element) {
      if (newestTop != null) return;
      final key = element.widget.key;
      if (key is ValueKey<String> && key.value == newestKey) {
        final box = element.renderObject;
        if (box is RenderBox && box.attached && box.hasSize) {
          newestTop = box.localToGlobal(Offset.zero).dy;
        }
        return;
      }
      element.visitChildElements(findNewest);
    }

    if (newestKey != null) list.visitChildElements(findNewest);
    final bottom = top + viewport.size.height;
    final newest = newestTop;
    if (newest != null && newest + delta >= bottom) return;
    final position = _transcriptScroll.position;
    // Reverse list: a larger offset moves the content down.
    _programmaticScroll = true;
    try {
      position.jumpTo(
        (position.pixels + delta).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    } finally {
      _programmaticScroll = false;
    }
  }

  // ── Build ────────────────────────────────────────────────────────────

  String _statusLine(Strings s, RoomRoundModel? round) {
    _agoSince = null;
    final driver = _driver;
    if (driver != null && driver.approvals.isNotEmpty) {
      return s.roomStatusNeedsApproval;
    }
    if (_prompts.isNotEmpty) {
      return _prompts.any((p) => p is RoomMemberApproval)
          ? s.roomStatusNeedsApproval
          : s.rq1215StatusNeedsAnswer;
    }
    if (driver != null &&
        _visibleRetries.isEmpty &&
        _recoveringRetries.isNotEmpty) {
      // The server is still checking an interrupted reply; it settles or
      // defers it on its own, so this is not a failure (yet).
      return s.roomStatusRecovering;
    }
    if (driver != null &&
        (_visibleRetries.isNotEmpty ||
            (driver.blocked && driver.retries.isEmpty))) {
      // Only offer a retry the card can actually perform; otherwise the
      // strip would promise what "Can't be retried from here" denies.
      return widget.capabilities.canRetry
          ? s.roomStatusBlocked
          : s.roomStatusFailed;
    }
    if (driver?.working ?? false) {
      final working = round?.rows
          .where((r) => r.state == RoomTurnState.working)
          .toList();
      return working != null && working.length == 1
          ? s.roomStatusMemberWorking(
              roomMemberName(working.single.member, null),
            )
          : s.roomStatusWorking;
    }
    // Idle: who is in the room and how the last round ended, in ONE grey
    // line ("4 bots · round finished 5 min ago").
    final presence = _presenceLine(s);
    final events = _events;
    if (events.isEmpty) return presence;
    final since = _agoSince = roomEventTime(events.last);
    final ago = roomAgo(s, _now.difference(since));
    if (round != null && !_roundNeedsPanel(round)) {
      return '$presence · ${s.rhdrRoundFinished(ago)}';
    }
    return '$presence · ${s.rhdrLastActivity(ago)}';
  }

  /// "4 bots", or "3 of 4 bots" while the server reports someone
  /// unavailable.
  String _presenceLine(Strings s) {
    final total = _room.members.length;
    final unavailable = roomUnavailableMembers(_events);
    final available = _room.members
        .where((m) => !unavailable.contains(m.memberId))
        .length;
    return available == total
        ? s.rhdrBots(total)
        : s.rhdrBotsAvailable(available, total);
  }

  /// The full round panel is shown only while the round is working or
  /// needs the user (approval, failure with retry); an idle room gets the
  /// compact status line.
  static bool _roundNeedsPanel(RoomRoundModel round) =>
      round.active || round.needsYou > 0 || round.failed > 0;

  /// The header opens what the old status strip opened: the round detail
  /// while there is a round, else the members sheet.
  void _openHeaderDetail(RoomRoundModel? round) {
    if (round != null) {
      setState(() => _detailOpen = !_detailOpen);
      return;
    }
    unawaited(_openMembers());
  }

  Widget? _palette(Strings s) {
    final query = _mentionQuery();
    if (query == null || !_focus.hasFocus) return null;
    final lower = query.toLowerCase();
    final colors = Theme.of(context).hermes;
    final members = _room.members
        .where(
          (m) =>
              m.handle.toLowerCase().startsWith(lower) ||
              (m.displayName?.toLowerCase().startsWith(lower) ?? false),
        )
        .toList();
    final broadcasts = [
      for (final h in const ['all', 'everyone'])
        if (h.startsWith(lower)) h,
    ];
    if (members.isEmpty && broadcasts.isEmpty) return null;
    return Container(
      key: const ValueKey('room-mention-palette'),
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 22,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 6),
          children: [
            for (final member in members)
              HermesListRow(
                key: ValueKey('room-mention-${member.handle}'),
                leading: RoomMemberFace(
                  member: member,
                  fallbackName: member.handle,
                  profile: widget.profileFor(member),
                  avatarCache: widget.avatarCache,
                  size: 26,
                ),
                title: '@${member.handle}',
                subtitle: member.displayName,
                onTap: () => _insertMention(member.handle),
              ),
            for (final handle in broadcasts)
              HermesListRow(
                key: ValueKey('room-mention-$handle'),
                icon: Icons.groups_outlined,
                title: '@$handle',
                onTap: () => _insertMention(handle),
              ),
          ],
        ),
      ),
    );
  }

  Widget _threadBanner(Strings s) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Container(
          key: const ValueKey('room-thread-banner'),
          padding: const EdgeInsetsDirectional.fromSTEB(10, 2, 2, 2),
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.reply_rounded, size: 14, color: colors.accentText),
              const SizedBox(width: 6),
              Text(
                s.roomReplyingInThread,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.accentText,
                ),
              ),
              IconButton(
                key: const ValueKey('room-thread-leave'),
                tooltip: s.roomLeaveThread,
                visualDensity: VisualDensity.compact,
                iconSize: 14,
                onPressed: () => _setThread(null),
                icon: Icon(Icons.close_rounded, color: colors.accentText),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The calm "reconnecting" line under the transcript: neutral color, a
  /// small spinner while polls keep retrying and a retry that reads now.
  /// It never touches the composer.
  Widget _staleStatus(Strings s, HermesThemeColors colors) {
    return Padding(
      key: const ValueKey('room-refresh-stale'),
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s.roomRefreshStale,
              maxLines: 2,
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
          ),
          TextButton(
            key: const ValueKey('room-refresh-retry'),
            onPressed: () => unawaited(refresh()),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: Text(s.commonRetry),
          ),
        ],
      ),
    );
  }

  Widget _composerArea(Strings s) {
    final colors = Theme.of(context).hermes;
    if (!widget.capabilities.canSend) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
          child: Text(
            s.roomCannotSend,
            key: const ValueKey('room-cannot-send'),
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
          ),
        ),
      );
    }
    final block = _attachBlock;
    final dictation = widget.dictation;
    final hasContent =
        _composer.text.trim().isNotEmpty || _attachments.isNotEmpty;
    final unknownMention = firstUnknownRoomMention(_composer.text, [
      for (final member in _room.members) member.handle,
    ]);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_threadId != null) _threadBanner(s),
        if (unknownMention != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 2, 24, 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                s.roomUnknownMention(unknownMention),
                key: const ValueKey('room-unknown-mention'),
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            ),
          ),
        if (block == RoomAttachBlock.crossGateway ||
            block == RoomAttachBlock.noUploader)
          const SizedBox.shrink(),
        ConsoleComposer(
          key: const ValueKey('room-composer'),
          controller: _composer,
          focusNode: _focus,
          showBotModeToggle: false,
          hintText: s.roomComposerHint,
          onSend: (text, drafts) => _send(text, List.of(drafts)),
          onAttach: (source) {
            if (block == RoomAttachBlock.none) {
              unawaited(_pick(source));
            }
          },
          attachEnabled: block == RoomAttachBlock.none,
          // Keyboard images (Gboard, clipboard screenshots) join the same
          // strip as the `+` picks, with the main composer's limits.
          onContentInserted: (content) =>
              unawaited(_insertKeyboardContent(content)),
          attachments: _attachments,
          onRemoveAttachment: (id) =>
              setState(() => _attachments.removeWhere((a) => a.localId == id)),
          sendEnabled: hasContent,
          palette: _palette(s),
          reduceMotion: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
          dictation: dictation == null
              ? null
              : ConsoleComposerDictation(
                  recording: dictation.recording,
                  transcribing: dictation.transcribing,
                  level: dictation.level,
                  cancelEnabled: !dictation.transcribing,
                  sendEnabled: false,
                  onStart: () => unawaited(
                    dictation.start(
                      currentText: _composer.text,
                      onText: (text) {
                        _composer.value = TextEditingValue(
                          text: text,
                          selection: TextSelection.collapsed(
                            offset: text.length,
                          ),
                        );
                      },
                      onFailure: (_) => _notice(s.roomActionFailed),
                    ),
                  ),
                  onStop: () => unawaited(dictation.stop()),
                  onCancel: () => unawaited(dictation.cancel()),
                  onSend: () => unawaited(dictation.stop()),
                ),
        ),
        if (block == RoomAttachBlock.crossGateway ||
            block == RoomAttachBlock.noUploader)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
            child: Text(
              block == RoomAttachBlock.crossGateway
                  ? s.roomAttachCrossGateway
                  : s.roomAttachUnavailable,
              key: const ValueKey('room-attach-disabled-reason'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: colors.textTertiary),
            ),
          ),
      ],
    );
  }

  List<Widget> _promptCards() {
    final s = Strings.of(context);
    final canAnswer = widget.capabilities.canAnswerPrompts;
    final cards = <Widget>[];
    for (final prompt in _prompts) {
      final member = roomMemberById(prompt.memberId, _room.members);
      final profile = member == null ? null : widget.profileFor(member);
      final busy = _promptBusy.contains(prompt.key);
      switch (prompt) {
        case RoomMemberClarify():
          cards.add(
            RoomMemberClarifyCard(
              key: ValueKey('room-inline-${prompt.key}'),
              prompt: prompt,
              member: member,
              profile: profile,
              busy: busy,
              onAnswer: canAnswer
                  ? (answer) => unawaited(
                      _answerPrompt(
                        prompt,
                        (source) => source.answerClarify(prompt, answer),
                        failure: s.rq1215AnswerFailed,
                      ),
                    )
                  : null,
            ),
          );
        case RoomMemberApproval():
          cards.add(
            RoomApprovalCard(
              key: ValueKey('room-inline-${prompt.key}'),
              action: prompt.toDisplayAction(),
              member: member,
              profile: profile,
              busy: busy,
              onChoice: canAnswer
                  ? (choice) => unawaited(
                      _answerPrompt(
                        prompt,
                        (source) => source.answerApproval(prompt, choice),
                        failure: s.rq1215AnswerFailed,
                      ),
                    )
                  : null,
            ),
          );
        case RoomMemberWaitingUnreachable():
          if (member == null) continue;
          final open = widget.onOpenMemberChat;
          cards.add(
            RoomMemberWaitingBanner(
              key: ValueKey('room-inline-${prompt.key}'),
              member: member,
              profile: profile,
              busy: busy,
              onOpenChat: open == null
                  ? null
                  : () => open(member, prompt.storedSessionId),
              onCancelWait: canAnswer
                  ? () => unawaited(_cancelWait(prompt))
                  : null,
            ),
          );
      }
    }
    return cards;
  }

  List<Widget> _stallCards() {
    final stall = _stall;
    final member = stall == null
        ? null
        : roomMemberById(stall.memberId, _room.members);
    if (stall == null || member == null) return const [];
    return [
      RoomMemberStallBanner(
        key: ValueKey('room-inline-${stall.key}'),
        member: member,
        profile: widget.profileFor(member),
        busy: _resuming,
        onResume: widget.capabilities.canAnswerPrompts
            ? () => unawaited(_resumeStall(stall))
            : null,
      ),
    ];
  }

  List<Widget> _inlineCards() {
    final driver = _driver;
    if (driver == null) return [..._promptCards(), ..._stallCards()];
    return [
      ..._promptCards(),
      ..._stallCards(),
      for (final action in driver.approvals)
        RoomApprovalCard(
          key: ValueKey('room-inline-approval-${action.requestId}'),
          action: action,
          member: roomMemberById(action.memberId, _room.members),
          profile: () {
            final m = roomMemberById(action.memberId, _room.members);
            return m == null ? null : widget.profileFor(m);
          }(),
          busy: _answering.contains(action.requestId),
          onChoice: widget.capabilities.canApprove
              ? (choice) => unawaited(_approve(action, choice))
              : null,
        ),
      // Until local state is read, a dismissed card must not flash back.
      if (_localLoaded)
        for (final retry in _visibleRetries)
          RoomRetryCard(
            key: ValueKey('room-inline-retry-${retry.taskId}'),
            taskId: retry.taskId,
            member: _memberForTask(retry.taskId),
            profile: switch (_memberForTask(retry.taskId)) {
              final m? => widget.profileFor(m),
              null => null,
            },
            busy: _retrying.contains(retry.taskId),
            onRetry: widget.capabilities.canRetry
                ? () => unawaited(_retry(retry.taskId))
                : null,
            onDismiss: () => _dismissTask(retry.taskId),
          ),
    ];
  }

  /// The round as the user sees it: a failure they dismissed no longer
  /// raises the alarm (it reads as "no reply"), and a room kept "active"
  /// only by dismissed retries is idle.
  RoomRoundModel? _visibleRound(RoomRoundModel? round) {
    if (round == null || _dismissedTasks.isEmpty) return round;
    var changed = false;
    final rows = [
      for (final r in round.rows)
        if (r.state == RoomTurnState.failed &&
            r.taskId != null &&
            _dismissedTasks.contains(r.taskId))
          () {
            changed = true;
            return RoomRoundRow(
              member: r.member,
              state: RoomTurnState.noReply,
              since: r.since,
              taskId: r.taskId,
              prompt: r.prompt,
              reasonCode: r.reasonCode,
            );
          }()
        else
          r,
    ];
    final driver = _driver;
    final active =
        round.active &&
        ((driver?.working ?? false) ||
            (driver?.approvals.isNotEmpty ?? false) ||
            _prompts.isNotEmpty ||
            _visibleRetries.isNotEmpty ||
            rows.any(
              (r) =>
                  r.state == RoomTurnState.working ||
                  r.state == RoomTurnState.needsYou,
            ));
    if (!changed && active == round.active) return round;
    return RoomRoundModel(
      discussionId: round.discussionId,
      round: round.round,
      rows: List.unmodifiable(rows),
      working: round.working,
      queued: round.queued,
      active: active,
    );
  }

  // ── Reading anchor ───────────────────────────────────────────────────

  bool get _atBottom {
    if (!_transcriptScroll.hasClients) return true;
    final p = _transcriptScroll.position;
    return p.pixels <= p.minScrollExtent + 0.5;
  }

  /// Collapse the header once the reader drags this far into the history.
  static const double _collapseAfter = 56;

  void _trackHeaderCollapse(ScrollNotification n) {
    if (n is UserScrollNotification) {
      _userScrolling = n.direction != ScrollDirection.idle;
    }
    final away = n.metrics.pixels - n.metrics.minScrollExtent;
    bool? collapsed;
    if (away <= 8) {
      collapsed = false;
    } else if (_userScrolling &&
        n is ScrollUpdateNotification &&
        away > _collapseAfter) {
      collapsed = true;
    }
    if (collapsed == null || collapsed == _headerCollapsed) return;
    void apply() {
      if (mounted) setState(() => _headerCollapsed = collapsed!);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    _trackHeaderCollapse(n);
    if (_programmaticScroll) return false;
    if (n is ScrollUpdateNotification && _reading == null && !_atBottom) {
      // The reader left the bottom (drag or fling): keep the boundary at
      // the newest history row. While following it already is, so nothing
      // moves now; from here on new content grows below it.
      _startReading();
    } else if (n is ScrollEndNotification && _reading != null && _atBottom) {
      _unfreeze();
    }
    return false;
  }

  /// Key of the newest history row in the last built transcript.
  String? _lastHistoryKey;

  void _startReading() {
    final boundary = _lastHistoryKey;
    if (boundary == null) return;
    _reading = (boundary: boundary, ceiling: _log?.latestSeq ?? 0);
  }

  void _unfreeze() {
    if (_reading == null) return;
    // At the bottom edge: the controller pins the merged list to its new
    // bottom inside the same layout, so nothing visibly moves.
    setState(() => _reading = null);
  }

  void _toBottom() {
    if (!_transcriptScroll.hasClients) {
      _reading = null;
      return;
    }
    final p = _transcriptScroll.position;
    if (_reading == null) {
      if (p.pixels != p.minScrollExtent) p.jumpTo(p.minScrollExtent);
      return;
    }
    unawaited(
      p
          .animateTo(
            p.minScrollExtent,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          )
          .then((_) {
            if (mounted) _unfreeze();
          }),
    );
  }

  List<String> _lastItemKeys = const [];

  HostedGroupMember? _memberForTask(String taskId) {
    for (final e in _events.reversed) {
      if (e.activity.taskId == taskId) {
        return roomMemberById(e.activity.memberId, _room.members);
      }
    }
    return null;
  }

  Widget _entry(RoomTranscriptEntry entry, Strings s, List<String> handles) {
    return switch (entry) {
      RoomDaySeparator(:final day) => RoomSeparator(
        key: ValueKey('room-day-${entry.key}'),
        label: roomDayLabel(s, day, _now),
      ),
      RoomNewSinceDivider() => RoomSeparator(
        key: const ValueKey('room-new-since'),
        label: s.roomNewSinceYouLeft,
        highlight: true,
      ),
      RoomRoundDivider(:final round) => RoomSeparator(
        key: ValueKey('room-round-divider-${entry.key}'),
        label: s.roomRoundLabel(round),
      ),
      RoomPassesEntry() => RoomPassesLine(
        entry: entry,
        members: _room.members,
        onOpenActivity: () => unawaited(_openActivity()),
      ),
      RoomMessageEntry() => RoomMessageTile(
        key: ValueKey(entry.key),
        entry: entry,
        profile: entry.member == null ? null : widget.profileFor(entry.member!),
        avatarCache: widget.avatarCache,
        mentionHandles: handles,
        attachmentActions: widget.attachmentActions,
        onReplyInThread:
            widget.capabilities.canSend && entry.event.threadId != null
            ? () => _replyInThread(entry)
            : null,
        onOpenThread: entry.thread == null
            ? null
            : () => unawaited(_openThread(entry.thread!.threadId)),
        onMention: _openMention,
      ),
    };
  }

  /// Handles whose mention opens something: members with a local profile
  /// when the host can open them (same rule as the members sheet). Peers,
  /// `@all` and `@everyone` stay plain text rather than dead links.
  List<String> _openableHandles() => [
    if (widget.onOpenMember != null)
      for (final m in _room.members)
        if (widget.profileFor(m) != null) m.handle,
  ];

  void _openMention(String handle) {
    final member = _room.members
        .where((m) => m.handle.toLowerCase() == handle.toLowerCase())
        .firstOrNull;
    if (member != null) widget.onOpenMember?.call(member);
  }

  /// Inputs the transcript depends on. Typing, focus, dictation and working
  /// timers change none of them, so the transcript subtree is reused as is
  /// (identical widget = no rebuild of any message).
  List<Object?> _transcriptInputs(Locale locale) => [
    _log,
    _driver,
    _room,
    _reading,
    _arrivedThroughSeq,
    _landPending,
    _dismissedTasks,
    _lastSeenSeq,
    _lastSeenLoaded,
    _localLoaded,
    _threadId == null,
    _retrying.join(','),
    _answering.join(','),
    _prompts,
    _promptBusy.join(','),
    _stall,
    _resuming,
    _outboxVersion,
    locale,
    widget,
    DateUtils.dateOnly(_now),
  ];

  List<Object?>? _viewInputs;
  ({Widget widget, int unread})? _view;
  List<Object?>? _roundInputs;
  RoomRoundModel? _round;

  static bool _sameInputs(List<Object?>? a, List<Object?> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] is String ||
          a[i] is bool ||
          a[i] is int ||
          a[i] is DateTime ||
          a[i] is Locale) {
        if (a[i] != b[i]) return false;
      } else if (!identical(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }

  RoomRoundModel? _roundView() {
    final now = _now;
    final inputs = [
      _log,
      _driver,
      _room,
      _dismissedTasks,
      _prompts,
      // Without driver status an open turn expires with time.
      if (_driver == null) now.millisecondsSinceEpoch ~/ 10000,
    ];
    if (_sameInputs(_roundInputs, inputs)) return _round;
    _roundInputs = inputs;
    return _round = _visibleRound(
      deriveRoomRound(
        events: _events,
        members: _room.members,
        driverStatus: _driver,
        now: now,
        memberPrompts: _prompts,
      ),
    );
  }

  /// Starts fetching the newest images of the room log as soon as the log
  /// changes, before their rows are built (lazy list), so a row scrolled
  /// into view paints from the private cache. Bounded per pass; the
  /// prefetcher dedupes, caps concurrency and waits while App Lock is on.
  void _prefetchRoomMedia(List<RoomTranscriptEntry> transcript) {
    final actions = widget.attachmentActions;
    if (actions == null || actions is! RoomAttachmentCache) return;
    final cache = actions as RoomAttachmentCache;
    var queued = 0;
    for (var i = transcript.length - 1; i >= 0 && queued < 12; i--) {
      final entry = transcript[i];
      if (entry is! RoomMessageEntry) continue;
      for (final ref in entry.body.attachments) {
        if (!ref.isImage || !actions.canFetch(ref)) continue;
        cache.prefetch(ref);
        queued++;
      }
    }
  }

  ({Widget widget, int unread}) _transcriptView(
    Strings s,
    HermesThemeColors colors,
  ) {
    final inputs = _transcriptInputs(Localizations.localeOf(context));
    final cached = _view;
    if (cached != null && _sameInputs(_viewInputs, inputs)) return cached;
    _viewInputs = inputs;
    final transcript = buildRoomTranscript(
      events: _events,
      members: _room.members,
      lastSeenSeq: _lastSeenLoaded ? _lastSeenSeq : null,
      arrivedThroughSeq: _arrivedThroughSeq,
    );
    _prefetchRoomMedia(transcript);
    final handles = _openableHandles();
    // Chronological items (oldest first), each with a stable identity.
    final items = <_RoomItem>[
      for (final entry in transcript)
        (
          key: entry.key,
          kind: entry is RoomMessageEntry
              ? roomEventUnreadKind(entry.event)
              : UnreadRowKind.quiet,
          seq: entry is RoomMessageEntry ? entry.event.sequence : 0,
          build: () => _entry(entry, s, handles),
        ),
      for (final message in _visibleOutbox())
        (
          key: 'room-pending-${message.attempt.clientEventId}',
          kind: UnreadRowKind.own,
          seq: 0,
          build: () => RoomPendingMessageTile(
            key: ValueKey('room-pending-${message.attempt.clientEventId}'),
            id: message.attempt.clientEventId,
            text: message.text,
            attachments: message.attachments,
            failed: message.failed,
            onRetry: () => _retrySend(message),
          ),
        ),
      for (final card in _inlineCards())
        (
          key: (card.key! as ValueKey<String>).value,
          kind: UnreadRowKind.quiet,
          seq: 0,
          build: () => card,
        ),
      // Whoever is replying right now, where the answer will appear.
      for (final row in _roundView()?.rows ?? const <RoomRoundRow>[])
        if (row.state == RoomTurnState.working)
          (
            key: 'room-typing-${row.member.memberId}',
            kind: UnreadRowKind.quiet,
            seq: 0,
            build: () => RoomTypingRow(
              key: ValueKey('room-typing-${row.member.memberId}'),
              member: row.member,
              name: roomSpeakerName(
                row.member,
                null,
                widget.profileFor(row.member),
              ),
              profile: widget.profileFor(row.member),
              avatarCache: widget.avatarCache,
            ),
          ),
    ];
    _lastItemKeys = [for (final i in items) i.key];
    _lastHistoryKey = transcript.isEmpty ? null : transcript.last.key;
    if (_landPending && _lastSeenLoaded && _log != null) {
      // Entry (or return after leaving) with news from while away: open
      // with the divider at the top, the history above it in the center.
      // Decided only once the log is here: consumed on an empty transcript
      // (read marker loaded before the first read) the room opened at the
      // bottom with the divider out of sight.
      _landPending = false;
      final at = transcript.indexWhere((e) => e is RoomNewSinceDivider);
      if (at > 0 && _reading == null) {
        _reading = (
          boundary: transcript[at - 1].key,
          ceiling: _arrivedThroughSeq ?? _log?.latestSeq ?? 0,
        );
        _transcriptScroll.requestLanding(context: _landingContext);
      }
    }
    var reading = _reading;
    var boundary = transcript.length - 1;
    if (reading != null) {
      boundary = items.indexWhere((i) => i.key == reading!.boundary);
      if (boundary < 0) {
        // The boundary row is gone (log reset): follow again.
        reading = _reading = null;
        _transcriptScroll.releaseLanding();
        boundary = transcript.length - 1;
      }
    }
    final anchored = items.sublist(0, boundary + 1);
    final newer = items.sublist(boundary + 1);
    final unread = reading == null
        ? 0
        : unreadNewsAfter<_RoomItem>(
            newer,
            baseline: reading.ceiling,
            positionOf: (i) => i.seq,
            kindOf: (i) => i.kind,
          );
    _viewInputs = _transcriptInputs(Localizations.localeOf(context));
    final Widget view = items.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                s.roomEmpty,
                key: const ValueKey('room-empty'),
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: KeyedSubtree(
                key: _transcriptKey,
                child: CustomScrollView(
                  key: const ValueKey('room-transcript'),
                  controller: _transcriptScroll,
                  reverse: true,
                  center: _centerKey,
                  slivers: [
                    // Newer than what the user is
                    // reading: grows below it.
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => newer[index].build(),
                        childCount: newer.length,
                      ),
                    ),
                    SliverPadding(
                      key: _centerKey,
                      padding: const EdgeInsets.only(top: 8),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) =>
                              anchored[anchored.length - 1 - index].build(),
                          childCount: anchored.length,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
    return _view = (widget: view, unread: unread);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final round = _roundView();
    final view = _transcriptView(s, colors);
    if (!_openAnchored && _lastItemKeys.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _anchorOnOpen());
    }
    String nameOf(HostedGroupMember m) =>
        roomSpeakerName(m, null, widget.profileFor(m));
    final summary = roomStripSummary(
      s,
      round: round,
      idleStatus: _statusLine(s, round),
      nameOf: nameOf,
      now: _now,
    );
    _armAgoTick();
    final detailOpen = _detailOpen && round != null;
    return Scaffold(
      key: const ValueKey('room-screen'),
      appBar: RoomHeaderBar(
        title: widget.displayName ?? _room.name,
        status: summary,
        members: _room.members,
        states: {
          for (final r in round?.rows ?? const <RoomRoundRow>[])
            r.member.memberId: r.state,
        },
        profileFor: widget.profileFor,
        avatarCache: widget.avatarCache,
        roomAvatar: widget.roomAvatar,
        collapsed: _headerCollapsed,
        onOpenDetail: () => _openHeaderDetail(round),
        onMore: () => unawaited(_openMenu()),
      ),
      body: SafeArea(
        top: false,
        // The real height left (after app bar, safe area and IME) bounds the
        // composer so it never overflows in landscape with the keyboard.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final available = constraints.maxHeight;
            return Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: FocusScope(
                          node: _transcriptFocus,
                          child: view.widget,
                        ),
                      ),
                      if (unreadPillVisible(
                        present: _presence.present,
                        reading: _reading != null,
                        count: view.unread,
                      ))
                        Positioned(
                          bottom: 20,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: RoomNewPill(
                              count: view.unread,
                              onTap: _toBottom,
                            ),
                          ),
                        ),
                      if (detailOpen) ...[
                        Positioned.fill(
                          child: GestureDetector(
                            key: const ValueKey('room-round-sheet-barrier'),
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() => _detailOpen = false),
                            child: ColoredBox(
                              color: colors.background.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 4,
                          left: 8,
                          right: 8,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: math.max(120, available * 0.55),
                            ),
                            child: Material(
                              color: colors.surface,
                              elevation: 8,
                              borderRadius: BorderRadius.circular(16),
                              clipBehavior: Clip.antiAlias,
                              child: SingleChildScrollView(
                                child: RoomRoundDetail(
                                  round: round,
                                  now: _now,
                                  profileFor: widget.profileFor,
                                  avatarCache: widget.avatarCache,
                                  onStopAll:
                                      widget.capabilities.canStop && !_stopping
                                      ? () => unawaited(_stop())
                                      : null,
                                  onRetry: widget.capabilities.canRetry
                                      ? (row) {
                                          final task = row.taskId;
                                          if (task != null) {
                                            unawaited(_retry(task));
                                          }
                                        }
                                      : null,
                                  onOpenActivity: () {
                                    setState(() => _detailOpen = false);
                                    unawaited(_openActivity());
                                  },
                                  onOpenMembers: () {
                                    setState(() => _detailOpen = false);
                                    unawaited(_openMembers());
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_stale) _staleStatus(s, colors),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.max(
                      0,
                      math.min(available * 0.6, available - 48),
                    ),
                  ),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: ListenableBuilder(
                      listenable: Listenable.merge([
                        _composer,
                        _focus,
                        widget.dictation,
                      ]),
                      builder: (context, _) => _composerArea(s),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Thread sheet page: the thread's messages with the same group layout.
class _RoomThreadPage extends StatelessWidget {
  final List<HostedGroupEvent> messages;
  final List<HostedGroupMember> members;
  final RoomProfileResolver profileFor;
  final MissionProfileAvatarCache? avatarCache;
  final RoomAttachmentActions? attachmentActions;
  final bool canReply;
  final List<String> mentionHandles;
  final ValueChanged<String> onMention;
  final VoidCallback onReply;

  const _RoomThreadPage({
    required this.messages,
    required this.members,
    required this.profileFor,
    required this.avatarCache,
    required this.attachmentActions,
    required this.canReply,
    required this.mentionHandles,
    required this.onMention,
    required this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final entries = buildRoomTranscript(
      events: messages,
      members: members,
    ).whereType<RoomMessageEntry>().toList();
    return Scaffold(
      key: const ValueKey('room-thread-page'),
      appBar: HermesAppBar(title: Text(s.roomThreadTitle)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: entries.length,
                itemBuilder: (_, index) => RoomMessageTile(
                  entry: RoomMessageEntry(
                    event: entries[index].event,
                    body: entries[index].body,
                    member: entries[index].member,
                    firstOfRun: entries[index].firstOfRun,
                  ),
                  profile: entries[index].member == null
                      ? null
                      : profileFor(entries[index].member!),
                  avatarCache: avatarCache,
                  mentionHandles: mentionHandles,
                  attachmentActions: attachmentActions,
                  onMention: onMention,
                ),
              ),
            ),
            if (canReply)
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  key: const ValueKey('room-thread-reply'),
                  onPressed: onReply,
                  icon: const Icon(Icons.reply_rounded),
                  label: Text(s.roomReplyInThread),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One message sent from this screen and not yet acknowledged.
final class _OutgoingMessage {
  /// Reused on retry, so the server keeps the send idempotent.
  final HostedGroupSendAttempt attempt;
  final String text;
  final List<AttachmentDraft> attachments;
  bool failed = false;

  _OutgoingMessage({
    required this.attempt,
    required this.text,
    required this.attachments,
  });
}
