import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../utils/enum_labels.dart';
import '../../main.dart';
import '../services/app_lock.dart';
import '../services/approval_activity.dart';
import '../services/approval_policy.dart';
import '../services/command_risk.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../utils/relative_time.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_ui.dart';
import 'lock_screen.dart';
import '../widgets/hermes_app_bar.dart';
import '../design/hermes_design.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;

/// Ajustes globales de permisos / aprobaciones (PRIORIDAD 2 de la fase de
/// permisos). Lee y escribe sobre el [ApprovalPolicyService] compartido, así
/// que afecta de verdad al comportamiento de las aprobaciones — no es una
/// pantalla muerta.
class PermissionsScreen extends StatefulWidget {
  final SavedConnection connection;
  const PermissionsScreen({required this.connection, super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  ApprovalPolicyService? _policy;
  AppLockService? _lock;
  ApprovalActivityLog? _activityLog;
  List<ApprovalActivityEntry> _activity = const [];

  @override
  void initState() {
    super.initState();
    _loadActivity();
  }

  Future<void> _loadActivity() async {
    final prefs = await SharedPreferences.getInstance();
    final log = ApprovalActivityLog(prefs);
    if (!mounted) return;
    setState(() {
      _activityLog = log;
      _activity = log.entries(widget.connection.id);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.findAncestorStateOfType<HermesAppState>();
    _policy ??= app?.approvalPolicy;
    _lock ??= app?.appLock;
  }

  Future<void> _selectMode(ApprovalMode mode) async {
    final policy = _policy;
    if (policy == null) return;

    // Activar YOLO global: confirmación fuerte + App Lock si está configurado.
    if (mode == ApprovalMode.yolo) {
      final lock = _lock;
      if (lock != null && lock.enabled) {
        final ok = await LockScreen.verify(
          context,
          lock,
          reason: Strings.of(context).permEnableYoloGlobal,
        );
        if (!ok || !mounted) return;
      }
      final confirmed = await _confirmYolo();
      if (!confirmed || !mounted) return;
    }

    await policy.setGlobalMode(mode);
    if (mounted) setState(() {});
  }

  Future<bool> _confirmYolo() async {
    final ok = await showHermesDialog<bool>(
      context: context,
      title: Strings.of(context).permEnableYoloQ,
      message: Strings.of(context).permYoloBody,
      actions: [
        HermesDialogAction(
          label: Strings.of(context).commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: Strings.of(context).permEnableYolo,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final policy = _policy;
    return Scaffold(
      appBar: HermesAppBar(title: Text(Strings.of(context).permTitle)),
      body: policy == null
          ? Center(child: TuiLoader())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                HermesSectionHeader(Strings.of(context).permDefaultMode),
                Text(
                  Strings.of(context).permDefaultModeNote,
                  style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
                ),
                const SizedBox(height: 10),
                ..._modeOptions.map(
                  (m) => _ModeCard(
                    mode: m,
                    selected: policy.globalMode == m,
                    onTap: () => _selectMode(m),
                  ),
                ),
                const SizedBox(height: 8),
                HermesSectionHeader(Strings.of(context).permOptions),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    Strings.of(context).permOptionsNote,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).hermes.textSecondary,
                    ),
                  ),
                ),
                _flag(
                  Strings.of(context).permAppLock,
                  Strings.of(context).permAppLockSub,
                  policy.requireLock,
                  policy.setRequireLock,
                ),
                _flag(
                  Strings.of(context).permConfirmAlways,
                  Strings.of(context).permConfirmAlwaysSub,
                  policy.confirmAlways,
                  policy.setConfirmAlways,
                ),
                _flag(
                  Strings.of(context).permConfirmHighRisk,
                  Strings.of(context).permConfirmHighRiskSub,
                  policy.confirmHighRisk,
                  policy.setConfirmHighRisk,
                ),
                _flag(
                  Strings.of(context).permRememberSession,
                  Strings.of(context).permRememberSessionSub,
                  policy.rememberSession,
                  policy.setRememberSession,
                ),
                _flag(
                  Strings.of(context).permAllowAlways,
                  Strings.of(context).permAllowAlwaysSub,
                  policy.allowAlways,
                  policy.setAllowAlways,
                ),
                const SizedBox(height: 8),
                HermesSectionHeader(Strings.of(context).permSavedPerms),
                _SavedRules(policy: policy, instanceId: widget.connection.id),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: HermesSectionHeader(
                        Strings.of(context).permActivity,
                      ),
                    ),
                    if (_activity.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          await _activityLog?.clear(widget.connection.id);
                          await _loadActivity();
                        },
                        child: Text(Strings.of(context).permClear),
                      ),
                  ],
                ),
                _ActivityList(entries: _activity),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  static const _modeOptions = [
    ApprovalMode.yolo,
    ApprovalMode.interactive,
    ApprovalMode.conservative,
    ApprovalMode.readOnly,
  ];

  Widget _flag(
    String title,
    String subtitle,
    bool value,
    Future<void> Function(bool) onChanged,
  ) {
    return HermesSwitchTile(
      contentPadding: EdgeInsets.zero,
      title: title,
      subtitle: subtitle,
      value: value,
      onChanged: (v) async {
        await onChanged(v);
        if (mounted) setState(() {});
      },
    );
  }
}

class _ModeCard extends StatelessWidget {
  final ApprovalMode mode;
  final bool selected;
  final VoidCallback onTap;

