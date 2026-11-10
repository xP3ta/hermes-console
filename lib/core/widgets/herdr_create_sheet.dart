// «New agent» in one step (1.4.0): the agent (only the ones the server has),
// the folder (chosen, not typed: recent, pinned and browsable) and an
// optional name for the workspace; then «Start». The folder picker reads the
// server's directories over SFTP and can create a folder there.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart';
import '../services/herdr_agents.dart';
import '../services/herdr_folders.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../utils/short_server_path.dart';
import 'console_loader.dart';
import 'herdr_agents_widgets.dart';
import 'hermes_premium_ui.dart' show HermesSearchField;

/// What the user picked in «new agent».
class HerdrCreateChoice {
  const HerdrCreateChoice({
    required this.kind,
    required this.folder,
    this.label,
  });

  final String kind;
  final String folder;

  /// The workspace's name when the user gave one.
  final String? label;
}

/// The words for what is wrong with a new folder's name.
String hdpFolderNameMessage(Strings strings, HerdrFolderNameProblem problem) =>
    switch (problem) {
      HerdrFolderNameProblem.empty => strings.hdpFolderNameEmpty,
      HerdrFolderNameProblem.tooLong => strings.hdpFolderNameLong,
      HerdrFolderNameProblem.slash => strings.hdpFolderNameSlash,
      HerdrFolderNameProblem.dots => strings.hdpFolderNameDots,
      HerdrFolderNameProblem.control => strings.hdpFolderNameControl,
    };

/// Shows the form. Returns the choice, or null when it was closed.
Future<HerdrCreateChoice?> showHerdrCreateSheet(
  BuildContext context, {
  required HerdrAgentsController controller,
  required String server,
  HerdrFolderSource? folders,
}) {
  unawaited(controller.detectHarnesses());
  return showHermesSurface<HerdrCreateChoice>(
    context: context,
    surfaceKey: const ValueKey('hda-create-dialog'),
    maxWidth: 520,
    maxHeightFactor: 0.92,
    scrim: HermesScrim.sheet,
    builder: (context) =>
        _CreateForm(controller: controller, server: server, folders: folders),
  );
}

class _CreateForm extends StatefulWidget {
  const _CreateForm({
    required this.controller,
    required this.server,
    required this.folders,
  });

  final HerdrAgentsController controller;
  final String server;
  final HerdrFolderSource? folders;

  @override
  State<_CreateForm> createState() => _CreateFormState();
}

class _CreateFormState extends State<_CreateForm> {
  late String _kind;
  String? _folder;
  final TextEditingController _name = TextEditingController();

  HerdrAgentsController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    final last = _c.store.lastKind;
    _kind = last != null && herdrAgentKinds.contains(last)
        ? last
        : herdrAgentKinds.first;
    final recent = _c.store.folders;
    _folder = recent.isEmpty ? null : recent.first;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool _installed(String kind) => _c.harness?.isInstalled(kind) ?? true;

  /// The kind to start: the chosen one when the server has it, else the
  /// first the server has (the choice moves when a look finds its harness
  /// missing).
  String? get _effectiveKind {
    if (_c.harness == null || _installed(_kind)) return _kind;
    for (final kind in herdrAgentKinds) {
      if (_installed(kind)) return kind;
    }
    return null;
  }

  Future<void> _pickFolder() async {
    final picked = await showHerdrFolderPicker(
      context,
      controller: _c,
      source: widget.folders,
      initial: _folder,
    );
    if (picked != null && mounted) setState(() => _folder = picked);
  }

