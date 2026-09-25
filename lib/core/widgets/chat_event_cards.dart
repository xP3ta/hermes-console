import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../companion/state/companion_controller.dart';
import '../models/activity_snapshot.dart';
import '../models/agent_task_list.dart';
import '../services/approval_policy.dart';
import '../services/command_risk.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../theme/component_profile.dart';
import 'activity_sections.dart';
import 'agent_task_widgets.dart';
import 'hermes_premium_ui.dart';
import 'hermes_spark_mascot.dart';
import 'hermes_pill.dart';

/// Clasificación y renderizado de eventos técnicos del chat.
///
/// PRIORIDAD 2/3 de la fase de corrección crítica: los eventos internos de
/// run/tool/approval NUNCA deben renderizarse como texto bruto (JSON) en el
/// timeline del chat. Aquí se clasifica un mensaje del historial del servidor
/// y se decide si es texto conversacional o un payload interno que debe ir a
/// una tarjeta estructurada (ToolEventCard / ApprovalRequestCard /
/// CommandPreviewCard).

enum ChatEventKind { text, toolEvent, approval }

/// Resultado de clasificar un mensaje del historial.
class ChatEventInfo {
  final ChatEventKind kind;
  String? get command => null;
  String? get description => null;
  String? get output => null;
  int? get exitCode => null;
  final String? status;
  String? get runId => null;
  String? get patternKey => null;
  final bool approvalPending;

  /// Texto a renderizar cuando [kind] == text (markdown normal).
  final String text;

  const ChatEventInfo._({
    required this.kind,
    required this.text,
    this.status,
    this.approvalPending = false,
  });

  static const _internalKeys = {
    'command',
    'approval_pending',
    'pattern_key',
    'exit_code',
    'tool_call_id',
  };

  static const _toolRoles = {
    'tool',
    'tool_result',
    'tool_use',
    'function',
    'function_call',
    'tool_call',
  };

  // Los resultados de herramientas pueden contener megabytes de salida. La
  // detección conserva las cinco frases históricas y su semántica sin distinguir
  // mayúsculas, pero evita materializar una copia minúscula de cada payload.
  static final RegExp _approvalMarkerRe = RegExp(
    r'asking the user for approval'
    r'|approval is one-shot'
    r'|pending_approval'
    r'|awaiting_approval'
    r'|waiting_for_approval',
    caseSensitive: false,
  );

  static bool _isApprovalToolResult(String content) =>
      _approvalMarkerRe.hasMatch(content);

  /// Clasifica un mensaje `{role, content, ...}` del historial del servidor.
  ///
  /// Heurística conservadora para no romper respuestas normales del asistente:
  /// solo se trata como payload interno si el content ENTERO parsea como objeto
  /// JSON con al menos una clave interna conocida, o si el rol es de tipo tool.
  factory ChatEventInfo.classify(Map<String, dynamic> msg) {
    final role = (msg['role'] ?? '').toString().toLowerCase();
    final rawContent = msg['content'];
    final textContent = rawContent is String ? rawContent : '';
    if (role != 'user' && role != 'assistant' && !_toolRoles.contains(role)) {
      return const ChatEventInfo._(kind: ChatEventKind.text, text: '');
    }

    // ── Caso 1: el asistente INVOCA una herramienta. ──────────────────────
    // El agente Hermes manda content:"" y la llamada en tool_calls[].function
    // (name + arguments, este último un string JSON con \n escapados). Solo lo
    // tratamos como tarjeta de llamada cuando NO hay prosa: si el assistant
    // mezcla texto + tool_calls, mostramos el texto (el resultado llegará luego
    // como mensaje role=tool).
    final toolCalls = msg['tool_calls'];
    if (toolCalls is List &&
        toolCalls.isNotEmpty &&
        textContent.trim().isEmpty) {
      return const ChatEventInfo._(
        kind: ChatEventKind.toolEvent,
        text: '',
        status: 'llamada',
      );
    }

    // ── Caso 2: resultado de una herramienta (role=tool/...). ─────────────
    // El content puede ser JSON puro, JSON + "\n\n[Tool loop warning: …]" o
    // texto plano. La señal de aprobación viene EMBEBIDA en el string de error.
    if (_toolRoles.contains(role)) {
      final isApproval = _isApprovalToolResult(textContent);

      if (isApproval) {
        return const ChatEventInfo._(
          kind: ChatEventKind.approval,
          text: '',
          status: 'pending_approval',
          approvalPending: true,
        );
      }
      return const ChatEventInfo._(
        kind: ChatEventKind.toolEvent,
        text: '',
        status: 'completado',
      );
    }

    // ── Caso 3: payload JSON con claves internas (compat. formato antiguo). ─
    Map<String, dynamic>? payload;
    if (rawContent is Map<String, dynamic>) {
      payload = rawContent;
    } else if (rawContent is String) {
      payload = _tryParseLeadingJson(rawContent);
    }

    final hasInternal =
        payload != null && payload.keys.any(_internalKeys.contains);

    if (payload == null || !hasInternal) {
      // Mensaje conversacional normal (incluye bloques de código markdown).
      return ChatEventInfo._(kind: ChatEventKind.text, text: textContent);
    }

    final status = (payload['status'] ?? msg['status'])?.toString();

    final approvalPending =
        payload['approval_pending'] == true ||
        status == 'pending_approval' ||
        status == 'awaiting_approval' ||
        status == 'waiting_for_approval';

    final kind = approvalPending
        ? ChatEventKind.approval
        : ChatEventKind.toolEvent;

    return ChatEventInfo._(
      kind: kind,
      text: '',
      status: approvalPending ? 'pending_approval' : 'completado',
      approvalPending: approvalPending,
    );
  }