  const _ModeCard({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  ({IconData icon, Color color, String desc}) _meta(
    BuildContext context,
    HermesThemeColors c,
  ) => switch (mode) {
    ApprovalMode.yolo => (
      icon: Icons.bolt,
      color: c.error,
      desc: Strings.of(context).permModeYoloDesc,
    ),
    ApprovalMode.interactive => (
      icon: Icons.chat_bubble_outline,
      color: c.accent,
      desc: Strings.of(context).permModeAskDesc,
    ),
    ApprovalMode.conservative => (
      icon: Icons.shield_outlined,
      color: c.warning,
      desc: Strings.of(context).permModeConservativeDesc,
    ),
    ApprovalMode.readOnly => (
      icon: Icons.visibility_outlined,
      color: c.textSecondary,
      desc: Strings.of(context).permModeReadOnlyDesc,
    ),
    ApprovalMode.globalDefault => (
      icon: Icons.settings,
      color: c.textSecondary,
      desc: '',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final m = _meta(context, colors);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? m.color.withValues(alpha: 0.08) : colors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? m.color.withValues(alpha: 0.55)
                  : colors.divider,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(m.icon, color: m.color, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          approvalModeLabel(Strings.of(context), mode),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: colors.textPrimary,
                          ),
                        ),
                        if (mode == ApprovalMode.yolo) ...[
                          const SizedBox(width: 8),
                          HermesPill(
                            color: colors.error,
                            label: Strings.of(context).permRisk,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      m.desc,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.35,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selected ? m.color : colors.textDisabled,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedRules extends StatefulWidget {
  final ApprovalPolicyService policy;
  final String instanceId;

  const _SavedRules({required this.policy, required this.instanceId});

  @override
  State<_SavedRules> createState() => _SavedRulesState();
}

class _SavedRulesState extends State<_SavedRules> {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final rules = widget.policy.rulesFor(widget.instanceId);
    if (rules.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          Strings.of(context).permNoSaved,
          style: TextStyle(fontSize: 12.5, color: colors.textDisabled),
        ),
      );
    }
    return Column(
      children: rules.map((r) {
        final riskColor = switch (r.risk) {
          CommandRisk.low => colors.success,
          CommandRisk.medium => colors.warning,
          CommandRisk.high => colors.error,
        };
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            title: Text(
              r.description.isNotEmpty ? r.description : (r.patternKey ?? r.id),
              style: TextStyle(fontSize: 13.5, color: colors.textPrimary),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (r.command != null)
                  Text(
                    r.command!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    HermesPill(
                      color: riskColor,
                      label: commandRiskLabel(Strings.of(context), r.risk),
                    ),
                    const SizedBox(width: 6),
                    HermesPill(
                      color: colors.textSecondary,
                      label: r.scope.name,
                      showDot: false,
                    ),
                  ],
                ),
              ],
            ),
            trailing: IconButton(
              icon: Icon(Icons.delete_outline, color: colors.error),
              tooltip: Strings.of(context).permRevoke,
              onPressed: () async {
                await widget.policy.revokeRule(widget.instanceId, r.id);
                if (mounted) setState(() {});
              },
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _ActivityList extends StatelessWidget {
  final List<ApprovalActivityEntry> entries;
  const _ActivityList({required this.entries});

  ({IconData icon, Color color}) _meta(String kind, HermesThemeColors c) =>
      switch (kind) {
        'auto_approved' => (icon: Icons.bolt, color: c.error),
        'allowed_once' => (icon: Icons.check, color: c.success),
        'allowed_session' => (
          icon: Icons.check_circle_outline,
          color: c.success,
        ),
        'allowed_always' => (icon: Icons.verified_outlined, color: c.success),
        'denied' => (icon: Icons.block, color: c.error),
        'blocked' => (icon: Icons.lock_outline, color: c.textSecondary),
        'yolo_enabled' => (icon: Icons.bolt, color: c.error),
        'yolo_disabled' => (icon: Icons.bolt_outlined, color: c.textSecondary),
        _ => (icon: Icons.verified_user_outlined, color: c.accent),
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          Strings.of(context).permNoActivity,
          style: TextStyle(fontSize: 12.5, color: colors.textDisabled),
        ),
      );
    }
    return Column(
      children: entries.take(30).map((e) {
        final m = _meta(e.kind, colors);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(m.icon, size: 16, color: m.color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.summary,
                      style: TextStyle(fontSize: 13, color: colors.textPrimary),
                    ),
                    if (e.command != null)
                      Text(
                        e.command!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                relativeTime(e.ts),
                style: TextStyle(fontSize: 10.5, color: colors.textDisabled),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