  void _start() {
    final kind = _effectiveKind;
    final folder = _folder;
    if (kind == null || folder == null) return;
    final label = herdrWorkspaceLabel(_name.text);
    Navigator.of(
      context,
    ).pop(HerdrCreateChoice(kind: kind, folder: folder, label: label));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final report = _c.harness;
        final kind = _effectiveKind;
        final canStart = kind != null && _folder != null;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HermesSurfaceHeader(
              title: strings.hdaNew,
              subtitle: widget.server,
              showClose: true,
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  HermesSpace.x5,
                  HermesSpace.x1,
                  HermesSpace.x5,
                  HermesSpace.x2,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            strings.hdaCreateKind,
                            style: HermesType.caption.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                        if (_c.detecting)
                          const ConsoleLoader.small(
                            key: ValueKey('hda-harness-loading'),
                          )
                        else
                          IconButton(
                            key: const ValueKey('hda-harness-refresh'),
                            tooltip: strings.hdpRefreshAgents,
                            constraints: const BoxConstraints(
                              minWidth: HermesSpace.tap,
                              minHeight: HermesSpace.tap,
                            ),
                            onPressed: () => _c.detectHarnesses(force: true),
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                      ],
                    ),
                    Wrap(
                      spacing: HermesSpace.x2,
                      runSpacing: HermesSpace.x2,
                      children: [
                        for (final k in herdrAgentKinds)
                          _KindChip(
                            kind: k,
                            selected: k == kind,
                            installed: _installed(k),
                            onTap: () => setState(() => _kind = k),
                          ),
                      ],
                    ),
                    if (report != null && report.failed)
                      _Note(
                        key: const ValueKey('hda-harness-failed'),
                        text: strings.hdpDetectFailed,
                      )
                    else if (report != null && kind == null)
                      _Note(
                        key: const ValueKey('hda-harness-none'),
                        text: strings.hdpNoneInstalled,
                      )
                    else if (report != null && report.missing.isNotEmpty)
                      _Note(
                        key: const ValueKey('hda-harness-note'),
                        text: strings.hdpInstallNote,
                      ),
                    const SizedBox(height: HermesSpace.x4),
                    Text(
                      strings.hdaCreateFolder,
                      style: HermesType.caption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: HermesSpace.x1),
                    _FolderField(folder: _folder, onTap: _pickFolder),
                    const SizedBox(height: HermesSpace.x4),
                    Text(
                      strings.hdpNameLabel,
                      style: HermesType.caption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: HermesSpace.x1),
                    TextField(
                      key: const ValueKey('hda-create-name'),
                      controller: _name,
                      maxLength: 40,
                      autocorrect: false,
                      textInputAction: TextInputAction.done,
                      style: HermesType.text.copyWith(
                        color: colors.textPrimary,
                      ),
                      decoration: InputDecoration(
                        hintText: strings.hdpNameHint,
                        counterText: '',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HermesSpace.x5,
                HermesSpace.x2,
                HermesSpace.x5,
                HermesSpace.x4,
              ),
              // Wraps at large text instead of overflowing.
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: HermesSpace.x2,
                runSpacing: HermesSpace.x2,
                children: [
                  HerdrGelButton(
                    key: const ValueKey('hda-create-cancel-sheet'),
                    onTap: () => Navigator.of(context).pop(),
                    child: Text(strings.commonCancel),
                  ),
                  HerdrGelButton(
                    key: const ValueKey('hda-create-start'),
                    accent: true,
                    onTap: canStart ? _start : null,
                    child: Text(strings.hdpStart),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: HermesSpace.x2),
    child: Text(
      text,
      style: HermesType.caption.copyWith(
        color: Theme.of(context).hermes.textSecondary,
      ),
    ),
  );
}

/// One harness. A missing one stays visible, dimmed, with «Not installed»,
/// and cannot be chosen.
class _KindChip extends StatelessWidget {
  const _KindChip({
    required this.kind,
    required this.selected,
    required this.installed,
    required this.onTap,
  });

  final String kind;
  final bool selected;
  final bool installed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final chip = HerdrGelButton(
      key: ValueKey('hda-kind-$kind'),
      selected: installed ? selected : null,
      semanticLabel: installed ? null : '$kind, ${strings.hdpNotInstalled}',
      onTap: installed ? onTap : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(kind),
          if (!installed)
            Text(
              strings.hdpNotInstalled,
              style: HermesType.caption.copyWith(color: colors.textSecondary),
            ),
        ],
      ),
    );
    return installed ? chip : Opacity(opacity: 0.55, child: chip);
  }
}

class _FolderField extends StatelessWidget {
  const _FolderField({required this.folder, required this.onTap});

