// Editor de personajes (studio): the look of one bot (a continuous body,
// eyes, pieces and colour) on a canvas that zooms and pans, previewed in
// fourteen animation states. It saves per profile on this device and rides
// the existing face motion engine; nothing is sent to the gateway.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../characters/bot_character.dart';
import '../../characters/bot_character_store.dart';
import '../../characters/character_draft.dart';
import '../../characters/character_export.dart';
import '../../characters/character_face.dart';
import '../../characters/character_library.dart';
import '../../characters/studio_catalog.dart';
import '../../design/modal.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_app_bar.dart';
import '../../widgets/hermes_premium_ui.dart';
import 'studio_canvas.dart';
import 'studio_panels.dart';
import 'studio_view.dart';
import 'studio_widgets.dart';

enum _Tab { shape, eyes, pieces, color }

enum _Action { redo, reset, save, saved, share, duplicate, fresh }

class CharacterEditorScreen extends StatefulWidget {
  /// Width from which the canvas sits beside the controls (open Fold).
  static const double wideBreakpoint = 720;

  /// Builds of the screen itself, for the test that dragging a slider
  /// repaints the canvas without rebuilding the screen.
  @visibleForTesting
  static int debugBuilds = 0;

  final String profileName;
  final String? connectionId;

  /// Store to read and write; tests inject their own.
  final BotCharacterStore? store;

  /// Saved characters; tests inject their own.
  final BotCharacterLibrary? library;

  /// Character to start from instead of the profile's own (a saved one).
  final BotCharacter? initial;

  /// Id of the saved character being edited, if it came from the library.
  final String? savedId;

  /// Opens the system share sheet; tests inject their own.
  final CharacterSharer? sharer;

  /// Opens a chat of the profile with the AI request written; null (a
  /// read-only connection, no active profile) leaves "Generate" off.
  final StudioAskAgent? askAgent;

  const CharacterEditorScreen({
    required this.profileName,
    this.connectionId,
    this.store,
    this.library,
    this.initial,
    this.savedId,
    this.sharer,
    this.askAgent,
    super.key,
  });

  @override
  State<CharacterEditorScreen> createState() => _CharacterEditorScreenState();
}

class _CharacterEditorScreenState extends State<CharacterEditorScreen> {
  late final BotCharacterStore _store =
      widget.store ?? BotCharacterStore.shared;
  late final BotCharacterLibrary _library =
      widget.library ?? BotCharacterLibrary.shared;
  late final CharacterDraft _draft;
  final StudioViewController _view = StudioViewController();
  final ValueNotifier<int?> _selection = ValueNotifier<int?>(null);
  final ValueNotifier<BotStudioState> _previewState =
      ValueNotifier<BotStudioState>(BotStudioState.idle);
  final ValueNotifier<_Tab> _tab = ValueNotifier<_Tab>(_Tab.shape);
  final GlobalKey _exportKey = GlobalKey();
  String? _savedId;
  bool _sharedPng = false;

  @override
  void initState() {
    super.initState();
    final start =
        widget.initial ??
        _store.characterFor(widget.connectionId, widget.profileName) ??
        BotCharacter.standard;
    _draft = CharacterDraft(start.toStudio());
    _savedId = widget.savedId;
  }

  @override
  void dispose() {
    // A PNG left by an interrupted share does not outlive the screen.
    if (_sharedPng) unawaited(clearCharacterShareFiles());
    _draft.dispose();
    _view.dispose();
    _selection.dispose();
    _previewState.dispose();
    _tab.dispose();
    super.dispose();
  }

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  void _randomSeed() {
    final value = Random.secure().nextInt(1 << 30).toRadixString(36);
    _draft.apply(_draft.value.copyWith(seed: value));
  }

  Future<void> _apply() async {
    final s = Strings.of(context);
    final navigator = Navigator.of(context);
    await _store.save(widget.connectionId, widget.profileName, _draft.value);
    _draft.markSaved();
    _toast(s.bstAppliedToast(widget.profileName));
    if (mounted) navigator.pop(true);
  }

