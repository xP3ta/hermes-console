import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/content.dart' show HermesSelectRow, HermesToggleRow;
import '../design/modal.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesOption,
        showHermesFormDialog,
        showHermesOptions;
import '../design/page.dart';
import '../services/active_profile_scope.dart';
import '../services/compression_config_repository.dart';
import '../services/connection_manager.dart';
import '../services/server_config_repository.dart';
import '../settings/server_config_controller.dart';
import '../settings/server_config_labels.dart';
import '../settings/server_config_pages.dart';
import '../theme/app_theme.dart';
import '../widgets/compression_config_card.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_ui.dart';
import 'voice_settings_screen.dart';

/// How a page gets its store for a profile (tests pass their own).
typedef ServerConfigStoreFactory =
    ServerConfigStore Function(String profile, {required bool writable});

/// How the Context page gets the compression repository for a profile.
typedef CompressionRepositoryFactory =
    CompressionConfigRepository Function(
      String profile, {
      required bool writable,
    });

/// One page of Settings › Advanced: the fields the schema brings for it,
/// with their values read when the page opens.
///
/// Booleans and selects save on the choice; numbers, text and lists save
/// only from the editor's Save button, never per keystroke. Every save is
/// confirmed by the store's re-read; a value the server did not keep goes
/// back to the server's.
class ServerConfigPageScreen extends StatefulWidget {
  final SavedConnection connection;
  final ConnectionManager connManager;
  final ServerConfigPage page;

  /// The `/api/config/schema` response the Advanced screen already read.
  final Map<String, dynamic> schema;

  /// A field to scroll to and highlight once (a settings-search result).
  final String? highlightPath;

  @visibleForTesting
  final ServerConfigStoreFactory? storeFor;

  @visibleForTesting
  final CompressionRepositoryFactory? compressionFor;

  const ServerConfigPageScreen({
    super.key,
    required this.connection,
    required this.connManager,
    required this.page,
    required this.schema,
    this.highlightPath,
    this.storeFor,
    this.compressionFor,
  });

  @override
  State<ServerConfigPageScreen> createState() => _ServerConfigPageScreenState();
}

class _ServerConfigPageScreenState extends State<ServerConfigPageScreen> {
  static const _highlightFor = Duration(seconds: 2);

  DashboardClient? _client;
  late final ActiveProfileScope _scope = ActiveProfileScope.of(
    widget.connManager,
    widget.connection.id,
  );
  late ServerConfigController _controller;
  late List<ServerConfigField> _fields;

  /// The Context page hands the `compression.*` fields to the existing card.
  late final bool _hasCompression;
  CompressionConfigRepository? _compression;
  late ProfileReadTicket _ticket;

  String? _highlight;
  bool _highlightPending = false;
  Timer? _highlightTimer;
  final GlobalKey _highlightKey = GlobalKey();

  bool get _readOnly =>
      widget.connection.readOnly ||
      widget.connManager.loadCapabilities(widget.connection.id).configWrite ==
          CapState.no;

  @override
  void initState() {
    super.initState();
    final all = serverConfigFieldsOf(widget.page, widget.schema);
    _hasCompression =
        widget.page == ServerConfigPage.context &&
        all.any((field) => field.path.startsWith('compression.'));
    _fields = [
      for (final field in all)
        if (!(_hasCompression && field.path.startsWith('compression.'))) field,
    ];
    final target = widget.highlightPath;
    if (target != null && _fields.any((field) => field.path == target)) {
      _highlight = target;
      _highlightPending = true;
    }
    _scope.addListener(_onProfileChanged);
    _open();
  }

  @override
  void dispose() {
    _scope.removeListener(_onProfileChanged);
    _highlightTimer?.cancel();
    _controller
      ..removeListener(_onController)
      ..dispose();
    _compression?.close();
    _client?.close();
    super.dispose();
  }

  void _open() {
    final ticket = _scope.capture();
    _ticket = ticket;
    final writable = !_readOnly;
    final custom = widget.storeFor;
    final store =
        custom?.call(ticket.name, writable: writable) ??
        ServerConfigRepository(
          _client ??= DashboardClient.lazy(widget.connection),
          profile: ticket.name,
          writable: writable,
        );
    _controller = ServerConfigController(
      store: store,
      isCurrent: () => mounted && ticket.isCurrent,
    )..addListener(_onController);
    if (_hasCompression) {
      _compression =
          widget.compressionFor?.call(ticket.name, writable: writable) ??
          CompressionConfigRepository(
            _client ??= DashboardClient.lazy(widget.connection),
            profile: ticket.name,
            writable: writable,
          );
    }
    unawaited(_controller.load());
  }

