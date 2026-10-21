// Pantalla "Ejecuciones": «Nueva tarea» abre un chat normal con el prompt como
// primer mensaje (como Desktop: session.create + prompt.submit, por el WS del
// Dashboard) y la lista muestra el histórico local de runs antiguos, solo
// lectura y sin red. Fuente del histórico: RunRegistry local (SharedPreferences).
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../navigation/chat_route.dart';
import '../services/connection_manager.dart';
import '../services/new_session_factory.dart';
import '../services/run_registry.dart';
import '../services/run_template_store.dart';
import '../design/hermes_design.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../theme/app_theme.dart';
import '../utils/relative_time.dart';
import '../widgets/accent_card.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/read_only.dart';
import '../widgets/run_template_composer.dart';
import 'chat_screen.dart' show ChatScreen;
import 'runs_screen.dart' show RunDetailScreen, runStatusColor, runStatusLabel;
import '../feedback/feedback_policy.dart';

class TaskCenterScreen extends StatefulWidget {
  final SavedConnection connection;
  final String profile;

  /// Lets a widget test receive the [ChatScreen] a new task opens without
  /// mounting the whole chat. Production leaves it null.
  @visibleForTesting
  final Widget Function(ChatScreen chat)? chatHost;

  const TaskCenterScreen({
    required this.connection,
    this.profile = 'default',
    this.chatHost,
    super.key,
  });

  @override
  State<TaskCenterScreen> createState() => _TaskCenterScreenState();
}

@visibleForTesting
String taskCenterRunOwnerKey(String profile, String runId) =>
    '${profile.trim().toLowerCase()}\u0000$runId';

class _TaskCenterScreenState extends State<TaskCenterScreen> {
  RunRegistry? _registry;
  RunTemplateStore? _templateStore;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final registry = await RunRegistry.load(prefs, widget.connection.id);
    final templateStore = await RunTemplateStore.load(prefs);
    if (!mounted) return;
    setState(() {
      _registry = registry;
      _templateStore = templateStore;
    });
  }

  // ─── Nueva tarea = chat normal ───────────────────────────────────────────────

  Future<void> _newRun() async {
    if (widget.connection.readOnly) {
      showReadOnlyNotice(context);
      return;
    }
    final store = _templateStore;
    if (store == null) return;
    // Composer con plantillas (predefinidas + propias). Devuelve el prompt, o
    // null si se cancela.
    final prompt = await showRunComposer(context, store);
    if (prompt == null || prompt.isEmpty || !mounted) return;
    openChatFromHome<void>(
      context,
      builder: (_) {
        final chat = ChatScreen(
          connection: widget.connection,
          session: NewSessionFactory().create(
            title: Strings.of(context).drawerNewChat,
          ),
          initialPrompt: prompt,
        );
        return widget.chatHost?.call(chat) ?? chat;
      },
    );
  }

  void _openDetail(RunRecord record) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            RunDetailScreen(connection: widget.connection, record: record),
      ),
    );
  }

  /// Elimina una ejecución del historial local (swipe). El run ya no vive en
  /// el servidor; esto solo limpia la lista del móvil.
  Future<void> _deleteRun(RunRecord record) async {
    await _registry?.remove(record.runId, profile: record.profile);
    if (!mounted) return;
    setState(() {});
    AppFeedback.of(
      context,
    ).notify(FeedbackKind.routine, Strings.of(context).runsDeleted);
  }

  /// Vacía toda la lista local de ejecuciones (con confirmación).
  Future<void> _clearAll() async {
    final registry = _registry;
    if (registry == null || registry.records.isEmpty) return;
    final s = Strings.of(context);
    final count = registry.records.length;
    final ok = await showHermesDialog<bool>(
      context: context,
      title: s.runsClearTitle,
      message: s.runsClearConfirm(count),
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: s.runsClear,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (ok != true) return;
    await registry.clear();
    if (!mounted) return;
    setState(() {});
    AppFeedback.of(context).notify(FeedbackKind.routine, s.runsCleared);
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final registry = _registry;

    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(
          s.drawerTaskCenter.toUpperCase(),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            letterSpacing: 1.5,
            color: colors.accentHover,
          ),
        ),
        actions: [
          // A new run starts from up here, not from a button over the list.
          if (!widget.connection.readOnly)
            IconButton(
              key: const ValueKey('runs-create'),
              icon: const Icon(Icons.add_rounded),
              tooltip: s.runsNewRun,
              onPressed: _newRun,
            ),
          if (registry != null && registry.records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined, size: 20),
              tooltip: s.runsClear,
              onPressed: _clearAll,
            ),
        ],
      ),
      body: registry == null
          ? const Center(child: TuiLoader())
          : _buildBody(registry, colors, s),
    );
  }

  Widget _buildBody(RunRegistry registry, HermesThemeColors colors, Strings s) {
    final records = registry.records;

    if (records.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.rocket_launch_outlined,
              size: 40,
              color: colors.textDisabled,
            ),
            const SizedBox(height: 14),
            Text(
              s.runsEmpty,
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              s.runsEmptySub,
              style: TextStyle(fontSize: 11, color: colors.textTertiary),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      clipBehavior: hermesUnderHeader,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 80),
      itemCount: records.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) return _HistoryHeader(title: s.runsHistoryHeader);
        final r = records[i - 1];
        final ownerKey = taskCenterRunOwnerKey(r.profile, r.runId);
        return Dismissible(
          key: ValueKey(ownerKey),
          direction: DismissDirection.endToStart,
          onDismissed: (_) => _deleteRun(r),
          background: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            alignment: Alignment.centerRight,
            decoration: BoxDecoration(
              color: colors.error.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.runsDelete,
                  style: TextStyle(
                    color: colors.error,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.delete_outline, color: colors.error, size: 18),
              ],
            ),
          ),
          child: _RunCard(record: r, onTap: () => _openDetail(r)),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _HistoryHeader extends StatelessWidget {
  final String title;
  const _HistoryHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 1.2,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

/// Un run antiguo, solo lectura. Sin servidor que lo siga, cualquier estado no
/// terminal se pinta como `expired` (el registro no se reescribe).
class _RunCard extends StatelessWidget {
  final RunRecord record;
  final VoidCallback onTap;

  const _RunCard({required this.record, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final status = record.isTerminal ? record.lastStatus : 'expired';

    return AccentCard(
      margin: const EdgeInsets.only(bottom: 7),
      background: colors.surface,
      borderColor: colors.divider,
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              HermesIconTile(
                status == 'failed'
                    ? Icons.error_outline
                    : Icons.rocket_launch_outlined,
                size: 34,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.prompt,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      relativeTime(record.createdAt),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              HermesPill(
                color: runStatusColor(status, colors),
                label: runStatusLabel(status, s),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
