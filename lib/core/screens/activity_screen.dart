// Registro (logs) de la instancia.
//
// GET /api/logs del Dashboard (9119).
// Contrato verificado (web_server.py del upstream + sondeo en vivo):
//   /api/logs?file=agent&lines=200&level=ERROR&search=...
//   → {"file": "agent", "lines": ["2026-06-11 03:31:41,093 INFO gateway.run: ...", ...]}
// Archivos: agent, errors, gateway, gui, desktop. Niveles: DEBUG..CRITICAL.
// El filtrado de nivel/búsqueda se delega al servidor; el parsing local es
// defensivo: una línea que no matchea el formato se muestra cruda.
//
// Las ejecuciones (/v1/runs) viven ahora en Ejecuciones (TaskCenterScreen),
// la pantalla principal de runs; esta pantalla es solo el registro.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_app_bar.dart';

class ActivityScreen extends StatelessWidget {
  final SavedConnection connection;
  const ActivityScreen({required this.connection, super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: HermesAppBar(title: Text(Strings.of(context).actTitle)),
      body: _LogsTab(connection: connection),
    );
  }
}

/// Línea de log parseada. [raw] siempre está; el resto es best-effort.
class _LogEntry {
  final String raw;
  final String? time; // HH:mm:ss
  final String? level; // DEBUG/INFO/WARNING/ERROR/CRITICAL
  final String? component; // p.ej. gateway.run, aiohttp.access, cron
  final String message;

  _LogEntry({
    required this.raw,
    this.time,
    this.level,
    this.component,
    required this.message,
  });

  // "2026-06-11 03:31:41,093 INFO gateway.run: mensaje"
  static final _re = RegExp(
    r'^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})(?:,\d+)?\s+'
    r'(DEBUG|INFO|WARNING|ERROR|CRITICAL)\s+([\w\.\-]+):\s?(.*)$',
  );

  factory _LogEntry.parse(String line) {
    final m = _re.firstMatch(line.trimRight());
    if (m == null) {
      return _LogEntry(raw: line, message: line.trimRight());
    }
    return _LogEntry(
      raw: line,
      time: m.group(2),
      level: m.group(3),
      component: m.group(4),
      message: m.group(5) ?? '',
    );
  }

  /// Origen inferido del nombre del logger. Mira el logger completo (no solo
  /// el primer segmento) para distinguir api_server/cron/runs dentro de
  /// `gateway.*`.
  String get origin {
    final c = component;
    if (c == null) return '—';
    if (c.contains('api_server')) return 'api';
    if (c.contains('cron') || c.contains('jobs')) return 'cron';
    if (c.contains('skill')) return 'skill';
    if (c.contains('session')) return 'session';
    final head = c.split('.').first;
    return switch (head) {
      'aiohttp' => 'api',
      'gateway' => 'gateway',
      'model' || 'llm' || 'providers' => 'model',
      _ => head,
    };
  }
}

class _LogsTab extends StatefulWidget {
  final SavedConnection connection;
  const _LogsTab({required this.connection});

  @override
  State<_LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<_LogsTab> with AutomaticKeepAliveClientMixin {
  late DashboardClient _client;
  List<_LogEntry> _entries = [];
  bool _loading = true;
  String? _error;

  static const _files = ['agent', 'errors', 'gateway'];
  String _file = 'agent';

  static const _levels = [
    (null, 'todos'),
    ('INFO', 'info'),
    ('WARNING', 'warn'),
    ('ERROR', 'error'),
    ('DEBUG', 'debug'),
  ];
  String? _level;

  final _searchCtrl = TextEditingController();
  String _localFilter = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _client = DashboardClient.lazy(widget.connection);
    _load();
  }

