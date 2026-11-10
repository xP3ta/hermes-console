// Estudio de personajes: the profile's current character, the ones the user
// saved and the presets, with a button into the editor. Picking a character
// makes it the profile's face (on this device only).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../characters/bot_character.dart';
import '../../characters/bot_character_store.dart';
import '../../characters/character_export.dart';
import '../../characters/character_face.dart';
import '../../characters/character_library.dart';
import '../../characters/character_presets.dart';
import '../../characters/studio_catalog.dart';
import '../../design/modal.dart';
import '../../design/tokens.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_app_bar.dart';
import '../../widgets/hermes_ui.dart';
import 'character_editor_screen.dart';
import 'studio_panels.dart' show StudioAskAgent;
import 'studio_widgets.dart';

enum _SavedAction { use, edit, duplicate, remove }

String studioPresetLabel(String id, Strings s) => switch (id) {
  'coral' => s.bstPresetCoral,
  'lilac' => s.bstPresetLilac,
  'sunny' => s.bstPresetSunny,
  'mint' => s.bstPresetMint,
  'slate' => s.bstPresetSlate,
  'kitten' => s.bstPresetKitten,
  'ember' => s.bstPresetEmber,
  _ => s.bstPresetRegal,
};

class CharacterStudioScreen extends StatefulWidget {
  final String profileName;
  final String? connectionId;
  final BotCharacterStore? store;
  final BotCharacterLibrary? library;
  final CharacterSharer? sharer;

  /// Opens a chat of the profile with the AI request written; null leaves
  /// "Generate" off in the editor.
  final StudioAskAgent? askAgent;

  const CharacterStudioScreen({
    required this.profileName,
    this.connectionId,
    this.store,
    this.library,
    this.sharer,
    this.askAgent,
    super.key,
  });

  @override
  State<CharacterStudioScreen> createState() => _CharacterStudioScreenState();
}

class _CharacterStudioScreenState extends State<CharacterStudioScreen> {
  late final BotCharacterStore _store =
      widget.store ?? BotCharacterStore.shared;
  late final BotCharacterLibrary _library =
      widget.library ?? BotCharacterLibrary.shared;

  BotCharacter get _current =>
      _store.characterFor(widget.connectionId, widget.profileName) ??
      BotCharacter.standard;

  void _toast(String text) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _use(BotCharacter character) async {
    final s = Strings.of(context);
    await _store.save(widget.connectionId, widget.profileName, character);
    if (mounted) _toast(s.bstAppliedToast(widget.profileName));
  }

