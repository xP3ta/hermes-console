import 'package:flutter/material.dart';

import '../design/floating.dart' show HermesFloatingSurface;
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'hermes_ui.dart';

class ChatControlLabels {
  final String title;
  final String refresh;

  /// Desktop's «Artefactos»: the images, files and links of this
  /// conversation.
  final String content;
  final String? prompts;
  final String? showPinnedPrompt;
  final String? branch;
  final String details;
  final String cron;
  final String? recovery;

  /// Extensions of THIS conversation (the centre scoped to its runtime).
  final String? extensions;
  final String delete;
  final String readOnly;

  /// "Buscar en este chat": the in-chat find bar.
  final String? findInChat;

  /// «Nuevo chat» (Vistas v3: beside «Buscar» in the window's quick pill).
  final String? newChat;

  /// A Bot Chat's «Escritorio» (Vistas v3, D2): it continues one
  /// conversation, so the quick pill offers its screen in the place of
  /// «Nuevo chat».
  final String? desktop;

  /// The heading of the panels (the owner's final windows: «Paneles», in
  /// Ajustes, above the conversation's actions).
  final String? panels;

  /// What the panel showing now says after its name («abierto»).
  final String? panelOpen;

  /// «Subagentes · n»: reopens the subagents of this chat.
  final String? subagents;

  /// «Mostrar subagentes ocultos»: undoes the group's «Cerrar» here.
  final String? showHiddenSubagents;

  /// «Configurar voz», while a voice conversation runs in this chat (voz
  /// inline: its settings left the voice controls).
  final String? voiceSettings;

  const ChatControlLabels({
    required this.title,
    required this.refresh,
    required this.content,
    required this.details,
    required this.cron,
    required this.delete,
    required this.readOnly,
    this.recovery,
    this.extensions,
    this.prompts,
    this.showPinnedPrompt,
    this.branch,
    this.findInChat,
    this.newChat,
    this.desktop,
    this.panels,
    this.panelOpen,
    this.subagents,
    this.showHiddenSubagents,
    this.voiceSettings,
  });
}

/// The panels of the window, in their fixed order (the owner's final windows:
/// Terminal, Archivos, Git, Navegador).
enum ChatWorkspaceKind { terminal, files, git, browser, agents }

IconData chatWorkspaceIcon(ChatWorkspaceKind kind) => switch (kind) {
  ChatWorkspaceKind.terminal => Icons.terminal_rounded,
  ChatWorkspaceKind.files => Icons.folder_open_outlined,
  ChatWorkspaceKind.git => Icons.call_split_rounded,
  ChatWorkspaceKind.browser => Icons.language_rounded,
  ChatWorkspaceKind.agents => Icons.smart_toy_outlined,
};

/// One workspace pill (Terminal · Git · Navegador). Only an [available]
/// entry with an [onTap] is drawn, so a destination that does not exist yet
/// leaves no trace in the sheet.
class ChatWorkspaceEntry {
  const ChatWorkspaceEntry({
    required this.kind,
    required this.label,
    required this.onTap,
    this.available = true,
    this.open = false,
    this.badgeCount,
    this.badgeSemanticLabel,
  });

  final ChatWorkspaceKind kind;
  final String label;
  final VoidCallback? onTap;
  final bool available;

  /// It is the panel showing now: its row is marked «abierto».
  final bool open;

  /// A count on the row (Git: changed files); nothing when null or 0.
  final int? badgeCount;

  /// What a screen reader says for the badge («4 cambios») instead of the
  /// bare number.
  final String? badgeSemanticLabel;

  bool get shown => available && onTap != null;
}

/// The chat's «Ajustes» window (the owner's final windows, ventanas-final-png):
/// a list. On top, the conversation's name and, at its right, the pill of
/// two round buttons [🔍][+] (a Bot Chat: [🔍][Escritorio]). Then PANELES,
/// Terminal · Archivos · Git · Navegador, the one showing marked «abierto»;
/// then the conversation's actions, one row each; «Borrar conversación»
/// last, apart, in red. It only projects state and callbacks: no services,
/// no copy of Hermes' authoritative settings.
///
/// Model and permissions live in the status pill under the composer; «Ir a»,
/// Memory and Skills in the ≡ menu; how the screen is shared in «Vistas».
class ChatControlSheet extends StatelessWidget {
  final ChatControlLabels labels;
  final String conversationTitle;
  final bool readOnly;
  final bool showDetails;
  final bool showCron;

