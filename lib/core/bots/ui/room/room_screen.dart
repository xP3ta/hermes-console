import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../models/attachment_draft.dart';
import '../../../models/hosted_groups.dart';
import '../../../services/attachment_uploader.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/attachment_source_sheet.dart';
import '../../../widgets/chat/console_composer.dart';
import '../../../widgets/hermes_app_bar.dart';
import '../../../widgets/hermes_notice.dart';
import '../../../widgets/hermes_premium_ui.dart';
import '../../../widgets/mission_profile_avatar.dart';
import '../../data/room_log_cursor.dart';
import 'room_dictation.dart';
import 'room_gateway.dart';
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
  final ScrollController _transcriptScroll = ScrollController();
  final GlobalKey _transcriptKey = GlobalKey(debugLabel: 'room-transcript');
  bool _openAnchored = false;

  /// Reading anchor. While the user reads above the newest content, the
  /// items present when they left the bottom stay in the scroll view's
  /// center sliver and anything newer grows *below* it, so what they read
  /// never moves; returning to the bottom merges everything again.
  final GlobalKey _centerKey = GlobalKey(debugLabel: 'room-center');
  Set<String>? _frozenKeys;
  Set<String> _dismissedTasks = const {};
  bool _localLoaded = false;
  bool _detailOpen = false;
  final List<AttachmentDraft> _attachments = [];
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
  final Set<String> _retrying = {};
  Animation<double>? _coverAnimation;
  bool _stopping = false;
  bool _pickerOpen = false;
  String? _threadId;
  String? _error;
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
    _poller = RoomLogPoller(
      tick: _tick,
      onDelta: (_) {},
      onError: (_) {
        if (mounted) {
          setState(() => _error = Strings.of(context).roomRefreshFailed);
        }
      },
      timer: widget.pollTimer,
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
    }
  }

  void _onCoverChanged(AnimationStatus status) {
    _poller.setVisible(status == AnimationStatus.dismissed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    _poller.setForeground(foreground);
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
    if (reset) _frozenKeys = null;
    final driverChanged = !_sameDriver(_driver, result.driverStatus);
    if (added.isNotEmpty ||
        reset ||
        driverChanged ||
        result.room.revision != previous.revision ||
        _error != null) {
      setState(() {
        _room = result.room;
        _log = log;
        _driver = result.driverStatus ?? _driver;
        _error = null;
        _answering.removeWhere(
          (id) => !(_driver?.approvals.any((a) => a.requestId == id) ?? false),
        );
      });
    } else if (_driver?.working ?? false) {
      // Working timers (elapsed) still tick visually; an idle room schedules
      // no frame on a quiet poll.
      setState(() {});
    }
    if (added.isNotEmpty || reset) _retirePublishedOutbox();
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
    } catch (_) {
      if (mounted) {
        setState(() => _error = Strings.of(context).roomRefreshFailed);
      }
    }
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
      _error = null;
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
      _error = null;
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
      final picked = <({String path, String name, AttachmentType type})>[];
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
            if (f.path == null ||
                !AttachmentUploader.isAllowedDocumentName(f.name)) {
              continue;
            }
            picked.add((
              path: f.path!,
              name: f.name,
              type: AttachmentType.document,
            ));
          }
      }
      for (final f in picked) {
        final size = await File(f.path).length();
        if (size <= 0 || size > AttachmentUploader.maxBytes) continue;
        final draft = await AttachmentUploader.materializeForDraft(
          AttachmentDraft(
            localId: const Uuid().v4(),
            type: f.type,
            name: f.name,
            mimeType: _mime(f.name, f.type),
            sizeBytes: size,
            localPath: f.path,
          ),
        );
        if (draft != null && mounted) setState(() => _attachments.add(draft));
      }
    } catch (_) {
      if (mounted) _notice(Strings.of(context).roomActionFailed);
    } finally {
      _pickerOpen = false;
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
    final position = _transcriptScroll.position;
    // Reverse list: a larger offset moves the content down.
    position.jumpTo(
      (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────

  String _statusLine(Strings s, RoomRoundModel? round) {
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
    final events = _events;
    if (events.isEmpty) return '';
    final ago = roomAgo(s, _now.difference(roomEventTime(events.last)));
    // Idle room with a finished round: ONE line, "Round 1 finished · 17 h
    // ago", instead of a round panel stacked over a last-activity bar.
    if (round != null && !_roundNeedsPanel(round)) {
      return s.roomStatusRoundFinished(round.round, ago);
    }
    return s.roomStatusLastActivity(ago);
  }

  /// The full round panel is shown only while the round is working or
  /// needs the user (approval, failure with retry); an idle room gets the
  /// compact status line.
  static bool _roundNeedsPanel(RoomRoundModel round) =>
      round.active || round.needsYou > 0 || round.failed > 0;

  PreferredSizeWidget _header(Strings s) {
    final colors = Theme.of(context).hermes;
    final unavailable = roomUnavailableMembers(_events);
    final available = _room.members
        .where((m) => !unavailable.contains(m.memberId))
        .length;
    return HermesAppBar(
      scrolledUnderElevation: 0,
      titleSpacing: 0,
      title: Semantics(
        button: true,
        label: s.roomMenuMembers,
        child: InkWell(
          key: const ValueKey('room-header'),
          onTap: () => unawaited(_openMembers()),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                widget.roomAvatar ??
                    RoomHeaderFaces(
                      members: _room.members,
                      profileFor: widget.profileFor,
                      avatarCache: widget.avatarCache,
                    ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.displayName ?? _room.name,
                        key: const ValueKey('room-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        s.roomViewAvailability(available, _room.members.length),
                        key: const ValueKey('room-availability'),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          key: const ValueKey('room-overflow'),
          tooltip: s.roomMoreActions,
          icon: const Icon(Icons.more_horiz_rounded),
          onPressed: () => unawaited(_openMenu()),
        ),
      ],
    );
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_threadId != null) _threadBanner(s),
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
              style: TextStyle(fontSize: 11, color: colors.textDisabled),
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

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is UserScrollNotification &&
        n.direction != ScrollDirection.idle &&
        _frozenKeys == null) {
      // The user took the scroll: what is on screen now stays put.
      _frozenKeys = {..._lastItemKeys};
    } else if (n is ScrollEndNotification && _frozenKeys != null && _atBottom) {
      _unfreeze();
    }
    return false;
  }

  void _unfreeze() {
    if (_frozenKeys == null) return;
    // At the very bottom edge: merging keeps the viewport pinned to the
    // new bottom (range-maintaining physics), so nothing visibly moves.
    setState(() => _frozenKeys = null);
  }

  void _toBottom() {
    if (!_transcriptScroll.hasClients) {
      _frozenKeys = null;
      return;
    }
    final p = _transcriptScroll.position;
    if (_frozenKeys == null) {
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
            ? () => _setThread(entry.event.threadId)
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
    _frozenKeys,
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
    );
    final handles = _openableHandles();
    // Chronological items (oldest first), each with a stable identity.
    final items = <({String key, bool message, Widget Function() build})>[
      for (final entry in transcript)
        (
          key: entry.key,
          message: entry is RoomMessageEntry,
          build: () => _entry(entry, s, handles),
        ),
      for (final message in _visibleOutbox())
        (
          key: 'room-pending-${message.attempt.clientEventId}',
          message: true,
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
          message: false,
          build: () => card,
        ),
      // Whoever is replying right now, where the answer will appear.
      for (final row in _roundView()?.rows ?? const <RoomRoundRow>[])
        if (row.state == RoomTurnState.working)
          (
            key: 'room-typing-${row.member.memberId}',
            message: false,
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
    final grew =
        _openAnchored &&
        _lastItemKeys.isNotEmpty &&
        items.isNotEmpty &&
        items.last.key != _lastItemKeys.last;
    _lastItemKeys = [for (final i in items) i.key];
    final frozen = _frozenKeys;
    if (grew && frozen == null) {
      // Not reading back: follow the newest content to the bottom.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _frozenKeys != null || !_transcriptScroll.hasClients) {
          return;
        }
        final p = _transcriptScroll.position;
        if (p.pixels != p.minScrollExtent) p.jumpTo(p.minScrollExtent);
      });
    }
    final anchored = frozen == null
        ? items
        : [
            for (final i in items)
              if (frozen.contains(i.key)) i,
          ];
    final newer = frozen == null
        ? const <({String key, bool message, Widget Function() build})>[]
        : [
            for (final i in items)
              if (!frozen.contains(i.key)) i,
          ];
    final unread = newer.where((i) => i.message).length;
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
    final next = roomStripNext(s, round: round, nameOf: nameOf);
    final detailOpen = _detailOpen && round != null;
    return Scaffold(
      key: const ValueKey('room-screen'),
      appBar: _header(s),
      body: SafeArea(
        top: false,
        // The real height left (after app bar, safe area and IME) decides
        // what fits: in landscape with the keyboard open the status strip
        // steps aside so the composer never overflows.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final available = constraints.maxHeight;
            final roomy = available > 300;
            return Column(
              children: [
                // Fixed height in every state: a round starting, needing
                // you or ending never moves the transcript.
                if (roomy)
                  RoomStatusStrip(
                    members: _room.members,
                    states: {
                      for (final r in round?.rows ?? const <RoomRoundRow>[])
                        r.member.memberId: r.state,
                    },
                    summary: summary,
                    next: next,
                    profileFor: widget.profileFor,
                    avatarCache: widget.avatarCache,
                    onTap: round != null
                        ? () => setState(() => _detailOpen = !_detailOpen)
                        : (_events.isEmpty
                              ? null
                              : () => unawaited(_openActivity())),
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: FocusScope(
                          node: _transcriptFocus,
                          child: view.widget,
                        ),
                      ),
                      if (view.unread > 0)
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
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Text(
                      _error!,
                      key: const ValueKey('room-error'),
                      style: TextStyle(color: colors.error, fontSize: 12),
                    ),
                  ),
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