  void _onProfileChanged() {
    _controller
      ..removeListener(_onController)
      ..dispose();
    _compression?.close(abortActiveOperations: true);
    _compression = null;
    _open();
    setState(() {});
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() => _controller.load();

  void _revealHighlight() {
    _highlightPending = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _highlightKey.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 200),
            alignment: .3,
          ),
        );
      }
      _highlightTimer = Timer(_highlightFor, () {
        if (mounted) setState(() => _highlight = null);
      });
    });
  }

  Future<void> _save(String path, Object? value) async {
    final notices = HermesNotice.of(context);
    final s = Strings.of(context);
    final saved = await _controller.save(path, value);
    if (saved || !mounted) return;
    final kind = _controller.errorOf(path);
    if (kind != null) {
      notices.show(message: _saveError(s, kind), kind: HermesNoticeKind.error);
    }
  }

  String _saveError(Strings s, ServerConfigFailureKind kind) => switch (kind) {
    ServerConfigFailureKind.unconfirmed => s.adv1215SaveUnconfirmed,
    ServerConfigFailureKind.authentication ||
    ServerConfigFailureKind.permissionDenied ||
    ServerConfigFailureKind.readOnly => s.adv1215SaveDenied,
    _ => s.adv1215SaveFailed,
  };

  String _loadError(Strings s, ServerConfigFailureKind? kind) => switch (kind) {
    ServerConfigFailureKind.unsupported => s.adv1215Unsupported,
    ServerConfigFailureKind.authentication ||
    ServerConfigFailureKind.permissionDenied => s.adv1215LoadDenied,
    _ => s.adv1215LoadFailed,
  };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final controller = _controller;
    final children = <Widget>[];
    if (_readOnly) {
      children.add(HermesInfoBanner(s.chaCompressionConfigReadOnly));
      children.add(const SizedBox(height: 12));
    }
    if (widget.page == ServerConfigPage.conversation) {
      children.add(
        HermesGroup(
          children: [
            HermesNavRow(
              key: const ValueKey('adv1215-voice-link'),
              icon: Icons.record_voice_over_outlined,
              title: s.setVoiceTitle,
              subtitle: s.setVoice,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      VoiceSettingsScreen(connection: widget.connection),
                ),
              ),
            ),
          ],
        ),
      );
      children.add(const SizedBox(height: 12));
    }
    final compression = _compression;
    if (compression != null) {
      children.add(
        CompressionConfigCard(
          key: ValueKey('adv1215-compression-${_ticket.owner}'),
          profile: _ticket.name.isEmpty ? null : _ticket.name,
          canRead: true,
          canWrite: controller.canWrite,
          load: compression.load,
          save: compression.save,
        ),
      );
      children.add(const SizedBox(height: 12));
    }
    switch (controller.phase) {
      case ServerConfigPhase.idle:
      case ServerConfigPhase.loading:
        children.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: TuiLoader()),
          ),
        );
      case ServerConfigPhase.failed:
        children.add(HermesInfoBanner(_loadError(s, controller.loadFailure)));
      case ServerConfigPhase.ready:
        if (_highlightPending) _revealHighlight();
        if (_fields.isNotEmpty) {
          children.add(
            HermesGroup(
              children: [
                for (final field in _fields)
                  _row(context, s, controller, field),
              ],
            ),
          );
        }
    }
    return HermesPage(
      title: serverConfigPageTitle(s, widget.page),
      onRefresh: _reload,
      children: children,
    );
  }

  Widget _row(
    BuildContext context,
    Strings s,
    ServerConfigController controller,
    ServerConfigField field,
  ) {
    final path = field.path;
    final value = controller.valueOf(path);
    final saving = controller.isSaving(path);
    final error = controller.errorOf(path);
    final editable = controller.canWrite && !saving;
    final title = serverConfigFieldTitle(s, field);
    final ownTitle = serverConfigOwnTitle(s, path) != null;
    final subtitle = saving
        ? s.adv1215Saving
        : error != null
        ? _saveError(s, error)
        : ownTitle
        ? field.description
        : null;
    final key = ValueKey('adv1215-field-$path');

    final Widget row;
    switch (field.type) {
      case ServerConfigFieldType.boolean:
        row = HermesToggleRow(
          key: key,
          title: title,
          subtitle: subtitle,
          value: value == true,
          onChanged: editable ? (next) => unawaited(_save(path, next)) : null,
        );
      case ServerConfigFieldType.select:
        row = HermesSelectRow(
          key: key,
          title: title,
          subtitle: subtitle,
          value: _display(value),
          onTap: editable
              ? () => unawaited(_pick(context, field, value))
              : null,
        );
      case ServerConfigFieldType.number:
      case ServerConfigFieldType.string:
      case ServerConfigFieldType.list:
        final listWithOther = value is List && value.any((e) => e is! String);
        row = HermesSelectRow(
          key: key,
          title: title,
          subtitle: subtitle,
          value: _display(value),
          onTap: editable && !listWithOther
              ? () => unawaited(_edit(context, field, value))
              : null,
        );
    }
    if (path != _highlight) return row;
    return KeyedSubtree(
      key: _highlightKey,
      child: DecoratedBox(
        key: ValueKey('adv1215-highlight-$path'),
        decoration: BoxDecoration(
          color: Theme.of(context).hermes.accent.withValues(alpha: .14),
        ),
        child: row,
      ),
    );
  }

  String _display(Object? value) {
    if (value == null) return '—';
    if (value is List) return value.isEmpty ? '—' : value.join(', ');
    final text = value.toString();
    return text.isEmpty ? '—' : text;
  }

  Future<void> _pick(
    BuildContext context,
    ServerConfigField field,
    Object? current,
  ) async {
    final s = Strings.of(context);
    final picked = await showHermesOptions<String>(
      context: context,
      title: serverConfigFieldTitle(s, field),
      selected: current?.toString(),
      options: [
        for (final option in field.options)
          HermesOption<String>(value: option, label: option),
      ],
    );
    if (picked == null || picked == current?.toString() || !mounted) return;
    await _save(field.path, picked);
  }

  Future<void> _edit(
    BuildContext context,
    ServerConfigField field,
    Object? current,
  ) async {
    final s = Strings.of(context);
    final text = TextEditingController(
      text: current is List
          ? current.join('\n')
          : current == null
          ? ''
          : current.toString(),
    );
    try {
      Object? parsed = current;
      String? invalid;
      void validate() {
        final result = _parse(s, field, text.text, current);
        parsed = result.value;
        invalid = result.error;
      }

      validate();
      final confirmed = await showHermesFormDialog<bool>(
        context: context,
        title: serverConfigFieldTitle(s, field),
        actions: [
          HermesDialogAction(
            label: s.commonCancel,
            value: false,
            style: HermesDialogActionStyle.cancel,
          ),
          HermesDialogAction(label: s.commonSave, value: true),
        ],
        enabled: (save) => !save || invalid == null,
        body: (context, setState) => TextField(
          controller: text,
          autofocus: true,
          keyboardType: field.type == ServerConfigFieldType.number
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.multiline,
          minLines: 1,
          maxLines: field.type == ServerConfigFieldType.list ? 6 : 1,
          decoration: InputDecoration(
            hintText: field.type == ServerConfigFieldType.list
                ? s.adv1215ListHint
                : null,
            errorText: invalid,
          ),
          onChanged: (_) => setState(validate),
        ),
      );
      if (confirmed != true || invalid != null || !mounted) return;
      await _save(field.path, parsed);
    } finally {
      // The dialog route may still be animating out: dispose after it.
      WidgetsBinding.instance.addPostFrameCallback((_) => text.dispose());
    }
  }

  ({Object? value, String? error}) _parse(
    Strings s,
    ServerConfigField field,
    String raw,
    Object? current,
  ) {
    switch (field.type) {
      case ServerConfigFieldType.number:
        final trimmed = raw.trim();
        final whole = int.tryParse(trimmed);
        if (whole != null) {
          return (
            value: current is double ? whole.toDouble() : whole,
            error: null,
          );
        }
        final fraction = double.tryParse(trimmed);
        if (fraction == null || !fraction.isFinite) {
          return (value: null, error: s.adv1215NumberInvalid);
        }
        if (current is! double) {
          return (value: null, error: s.adv1215IntegerInvalid);
        }
        return (value: fraction, error: null);
      case ServerConfigFieldType.list:
        return (
          value: [
            for (final line in raw.split('\n'))
              if (line.trim().isNotEmpty) line.trim(),
          ],
          error: null,
        );
      case ServerConfigFieldType.boolean:
      case ServerConfigFieldType.select:
      case ServerConfigFieldType.string:
        return (value: raw.trim(), error: null);
    }
  }
}
