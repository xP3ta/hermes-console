import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
  Future<({String text, String? threadId})> load();
  Future<void> save(String text, {String? threadId, String? preparedId});
  Future<void> clear({required String preparedId});
}

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
  final ScrollController _transcriptScroll = ScrollController();
  final GlobalKey _transcriptKey = GlobalKey(debugLabel: 'room-transcript');
  bool _openAnchored = false;
  final List<AttachmentDraft> _attachments = [];
  final Set<String> _answering = {};
  final Set<String> _retrying = {};
  Animation<double>? _coverAnimation;
  bool _sending = false;
  bool _stopping = false;
  bool _pickerOpen = false;
  String? _threadId;
  String? _error;
  int? _lastSeenSeq;
  bool _lastSeenLoaded = false;
  RoomNotificationLevel _notifications = RoomNotificationLevel.all;
  HostedGroupSendAttempt? _pendingAttempt;
  String? _pendingText;
  Timer? _draftTimer;
  bool _draftDirty = false;
  bool _restoringDraft = false;
  bool _foreground = true;

  String get _roomKey => '${_room.authorityGatewayId}:${_room.roomId}';
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
    _composer.addListener(_onComposerChanged);
    _focus.addListener(_rebuild);
    widget.dictation?.addListener(_rebuild);
    unawaited(_loadLocal());
    unawaited(_restoreDraft());
  }

  void _rebuild() {
    if (mounted) setState(() {});
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
      if (!mounted || _draftDirty) return;
      _restoringDraft = true;
      _threadId = draft.threadId;
      _composer.text = draft.text;
      _restoringDraft = false;
    } catch (_) {
      // Never overwrite an unreadable draft.
    }
  }

  void _onComposerChanged() {
    if (_pendingAttempt != null && _composer.text.trim() != _pendingText) {
      _pendingAttempt = null;
      _pendingText = null;
    }
    if (!_restoringDraft && widget.drafts != null) {
      _draftDirty = true;
      _draftTimer?.cancel();
      _draftTimer = Timer(const Duration(milliseconds: 350), _flushDraft);
    }
    if (mounted) setState(() {});
  }

  void _flushDraft() {
    _draftTimer?.cancel();
    final store = widget.drafts;
    if (!_draftDirty || store == null) return;
    unawaited(
      store
          .save(
            _composer.text,
            threadId: _threadId,
            preparedId: _pendingAttempt?.clientEventId,
          )
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _coverAnimation?.removeStatusListener(_onCoverChanged);
    _poller.dispose();
    _flushDraft();
    _markSeen();
    widget.dictation?.removeListener(_rebuild);
    _composer.removeListener(_onComposerChanged);
    _composer.dispose();
    _focus.removeListener(_rebuild);
    _focus.dispose();
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

  Future<void> _send(String raw, List<AttachmentDraft> drafts) async {
    final text = raw.trim();
    if ((text.isEmpty && drafts.isEmpty) ||
        _sending ||
        !widget.capabilities.canSend) {
      return;
    }
    final s = Strings.of(context);
    setState(() => _sending = true);
    try {
      final refs = <RoomAttachmentRef>[];
      for (final draft in drafts) {
        final path = await widget.uploader?.upload(draft);
        if (path == null) {
          if (mounted) _notice(s.roomAttachFailed(draft.name));
          return;
        }
        refs.add(RoomAttachmentRef(name: draft.name, path: path));
      }
      final full = appendRoomAttachmentSuffix(text, refs);
      if (_pendingAttempt == null || _pendingText != text || refs.isNotEmpty) {
        _pendingAttempt = HostedGroupSendAttempt.forClientEvent(
          const Uuid().v4(),
          threadId: _threadId,
        );
        _pendingText = text;
      }
      final attempt = _pendingAttempt!;
      _flushDraft();
      final submittedThread = _threadId;
      final result = await widget.gateway.send(
        _room,
        text: full,
        attempt: attempt,
      );
      // The acknowledged send never waits on draft storage.
      unawaited(
        widget.drafts
                ?.clear(preparedId: attempt.clientEventId)
                .then<void>((_) {}, onError: (Object _) {}) ??
            Future<void>.value(),
      );
      if (!mounted) return;
      _apply(result);
      setState(() {
        _pendingAttempt = null;
        _pendingText = null;
        _attachments.clear();
        if (_composer.text.trim() == text && _threadId == submittedThread) {
          _composer.clear();
          _threadId = null;
        }
      });
      _poller.setVisible(true);
    } catch (_) {
      if (mounted) setState(() => _error = s.roomActionFailed);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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

  void _setThread(String? threadId) {
    setState(() {
      _threadId = threadId;
      _pendingAttempt = null;
      _pendingText = null;
    });
    _draftDirty = true;
    _flushDraft();
    if (threadId != null) _focus.requestFocus();
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
        onReply: () {
          Navigator.of(context).pop();
          _setThread(threadId);
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
    if (driver != null && (driver.blocked || driver.retries.isNotEmpty)) {
      return s.roomStatusBlocked;
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
          onSend: (text, drafts) => unawaited(_send(text, List.of(drafts))),
          onAttach: (source) {
            if (block == RoomAttachBlock.none) {
              unawaited(_pick(source));
            }
          },
          attachEnabled: block == RoomAttachBlock.none && !_sending,
          attachments: _attachments,
          onRemoveAttachment: (id) =>
              setState(() => _attachments.removeWhere((a) => a.localId == id)),
          busy: _sending,
          sendEnabled: hasContent && !_sending,
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

  List<Widget> _inlineCards() {
    final driver = _driver;
    if (driver == null) return const [];
    return [
      for (final action in driver.approvals)
        RoomApprovalCard(
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
      for (final retry in driver.retries)
        RoomRetryCard(
          taskId: retry.taskId,
          member: _memberForTask(retry.taskId),
          busy: _retrying.contains(retry.taskId),
          onRetry: widget.capabilities.canRetry
              ? () => unawaited(_retry(retry.taskId))
              : null,
        ),
    ];
  }

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
        onMention: (handle) {
          final member = _room.members
              .where((m) => m.handle.toLowerCase() == handle.toLowerCase())
              .firstOrNull;
          if (member != null) widget.onOpenMember?.call(member);
        },
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final transcript = buildRoomTranscript(
      events: _events,
      members: _room.members,
      lastSeenSeq: _lastSeenLoaded ? _lastSeenSeq : null,
    );
    final round = deriveRoomRound(
      events: _events,
      members: _room.members,
      driverStatus: _driver,
    );
    final handles = [
      for (final m in _room.members) m.handle,
      'all',
      'everyone',
    ];
    final inline = _inlineCards();
    final status = _statusLine(s, round);
    final itemCount = transcript.length + inline.length;
    if (!_openAnchored && itemCount > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _anchorOnOpen());
    }
    return Scaffold(
      key: const ValueKey('room-screen'),
      appBar: _header(s),
      body: SafeArea(
        top: false,
        // The real height left (after app bar, safe area and IME) decides
        // what fits: in landscape with the keyboard open the round panel and
        // status line step aside so the composer never overflows.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final available = constraints.maxHeight;
            final roomy = available > 300;
            return Column(
              children: [
                if (round != null && _roundNeedsPanel(round) && roomy)
                  RoomRoundPanel(
                    round: round,
                    now: _now,
                    profileFor: widget.profileFor,
                    avatarCache: widget.avatarCache,
                    onStopAll: widget.capabilities.canStop && !_stopping
                        ? () => unawaited(_stop())
                        : null,
                    onRetry: widget.capabilities.canRetry
                        ? (row) {
                            final task = row.taskId;
                            if (task != null) unawaited(_retry(task));
                          }
                        : null,
                  ),
                if (status.isNotEmpty && !(round?.active ?? false) && roomy)
                  InkWell(
                    key: const ValueKey('room-status-line'),
                    onTap: () => unawaited(_openActivity()),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 12, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              status,
                              key: const ValueKey('room-status-text'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 16,
                            color: colors.textSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: itemCount == 0
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
                      : KeyedSubtree(
                          key: _transcriptKey,
                          child: ListView.builder(
                            key: const ValueKey('room-transcript'),
                            controller: _transcriptScroll,
                            reverse: true,
                            padding: const EdgeInsets.only(bottom: 12, top: 8),
                            itemCount: itemCount,
                            itemBuilder: (context, index) {
                              if (index < inline.length) {
                                return inline[inline.length - 1 - index];
                              }
                              final entry =
                                  transcript[transcript.length -
                                      1 -
                                      (index - inline.length)];
                              return _entry(entry, s, handles);
                            },
                          ),
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
                    child: _composerArea(s),
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
  final VoidCallback onReply;

  const _RoomThreadPage({
    required this.messages,
    required this.members,
    required this.profileFor,
    required this.avatarCache,
    required this.attachmentActions,
    required this.canReply,
    required this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final entries = buildRoomTranscript(
      events: messages,
      members: members,
    ).whereType<RoomMessageEntry>().toList();
    final handles = [for (final m in members) m.handle];
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
                  mentionHandles: handles,
                  attachmentActions: attachmentActions,
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