  /// Terminal, Archivos, Git and Navegador, in this order; unavailable
  /// ones are not drawn.
  final List<ChatWorkspaceEntry> workspace;
  final VoidCallback? onFindInChat;
  final VoidCallback? onNewChat;

  /// D2: a Bot Chat's screen, in the quick pill when there is no
  /// [onNewChat].
  final VoidCallback? onDesktop;
  final VoidCallback onRefresh;
  final VoidCallback onContent;
  final VoidCallback? onPrompts;

  /// Shows the pinned prompt again; null while it is not hidden here.
  final VoidCallback? onShowPinnedPrompt;

  /// Opens the chat's subagents (list and detail); null when it has none.
  final VoidCallback? onSubagents;

  /// Shows the subagents the person closed in this chat again; null while
  /// none of its agents is closed.
  final VoidCallback? onShowHiddenSubagents;
  final VoidCallback? onBranch;
  final VoidCallback? onDetails;
  final VoidCallback? onCron;
  final VoidCallback? onRecovery;
  final VoidCallback? onExtensions;
  final VoidCallback? onDelete;

  /// Opens the voice settings; null without a voice conversation here.
  final VoidCallback? onVoiceSettings;

  const ChatControlSheet({
    required this.labels,
    required this.conversationTitle,
    required this.onRefresh,
    required this.onContent,
    this.workspace = const [],
    this.onFindInChat,
    this.onNewChat,
    this.onDesktop,
    this.onDelete,
    this.onPrompts,
    this.onShowPinnedPrompt,
    this.onSubagents,
    this.onShowHiddenSubagents,
    this.onBranch,
    this.readOnly = false,
    this.showDetails = false,
    this.showCron = false,
    this.onDetails,
    this.onCron,
    this.onRecovery,
    this.onExtensions,
    this.onVoiceSettings,
    super.key,
  });