  /// Parsea el PRIMER objeto JSON balanceado al inicio de [s], tolerando texto
  /// extra después (p.ej. `{...}\n\n[Tool loop warning: …]`). Devuelve null si
  /// no empieza por un objeto JSON válido.
  static Map<String, dynamic>? _tryParseLeadingJson(String s) {
    final t = s.trimLeft();
    if (!t.startsWith('{')) return null;
    int depth = 0;
    bool inStr = false;
    bool esc = false;
    for (int i = 0; i < t.length; i++) {
      final c = t[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (c == '\\') {
          esc = true;
        } else if (c == '"') {
          inStr = false;
        }
      } else if (c == '"') {
        inStr = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) {
          try {
            final d = jsonDecode(t.substring(0, i + 1));
            return d is Map<String, dynamic> ? d : null;
          } catch (error) {
            debugPrint(
              '[chat-cards] malformed legacy tool envelope '
              '(${error.runtimeType})',
            );
            return null;
          }
        }
      }
    }
    return null;
  }
}

/// Color asociado al nivel de riesgo de un comando.
Color commandRiskColor(CommandRisk risk, HermesThemeColors colors) =>
    switch (risk) {
      CommandRisk.low => colors.success,
      CommandRisk.medium => colors.warning,
      CommandRisk.high => colors.error,
    };

// ─────────────────────────────────────────────────────────────────────────────
// CommandPreviewCard — comando en monoespaciado, colapsado si es largo, copiar
// ─────────────────────────────────────────────────────────────────────────────

class CommandPreviewCard extends StatefulWidget {
  final String command;

  /// Umbral para colapsar por defecto (caracteres o saltos de línea).
  final int collapseThreshold;

  const CommandPreviewCard({
    required this.command,
    this.collapseThreshold = 160,
    super.key,
  });

  @override
  State<CommandPreviewCard> createState() => _CommandPreviewCardState();
}

class _CommandPreviewCardState extends State<CommandPreviewCard> {
  bool _expanded = false;
  bool _copied = false;