  @override
  void dispose() {
    _client.close();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lines = await _client.getLogs(
        file: _file,
        lines: 300,
        level: _level,
      );
      if (!mounted) return;
      setState(() {
        // Más reciente arriba.
        _entries = lines.reversed.map(_LogEntry.parse).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  List<_LogEntry> get _visible {
    if (_localFilter.isEmpty) return _entries;
    final q = _localFilter.toLowerCase();
    return _entries.where((e) => e.raw.toLowerCase().contains(q)).toList();
  }

  void _copyVisible() {
    final visible = _visible;
    if (visible.isEmpty) return;
    // Copia en orden cronológico (el inverso del de pantalla).
    final text = visible.reversed.map((e) => e.raw.trimRight()).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    HermesNotice.of(context).showSnackBar(
      SnackBar(
        content: Text(Strings.of(context).actLinesCopied(visible.length)),
      ),
      kind: HermesNoticeKind.success,
    );
  }

  Color _levelColor(String? level, HermesThemeColors colors) => switch (level) {
    'ERROR' || 'CRITICAL' => colors.error,
    'WARNING' => colors.warning,
    'DEBUG' => colors.textDisabled,
    'INFO' => colors.textSecondary,
    _ => colors.textDisabled,
  };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = Theme.of(context).hermes;
    return Column(
      children: [
        // Selector de archivo + acciones, en una sola franja compacta.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
          child: Row(
            children: [
              for (final f in _files) ...[
                PressableScale(
                  onTap: () {
                    if (_file == f) return;
                    setState(() => _file = f);
                    _load();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _file == f
                          ? colors.accent.withValues(alpha: 0.10)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(
                        color: _file == f
                            ? colors.accent.withValues(alpha: 0.55)
                            : colors.divider,
                      ),
                    ),
                    child: Text(
                      f,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: _file == f
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: _file == f
                            ? colors.accentHover
                            : colors.textSecondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                tooltip: Strings.of(context).actCopyVisibleLines,
                onPressed: _entries.isEmpty ? null : _copyVisible,
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 19),
                tooltip: Strings.of(context).commonRefresh,
                onPressed: _loading ? null : _load,
              ),
            ],
          ),
        ),
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            children: [
              for (final (value, label) in _levels)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: PressableScale(
                    onTap: () {
                      if (_level == value) return;
                      setState(() => _level = value);
                      _load();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: _level == value
                            ? colors.surfaceVariant
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: _level == value
                              ? colors.textSecondary.withValues(alpha: 0.5)
                              : colors.divider,
                        ),
                      ),
                      child: Text(
                        value == null ? Strings.of(context).commonAll : label,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: _level == value
                              ? colors.textPrimary
                              : colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _localFilter = v),
            style: const TextStyle(fontSize: 12.5),
            decoration: InputDecoration(
              hintText: Strings.of(context).actSearchHint,
              hintStyle: TextStyle(fontSize: 12, color: colors.textDisabled),
              prefixIcon: Icon(
                Icons.search,
                size: 16,
                color: colors.textDisabled,
              ),
              suffixIcon: _localFilter.isEmpty
                  ? null
                  : IconButton(
                      icon: Icon(
                        Icons.clear,
                        size: 15,
                        color: colors.textDisabled,
                      ),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _localFilter = '');
                      },
                    ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(child: _buildBody(colors)),
      ],
    );
  }

  Widget _buildBody(HermesThemeColors colors) {
    if (_loading) {
      return Center(
        child: TuiLoader(label: Strings.of(context).actReadingLogs),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 36, color: colors.error),
              const SizedBox(height: 12),
              Text(
                Strings.of(context).actLogsReadError,
                style: TextStyle(fontSize: 14, color: colors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
              ),
              const SizedBox(height: 16),
              HermesSecondaryButton(
                label: Strings.of(context).commonRetry,
                icon: Icons.refresh,
                onTap: _load,
              ),
            ],
          ),
        ),
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 36,
              color: colors.textDisabled,
            ),
            const SizedBox(height: 12),
            Text(
              (_localFilter.isNotEmpty
                      ? Strings.of(context).actNoMatchesFor(_localFilter)
                      : Strings.of(context).actLogEmpty(_file)) +
                  (_level != null
                      ? Strings.of(context).actForLevel(_level!)
                      : ''),
              style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: colors.accent,
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        itemCount: visible.length,
        itemBuilder: (_, i) => _LogLine(
          entry: visible[i],
          color: _levelColor(visible[i].level, colors),
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: visible[i].raw));
            HermesNotice.of(context).showSnackBar(
              SnackBar(content: Text(Strings.of(context).actLineCopied)),
              kind: HermesNoticeKind.success,
            );
          },
        ),
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  final _LogEntry entry;
  final Color color;
  final VoidCallback onLongPress;

  const _LogLine({
    required this.entry,
    required this.color,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final isError = entry.level == 'ERROR' || entry.level == 'CRITICAL';
    return InkWell(
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Dot de nivel — la línea entera no grita, solo el indicador.
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: isError
                      ? [
                          BoxShadow(
                            color: color.withValues(alpha: 0.5),
                            blurRadius: 5,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (entry.time != null)
                        Text(
                          entry.time!,
                          style: TextStyle(
                            fontSize: 10,
                            color: colors.textDisabled,
                          ),
                        ),
                      if (entry.component != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          entry.origin,
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 0.5,
                            color: colors.accentHover.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    entry.message,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: isError
                          ? colors.error.withValues(alpha: 0.9)
                          : entry.level == 'WARNING'
                          ? colors.warning.withValues(alpha: 0.9)
                          : colors.textPrimary.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