  final String? folder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Semantics(
      button: true,
      label: folder == null
          ? strings.hdpChooseFolder
          : '${strings.hdaCreateFolder}: $folder',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        key: const ValueKey('hda-create-folder-pick'),
        borderRadius: BorderRadius.circular(HermesRadius.control),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HermesSpace.tap),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(HermesRadius.control),
              border: Border.all(color: colors.divider),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HermesSpace.x3,
                vertical: HermesSpace.x2,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_open_rounded,
                    size: HermesIcon.lg,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: HermesSpace.x3),
                  Expanded(
                    child: Text(
                      folder == null
                          ? strings.hdpChooseFolder
                          : shortServerPath(folder!),
                      key: const ValueKey('hda-create-folder-value'),
                      style: HermesType.text.copyWith(
                        fontFamily: folder == null
                            ? null
                            : HermesType.monoFamily,
                        color: folder == null
                            ? colors.textSecondary
                            : colors.textPrimary,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.textSecondary,
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

// ── Folder picker ───────────────────────────────────────────────────────

/// The folder picker. Returns the chosen absolute folder, or null.
Future<String?> showHerdrFolderPicker(
  BuildContext context, {
  required HerdrAgentsController controller,
  required HerdrFolderSource? source,
  String? initial,
}) => showHermesSurface<String>(
  context: context,
  surfaceKey: const ValueKey('hda-folder-picker'),
  maxWidth: 520,
  maxHeightFactor: 0.94,
  scrim: HermesScrim.sheet,
  builder: (context) => HerdrFolderPicker(
    controller: controller,
    source: source,
    initial: initial,
  ),
);

class HerdrFolderPicker extends StatefulWidget {
  const HerdrFolderPicker({
    required this.controller,
    required this.source,
    this.initial,
    super.key,
  });

  final HerdrAgentsController controller;
  final HerdrFolderSource? source;
  final String? initial;

  @override
  State<HerdrFolderPicker> createState() => _HerdrFolderPickerState();
}

class _HerdrFolderPickerState extends State<HerdrFolderPicker> {
  /// The folder being browsed; null shows the starting points.
  String? _path;
  HerdrDirListing? _listing;
  bool _loading = false;
  bool _failed = false;
  int _token = 0;

  String? _home;
  bool _showHidden = false;
  final TextEditingController _filter = TextEditingController();
  final TextEditingController _typed = TextEditingController();
  final TextEditingController _newName = TextEditingController();
  bool _creating = false;
  String? _typedError;
  String? _createError;
  bool _checking = false;

  HerdrAgentsController get _c => widget.controller;
  HerdrFolderSource? get _source => widget.source;

  late List<String> _favorites = List.of(_c.store.favorites);

  @override
  void initState() {
    super.initState();
    unawaited(_loadHome());
  }

  @override
  void dispose() {
    _filter.dispose();
    _typed.dispose();
    _newName.dispose();
    super.dispose();
  }

  Future<void> _loadHome() async {
    final source = _source;
    if (source == null) return;
    try {
      final home = await source.home();
      if (mounted) setState(() => _home = home);
    } catch (_) {
      // No home to offer: the other starting points remain.
    }
  }

  Future<void> _open(String path) async {
    final source = _source;
    if (source == null) {
      Navigator.of(context).pop(path);
      return;
    }
    final token = ++_token;
    setState(() {
      _path = path;
      _loading = true;
      _failed = false;
      _creating = false;
      _createError = null;
      _filter.clear();
    });
    try {
      final listing = await source.list(path);
      if (!mounted || token != _token) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || token != _token) return;
      setState(() {
        _listing = null;
        _loading = false;
        _failed = true;
      });
    }
  }

  void _up() {
    final path = _path;
    if (path == null) return;
    if (path == '/') {
      setState(() => _path = null);
    } else {
      unawaited(_open(herdrParentPath(path)));
    }
  }

  Future<void> _toggleFavorite(String folder) async {
    await _c.store.toggleFavorite(folder);
    if (mounted) setState(() => _favorites = List.of(_c.store.favorites));
  }

  Future<void> _useTyped() async {
    final strings = Strings.of(context);
    final String folder;
    try {
      folder = herdrFolder(_typed.text);
    } on HerdrInputException {
      setState(() => _typedError = strings.hdaErrFolder);
      return;
    }
    final source = _source;
    if (source == null) {
      Navigator.of(context).pop(folder);
      return;
    }
    setState(() {
      _checking = true;
      _typedError = null;
    });
    bool exists;
    try {
      exists = await source.isDirectory(folder);
    } catch (_) {
      exists = false;
    }
    if (!mounted) return;
    if (exists) {
      Navigator.of(context).pop(folder);
    } else {
      setState(() {
        _checking = false;
        _typedError = strings.hdpFolderNotFound;
      });
    }
  }

  Future<void> _createFolder() async {
    final strings = Strings.of(context);
    final path = _path;
    final source = _source;
    if (path == null || source == null) return;
    final problem = herdrFolderNameProblem(_newName.text);
    if (problem != null) {
      setState(() => _createError = hdpFolderNameMessage(strings, problem));
      return;
    }
    final target = herdrJoinPath(path, _newName.text);
    try {
      await source.makeDirectory(target);
    } catch (_) {
      if (mounted) {
        setState(() => _createError = strings.hdpFolderCreateFailed);
      }
      return;
    }
    if (!mounted) return;
    _newName.clear();
    await _open(target);
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final path = _path;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesSurfaceHeader(
          title: strings.hdpFolderTitle,
          subtitle: path == null ? null : shortServerPath(path),
          showClose: true,
        ),
        Flexible(
          child: path == null ? _roots(context) : _browser(context, path),
        ),
        if (path != null) _footer(context, path),
      ],
    );
  }

  // ── Starting points ──

  Widget _roots(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final running = <String>[];
    for (final row in _c.allRows) {
      final cwd = row.pane.cwd;
      if (cwd != null && cwd.startsWith('/') && !running.contains(cwd)) {
        running.add(cwd);
      }
    }
    final recents = _c.store.folders;
    Widget section(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x5,
        HermesSpace.x3,
        HermesSpace.x5,
        HermesSpace.x1,
      ),
      child: Text(
        label,
        style: HermesType.caption.copyWith(color: colors.textSecondary),
      ),
    );
    return ListView(
      key: const ValueKey('hda-folder-roots'),
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: HermesSpace.x3),
      children: [
        if (_home != null)
          _FolderRow(
            key: const ValueKey('hda-folder-home'),
            icon: Icons.home_outlined,
            title: strings.hdpFolderHome,
            subtitle: shortServerPath(_home!),
            onTap: () => _open(_home!),
          ),
        if (_favorites.isNotEmpty) ...[
          section(strings.hdpFolderFavorites),
          for (final folder in _favorites)
            _FolderRow(
              key: ValueKey('hda-folder-fav-$folder'),
              icon: Icons.star_rounded,
              title: shortServerPath(folder),
              subtitle: folder,
              onTap: () => Navigator.of(context).pop(folder),
              onBrowse: _source == null ? null : () => _open(folder),
              browseLabel: strings.hdpFolderTitle,
            ),
        ],
        if (running.isNotEmpty) ...[
          section(strings.hdpFolderRunning),
          for (final folder in running)
            _FolderRow(
              key: ValueKey('hda-folder-running-$folder'),
              icon: Icons.smart_toy_outlined,
              title: shortServerPath(folder),
              subtitle: folder,
              onTap: () => Navigator.of(context).pop(folder),
              onBrowse: _source == null ? null : () => _open(folder),
              browseLabel: strings.hdpFolderTitle,
            ),
        ],
        if (recents.isNotEmpty) ...[
          section(strings.hdaCreateRecent),
          for (final folder in recents)
            _FolderRow(
              key: ValueKey('hda-folder-recent-$folder'),
              icon: Icons.history_rounded,
              title: shortServerPath(folder),
              subtitle: folder,
              onTap: () => Navigator.of(context).pop(folder),
              onBrowse: _source == null ? null : () => _open(folder),
              browseLabel: strings.hdpFolderTitle,
            ),
        ],
        _advanced(context),
      ],
    );
  }

  /// A path typed by hand: folded away, checked against the server.
  Widget _advanced(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const ValueKey('hda-folder-advanced'),
        tilePadding: const EdgeInsets.symmetric(horizontal: HermesSpace.x5),
        childrenPadding: const EdgeInsets.fromLTRB(
          HermesSpace.x5,
          0,
          HermesSpace.x5,
          HermesSpace.x3,
        ),
        title: Text(
          strings.hdpFolderAdvanced,
          style: HermesType.support.copyWith(color: colors.textSecondary),
        ),
        initiallyExpanded: _source == null,
        children: [
          TextField(
            key: const ValueKey('hda-folder-path-field'),
            controller: _typed,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            style: HermesType.text.copyWith(
              fontFamily: HermesType.monoFamily,
              color: colors.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: strings.hdaCreateFolderHint,
              errorText: _typedError,
            ),
            onChanged: (_) {
              if (_typedError != null) setState(() => _typedError = null);
            },
            onSubmitted: (_) => _useTyped(),
          ),
          const SizedBox(height: HermesSpace.x2),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: HerdrGelButton(
              key: const ValueKey('hda-folder-path-go'),
              onTap: _checking ? null : _useTyped,
              child: Text(strings.hdpFolderCheck),
            ),
          ),
        ],
      ),
    );
  }

  // ── A folder ──

  Widget _browser(BuildContext context, String path) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final listing = _listing;
    final needle = _filter.text.trim().toLowerCase();
    final dirs = [
      for (final dir in listing?.dirs ?? const <HerdrDirEntry>[])
        if ((_showHidden || !dir.hidden) &&
            (needle.isEmpty || dir.name.toLowerCase().contains(needle)))
          dir,
    ];
    final crumbs = herdrBreadcrumbs(path);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          key: const ValueKey('hda-folder-crumbs'),
          scrollDirection: Axis.horizontal,
          reverse: true,
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x4),
          child: Semantics(
            container: true,
            label: strings.hdpFolderPathLabel(path),
            child: Row(
              children: [
                for (var i = 0; i < crumbs.length; i++) ...[
                  if (i > 1)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: HermesIcon.md,
                      color: colors.textSecondary,
                    ),
                  TextButton(
                    key: ValueKey('hda-folder-crumb-$i'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(HermesSpace.tap, HermesSpace.tap),
                      padding: const EdgeInsets.symmetric(
                        horizontal: HermesSpace.x2,
                      ),
                      foregroundColor: i == crumbs.length - 1
                          ? colors.textPrimary
                          : colors.accentText,
                    ),
                    onPressed: i == crumbs.length - 1
                        ? null
                        : () => _open(crumbs[i].path),
                    child: Text(crumbs[i].label),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x4),
          child: Row(
            children: [
              Expanded(
                child: HermesSearchField(
                  key: const ValueKey('hda-folder-filter'),
                  controller: _filter,
                  hintText: strings.hdpFolderFilter,
                  clearTooltip: strings.hdpSearchClear,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: HermesSpace.x2),
              IconButton(
                key: const ValueKey('hda-folder-hidden'),
                tooltip: strings.hdpFolderHidden,
                isSelected: _showHidden,
                constraints: const BoxConstraints(
                  minWidth: HermesSpace.tap,
                  minHeight: HermesSpace.tap,
                ),
                onPressed: () => setState(() => _showHidden = !_showHidden),
                icon: const Icon(Icons.visibility_off_outlined),
                selectedIcon: const Icon(Icons.visibility_outlined),
              ),
            ],
          ),
        ),
        if (listing != null && listing.isGit)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.x5,
              HermesSpace.x1,
              HermesSpace.x5,
              0,
            ),
            child: Row(
              key: const ValueKey('hda-folder-git'),
              children: [
                Icon(
                  Icons.commit_rounded,
                  size: HermesIcon.sm,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: HermesSpace.x1),
                Text(
                  strings.hdpFolderGit,
                  style: HermesType.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        Flexible(
          child: _loading
              ? const Padding(
                  padding: EdgeInsets.all(HermesSpace.x6),
                  child: Center(child: ConsoleLoader.medium()),
                )
              : _failed
              ? Padding(
                  padding: const EdgeInsets.all(HermesSpace.x5),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        strings.hdpFolderUnreadable,
                        key: const ValueKey('hda-folder-error'),
                        style: HermesType.text.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: HermesSpace.x2),
                      HerdrGelButton(
                        onTap: () => _open(path),
                        child: Text(strings.commonRetry),
                      ),
                    ],
                  ),
                )
              : ListView(
                  key: const ValueKey('hda-folder-list'),
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: HermesSpace.x2),
                  children: [
                    _FolderRow(
                      key: const ValueKey('hda-folder-up'),
                      icon: Icons.arrow_upward_rounded,
                      title: strings.hdpFolderUp,
                      onTap: _up,
                    ),
                    if (dirs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(HermesSpace.x5),
                        child: Text(
                          strings.hdpFolderEmpty,
                          key: const ValueKey('hda-folder-empty'),
                          style: HermesType.support.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    for (final dir in dirs)
                      _FolderRow(
                        key: ValueKey('hda-folder-dir-${dir.name}'),
                        icon: Icons.folder_outlined,
                        title: dir.name,
                        onTap: () => _open(herdrJoinPath(path, dir.name)),
                      ),
                    if (listing != null && listing.truncated)
                      Padding(
                        padding: const EdgeInsets.all(HermesSpace.x4),
                        child: Text(
                          strings.hdpFolderMore(SftpFolderSource.maxEntries),
                          style: HermesType.caption.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        if (_creating) _newFolderForm(context),
      ],
    );
  }

  Widget _newFolderForm(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x5,
        HermesSpace.x2,
        HermesSpace.x5,
        HermesSpace.x2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('hda-folder-new-name'),
              controller: _newName,
              autofocus: true,
              autocorrect: false,
              style: HermesType.text.copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                labelText: strings.hdpFolderNameLabel,
                errorText: _createError,
                errorMaxLines: 2,
              ),
              onChanged: (_) {
                if (_createError != null) {
                  setState(() => _createError = null);
                }
              },
              onSubmitted: (_) => _createFolder(),
            ),
          ),
          const SizedBox(width: HermesSpace.x2),
          Padding(
            padding: const EdgeInsets.only(top: HermesSpace.x1),
            child: HerdrGelButton(
              key: const ValueKey('hda-folder-new-go'),
              accent: true,
              onTap: _createFolder,
              child: Text(strings.hdaCreateAction),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context, String path) {
    final strings = Strings.of(context);
    final pinned = _favorites.contains(path);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HermesSpace.x4,
        HermesSpace.x1,
        HermesSpace.x4,
        HermesSpace.x3,
      ),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: HermesSpace.x2,
        runSpacing: HermesSpace.x2,
        children: [
          IconButton(
            key: const ValueKey('hda-folder-star'),
            tooltip: pinned ? strings.hdpFolderUnpin : strings.hdpFolderPin,
            constraints: const BoxConstraints(
              minWidth: HermesSpace.tap,
              minHeight: HermesSpace.tap,
            ),
            isSelected: pinned,
            onPressed: () => _toggleFavorite(path),
            icon: const Icon(Icons.star_outline_rounded),
            selectedIcon: const Icon(Icons.star_rounded),
          ),
          if (_source != null)
            HerdrGelButton(
              key: const ValueKey('hda-folder-new'),
              onTap: () => setState(() {
                _creating = !_creating;
                _createError = null;
              }),
              child: Text(strings.hdpFolderCreate),
            ),
          HerdrGelButton(
            key: const ValueKey('hda-folder-use'),
            accent: true,
            onTap: _loading || _failed
                ? null
                : () => Navigator.of(context).pop(path),
            child: Text(strings.hdpFolderUse),
          ),
        ],
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.onBrowse,
    this.browseLabel,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// Opens the folder in the browser instead of choosing it.
  final VoidCallback? onBrowse;
  final String? browseLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: HermesSpace.tap),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HermesSpace.x5,
                  vertical: HermesSpace.x2,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: HermesIcon.lg,
                      color: colors.textSecondary,
                    ),
                    const SizedBox(width: HermesSpace.x3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HermesType.body.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HermesType.caption.copyWith(
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
        ),
        if (onBrowse != null)
          IconButton(
            tooltip: browseLabel,
            constraints: const BoxConstraints(
              minWidth: HermesSpace.tap,
              minHeight: HermesSpace.tap,
            ),
            onPressed: onBrowse,
            icon: Icon(
              Icons.chevron_right_rounded,
              color: colors.textSecondary,
            ),
          ),
      ],
    );
  }
}

/// The last word before anything is created: short, one line.
Future<bool> confirmHerdrCreate(
  BuildContext context, {
  required HerdrCreateChoice choice,
  required String server,
}) async {
  final strings = Strings.of(context);
  final ok = await showHermesDialog<bool>(
    context: context,
    surfaceKey: const ValueKey('hda-create-confirm'),
    title: strings.hdaCreateConfirmTitle,
    message: strings.hdpConfirmBody(
      choice.kind,
      shortServerPath(choice.folder),
      server,
    ),
    actions: [
      HermesDialogAction(
        key: const ValueKey('hda-create-cancel'),
        label: strings.commonCancel,
        value: false,
        style: HermesDialogActionStyle.cancel,
      ),
      HermesDialogAction(
        key: const ValueKey('hda-create-go'),
        label: strings.hdpStart,
        value: true,
      ),
    ],
  );
  return ok == true;
}