  /// The conversation's actions, in the mock's order; the conditional
  /// ones only when they exist.
  List<_RowData> get _actions => [
    // First while the voice is on: the one voice setting a conversation
    // reaches from the chat.
    if (labels.voiceSettings != null && onVoiceSettings != null)
      _RowData(
        id: 'voice-settings',
        icon: Icons.settings_voice_rounded,
        label: labels.voiceSettings!,
        onTap: onVoiceSettings,
      ),
    _RowData(
      id: 'refresh',
      icon: Icons.refresh_rounded,
      label: labels.refresh,
      onTap: onRefresh,
    ),
    // One entry, as Desktop's Artifacts view: images, files and links.
    _RowData(
      id: 'content',
      icon: Icons.view_in_ar_outlined,
      label: labels.content,
      onTap: onContent,
    ),
    if (labels.prompts != null && onPrompts != null)
      _RowData(
        id: 'prompts',
        icon: Icons.chat_bubble_outline_rounded,
        label: labels.prompts!,
        onTap: onPrompts,
      ),
    if (labels.showPinnedPrompt != null && onShowPinnedPrompt != null)
      _RowData(
        id: 'show-pinned-prompt',
        icon: Icons.vertical_align_top_rounded,
        label: labels.showPinnedPrompt!,
        onTap: onShowPinnedPrompt,
      ),
    if (labels.subagents != null && onSubagents != null)
      _RowData(
        id: 'subagents',
        icon: Icons.smart_toy_outlined,
        label: labels.subagents!,
        onTap: onSubagents,
      ),
    if (labels.showHiddenSubagents != null && onShowHiddenSubagents != null)
      _RowData(
        id: 'show-hidden-subagents',
        icon: Icons.visibility_outlined,
        label: labels.showHiddenSubagents!,
        onTap: onShowHiddenSubagents,
      ),
    if (labels.branch != null && onBranch != null)
      _RowData(
        id: 'branch',
        icon: Icons.call_split_rounded,
        label: labels.branch!,
        onTap: onBranch,
      ),
    if (showDetails && onDetails != null)
      _RowData(
        id: 'details',
        icon: Icons.info_outline,
        label: labels.details,
        onTap: onDetails,
      ),
    if (showCron && onCron != null)
      _RowData(
        id: 'cron',
        icon: Icons.schedule_outlined,
        label: labels.cron,
        onTap: onCron,
      ),
    if (labels.recovery != null && onRecovery != null)
      _RowData(
        id: 'recovery',
        icon: Icons.restore_page_outlined,
        label: labels.recovery!,
        onTap: onRecovery,
      ),
    if (labels.extensions != null && onExtensions != null)
      _RowData(
        id: 'extensions',
        icon: Icons.extension_outlined,
        label: labels.extensions!,
        onTap: onExtensions,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final panels = [
      for (final entry in workspace)
        if (entry.shown) entry,
    ];
    final find = labels.findInChat != null ? onFindInChat : null;
    final newChat = labels.newChat != null ? onNewChat : null;
    final desktop = labels.desktop != null ? onDesktop : null;
    final quick = find != null && (newChat != null || desktop != null);
    Widget divider() => Padding(
      padding: const EdgeInsets.symmetric(vertical: HermesSpace.x1),
      child: Divider(height: 1, thickness: 1, color: chrome.line),
    );

    return SafeArea(
      top: false,
      child: Semantics(
        // The window's name; its heading is the conversation's.
        label: labels.title,
        explicitChildNodes: true,
        child: ListView(
          key: const ValueKey('chat-control-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.all(HermesSpace.x3),
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(
                start: HermesSpace.x1,
                bottom: HermesSpace.x2,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Semantics(
                      key: const ValueKey('chat-control-header'),
                      container: true,
                      header: true,
                      child: Text(
                        conversationTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: HermesFloatingSurface.windowInk(
                            colors,
                            colors.textPrimary,
                          ),
                          fontSize: HermesType.titleSize,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  if (readOnly) ...[
                    const SizedBox(width: HermesSpace.x2),
                    HermesBadge(labels.readOnly, color: colors.warning),
                  ],
                  if (quick) ...[
                    const SizedBox(width: HermesSpace.x2),
                    _QuickPill(
                      findLabel: labels.findInChat!,
                      onFind: find,
                      second: newChat != null
                          ? (
                              key: const ValueKey('chat-control-new-chat'),
                              icon: Icons.add_rounded,
                              label: labels.newChat!,
                              onTap: newChat,
                            )
                          : (
                              key: const ValueKey('chat-control-desktop'),
                              icon: Icons.desktop_windows_outlined,
                              label: labels.desktop!,
                              onTap: desktop!,
                            ),
                    ),
                  ],
                ],
              ),
            ),
            // The panels first; «Vistas» only shares the screen.
            if (panels.isNotEmpty) ...[
              if (labels.panels case final heading?)
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: HermesSpace.x3,
                    bottom: HermesSpace.x1,
                  ),
                  child: Semantics(
                    header: true,
                    child: Text(
                      heading.toUpperCase(),
                      key: const ValueKey('chat-control-panels'),
                      style: TextStyle(
                        fontSize: HermesType.captionSize,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                        // REVIEW-Q9-VENT P2-2: readable on the window
                        // wherever it blurs.
                        color: HermesFloatingSurface.windowInk(
                          colors,
                          chrome.mutedInk,
                        ),
                      ),
                    ),
                  ),
                ),
              Column(
                key: const ValueKey('chat-control-workspace'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final entry in panels)
                    _SheetRow(
                      key: ValueKey(
                        'chat-control-workspace-${entry.kind.name}',
                      ),
                      icon: chatWorkspaceIcon(entry.kind),
                      label: entry.label,
                      onTap: entry.onTap,
                      selected: entry.open,
                      trailing: entry.open ? labels.panelOpen : null,
                      badgeCount: entry.badgeCount,
                      badgeSemanticLabel: entry.badgeSemanticLabel,
                    ),
                ],
              ),
              divider(),
            ],
            Column(
              key: const ValueKey('chat-control-actions'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!quick && find != null)
                  _SheetRow(
                    key: const ValueKey('chat-control-find'),
                    icon: Icons.search_rounded,
                    label: labels.findInChat!,
                    onTap: find,
                  ),
                for (final item in _actions)
                  _SheetRow(
                    key: ValueKey('chat-control-${item.id}'),
                    icon: item.icon,
                    label: item.label,
                    onTap: item.onTap,
                  ),
              ],
            ),
            if (onDelete != null) ...[
              divider(),
              _SheetRow(
                key: const ValueKey('chat-control-delete'),
                icon: Icons.delete_outline,
                label: labels.delete,
                color: colors.error,
                onTap: readOnly ? null : onDelete,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// «Buscar» and «Nuevo chat» (a Bot Chat: «Escritorio») in one pill
/// (ref-ventanas-2): two round icon buttons, each its own raised circle,
/// on 48 dp targets, the same height as every pill.
class _QuickPill extends StatelessWidget {
  const _QuickPill({
    required this.findLabel,
    required this.onFind,
    required this.second,
  });

  final String findLabel;
  final VoidCallback onFind;
  final ({Key key, IconData icon, String label, VoidCallback onTap}) second;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    // ref-ventanas-2: each action its own raised circle inside the pill,
    // on a 48 dp target.
    Widget action(Key key, IconData icon, String label, VoidCallback onTap) =>
        IconButton(
          key: key,
          tooltip: label,
          onPressed: onTap,
          icon: Icon(icon, size: 20, color: colors.textPrimary),
          style: IconButton.styleFrom(
            fixedSize: const Size.square(_kQuickCircle),
            minimumSize: const Size.square(_kQuickCircle),
            tapTargetSize: MaterialTapTargetSize.padded,
            backgroundColor: chrome.raised,
            shape: CircleBorder(side: BorderSide(color: chrome.line)),
          ),
        );
    return Material(
      key: const ValueKey('chat-control-quick'),
      color: colors.surfaceVariant,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          action(
            const ValueKey('chat-control-find'),
            Icons.search_rounded,
            findLabel,
            onFind,
          ),
          action(second.key, second.icon, second.label, second.onTap),
        ],
      ),
    );
  }
}

/// Touch height of every row and button.
const double _kRowMinHeight = 48;

/// The visible circle of an action of the quick pill (its target is 48).
const double _kQuickCircle = 40;

/// Above and below the count of a row.
const double _kBadgePad = HermesSpace.x1 / 2;

class _RowData {
  const _RowData({
    required this.id,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String id;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
}

/// One row of the window: its icon, its name, at least 48 dp tall; the name
/// wraps at large text instead of being cut. The panel showing now
/// ([selected]) sits on a soft accent tint, its name in bold accent and
/// [trailing] («en pantalla») after it. Name, count and status wrap within
/// the available width, including at large text sizes.
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.selected = false,
    this.trailing,
    this.badgeCount,
    this.badgeSemanticLabel,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// Icon and text colour (Borrar: the theme's error colour).
  final Color? color;
  final bool selected;
  final String? trailing;
  final int? badgeCount;
  final String? badgeSemanticLabel;

  /// The accent's tint under the panel showing now.
  static const double _tint = 0.16;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final enabled = onTap != null;
    final disabled = colors.textDisabled;
    final tint = selected ? colors.accent.withValues(alpha: _tint) : null;
    // REVIEW-Q9-VENT P2: the words read at 4.5:1 on the window, blurring or
    // not, and on the accent's tint; «Borrar» keeps its red, lighter or
    // darker.
    final ink = !enabled
        ? disabled
        : HermesFloatingSurface.windowInk(
            colors,
            selected ? colors.accentText : color ?? colors.textPrimary,
            tint: tint,
          );
    final iconInk = !enabled
        ? disabled
        : selected || color != null
        ? ink
        : chrome.mutedInk;
    final count = badgeCount ?? 0;
    final said = [
      label,
      if (count > 0) badgeSemanticLabel ?? '$count',
      ?trailing,
    ].join(', ');
    final radius = BorderRadius.circular(HermesRadius.control);
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: selected,
      onTap: onTap,
      label: said,
      excludeSemantics: true,
      child: Material(
        color: tint ?? Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _kRowMinHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x3,
                vertical: HermesSpace.x2,
              ),
              child: Row(
                children: [
                  Icon(icon, size: HermesIcon.lg, color: iconInk),
                  const SizedBox(width: HermesSpace.x3),
                  Expanded(
                    child: Wrap(
                      spacing: HermesSpace.x2,
                      runSpacing: HermesSpace.x1,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            color: ink,
                            fontSize: HermesType.readingSize,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                        if (count > 0)
                          DecoratedBox(
                            key: const ValueKey('chat-control-workspace-badge'),
                            decoration: BoxDecoration(
                              color: colors.accent,
                              borderRadius: BorderRadius.circular(
                                HermesRadius.tag,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: HermesSpace.x2,
                                vertical: _kBadgePad,
                              ),
                              child: Text(
                                '$count',
                                style: TextStyle(
                                  fontSize: HermesType.supportSize,
                                  fontWeight: FontWeight.w700,
                                  color: colors.onAccent,
                                ),
                              ),
                            ),
                          ),
                        if (trailing case final word?)
                          Text(
                            word,
                            key: const ValueKey('chat-control-panel-open'),
                            style: TextStyle(
                              fontSize: HermesType.supportSize,
                              fontWeight: FontWeight.w600,
                              color: ink,
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
      ),
    );
  }
}