  Future<void> _confirmLeave() async {
    final s = Strings.of(context);
    final navigator = Navigator.of(context);
    final discard = await showHermesDialog<bool>(
      context: context,
      title: s.bstDiscardTitle,
      message: s.bstDiscardBody,
      actions: [
        HermesDialogAction(
          key: const ValueKey('studio-keep-editing'),
          label: s.bstKeepEditing,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('studio-discard'),
          label: s.bstDiscard,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (discard == true && mounted) navigator.pop();
  }

  Future<String?> _askName(String initial) async {
    final s = Strings.of(context);
    final controller = TextEditingController(text: initial);
    final saved = await showHermesFormDialog<bool>(
      context: context,
      title: s.bstNameTitle,
      body: (dialogContext, setState) => DisposeControllersOnUnmount(
        controllers: [controller],
        child: TextField(
          key: const ValueKey('studio-name-field'),
          controller: controller,
          autofocus: true,
          maxLength: BotStudioLimits.maxNameLength,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {}),
          onSubmitted: (value) {
            if (value.trim().isEmpty) return;
            Navigator.of(dialogContext).pop(true);
          },
          decoration: InputDecoration(hintText: s.bstNameHint),
        ),
      ),
      enabled: (value) => !value || controller.text.trim().isNotEmpty,
      actions: [
        HermesDialogAction(
          label: s.commonCancel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('studio-name-save'),
          label: s.commonSave,
          value: true,
        ),
      ],
    );
    if (saved != true) return null;
    final name = BotCharacterLibrary.cleanName(controller.text);
    return name.isEmpty ? null : name;
  }

  Future<void> _save() async {
    final s = Strings.of(context);
    final current = _library.byId(_savedId);
    final name = await _askName(current?.name ?? s.bstDefaultName);
    if (name == null || !mounted) return;
    if (current != null) {
      await _library.update(current.id, name: name, character: _draft.value);
    } else {
      final item = await _library.add(name, _draft.value);
      _savedId = item.id;
    }
    _toast(s.bstSavedToast);
  }

  Future<void> _duplicate() async {
    final s = Strings.of(context);
    final base = _library.byId(_savedId)?.name ?? s.bstDefaultName;
    await _library.add(s.bstCopyName(base), _draft.value);
    _toast(s.bstSavedToast);
  }

  void _fresh() {
    _selection.value = null;
    _savedId = null;
    _draft.apply(BotCharacter.fresh.copyWith(seed: _draft.value.seed));
  }

  void _reset() {
    _selection.value = null;
    _draft.apply(BotCharacter.fresh);
  }

  Future<void> _openSaved() async {
    final s = Strings.of(context);
    final picked = await showHermesSurface<SavedCharacter>(
      context: context,
      surfaceKey: const ValueKey('studio-saved-sheet'),
      builder: (sheetContext) => _SavedSheet(
        library: _library,
        profileName: widget.profileName,
        title: s.bstSavedCharacters,
        emptyText: s.bstSavedEmpty,
      ),
    );
    if (picked == null || !mounted) return;
    _selection.value = null;
    _savedId = picked.id;
    _draft.apply(picked.character.toStudio());
  }

  Future<void> _share() async {
    final s = Strings.of(context);
    try {
      final png = await captureCharacterPng(_exportKey);
      if (png == null) {
        if (mounted) _toast(s.bstShareFailed);
        return;
      }
      final name = _library.byId(_savedId)?.name ?? widget.profileName;
      _sharedPng = widget.sharer == null;
      await (widget.sharer ?? shareCharacterPng)(png, name);
    } on Object {
      if (mounted) _toast(s.bstShareFailed);
    }
  }

  Future<void> _pickState(BuildContext anchor) async {
    final s = Strings.of(context);
    final picked = await showHermesOptions<BotStudioState>(
      context: anchor,
      title: s.bstStatePickTitle,
      selected: _previewState.value,
      searchThreshold: BotStudioState.values.length + 1,
      options: [
        for (final state in BotStudioState.values)
          HermesOption(
            key: ValueKey('studio-state-${state.name}'),
            value: state,
            label: studioStateLabel(state, s),
          ),
      ],
    );
    if (picked != null) _previewState.value = picked;
  }

  Future<void> _openMenu(BuildContext anchor) async {
    final s = Strings.of(context);
    final picked = await showHermesMenu<_Action>(
      context: anchor,
      surfaceKey: const ValueKey('studio-menu'),
      actions: [
        HermesAction(
          key: const ValueKey('studio-menu-redo'),
          value: _Action.redo,
          label: s.bstRedo,
          icon: Icons.redo_rounded,
        ),
        HermesAction(
          key: const ValueKey('studio-menu-reset'),
          value: _Action.reset,
          label: s.bstReset,
          icon: Icons.restart_alt_rounded,
        ),
        HermesAction(
          key: const ValueKey('studio-menu-save'),
          value: _Action.save,
          label: s.bstSaveCharacter,
          icon: Icons.bookmark_add_outlined,
          divided: true,
        ),
        HermesAction(
          key: const ValueKey('studio-menu-saved'),
          value: _Action.saved,
          label: s.bstSavedCharacters,
          icon: Icons.collections_bookmark_outlined,
        ),
        HermesAction(
          key: const ValueKey('studio-menu-share'),
          value: _Action.share,
          label: s.bstSharePng,
          icon: Icons.ios_share_rounded,
        ),
        HermesAction(
          key: const ValueKey('studio-menu-duplicate'),
          value: _Action.duplicate,
          label: s.bstDuplicate,
          icon: Icons.copy_all_outlined,
        ),
        HermesAction(
          key: const ValueKey('studio-menu-new'),
          value: _Action.fresh,
          label: s.bstNewCharacter,
          icon: Icons.add_circle_outline_rounded,
        ),
      ],
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case _Action.redo:
        _draft.redo();
      case _Action.reset:
        _reset();
      case _Action.save:
        await _save();
      case _Action.saved:
        await _openSaved();
      case _Action.share:
        await _share();
      case _Action.duplicate:
        await _duplicate();
      case _Action.fresh:
        _fresh();
    }
  }

  // ── Pieces of the screen ────────────────────────────────────────────────

  List<Widget> _barActions(Strings s) => [
    ListenableBuilder(
      listenable: _draft,
      builder: (context, _) => IconButton(
        key: const ValueKey('studio-undo'),
        tooltip: s.bstUndo,
        icon: const Icon(Icons.undo_rounded),
        onPressed: _draft.canUndo ? _draft.undo : null,
      ),
    ),
    Builder(
      builder: (buttonContext) => IconButton(
        key: const ValueKey('studio-more'),
        tooltip: s.bstMore,
        icon: const Icon(Icons.more_horiz_rounded),
        onPressed: () => unawaited(_openMenu(buttonContext)),
      ),
    ),
    IconButton(
      key: const ValueKey('studio-confirm'),
      tooltip: s.bstConfirm,
      icon: const Icon(Icons.check_rounded),
      onPressed: () => unawaited(_apply()),
    ),
  ];

  Widget _toolbar(Strings s) => ListenableBuilder(
    listenable: _view,
    builder: (context, _) => SingleChildScrollView(
      key: const ValueKey('studio-toolbar'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('studio-pan'),
            tooltip: s.bstPan,
            isSelected: _view.panMode,
            icon: const Icon(Icons.pan_tool_outlined),
            selectedIcon: const Icon(Icons.pan_tool_rounded),
            onPressed: _view.togglePanMode,
          ),
          IconButton(
            key: const ValueKey('studio-zoom-out'),
            tooltip: s.bstZoomOut,
            icon: const Icon(Icons.remove_rounded),
            onPressed: _view.canZoomOut ? _view.zoomOut : null,
          ),
          StudioPill(
            key: const ValueKey('studio-zoom-level'),
            label: s.bstZoomValue(_view.percent),
            semanticLabel: s.bstZoomResetTip,
            onTap: _view.actualSize,
          ),
          IconButton(
            key: const ValueKey('studio-zoom-in'),
            tooltip: s.bstZoomIn,
            icon: const Icon(Icons.add_rounded),
            onPressed: _view.canZoomIn ? _view.zoomIn : null,
          ),
          StudioPill(
            key: const ValueKey('studio-fit'),
            label: s.bstFit,
            onTap: _view.fit,
          ),
        ],
      ),
    ),
  );

