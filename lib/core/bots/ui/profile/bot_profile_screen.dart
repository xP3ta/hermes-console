import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../models/agent_profile.dart';
import '../../../models/desktop_model_catalog.dart';
import '../../../services/bot_profile_client.dart';
import '../../../design/hermes_design.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/hermes_app_bar.dart';
import '../../../widgets/hermes_notice.dart';
import '../../../widgets/mission_profile_avatar.dart';
import '../roster/living_bot_face.dart';

/// One line of the profile's **Now** block.
final class BotNowItem {
  final String label;
  final String? detail;
  final bool attention;

  /// Stop action, present only where the server allows it (hosted room
  /// `groups.stop`, or the bot's own live chat `session.interrupt`).
  final Future<void> Function()? onStop;

  const BotNowItem({
    required this.label,
    this.detail,
    this.attention = false,
    this.onStop,
  });
}

/// Secondary action in the profile's overflow (duplicate, delete, …).
final class BotProfileAction {
  final Key key;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const BotProfileAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

/// Live data of the profile, recomputed on every roster refresh.
final class BotProfileData {
  final AgentProfile profile;
  final BotFaceSignal signal;
  final List<BotNowItem> now;
  final int roomCount;

  /// Kanban tasks assigned to the bot (open work).
  final int taskCount;

  const BotProfileData({
    required this.profile,
    required this.signal,
    this.now = const [],
    this.roomCount = 0,
    this.taskCount = 0,
  });
}

/// Bot profile (spec 070 S4): animated hero face, shortcuts (Chat · Rooms ·
/// Routines), **Now** with Stop where allowed, editable model & reasoning
/// (`model.options {profile}` → `profiles.configure`; reasoning via the
/// profile's `config.set reasoning`), and links to SOUL, skills, memory and
/// machine.
class BotProfileScreen extends StatefulWidget {
  final BotProfileData Function() data;

  /// Notifies when [data] may have changed (roster refresh).
  final Listenable? refresh;
  final MissionProfileAvatarCache? avatarCache;
  final BotModelGateway? modelGateway;
  final BotProfileGateway? profileGateway;
  final bool readOnly;
  final String machineLabel;
  final VoidCallback onChat;
  final VoidCallback? onRooms;
  final VoidCallback onRoutines;
  final VoidCallback onSoul;
  final VoidCallback onSkills;
  final VoidCallback onMemory;
  final VoidCallback? onTasks;
  final VoidCallback? onEditIdentity;

  /// Called after a successful model/reasoning change (roster reload).
  final VoidCallback? onChanged;
  final List<BotProfileAction> moreActions;

  const BotProfileScreen({
    super.key,
    required this.data,
    required this.onChat,
    required this.onRoutines,
    required this.onSoul,
    required this.onSkills,
    required this.onMemory,
    required this.machineLabel,
    this.refresh,
    this.avatarCache,
    this.modelGateway,
    this.profileGateway,
    this.readOnly = false,
    this.onRooms,
    this.onTasks,
    this.onEditIdentity,
    this.onChanged,
    this.moreActions = const [],
  });

  @override
  State<BotProfileScreen> createState() => _BotProfileScreenState();
}

class _BotProfileScreenState extends State<BotProfileScreen> {
  String? _reasoning;
  bool _reasoningLoaded = false;
  String? _modelOverride;
  String? _providerOverride;
  bool _busy = false;
  final Set<int> _stopping = {};
  final ScrollController _scroll = ScrollController();
  final GlobalKey _heroTitleKey = GlobalKey(debugLabel: 'bot-profile-name');

  /// True once the hero name has scrolled under the app bar: the app bar
  /// then shows the Bot's name instead of the generic title.
  bool _nameInAppBar = false;

  @override
  void initState() {
    super.initState();
    widget.refresh?.addListener(_onRefresh);
    _scroll.addListener(_onScroll);
    unawaited(_loadReasoning());
  }