  bool get _isLong =>
      widget.command.length > widget.collapseThreshold ||
      '\n'.allMatches(widget.command).length > 2;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.command));
    HapticFeedback.selectionClick();
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final risk = assessCommandRisk(widget.command);
    final riskColor = commandRiskColor(risk, colors);
    final collapsed = _isLong && !_expanded;
    final display = collapsed
        ? '${widget.command.substring(0, widget.collapseThreshold).trimRight()}…'
        : widget.command;

    return Container(
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: riskColor.withValues(alpha: 0.30)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.terminal, size: 13, color: riskColor),
              const SizedBox(width: 6),
              HermesPill(color: riskColor, label: risk.label, showDot: false),
              const Spacer(),
              _IconAction(
                icon: _copied ? Icons.check : Icons.content_copy,
                color: _copied ? colors.accent : colors.textSecondary,
                tooltip: s.cevCopyTooltip,
                onTap: _copy,
              ),
            ],
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            // Text (no SelectableText): SelectableText registra un
            // SelectionRegistrarScope que al desmontarse durante el streaming /
            // transiciones revienta con "_dependents.isEmpty". Mismo motivo por
            // el que el chat usa MarkdownBody con selectable:false.
            child: Text(
              display,
              style: TextStyle(
                // Monoespaciado: un comando se lee como en una terminal.
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.4,
                color: colors.textPrimary,
              ),
            ),
          ),
          if (_isLong) ...[
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                _expanded ? s.cevHide : s.cevShowFull,
                style: TextStyle(fontSize: 11, color: colors.accent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ToolEventCard — salida de herramienta colapsada (P3: no JSON bruto)
// ─────────────────────────────────────────────────────────────────────────────

class ToolEventCard extends StatefulWidget {
  final ChatEventInfo info;

  const ToolEventCard({required this.info, super.key});

  @override
  State<ToolEventCard> createState() => _ToolEventCardState();
}

class _ToolEventCardState extends State<ToolEventCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final info = widget.info;
    final exit = info.exitCode;
    final ok = exit == null || exit == 0;
    final stateColor = ok ? colors.success : colors.error;
    final isCall = info.status == 'llamada';
    final summary = exit != null
        ? (ok ? s.cevExitOk : s.cevExitFailed(exit))
        : (info.status ?? s.cevStatusDone);
    // Nombre de la herramienta (write_file, execute_code…) si el servidor lo da.
    final toolLabel = (info.description != null && info.description!.isNotEmpty)
        ? info.description!
        : s.cevToolFallback;

    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 40, top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: [
                  Icon(
                    isCall
                        ? Icons.arrow_outward_rounded
                        : Icons.build_circle_outlined,
                    size: 15,
                    color: stateColor,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      toolLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    summary,
                    style: TextStyle(
                      color: stateColor,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: Icon(
                      Icons.expand_more,
                      size: 16,
                      color: colors.textDisabled,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 9),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (info.command != null)
                          CommandPreviewCard(command: info.command!),
                        if (info.output != null) ...[
                          const SizedBox(height: 8),
                          _OutputBlock(output: info.output!),
                        ],
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _OutputBlock extends StatelessWidget {
  final String output;
  const _OutputBlock({required this.output});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final trimmed = output.length > 2000
        ? '${output.substring(0, 2000)}\n…(salida truncada)'
        : output;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
      ),
      padding: const EdgeInsets.all(10),
      child: SingleChildScrollView(
        // Text, no SelectableText: evita el crash _dependents.isEmpty al
        // desmontar el SelectionRegistrarScope durante streaming/transiciones.
        child: Text(
          trimmed,
          style: TextStyle(
            // Monoespaciado: la salida de herramienta/logs mantiene columnas.
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.4,
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ToolActivityGroup — TODA la actividad de un turno (llamadas, resultados,
// aprobaciones) en UN solo desplegable colapsado. Sustituye a la pila de
// tarjetas sueltas: el chat queda limpio y el detalle vive bajo demanda.
// ─────────────────────────────────────────────────────────────────────────────

class ToolActivityGroup extends StatefulWidget {
  final List<ChatEventInfo> events;

  const ToolActivityGroup({required this.events, super.key});

  @override
  State<ToolActivityGroup> createState() => _ToolActivityGroupState();
}

class _ToolActivityGroupState extends State<ToolActivityGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final events = widget.events;
    final n = events.length;
    final hasApproval = events.any((e) => e.kind == ChatEventKind.approval);
    final anyFailed = events.any((e) => e.exitCode != null && e.exitCode != 0);
    // Un fallo acompañado de algún paso correcto = recuperado → ámbar, no rojo.
    // Rojo solo si todo lo ejecutado falló (error real, no ruido interno).
    final anyOk = events.any((e) => e.exitCode == 0);
    final accent = hasApproval
        ? colors.warning
        : (anyFailed
              ? (anyOk ? colors.warning : colors.error)
              : colors.textSecondary);

    // Resumen de herramientas usadas (nombres únicos, máx 3) para el subtítulo.
    final names = <String>[];
    for (final e in events) {
      final d = e.description;
      if (d != null && d.isNotEmpty && !names.contains(d)) names.add(d);
    }
    final namesLabel = names.take(3).join(', ') + (names.length > 3 ? '…' : '');

    // Subtítulo colapsado: nombres de herramientas o "actividad" al expandir.
    final s = Strings.of(context);
    final headLabel = _expanded
        ? s.cevActivity
        : (namesLabel.isNotEmpty ? namesLabel : s.cevActivity);

    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 40, top: 2, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Línea fina, sin tarjeta: casi un separador. El detalle vive bajo
          // demanda al expandir.
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
              child: Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 14, color: accent),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      headLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.textDisabled,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.cevStepCount(n),
                    style: TextStyle(
                      fontSize: 10.5,
                      color: colors.textDisabled,
                    ),
                  ),
                  if (hasApproval) ...[
                    const SizedBox(width: 7),
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 12,
                      color: colors.warning,
                    ),
                  ],
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: Icon(
                      Icons.expand_more,
                      size: 15,
                      color: colors.textDisabled,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(8, 3, 0, 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [for (final e in events) _ToolStep(info: e)],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// Un paso dentro de [ToolActivityGroup]: nombre de la herramienta + estado y,
/// bajo demanda, el comando/código y la salida. Compacto y sin SelectableText.
class _ToolStep extends StatefulWidget {
  final ChatEventInfo info;
  const _ToolStep({required this.info});

  @override
  State<_ToolStep> createState() => _ToolStepState();
}

class _ToolStepState extends State<_ToolStep> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final info = widget.info;
    final isApproval = info.kind == ChatEventKind.approval;
    final exit = info.exitCode;
    final failed = exit != null && exit != 0;
    final color = isApproval
        ? colors.warning
        : (failed ? colors.error : colors.success);

    final String label;
    if (isApproval) {
      label = s.cevStatusApproval;
    } else if (info.status == 'llamada') {
      label = s.cevStatusCall;
    } else if (exit != null) {
      label = failed ? 'exit $exit' : 'ok';
    } else {
      label = s.cevStatusDone;
    }

    final name = (info.description != null && info.description!.isNotEmpty)
        ? info.description!
        : s.cevToolFallback;
    final hasDetail =
        (info.command != null && info.command!.isNotEmpty) ||
        (info.output != null && info.output!.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: hasDetail ? () => setState(() => _open = !_open) : null,
            child: Row(
              children: [
                Icon(
                  isApproval
                      ? Icons.verified_user_outlined
                      : (info.status == 'llamada'
                            ? Icons.arrow_outward_rounded
                            : Icons.check_circle_outline),
                  size: 13,
                  color: color,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                HermesPill(color: color, label: label, showDot: false),
                if (hasDetail) ...[
                  const Spacer(),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.expand_more,
                      size: 14,
                      color: colors.textDisabled,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_open && hasDetail) ...[
            const SizedBox(height: 6),
            if (info.command != null && info.command!.isNotEmpty)
              CommandPreviewCard(command: info.command!),
            if (info.output != null && info.output!.isNotEmpty) ...[
              const SizedBox(height: 6),
              _OutputBlock(output: info.output!),
            ],
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ApprovalCommandBox — el comando/código que pide permiso, en monoespaciado y
// con botón de copiar. Compartido por la tarjeta inline del chat y la de runs
// para que el usuario SIEMPRE pueda copiar el comando exacto en formato código.
// ─────────────────────────────────────────────────────────────────────────────

class ApprovalCommandBox extends StatefulWidget {
  final String command;

  /// Comando corto de una sola línea ⇒ scroll horizontal; multilínea ⇒ vertical.
  final bool oneLine;

  const ApprovalCommandBox({
    required this.command,
    required this.oneLine,
    super.key,
  });

  @override
  State<ApprovalCommandBox> createState() => _ApprovalCommandBoxState();
}

class _ApprovalCommandBoxState extends State<ApprovalCommandBox> {
  bool _copied = false;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.command));
    HapticFeedback.selectionClick();
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: colors.divider.withValues(alpha: 0.55)),
      ),
      padding: const EdgeInsets.fromLTRB(11, 7, 6, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Cabecera mínima: icono de terminal + copiar (a la derecha).
          Row(
            children: [
              Icon(Icons.terminal, size: 12, color: colors.textSecondary),
              const Spacer(),
              _IconAction(
                icon: _copied ? Icons.check : Icons.content_copy,
                color: _copied ? colors.accent : colors.textSecondary,
                tooltip: s.cevCopyTooltip,
                onTap: _copy,
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 132),
            child: SingleChildScrollView(
              scrollDirection: widget.oneLine ? Axis.horizontal : Axis.vertical,
              child: Text(
                widget.command,
                maxLines: widget.oneLine ? 1 : null,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  fontFamily: 'monospace',
                  color: colors.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ChatApprovalCard — aprobación inline en el chat (motor /v1/runs). Tarjeta
// limpia con el código a ejecutar y los 4 botones: permitir / denegar /
// esta sesión / siempre. Pensada para vivir encima de la barra de entrada.
// ─────────────────────────────────────────────────────────────────────────────

class ChatApprovalCard extends StatelessWidget {
  final Map<String, dynamic> approval;
  final bool busy;
  final void Function(String choice) onChoice;

  /// Mascota (companion) para el toque sutil del encabezado: tu asistente
  /// "esperando" tu decisión. Si es null o está apagada, cae a un icono.
  final CompanionController? companion;

  const ChatApprovalCard({
    required this.approval,
    required this.busy,
    required this.onChoice,
    this.companion,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final command = (approval['command'] ?? approval['code'] ?? '')
        .toString()
        .trim();
    final description = (approval['description'] ?? approval['tool'] ?? '')
        .toString()
        .trim();
    final risk = assessCommandRisk(command.isEmpty ? description : command);
    final riskColor = commandRiskColor(risk, colors);
    // Qué mostrar como "lo que se va a ejecutar": preferimos el comando/código;
    // si no hay, una etiqueta corta de la herramienta (nunca el volcado técnico
    // en inglés del servidor).
    final what = command.isNotEmpty ? command : description;
    final oneLine = !what.contains('\n') && what.length <= 80;
    final allowed = permittedApprovalChoices(approval);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Semantics(
        container: true,
        label: s.cevPermissionHeadline,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 20,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        s.cevPermissionHeadline,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: colors.textPrimary,
                        ),
                      ),
                      if (description.isNotEmpty && description != what) ...[
                        const SizedBox(height: 2),
                        Text(
                          description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  risk.label,
                  style: TextStyle(
                    color: riskColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (what.isNotEmpty) ...[
              const SizedBox(height: 11),
              ApprovalCommandBox(command: what, oneLine: oneLine),
            ],
            const SizedBox(height: 13),
            if (allowed.contains('once') || allowed.contains('deny'))
              Row(
                children: [
                  if (allowed.contains('once'))
                    Expanded(
                      child: _ApprovalChoice(
                        label: s.cevAllow,
                        icon: Icons.check_rounded,
                        color: colors.success,
                        busy: busy,
                        onTap: () => onChoice('once'),
                      ),
                    ),
                  if (allowed.contains('once') && allowed.contains('deny'))
                    const SizedBox(width: 9),
                  if (allowed.contains('deny'))
                    Expanded(
                      child: _ApprovalChoice(
                        label: s.cevDeny,
                        icon: Icons.close_rounded,
                        color: colors.error,
                        busy: busy,
                        onTap: () => onChoice('deny'),
                      ),
                    ),
                ],
              ),
            if (allowed.contains('session') || allowed.contains('always'))
              const SizedBox(height: 10),
            if (allowed.contains('session') || allowed.contains('always'))
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                runSpacing: 2,
                children: [
                  Text(
                    '${s.cevRemember}:',
                    style: TextStyle(fontSize: 11, color: colors.textDisabled),
                  ),
                  if (allowed.contains('session'))
                    _ScopeChip(
                      label: s.cevThisSession,
                      icon: Icons.repeat_rounded,
                      busy: busy,
                      semanticHint: s.cevRemember,
                      onTap: () => onChoice('session'),
                    ),
                  if (allowed.contains('always'))
                    _ScopeChip(
                      label: s.cevAlways,
                      icon: Icons.all_inclusive_rounded,
                      busy: busy,
                      semanticHint: s.cevRemember,
                      onTap: () => onChoice('always'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Acciones secundarias para ampliar el alcance de la aprobación.
class _ScopeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool busy;
  final String semanticHint;
  final VoidCallback onTap;

  const _ScopeChip({
    required this.label,
    required this.icon,
    required this.busy,
    required this.semanticHint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final onPressed = busy ? null : onTap;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      hint: semanticHint,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: TextButton.icon(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: colors.textSecondary,
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            textStyle: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
            shape: const StadiumBorder(),
            overlayColor: colors.textSecondary.withValues(alpha: 0.12),
          ),
          icon: Icon(icon, size: 13),
          label: Text(label),
        ),
      ),
    );
  }
}

/// Permitir/Denegar del mismo peso visual; solo cambia el tinte semántico.
class _ApprovalChoice extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool busy;

  final VoidCallback onTap;

  const _ApprovalChoice({
    required this.label,
    required this.icon,
    required this.color,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final buttonStyle =
        FilledButton.styleFrom(
          backgroundColor: color.withValues(alpha: 0.14),
          foregroundColor: color,
          minimumSize: const Size.fromHeight(componentMinimumTapTarget),
          shape: const StadiumBorder(),
        ).copyWith(
          overlayColor: WidgetStatePropertyAll(color.withValues(alpha: 0.12)),
        );
    return FilledButton.icon(
      onPressed: busy ? null : onTap,
      style: buttonStyle,
      icon: Icon(icon, size: 16),
      label: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ApprovalRequestCard — aprobación pendiente con resolución inline
// ─────────────────────────────────────────────────────────────────────────────
//
// El flujo /v1/runs/{id}/approval del Gateway soporta resolver una aprobación
// pendiente. Cuando el chat tiene el [ApiClient] de la instancia y la tarjeta
// llega con run_id + estado pendiente, se ofrecen botones Permitir/Denegar que
// llaman a resolveRunApproval y actualizan el estado local SIN esperar a que el
// servidor reenvíe un mensaje. Si no hay ApiClient (p. ej. rehidratación pura)
// se cae al enlace "Abrir en Ejecuciones". Nunca se renderiza el JSON crudo ni
// se finge un approve/deny que el backend no soporta.

class ApprovalRequestCard extends StatefulWidget {
  final ChatEventInfo info;

  /// Abrir el run asociado en Ejecuciones (si hay runId y sigue pendiente).
  final void Function(String runId)? onOpenInRuns;

  /// Cliente del Gateway de la instancia activa. Si está presente y hay runId,
  /// la tarjeta resuelve la aprobación inline (Permitir/Denegar).
  final ApiClient? apiClient;

  const ApprovalRequestCard({
    required this.info,
    this.onOpenInRuns,
    this.apiClient,
    super.key,
  });

  @override
  State<ApprovalRequestCard> createState() => _ApprovalRequestCardState();
}

class _ApprovalRequestCardState extends State<ApprovalRequestCard> {
  /// null = sin resolver inline; 'once' (permitido) | 'deny' (denegado).
  String? _resolvedChoice;
  bool _busy = false;
  String? _actionError;

  bool get _serverPending => widget.info.approvalPending;
  bool get _pending => _serverPending && _resolvedChoice == null;
  bool get _canResolveInline =>
      widget.apiClient != null && widget.info.runId != null;

  Future<void> _resolve(String choice) async {
    final api = widget.apiClient;
    final runId = widget.info.runId;
    if (api == null || runId == null || _busy) return;
    final s = Strings.of(context);
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await api.resolveRunApproval(runId, choice);
      if (!mounted) return;
      HapticFeedback.selectionClick();
      setState(() {
        _resolvedChoice = choice;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _actionError = s.cevSendError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final info = widget.info;

    // Color de acento según el estado efectivo (resuelto inline > servidor).
    final Color accent;
    if (_resolvedChoice != null) {
      accent = _resolvedChoice == 'deny' ? colors.error : colors.success;
    } else if (_pending) {
      accent = colors.warning;
    } else {
      accent = colors.textSecondary;
    }

    final s = Strings.of(context);
    final String title;
    final String pillLabel;
    if (_resolvedChoice != null) {
      title = s.cevApprovalResolved;
      pillLabel = _resolvedChoice == 'deny'
          ? s.cevApprovalDenied
          : s.cevApprovalGranted;
    } else if (_pending) {
      title = s.cevApprovalRequired;
      pillLabel = s.cevApprovalPending;
    } else {
      title = s.cevApprovalHistorical;
      pillLabel = info.status ?? s.cevApprovalDefaultStatus;
    }

    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 40, top: 6, bottom: 4),
      child: Semantics(
        container: true,
        label: title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.verified_user_outlined, size: 16, color: accent),
                const SizedBox(width: 7),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  pillLabel,
                  style: TextStyle(
                    color: accent,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (info.description != null) ...[
              const SizedBox(height: 7),
              Text(
                info.description!,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: colors.textSecondary,
                ),
              ),
            ],
            if (info.command != null) ...[
              const SizedBox(height: 9),
              CommandPreviewCard(command: info.command!),
            ],
            if (info.patternKey != null) ...[
              const SizedBox(height: 6),
              Text(
                s.cevPatternKey(info.patternKey!),
                style: TextStyle(fontSize: 10.5, color: colors.textDisabled),
              ),
            ],
            const SizedBox(height: 10),
            _buildAction(colors, accent),
            if (_actionError != null) ...[
              const SizedBox(height: 6),
              Text(
                _actionError!,
                style: TextStyle(fontSize: 11, color: colors.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAction(HermesThemeColors colors, Color accent) {
    final info = widget.info;
    final s = Strings.of(context);

    // Resuelta inline: chip de confirmación local.
    if (_resolvedChoice != null) {
      final denied = _resolvedChoice == 'deny';
      final color = denied ? colors.error : colors.success;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            denied ? Icons.block : Icons.check_circle,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 7),
          Text(
            denied ? s.cevApprovalDenied : s.cevApprovalGranted,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      );
    }

    // Pendiente + ApiClient + runId: botones de resolución inline.
    if (_pending && _canResolveInline) {
      return Row(
        children: [
          Expanded(
            child: _ApprovalButton(
              label: s.cevAllow,
              icon: Icons.check,
              color: colors.accent,
              busy: _busy,
              filled: true,
              onTap: () => _resolve('once'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ApprovalButton(
              label: s.cevDeny,
              icon: Icons.close,
              color: colors.error,
              busy: _busy,
              onTap: () => _resolve('deny'),
            ),
          ),
        ],
      );
    }

    // Pendiente sin ApiClient pero con runId: abrir en Ejecuciones.
    if (_pending && info.runId != null && widget.onOpenInRuns != null) {
      return TextButton.icon(
        onPressed: () => widget.onOpenInRuns!(info.runId!),
        style: TextButton.styleFrom(foregroundColor: accent),
        icon: const Icon(Icons.open_in_new, size: 14),
        label: Text(s.cevOpenInRuns, style: const TextStyle(fontSize: 12)),
      );
    }

    // Nada accionable: nota informativa.
    return Text(
      _pending ? s.cevResolveInRuns : s.cevResolvedRecord,
      style: TextStyle(
        fontSize: 11,
        fontStyle: FontStyle.italic,
        color: colors.textDisabled,
      ),
    );
  }
}

/// Botón de resolución de aprobación (Permitir verde / Denegar rojo).
class _ApprovalButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool busy;
  final bool filled;
  final VoidCallback onTap;

  const _ApprovalButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.busy,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final onFilled = color.computeLuminance() > 0.5
        ? const Color(0xFF0A0A0A)
        : Colors.white;
    final style = filled
        ? FilledButton.styleFrom(
            backgroundColor: color,
            foregroundColor: onFilled,
            minimumSize: const Size.fromHeight(44),
            shape: const StadiumBorder(),
          )
        : TextButton.styleFrom(
            foregroundColor: color,
            minimumSize: const Size.fromHeight(44),
            shape: const StadiumBorder(),
          );
    return filled
        ? FilledButton.icon(
            onPressed: busy ? null : onTap,
            style: style,
            icon: Icon(icon, size: 15),
            label: Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          )
        : TextButton.icon(
            onPressed: busy ? null : onTap,
            style: style,
            icon: Icon(icon, size: 15),
            label: Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ThinkingTraceCard — UNA tarjeta por respuesta/run con el progreso agregado
// ─────────────────────────────────────────────────────────────────────────────

enum ChatTraceEventKind { reasoning, tool, skill }

/// Un evento agregado del trace de pensamiento/herramientas.
class ChatTraceEvent {
  final String id;
  final String label;
  String status; // running | completed | finished | failed | error
  final String emoji;
  final ChatTraceEventKind kind;

  /// Vista previa REAL del argumento de la herramienta (query, ruta, comando…)
  /// tal como la mandó el agente en `tool.started`. Pertenece exclusivamente a
  /// la tarjeta técnica del chat: Modo Voz nunca la muestra ni la pronuncia
  /// porque puede contener rutas, comandos o secretos. Vacío si no viene.
  final String preview;

  /// Detalle SEGURO del paso (ejecutable, nombre de archivo, host…) y sus
  /// tiempos medidos, cuando el trace los trae. Alimentan las mismas filas
  /// «✓ terminal · date  0.7 s» del panel en vivo.
  final String? detail;
  final DateTime? startedAt;
  final Duration? duration;

  ChatTraceEvent({
    required this.id,
    required this.label,
    required this.status,
    this.emoji = '🔧',
    this.preview = '',
    this.kind = ChatTraceEventKind.tool,
    this.detail,
    this.startedAt,
    this.duration,
  });

  bool get isDone => status == 'completed' || status == 'finished';
  bool get isFailed => status == 'failed' || status == 'error';
}

/// Desenlace de un trace de herramientas, una vez clasificado el conjunto de
/// pasos. Separa "falló un paso pero el turno se recuperó" (ruido interno, no
/// accionable) de "el turno terminó en error" (sí accionable). Evita que un
/// `execute_code · failed` seguido de un `completed` pinte toda la tarjeta de
/// rojo como si la respuesta hubiera fallado.
enum TraceOutcome {
  /// El run sigue trabajando.
  working,

  /// El usuario detuvo el turno.
  stopped,

  /// Terminó sin ningún fallo.
  completed,

  /// Hubo algún fallo intermedio pero también pasos completados: el agente
  /// reintentó y siguió adelante. No es un error final.
  recovered,

  /// Terminó y solo hubo fallos (nada completado): error real y bloqueante.
  failed,
}

/// Clasifica el desenlace de un trace a partir de sus eventos y de si el run
/// sigue activo. Función pura para poder testearla sin construir widgets.
TraceOutcome traceOutcome({
  required List<ChatTraceEvent> events,
  required bool active,
  bool stopped = false,
}) {
  if (stopped) return TraceOutcome.stopped;
  if (active) return TraceOutcome.working;
  final anyFailed = events.any((e) => e.isFailed);
  if (!anyFailed) return TraceOutcome.completed;
  final anyDone = events.any((e) => e.isDone);
  // Falló algo: si además hay pasos completados, el turno se recuperó.
  return anyDone ? TraceOutcome.recovered : TraceOutcome.failed;
}

/// Tarjeta única y colapsable que agrega el progreso de herramientas de la
/// respuesta/run activo. Sustituye al apilado de líneas `terminal — done`
/// (PRIORIDAD 2): los eventos actualizan ESTA tarjeta, no crean mensajes.
class ThinkingTraceCard extends StatefulWidget {
  static const double statusIconSize = 17;
  static const double statusFontSize = 12;
  static const double statusLetterSpacing = 0.35;

  final List<ChatTraceEvent> events;

  /// true mientras el run/respuesta sigue trabajando (muestra pulso).
  final bool active;

  /// Texto de cabecera cuando está activo y aún sin herramientas (p.ej.
  /// "Conectando…", "Pensando…", "Ejecutando…").
  final String headline;

  /// Estado vivo del pipeline, usado para elegir el icono y su color.
  final HermesSparkMood? activeMood;

  /// El runtime está bloqueado esperando una aclaración o aprobación.
  final bool waitingForUser;

  /// El usuario interrumpió este turno.
  final bool stopped;

  final Duration? duration;

  /// El estado vivo del turno lo cuenta la pastilla de actividad sobre el
  /// compositor: mientras [active] la tarjeta no pinta NADA (ni fila de estado
  /// ni shimmer) y solo aparece, plegada, cuando el turno termina.
  final bool liveInPill;

  /// Coloca la línea de resumen (apagada, con un chevron minúsculo) y el bloque
  /// desplegable donde el llamador quiera: la cabecera del mensaje pone el
  /// resumen bajo el título y el detalle a todo ancho debajo. Con esto la tarjeta
  /// no pinta nada por su cuenta, ni siquiera en vivo («Trabajando…»).
  final Widget Function(BuildContext context, Widget summary, Widget details)?
  headerBuilder;

  const ThinkingTraceCard({
    required this.events,
    required this.active,
    this.headline = 'Pensando…',
    this.activeMood,
    this.waitingForUser = false,
    this.stopped = false,
    this.duration,
    this.liveInPill = false,
    this.headerBuilder,
    super.key,
  });

  @override
  State<ThinkingTraceCard> createState() => _ThinkingTraceCardState();
}

String _cleanTraceStatus(String value) {
  final trimmed = value.trim();
  var clean = trimmed;
  while (clean.endsWith('.') || clean.endsWith('…')) {
    clean = clean.substring(0, clean.length - 1).trimRight();
  }
  return clean.isEmpty ? trimmed : clean;
}

/// Transición vertical inspirada en fresh-lizard-20, pero gobernada por el
/// estado real del run. No cicla frases inventadas: cada cambio corresponde a
/// connecting / thinking / tools / streaming / completed / failed.
class _TraceStatusWord extends StatelessWidget {
  const _TraceStatusWord({
    required this.label,
    required this.color,
    required this.reduceMotion,
  });

  final String label;
  final Color color;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final cleanLabel = _cleanTraceStatus(label);
    final childKey = ValueKey<String>('trace-status-$cleanLabel');
    final text = Text(
      cleanLabel,
      key: childKey,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color,
        fontSize: ThinkingTraceCard.statusFontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: ThinkingTraceCard.statusLetterSpacing,
      ),
    );

    final content = reduceMotion
        ? Align(alignment: Alignment.centerLeft, child: text)
        : AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            reverseDuration: const Duration(milliseconds: 140),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) => Stack(
              alignment: Alignment.centerLeft,
              children: <Widget>[...previousChildren, ?currentChild],
            ),
            transitionBuilder: (child, animation) {
              final incoming = child.key == childKey;
              final slide = Tween<Offset>(
                begin: incoming
                    ? const Offset(0, 0.62)
                    : const Offset(0, -0.62),
                end: Offset.zero,
              ).animate(animation);
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(position: slide, child: child),
              );
            },
            child: text,
          );

    return SizedBox(
      key: const ValueKey('trace-status-viewport'),
      height: 26,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0, 0.18, 0.82, 1],
        ).createShader(bounds),
        child: ClipRect(child: content),
      ),
    );
  }
}

class _TraceStateIcon extends StatefulWidget {
  const _TraceStateIcon({
    required this.icon,
    required this.color,
    required this.animate,
  });

  final IconData icon;
  final Color color;
  final bool animate;

  @override
  State<_TraceStateIcon> createState() => _TraceStateIconState();
}

class _TraceStateIconState extends State<_TraceStateIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: 0.5,
  );
  late final Animation<double> _scale = Tween<double>(begin: 0.94, end: 1.04)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _TraceStateIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) _syncAnimation();
  }

  void _syncAnimation() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.animate && !reduceMotion) {
      _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 0.5;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      widget.icon,
      key: const ValueKey('thinking-trace-state-icon'),
      color: widget.color,
      size: ThinkingTraceCard.statusIconSize,
    );
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!widget.animate || reduceMotion) return icon;
    return ScaleTransition(scale: _scale, child: icon);
  }
}

/// Hermes Desktop's `formatElapsed` (components/chat/activity-timer.ts):
/// "12s" under a minute, "m:ss" from there.
String formatThoughtDuration(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 60) return '${seconds}s';
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _ThinkingTraceCardState extends State<ThinkingTraceCard> {
  /// null = expansión automática (expandido mientras hay una herramienta en
  /// curso, colapsado cuando todas terminan). Un toque del usuario fija un
  /// valor explícito que manda a partir de entonces.
  bool? _userExpanded;

  /// Desenlace del trace: distingue "falló un paso pero el turno se recuperó"
  /// (ruido interno, no accionable) de "el turno terminó en error" (accionable).
  TraceOutcome get _outcome => traceOutcome(
    events: widget.events,
    active: widget.active,
    stopped: widget.stopped,
  );

  /// Estado de expansión efectivo: colapsada por defecto (la línea de resumen
  /// ya informa del progreso en vivo); solo el toque del usuario la expande.
  /// U-01 (spec 028): el auto-expand/colapso durante la ejecución mareaba y
  /// violaba la regla del ThinkingCard (colapsado salvo petición explícita).
  bool get _expanded => _userExpanded ?? false;

  /// Pasos que el usuario debe ver: sin las herramientas puente de Hermes.
  List<ChatTraceEvent> get _visibleEvents => widget.events
      .where(
        (event) =>
            event.kind == ChatTraceEventKind.reasoning ||
            !isInternalActivityLabel(event.label),
      )
      .toList(growable: false);

  String get _summary {
    final s = Strings.of(context);
    if (widget.active) {
      if (widget.events.isEmpty) return widget.headline;
      final current = widget.events.lastWhere(
        (event) => !event.isDone && !event.isFailed,
        orElse: () => widget.events.last,
      );
      return switch (current.kind) {
        ChatTraceEventKind.reasoning => s.chatActivityThinking,
        ChatTraceEventKind.tool => s.chatActivityRunningTool,
        ChatTraceEventKind.skill => s.chatActivityRunningSkill,
      };
    }
    // Hermes Desktop has one label for a finished block, with or without
    // tools (components/assistant-ui/thread/message-parts.tsx): watched live
    // it reports the measured time ("Thought for 1:12", `formatElapsed`),
    // under a second "Thought briefly", and reopened from history — where no
    // time was measured — plain "Thought". Failed/recovered/stopped keep
    // their own outcome.
    switch (_outcome) {
      case TraceOutcome.stopped:
        return s.cevTraceStopped;
      case TraceOutcome.failed:
        return s.cevTraceFailed;
      case TraceOutcome.recovered:
        return s.cevTraceRecovered;
      case TraceOutcome.working:
      case TraceOutcome.completed:
        final duration = widget.duration;
        if (duration == null) return s.chatActivityThought;
        if (duration < const Duration(seconds: 1)) {
          return s.chatActivityThoughtBriefly;
        }
        return s.chatActivityThoughtForDuration(
          formatThoughtDuration(duration),
        );
    }
  }

  ({IconData icon, Color color, bool animate}) _indicatorSpec(
    HermesThemeColors colors,
  ) {
    if (!widget.active) {
      return switch (_outcome) {
        TraceOutcome.stopped => (
          icon: Icons.stop_circle,
          color: colors.textSecondary,
          animate: false,
        ),
        TraceOutcome.recovered => (
          icon: Icons.warning_amber_rounded,
          color: colors.warning,
          animate: false,
        ),
        TraceOutcome.failed => (
          icon: Icons.error_outline,
          color: colors.error,
          animate: false,
        ),
        TraceOutcome.working || TraceOutcome.completed => (
          icon: Icons.check_circle,
          color: colors.success,
          animate: false,
        ),
      };
    }
    if (widget.waitingForUser) {
      return (
        icon: Icons.help_outline_rounded,
        color: colors.textSecondary,
        animate: false,
      );
    }
    final mood = widget.activeMood ?? HermesSparkMood.thinking;
    if (mood == HermesSparkMood.offline) {
      return (
        icon: Icons.cloud_off_rounded,
        color: colors.warning,
        animate: false,
      );
    }
    if (widget.events.isEmpty) {
      return switch (mood) {
        HermesSparkMood.connecting || HermesSparkMood.waiting => (
          icon: Icons.cloud_queue_rounded,
          color: colors.accent,
          animate: false,
        ),
        HermesSparkMood.error => (
          icon: Icons.error_outline,
          color: colors.error,
          animate: false,
        ),
        HermesSparkMood.success => (
          icon: Icons.check_circle,
          color: colors.success,
          animate: false,
        ),
        _ => (
          icon: Icons.psychology_alt_rounded,
          color: colors.textSecondary,
          animate: true,
        ),
      };
    }
    final current = widget.events.lastWhere(
      (event) => !event.isDone && !event.isFailed,
      orElse: () => widget.events.last,
    );
    return switch (current.kind) {
      ChatTraceEventKind.reasoning => (
        icon: Icons.psychology_alt_rounded,
        color: colors.textSecondary,
        animate: true,
      ),
      ChatTraceEventKind.tool => (
        icon: Icons.terminal_rounded,
        color: colors.textSecondary,
        animate: false,
      ),
      ChatTraceEventKind.skill => (
        icon: Icons.auto_awesome_rounded,
        color: colors.textSecondary,
        animate: false,
      ),
    };
  }

  void _copyTrace() {
    final text = widget.events
        .map(
          (e) => e.preview.trim().isEmpty
              ? '${e.emoji} ${e.label} — ${e.status}'
              : '${e.emoji} ${e.label} — ${e.status}\n  ${e.preview.trim()}',
        )
        .join('\n');
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();
  }

  /// Lista de tareas del agente que pertenece a ESTE bloque de actividad (el
  /// del turno que escribió la última `todo_list`), o null.
  AgentTaskList? get _ownedTasks => AgentTaskScope.ownedBy(
    context,
    widget.events.map((event) => (id: event.id, label: event.label)),
  );

  Widget _buildTraceDetails(
    HermesThemeColors colors,
    AgentTaskList? tasks, {
    bool muted = false,
  }) {
    final s = Strings.of(context);
    final now = DateTime.now();
    final steps = _visibleEvents.reversed
        .map(
          (event) => ActivityStep(
            id: event.id,
            kind: switch (event.kind) {
              ChatTraceEventKind.reasoning => ActivityStepKind.reasoning,
              ChatTraceEventKind.skill => ActivityStepKind.skill,
              ChatTraceEventKind.tool => ActivityStepKind.tool,
            },
            label: event.label,
            status: event.isFailed
                ? ActivityStepStatus.failed
                : event.isDone
                ? ActivityStepStatus.done
                : ActivityStepStatus.running,
            detail: event.detail,
            startedAt: event.startedAt,
            duration: event.duration,
            text: event.preview.trim().isEmpty ? null : event.preview.trim(),
          ),
        )
        .toList(growable: false);
    return Padding(
      padding: EdgeInsets.only(left: muted ? 50 : 40, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tasks != null)
            ActivityTasksSection(
              tasks: tasks,
              dense: true,
              incomplete: !widget.active && tasks.hasOpen,
            ),
          if (steps.isNotEmpty)
            ActivityDoneSection(
              steps: steps,
              now: now,
              dense: true,
              muted: muted,
            ),
          const SizedBox(height: 6),
          Semantics(
            button: true,
            label: s.chatCopyTrace,
            onTap: _copyTrace,
            child: ExcludeSemantics(
              child: TextButton.icon(
                key: const ValueKey('thinking-trace-copy'),
                onPressed: _copyTrace,
                style: TextButton.styleFrom(
                  foregroundColor: colors.textDisabled,
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: const TextStyle(fontSize: 10.5),
                  shape: const StadiumBorder(),
                  overlayColor: colors.textSecondary.withValues(alpha: 0.12),
                ),
                icon: const Icon(Icons.content_copy, size: 12),
                label: Text(s.chatCopyTrace),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    // Una traza solo de herramientas puente no tiene nada que desplegar.
    final hasEvents = widget.active
        ? widget.events.isNotEmpty
        : _visibleEvents.isNotEmpty;
    final tasks = widget.events.isNotEmpty ? _ownedTasks : null;
    final indicator = _indicatorSpec(colors);

    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    final headerBuilder = widget.headerBuilder;
    if (headerBuilder != null) {
      final s = Strings.of(context);
      final muted = TextStyle(fontSize: 11.5, color: colors.textSecondary);
      if (widget.active) {
        // El estado vivo lo cuenta la pastilla de actividad; aquí, una palabra.
        return headerBuilder(
          context,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              s.liveHeaderWorking,
              key: const ValueKey('thinking-trace-live-in-pill'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
          const SizedBox.shrink(),
        );
      }
      final summary = Semantics(
        button: hasEvents,
        expanded: hasEvents ? _expanded : null,
        label: _summary,
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('thinking-trace-summary'),
          borderRadius: BorderRadius.circular(8),
          onTap: hasEvents
              ? () {
                  HapticFeedback.selectionClick();
                  setState(() => _userExpanded = !_expanded);
                }
              : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 30),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _cleanTraceStatus(_summary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ),
                if (hasEvents) ...[
                  const SizedBox(width: 2),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 160),
                    child: Icon(
                      Icons.expand_more,
                      size: 15,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
      final body = hasEvents && _expanded
          ? _buildTraceDetails(colors, tasks, muted: true)
          : const SizedBox.shrink();
      return headerBuilder(
        context,
        summary,
        reduceMotion
            ? body
            : AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: body,
              ),
      );
    }

    // El estado vivo lo cuenta la pastilla de actividad, no la burbuja.
    if (widget.active && widget.liveInPill) {
      return const SizedBox.shrink(
        key: ValueKey('thinking-trace-live-in-pill'),
      );
    }

    if (widget.active && !hasEvents) {
      return Padding(
        padding: const EdgeInsets.only(left: 12, right: 16, top: 3, bottom: 1),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380, minHeight: 48),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TraceStateIcon(
                  icon: indicator.icon,
                  color: indicator.color,
                  animate: indicator.animate,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: HermesShimmerText(
                    _cleanTraceStatus(widget.headline),
                    key: const ValueKey('thinking-shimmer'),
                    style: TextStyle(
                      color: indicator.color,
                      fontSize: ThinkingTraceCard.statusFontSize,
                      fontWeight: FontWeight.w700,
                      letterSpacing: ThinkingTraceCard.statusLetterSpacing,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 16, top: 8, bottom: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: hasEvents
                    ? () {
                        HapticFeedback.selectionClick();
                        setState(() => _userExpanded = !_expanded);
                      }
                    : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      _TraceStateIcon(
                        icon: indicator.icon,
                        color: indicator.color,
                        animate: indicator.animate,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: widget.active
                            ? HermesShimmerText(
                                _cleanTraceStatus(_summary),
                                key: ValueKey<String>(
                                  'trace-current-${_cleanTraceStatus(_summary)}',
                                ),
                                style: TextStyle(
                                  color: indicator.color,
                                  fontSize: ThinkingTraceCard.statusFontSize,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing:
                                      ThinkingTraceCard.statusLetterSpacing,
                                ),
                              )
                            : _TraceStatusWord(
                                label: _summary,
                                color: indicator.color,
                                reduceMotion: reduceMotion,
                              ),
                      ),
                      if (hasEvents) ...[
                        if (tasks != null) ...[
                          const SizedBox(width: 8),
                          AgentTaskChip(tasks: tasks),
                        ],
                        const SizedBox(width: 8),
                        AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 160),
                          child: Icon(
                            Icons.expand_more,
                            size: 18,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (hasEvents)
                if (reduceMotion)
                  _expanded
                      ? _buildTraceDetails(colors, tasks)
                      : const SizedBox.shrink()
                else
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    child: _expanded
                        ? _buildTraceDetails(colors, tasks)
                        : const SizedBox.shrink(),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  const _IconAction({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 14, color: color),
        ),
      ),
    );
  }
}