  Widget _canvas(HermesThemeColors colors) => StudioCanvas(
    draft: _draft,
    profileName: widget.profileName,
    view: _view,
    selection: _selection,
    previewState: _previewState,
    exportKey: _exportKey,
    background: colors.surface,
    onPickState: () => unawaited(_pickStateFromCanvas()),
  );

  final GlobalKey _canvasKey = GlobalKey();

  Future<void> _pickStateFromCanvas() =>
      _pickState(_canvasKey.currentContext ?? context);

  Widget _tabs(Strings s) => ValueListenableBuilder<_Tab>(
    valueListenable: _tab,
    builder: (context, tab, _) => StudioTabs<_Tab>(
      key: const ValueKey('studio-tabs'),
      value: tab,
      semanticLabel: s.bstEditorTitle,
      onChanged: (value) => _tab.value = value,
      items: [
        StudioTabItem(
          key: const ValueKey('studio-tab-shape'),
          value: _Tab.shape,
          label: s.bstTabShape,
        ),
        StudioTabItem(
          key: const ValueKey('studio-tab-eyes'),
          value: _Tab.eyes,
          label: s.bstTabEyes,
        ),
        StudioTabItem(
          key: const ValueKey('studio-tab-pieces'),
          value: _Tab.pieces,
          label: s.bstTabPieces,
        ),
        StudioTabItem(
          key: const ValueKey('studio-tab-color'),
          value: _Tab.color,
          label: s.bstTabColor,
        ),
      ],
    ),
  );

