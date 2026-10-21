// Ejecuciones antiguas — detalle de solo lectura de un run guardado en el
// RunRegistry local. Desde que «Nueva tarea» abre un chat normal, ya no se
// sigue, aprueba ni para ningún run: solo se muestran su prompt,
// estado, salida y error guardados.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../services/command_risk.dart';
import '../services/connection_manager.dart';
import '../services/run_registry.dart';
import '../design/hermes_design.dart' as d show HermesListRow;
import '../design/hermes_design.dart'
    show
        HermesListGroup,
        HermesSpace,
        HermesStatusText,
        HermesStatusTone,
        HermesTextBlock,
        HermesType;
import '../theme/app_theme.dart';
import '../utils/relative_time.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_app_bar.dart';
import '../feedback/feedback_policy.dart';

Color commandRiskColor(CommandRisk risk, HermesThemeColors colors) =>
    switch (risk) {
      CommandRisk.low => colors.textSecondary,
      CommandRisk.medium => colors.warning,
      CommandRisk.high => colors.error,
    };

String runStatusLabel(String status, Strings s) => switch (status) {
  'queued' => s.runsStatusQueued,
  'running' => s.runsStatusRunning,
  'waiting_for_approval' => s.runsStatusWaiting,
  'stopping' => s.runsStatusStopping,
  'completed' => s.runsStatusCompleted,
  'failed' => s.runsStatusFailed,
  'cancelled' => s.runsStatusCancelled,
  'expired' => s.runsStatusExpired,
  _ => status,
};

Color runStatusColor(String status, HermesThemeColors colors) =>
    switch (status) {
      'queued' || 'running' || 'stopping' => colors.accent,
      'waiting_for_approval' => colors.warning,
      'completed' => colors.success,
      'failed' => colors.error,
      'cancelled' || 'expired' => colors.textTertiary,
      _ => colors.textSecondary,
    };

/// Inline status tone of a run (spec 080: no boxed pills).
HermesStatusTone runStatusTone(String status) => switch (status) {
  'queued' || 'running' || 'stopping' => HermesStatusTone.active,
  'waiting_for_approval' => HermesStatusTone.warn,
  'completed' => HermesStatusTone.ok,
  'failed' => HermesStatusTone.error,
  _ => HermesStatusTone.neutral,
};

// ─────────────────────────────────────────────────────────────────────────────
// Detalle de ejecución — SSE en vivo + aprobaciones
// ─────────────────────────────────────────────────────────────────────────────

class RunDetailScreen extends StatefulWidget {
  final SavedConnection connection;
  final RunRecord record;
  final ApiClient? client;
  final String? initialApprovalId;
  final VoidCallback? onInitialApprovalReady;

  const RunDetailScreen({
    required this.connection,
    required this.record,
    this.client,
    this.initialApprovalId,
    this.onInitialApprovalReady,
    super.key,
  });

  @override
  State<RunDetailScreen> createState() => _RunDetailScreenState();
}

class _RunDetailScreenState extends State<RunDetailScreen> {
  @override
  void initState() {
    super.initState();
    // Un toque de notificación antigua con aprobación pendiente: ya no hay
    // servidor que seguir, así que se libera el toque en el primer frame.
    if (widget.initialApprovalId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onInitialApprovalReady?.call();
      });
    }
  }

  void _copyOutput() {
    final s = Strings.of(context);
    Clipboard.setData(ClipboardData(text: widget.record.output ?? ''));
    AppFeedback.of(context).notify(FeedbackKind.routine, s.runsReplyCopied);
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final record = widget.record;
    // Solo lectura: sin servidor que lo siga, lo no terminal es `expired`.
    final status = record.isTerminal ? record.lastStatus : 'expired';
    final output = (record.output ?? '').trim();
    final error = record.error;
    return Scaffold(
      appBar: HermesAppBar(
        centerTitle: false,
        title: Text(
          s.runsDetailTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListView(
        clipBehavior: hermesUnderHeader,
        key: const ValueKey('run-detail'),
        padding: const EdgeInsets.fromLTRB(
          HermesSpace.pageH,
          HermesSpace.pageTop,
          HermesSpace.pageH,
          HermesSpace.pageBottom,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 4),
            child: Text(
              record.prompt,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: HermesType.display.copyWith(
                fontSize: 19,
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: HermesSpace.x1),
          HermesStatusText(
            key: const ValueKey('run-detail-status'),
            label: runStatusLabel(status, s),
            tone: runStatusTone(status),
            meta: relativeTime(record.createdAt),
          ),
          const SizedBox(height: HermesSpace.x3),
          HermesListGroup(
            dividerIndent: HermesSpace.rowH,
            children: [
              d.HermesListRow(
                title: widget.connection.label,
                subtitle: record.sessionId,
                showChevron: false,
              ),
              d.HermesListRow(
                key: const ValueKey('run-detail-id'),
                title: record.runId,
                muted: true,
                trailing: Icon(
                  Icons.copy_rounded,
                  size: 18,
                  color: colors.textSecondary,
                ),
                semanticLabel: s.commonCopy,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: record.runId));
                  AppFeedback.of(
                    context,
                  ).notify(FeedbackKind.routine, s.runsRunIdCopied);
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          HermesInfoBanner(s.runsHistoryReadOnly, icon: Icons.history),
          if (output.isNotEmpty) ...[
            const SizedBox(height: 16),
            HermesSectionHeader(
              s.runsReplySection,
              trailing: Semantics(
                container: true,
                button: true,
                enabled: true,
                label: s.commonCopy,
                onTap: _copyOutput,
                child: ExcludeSemantics(
                  child: IconButton(
                    key: const ValueKey('runs-copy-reply'),
                    onPressed: _copyOutput,
                    tooltip: s.commonCopy,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    padding: EdgeInsets.zero,
                    focusColor: colors.textSecondary.withValues(alpha: 0.12),
                    icon: Icon(
                      Icons.content_copy_outlined,
                      size: 14,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            HermesTextBlock(
              key: const ValueKey('run-detail-reply'),
              text: output,
              collapsedLines: 12,
              openTitle: s.runsReplySection,
            ),
          ],
          if (error != null && error.isNotEmpty) ...[
            const SizedBox(height: 14),
            HermesInfoBanner(
              s.runsError(error),
              icon: Icons.error_outline,
              tone: colors.error,
            ),
          ],
        ],
      ),
    );
  }
}