  Future<void> _customize({SavedCharacter? from}) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CharacterEditorScreen(
        profileName: widget.profileName,
        connectionId: widget.connectionId,
        store: _store,
        library: _library,
        initial: from?.character,
        savedId: from?.id,
        sharer: widget.sharer,
        askAgent: widget.askAgent,
      ),
    ),
  );

  Future<void> _savedMenu(BuildContext anchor, SavedCharacter item) async {
    final s = Strings.of(context);
    final picked = await showHermesMenu<_SavedAction>(
      context: anchor,
      surfaceKey: const ValueKey('studio-saved-menu'),
      title: item.name,
      actions: [
        HermesAction(
          key: const ValueKey('studio-saved-use'),
          value: _SavedAction.use,
          label: s.bstUseCharacter,
        ),
        HermesAction(
          key: const ValueKey('studio-saved-edit'),
          value: _SavedAction.edit,
          label: s.bstCustomize,
        ),
        HermesAction(
          key: const ValueKey('studio-saved-duplicate'),
          value: _SavedAction.duplicate,
          label: s.bstDuplicate,
        ),
        HermesAction(
          key: const ValueKey('studio-saved-delete'),
          value: _SavedAction.remove,
          label: s.bstPieceDelete,
          destructive: true,
        ),
      ],
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case _SavedAction.use:
        await _use(item.character);
      case _SavedAction.edit:
        await _customize(from: item);
      case _SavedAction.duplicate:
        await _library.duplicate(item.id, s.bstCopyName(item.name));
      case _SavedAction.remove:
        final sure = await showHermesDialog<bool>(
          context: context,
          title: s.bstDeleteTitle(item.name),
          actions: [
            HermesDialogAction(
              label: s.commonCancel,
              value: false,
              style: HermesDialogActionStyle.cancel,
            ),
            HermesDialogAction(
              key: const ValueKey('studio-saved-delete-confirm'),
              label: s.bstPieceDelete,
              value: true,
              style: HermesDialogActionStyle.destructive,
            ),
          ],
        );
        if (sure == true) await _library.remove(item.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: HermesAppBar(
        title: Text(s.bstStudioTitle),
        actions: [
          IconButton(
            key: const ValueKey('studio-original-face'),
            tooltip: s.bstOriginalFace,
            icon: const Icon(Icons.face_retouching_off_rounded),
            onPressed: () => unawaited(
              _store
                  .reset(widget.connectionId, widget.profileName)
                  .then((_) => mounted ? _toast(s.bstOriginalToast) : null),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([_store, _library]),
            builder: (context, _) {
              final current = _current;
              final items = _library.items;
              return ListView(
                key: const ValueKey('studio-list'),
                padding: const EdgeInsets.fromLTRB(
                  HermesSpace.x4,
                  HermesSpace.x2,
                  HermesSpace.x4,
                  HermesSpace.x8 * 3,
                ),
                children: [
                  Center(
                    child: Semantics(
                      container: true,
                      label: s.bstCurrentCharacter,
                      child: CharacterFace(
                        key: const ValueKey('studio-current'),
                        profileName: widget.profileName,
                        character: current,
                        size: 200,
                        animate: true,
                        studioState: BotStudioState.idle,
                      ),
                    ),
                  ),
                  const SizedBox(height: HermesSpace.x2),
                  Text(
                    widget.profileName,
                    textAlign: TextAlign.center,
                    style: HermesType.style(
                      HermesType.title,
                      colors.textPrimary,
                    ),
                  ),
                  HermesSectionHeader(s.bstMyCharacters),
                  if (items.isEmpty)
                    Text(
                      s.bstSavedEmpty,
                      style: HermesType.style(
                        HermesType.support,
                        colors.textSecondary,
                      ),
                    )
                  else ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: HermesSpace.x3),
                      child: Text(
                        s.bstSavedHint,
                        style: HermesType.style(
                          HermesType.support,
                          colors.textSecondary,
                        ),
                      ),
                    ),
                    Wrap(
                      spacing: HermesSpace.x2,
                      runSpacing: HermesSpace.x3,
                      children: [
                        for (final item in items)
                          Builder(
                            builder: (tileContext) => StudioTile(
                              key: ValueKey('studio-mine-${item.id}'),
                              label: item.name,
                              extent: 72,
                              selected: item.character == current,
                              onTap: () => unawaited(_use(item.character)),
                              onLongPress: () =>
                                  unawaited(_savedMenu(tileContext, item)),
                              longPressLabel: s.bstMoreActions,
                              preview: Center(
                                child: CharacterFace(
                                  profileName: widget.profileName,
                                  character: item.character,
                                  size: 56,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  HermesSectionHeader(s.bstPresets),
                  Wrap(
                    spacing: HermesSpace.x2,
                    runSpacing: HermesSpace.x3,
                    children: [
                      for (final preset in botPresets)
                        StudioTile(
                          key: ValueKey('studio-preset-${preset.id}'),
                          label: studioPresetLabel(preset.id, s),
                          extent: 72,
                          selected: preset.character == current,
                          onTap: () => unawaited(_use(preset.character)),
                          preview: Center(
                            child: CharacterFace(
                              profileName: widget.profileName,
                              character: preset.character,
                              size: 56,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
          PositionedDirectional(
            end: HermesSpace.x4,
            bottom: HermesSpace.x6,
            child: StudioPill(
              key: const ValueKey('studio-customize'),
              label: s.bstCustomize,
              icon: Icons.brush_rounded,
              accent: true,
              onTap: () => unawaited(_customize()),
            ),
          ),
        ],
      ),
    );
  }
}