  Widget _panel() => ValueListenableBuilder<_Tab>(
    valueListenable: _tab,
    // A list tile paints on the nearest Material: give it one under the
    // tinted page, or the tint would hide its ink.
    builder: (context, tab, _) => Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
        key: ValueKey('studio-panel-${tab.name}'),
        padding: const EdgeInsets.only(bottom: HermesSpace.x8),
        child: switch (tab) {
          _Tab.shape => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StudioShapePanel(
                draft: _draft,
                profileName: widget.profileName,
                onRandomSeed: _randomSeed,
              ),
              StudioGenerateBlock(
                draft: _draft,
                profileName: widget.profileName,
                askAgent: widget.askAgent,
                onApplied: () => _selection.value = null,
              ),
            ],
          ),
          _Tab.eyes => StudioEyesPanel(
            draft: _draft,
            profileName: widget.profileName,
          ),
          _Tab.pieces => StudioPiecesPanel(
            draft: _draft,
            profileName: widget.profileName,
            selection: _selection,
          ),
          _Tab.color => StudioColorPanel(
            draft: _draft,
            profileName: widget.profileName,
          ),
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    CharacterEditorScreen.debugBuilds++;
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    const pad = EdgeInsets.symmetric(horizontal: HermesSpace.x4);
    final scaffold = Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        title: Text(s.bstEditorTitle),
        actions: _barActions(s),
      ),
      body: _Tinted(
        draft: _draft,
        profileName: widget.profileName,
        base: colors.background,
        ink: colors.textSecondary,
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= CharacterEditorScreen.wideBreakpoint;
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 5,
                    child: Padding(
                      padding: pad,
                      child: Column(
                        children: [
                          _toolbar(s),
                          Expanded(
                            child: KeyedSubtree(
                              key: _canvasKey,
                              child: _canvas(colors),
                            ),
                          ),
                          const SizedBox(height: HermesSpace.x3),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Padding(
                      padding: pad,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _tabs(s),
                          Expanded(child: _panel()),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }
            final canvasSide = min(
              box.maxWidth - 2 * HermesSpace.x4,
              box.maxHeight * 0.42,
            );
            return Padding(
              padding: pad,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _toolbar(s),
                  SizedBox(
                    height: canvasSide,
                    child: KeyedSubtree(
                      key: _canvasKey,
                      child: _canvas(colors),
                    ),
                  ),
                  const SizedBox(height: HermesSpace.x3),
                  _tabs(s),
                  Expanded(child: _panel()),
                ],
              ),
            );
          },
        ),
      ),
    );
    return ListenableBuilder(
      listenable: _draft,
      child: scaffold,
      builder: (context, child) => PopScope(
        canPop: !_draft.dirty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_confirmLeave());
        },
        child: child!,
      ),
    );
  }
}

/// The page background, pulled toward the body colour being edited. Only
/// this paints again when the colour changes: [child] is built once.
class _Tinted extends StatelessWidget {
  final CharacterDraft draft;
  final String profileName;
  final Color base;
  final Color ink;
  final Widget child;

  const _Tinted({
    required this.draft,
    required this.profileName,
    required this.base,
    required this.ink,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: draft,
    child: child,
    builder: (context, child) => ColoredBox(
      color: studioTint(base, draft.value, profileName, 0.1, ink: ink),
      child: child,
    ),
  );
}

/// The saved characters in a floating sheet; a tap picks one.
class _SavedSheet extends StatelessWidget {
  final BotCharacterLibrary library;
  final String profileName;
  final String title;
  final String emptyText;

  const _SavedSheet({
    required this.library,
    required this.profileName,
    required this.title,
    required this.emptyText,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final items = library.items;
        return Padding(
          padding: const EdgeInsets.all(HermesSpace.x4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: HermesType.style(HermesType.title, colors.textPrimary),
                ),
              ),
              const SizedBox(height: HermesSpace.x3),
              if (items.isEmpty)
                Text(
                  emptyText,
                  style: HermesType.style(
                    HermesType.text,
                    colors.textSecondary,
                  ),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: HermesSpace.x2,
                      runSpacing: HermesSpace.x3,
                      children: [
                        for (final item in items)
                          StudioTile(
                            key: ValueKey('studio-saved-${item.id}'),
                            label: item.name,
                            onTap: () => Navigator.of(context).pop(item),
                            preview: Center(
                              child: CharacterFace(
                                profileName: profileName,
                                character: item.character,
                                size: 52,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