  @override
  void dispose() {
    widget.refresh?.removeListener(_onRefresh);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  bool _checkScheduled = false;

  /// Scroll notifications fire before the list relays out, so the hero's
  /// geometry is only trustworthy after the frame: check it then.
  void _onScroll() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (mounted) _updateAppBarTitle();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _updateAppBarTitle() {
    final context = _heroTitleKey.currentContext;
    final box = context?.findRenderObject();
    final viewport = context == null
        ? null
        : Scrollable.maybeOf(context)?.context.findRenderObject();
    final bool hidden;
    if (box is RenderBox &&
        box.attached &&
        box.hasSize &&
        viewport is RenderBox &&
        viewport.hasSize) {
      // Hidden once the name has passed completely under the list's top edge.
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      hidden = bottom <= viewport.localToGlobal(Offset.zero).dy;
    } else {
      // Scrolled far enough that the hero is no longer built.
      hidden = _scroll.hasClients && _scroll.offset > 0;
    }
    if (hidden != _nameInAppBar) setState(() => _nameInAppBar = hidden);
  }

  void _onRefresh() {
    if (mounted) setState(() {});
  }

  Future<void> _loadReasoning() async {
    final gateway = widget.modelGateway;
    if (gateway == null) return;
    try {
      final value = await gateway.botReasoning(widget.data().profile.name);
      if (mounted) {
        setState(() {
          _reasoning = value;
          _reasoningLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _reasoningLoaded = true);
    }
  }

  void _notice(String text, {bool error = false}) {
    if (!mounted) return;
    HermesNotice.of(context).showSnackBar(
      SnackBar(content: Text(text)),
      kind: error ? HermesNoticeKind.error : HermesNoticeKind.success,
    );
  }

  Future<void> _pickModel(AgentProfile profile) async {
    final gateway = widget.modelGateway;
    final writer = widget.profileGateway;
    final s = Strings.of(context);
    if (gateway == null || writer == null || widget.readOnly || _busy) return;
    DesktopModelCatalog catalog;
    setState(() => _busy = true);
    try {
      catalog = await gateway.botModelOptions(profile.name);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      _notice(s.botProfileModelUnavailable, error: true);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final current = _modelOverride ?? profile.model;
    final groups = [
      for (final p in catalog.providers)
        if (p.authenticated != false && p.models.isNotEmpty)
          HermesModelGroup(slug: p.slug, name: p.name, models: p.models),
    ];
    if (groups.isEmpty) {
      _notice(s.botProfileModelUnavailable, error: true);
      return;
    }
    final choice = await showHermesModelPicker(
      context: context,
      groups: groups,
      current: HermesModelChoice(
        _providerOverride ?? profile.provider,
        current,
      ),
      surfaceKey: const ValueKey('bot-profile-model-picker'),
      keyPrefix: 'bot-profile-model',
    );
    if (choice == null || choice.isDefault || !mounted) return;
    final picked = (choice.provider, choice.model);
    await _applyModel(profile, picked.$1, picked.$2);
  }

  Future<void> _applyModel(
    AgentProfile profile,
    String provider,
    String model, {
    bool confirmed = false,
  }) async {
    final writer = widget.profileGateway!;
    final s = Strings.of(context);
    setState(() => _busy = true);
    try {
      final result = await writer.configureBotProfile(profile.name, {
        'model': model,
        'provider': provider,
        if (confirmed) 'confirm_expensive_model': true,
      });
      if (!mounted) return;
      if (result['confirm_required'] == true && !confirmed) {
        setState(() => _busy = false);
        final yes = await showHermesDialog<bool>(
          context: context,
          surfaceKey: const ValueKey('bot-profile-model-confirm'),
          title: s.botProfileModel,
          message: (result['confirm_message'] as String?) ?? s.botProfileModel,
          actions: [
            HermesDialogAction(
              label: s.botCancel,
              value: false,
              style: HermesDialogActionStyle.cancel,
            ),
            HermesDialogAction(
              key: const ValueKey('bot-profile-model-confirm-save'),
              label: s.botSave,
              value: true,
            ),
          ],
        );
        if (yes == true && mounted) {
          await _applyModel(profile, provider, model, confirmed: true);
        }
        return;
      }
      final applied = result['applied'];
      if (applied is! Map || applied['model'] != true) {
        throw StateError('model not applied');
      }
      setState(() {
        _modelOverride = model;
        _providerOverride = provider;
      });
      _notice(s.botProfileModelSaved);
      widget.onChanged?.call();
    } catch (_) {
      _notice(s.botProfileFailed, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickReasoning(AgentProfile profile) async {
    final gateway = widget.modelGateway;
    final s = Strings.of(context);
    if (gateway == null || widget.readOnly || _busy) return;
    final picked = await showHermesOptions<String>(
      context: context,
      surfaceKey: const ValueKey('bot-profile-reasoning-picker'),
      selected: _reasoning,
      options: [
        for (final effort in BotProfileClient.reasoningEfforts)
          HermesOption(
            key: ValueKey('bot-profile-reasoning-$effort'),
            value: effort,
            label: reasoningLabel(s, effort),
          ),
      ],
    );
    if (picked == null || !mounted || picked == _reasoning) return;
    setState(() => _busy = true);
    try {
      await gateway.setBotReasoning(profile.name, picked);
      if (!mounted) return;
      setState(() => _reasoning = picked);
      _notice(s.botProfileReasoningSaved);
      widget.onChanged?.call();
    } catch (_) {
      _notice(s.botProfileFailed, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  final GlobalKey _moreKey = GlobalKey(debugLabel: 'bot-profile-more');

  Future<void> _showMore() async {
    final action = await showHermesMenu<BotProfileAction>(
      context: context,
      surfaceKey: const ValueKey('bot-profile-more-surface'),
      anchorKey: _moreKey,
      actions: [
        for (final action in widget.moreActions)
          HermesAction(
            key: action.key,
            value: action,
            icon: action.icon,
            label: action.label,
          ),
      ],
    );
    action?.onTap();
  }

  Future<void> _stop(int index, BotNowItem item) async {
    final stop = item.onStop;
    if (stop == null || _stopping.contains(index)) return;
    setState(() => _stopping.add(index));
    try {
      await stop();
    } catch (_) {
      if (mounted) {
        _notice(Strings.of(context).botProfileStopFailed, error: true);
      }
    } finally {
      if (mounted) setState(() => _stopping.remove(index));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final data = widget.data();
    final profile = data.profile;
    final title = profile.botTitle ?? profile.name;
    final model = _modelOverride ?? profile.model;
    final provider = _providerOverride ?? profile.provider;
    final canEditModel =
        !widget.readOnly &&
        widget.modelGateway != null &&
        widget.profileGateway != null;
    return Scaffold(
      appBar: HermesAppBar(
        // The generic title until the hero name scrolls under the app bar,
        // then the Bot's own name (spec 070).
        title: Text(
          _nameInAppBar ? title : s.botProfileTitle,
          key: ValueKey(
            _nameInAppBar ? 'bot-profile-appbar-name' : 'bot-profile-appbar',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (widget.onEditIdentity != null)
            IconButton(
              key: const ValueKey('bot-profile-edit-identity'),
              tooltip: s.botProfileEditIdentity,
              icon: const Icon(Icons.edit_outlined),
              onPressed: widget.onEditIdentity,
            ),
          if (widget.moreActions.isNotEmpty)
            KeyedSubtree(
              key: _moreKey,
              child: IconButton(
                key: const ValueKey('bot-profile-more'),
                tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
                icon: const Icon(Icons.more_vert_rounded),
                onPressed: _showMore,
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const ValueKey('bot-profile'),
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(
            18,
            12,
            18,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            Center(
              child: LivingBotFace(
                key: const ValueKey('bot-profile-hero'),
                profileName: profile.name,
                profile: profile,
                avatarCache: widget.avatarCache,
                signal: data.signal,
                size: 104,
                semanticLabel: title,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              key: _heroTitleKey,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -.3,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              [
                '@${profile.name}',
                if (profile.description.trim().isNotEmpty)
                  profile.description.trim(),
              ].join(' · '),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                _Shortcut(
                  key: const ValueKey('bot-profile-chat'),
                  icon: Icons.chat_bubble_outline_rounded,
                  label: s.botProfileChat,
                  onTap: widget.onChat,
                  primary: true,
                ),
                const SizedBox(width: 10),
                _Shortcut(
                  key: const ValueKey('bot-profile-rooms'),
                  icon: Icons.forum_outlined,
                  label: s.botProfileRooms(data.roomCount),
                  onTap: widget.onRooms,
                ),
                const SizedBox(width: 10),
                _Shortcut(
                  key: const ValueKey('bot-profile-routines'),
                  icon: Icons.schedule_outlined,
                  label: s.botProfileRoutines,
                  onTap: widget.onRoutines,
                ),
              ],
            ),
            HermesSectionHeader(s.botProfileNow),
            HermesListGroup(
              key: const ValueKey('bot-profile-now'),
              children: data.now.isEmpty
                  ? [
                      HermesListRow(
                        icon: Icons.bedtime_outlined,
                        title: s.botProfileIdle,
                        muted: true,
                      ),
                    ]
                  : [
                      for (var i = 0; i < data.now.length; i++)
                        HermesListRow(
                          key: ValueKey('bot-profile-now-$i'),
                          icon: data.now[i].attention
                              ? Icons.front_hand_outlined
                              : Icons.bolt_rounded,
                          iconColor: data.now[i].attention
                              ? colors.warning
                              : colors.accentText,
                          title: data.now[i].label,
                          subtitle: data.now[i].detail,
                          trailing: data.now[i].onStop == null
                              ? null
                              : TextButton.icon(
                                  key: ValueKey('bot-profile-stop-$i'),
                                  onPressed: _stopping.contains(i)
                                      ? null
                                      : () => _stop(i, data.now[i]),
                                  icon: const Icon(
                                    Icons.stop_rounded,
                                    size: 18,
                                  ),
                                  label: Text(s.botProfileStop),
                                  style: TextButton.styleFrom(
                                    foregroundColor: colors.error,
                                    minimumSize: const Size(48, 48),
                                  ),
                                ),
                        ),
                    ],
            ),
            Column(
              key: const ValueKey('bot-profile-sections'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                HermesSectionHeader(s.botProfileModelSection),
                HermesListGroup(
                  children: [
                    HermesListRow(
                      key: const ValueKey('bot-profile-model'),
                      icon: Icons.memory_rounded,
                      title: s.botProfileModel,
                      value: [
                        if (provider.isNotEmpty) provider,
                        if (model.isNotEmpty) model,
                      ].join(' · '),
                      onTap: canEditModel ? () => _pickModel(profile) : null,
                    ),
                    HermesListRow(
                      key: const ValueKey('bot-profile-reasoning'),
                      icon: Icons.psychology_alt_outlined,
                      title: s.botProfileReasoning,
                      value: !_reasoningLoaded
                          ? '…'
                          : _reasoning == null
                          ? s.botProfileReasoningDefault
                          : reasoningLabel(s, _reasoning!),
                      onTap: canEditModel && _reasoningLoaded
                          ? () => _pickReasoning(profile)
                          : null,
                    ),
                  ],
                ),
                HermesSectionHeader(s.botProfileProfileSection),
                HermesListGroup(
                  children: [
                    HermesListRow(
                      key: const ValueKey('bot-profile-soul'),
                      icon: Icons.auto_awesome_outlined,
                      title: s.botProfileSoul,
                      onTap: widget.onSoul,
                    ),
                    HermesListRow(
                      key: const ValueKey('bot-profile-skills'),
                      icon: Icons.extension_outlined,
                      title: s.botProfileSkills,
                      value: profile.skillCount > 0
                          ? '${profile.skillCount}'
                          : null,
                      onTap: widget.onSkills,
                    ),
                    HermesListRow(
                      key: const ValueKey('bot-profile-memory'),
                      icon: Icons.bookmark_border_rounded,
                      title: s.botProfileMemory,
                      onTap: widget.onMemory,
                    ),
                    if (widget.onTasks != null)
                      HermesListRow(
                        key: const ValueKey('bot-profile-tasks'),
                        icon: Icons.view_kanban_outlined,
                        title: s.botProfileTasks,
                        value: data.taskCount > 0 ? '${data.taskCount}' : null,
                        onTap: widget.onTasks,
                      ),
                    HermesListRow(
                      key: const ValueKey('bot-profile-machine'),
                      icon: Icons.dns_outlined,
                      title: s.botProfileMachine,
                      value: widget.machineLabel,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String reasoningLabel(Strings s, String effort) => switch (effort) {
  'none' => s.reasoningEffortNone,
  'minimal' => s.reasoningEffortMinimal,
  'low' => s.reasoningEffortLow,
  'medium' => s.reasoningEffortMedium,
  'high' => s.reasoningEffortHigh,
  'xhigh' => s.reasoningEffortXhigh,
  'max' => s.reasoningEffortMax,
  'ultra' => s.reasoningEffortUltra,
  _ => effort,
};

class _Shortcut extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  const _Shortcut({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final fg = primary ? colors.accentText : colors.textPrimary;
    return Expanded(
      child: Material(
        color: primary
            ? colors.accent.withValues(alpha: .14)
            : colors.surfaceVariant.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
            child: Column(
              children: [
                Icon(icon, color: onTap == null ? colors.textDisabled : fg),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: onTap == null ? colors.textDisabled : fg,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
