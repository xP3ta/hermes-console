import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../theme/app_theme.dart';
import '../theme/component_profile.dart';
import '../theme/theme_profile.dart';
import '../theme/theme_profile_adapter.dart';
import '../theme/theme_profile_codec.dart';
import '../theme/theme_profile_store.dart';
import '../theme/theme_profile_validator.dart';
import '../theme/theme_tagline.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import 'theme_studio_screen.dart';
import '../design/hermes_design.dart'
    show
        HermesAction,
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesMenuButton,
        showHermesDialog;
import '../feedback/feedback_policy.dart';

@visibleForTesting
Future<Uint8List> readThemeImportBytes(PlatformFile selected) async {
  if (selected.size > ThemeProfileCodec.maxBytes) {
    throw const ThemeProfileCodecException(
      'payload_too_large',
      'Theme payload exceeds 64 KiB',
    );
  }

  final eagerBytes = selected.bytes;
  if (eagerBytes != null) {
    if (eagerBytes.length > ThemeProfileCodec.maxBytes) {
      throw const ThemeProfileCodecException(
        'payload_too_large',
        'Theme payload exceeds 64 KiB',
      );
    }
    return eagerBytes;
  }

  final stream = selected.readStream;
  if (stream != null) return _readBoundedThemeBytes(stream);

  final path = selected.path;
  if (path != null) {
    final file = File(path);
    if (await file.length() > ThemeProfileCodec.maxBytes) {
      throw const ThemeProfileCodecException(
        'payload_too_large',
        'Theme payload exceeds 64 KiB',
      );
    }
    return _readBoundedThemeBytes(
      file.openRead(0, ThemeProfileCodec.maxBytes + 1),
    );
  }

  throw const ThemeProfileStoreException(
    'file_unreadable',
    'The selected theme could not be read',
  );
}

Future<Uint8List> _readBoundedThemeBytes(Stream<List<int>> stream) async {
  final output = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in stream) {
    length += chunk.length;
    if (length > ThemeProfileCodec.maxBytes) {
      throw const ThemeProfileCodecException(
        'payload_too_large',
        'Theme payload exceeds 64 KiB',
      );
    }
    output.add(chunk);
  }
  return output.takeBytes();
}

typedef ThemeSelectCallback =
    Future<void> Function(String id, {bool followSystem});

class ThemesScreen extends StatefulWidget {
  const ThemesScreen({
    super.key,
    this.snapshotForTesting,
    this.onSelectForTesting,
  });

  /// Tests drive the screen without a running [HermesApp].
  @visibleForTesting
  final ThemeProfileStoreSnapshot? snapshotForTesting;
  @visibleForTesting
  final ThemeSelectCallback? onSelectForTesting;

  @override
  State<ThemesScreen> createState() => _ThemesScreenState();
}

class _ThemesScreenState extends State<ThemesScreen> {
  bool _busy = false;

  HermesAppState? get _root =>
      context.findAncestorStateOfType<HermesAppState>();
  bool get _es => Localizations.localeOf(context).languageCode == 'es';
  String _t(String es, String en) => _es ? es : en;

  Future<void> _select(String id, {bool followSystem = false}) async {
    final testSelect = widget.onSelectForTesting;
    if (testSelect != null) {
      await testSelect(id, followSystem: followSystem);
      return;
    }
    final root = _root;
    if (root == null || _busy) return;
    setState(() => _busy = true);
    try {
      await root.setThemeId(id, followSystem: followSystem);
    } on ThemeProfileStoreException catch (error) {
      _message(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openStudio(ThemeProfile profile) async {
    final root = _root;
    if (root == null) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ThemeStudioScreen(
          initialProfile: profile,
          store: root.themeProfileStore,
          onChanged: () => root.refreshThemeProfiles(force: true),
        ),
      ),
    );
    if (mounted) await root.refreshThemeProfiles(force: true);
  }

  Future<void> _createTheme(ThemeProfileStoreSnapshot snapshot) async {
    final custom = snapshot.customById(snapshot.activeProfileId);
    final ThemeProfile base;
    if (custom != null) {
      base = custom.copyWith(
        id: const Uuid().v4(),
        name: _copyName(custom.name),
        source: ThemeProfileSource.custom,
        draft: true,
      );
    } else {
      base = ThemeProfileAdapter.duplicatePreset(
        AppTheme.presetById(snapshot.activeProfileId),
        id: const Uuid().v4(),
        name: _copyName(AppTheme.presetById(snapshot.activeProfileId).name),
      ).copyWith(draft: true);
    }
    await _openStudio(base);
  }

  String _copyName(String name) {
    final suffix = Strings.of(context).themesCopySuffix;
    final room = 48 - suffix.runes.length;
    return '${String.fromCharCodes(name.runes.take(room))}$suffix';
  }

  Future<void> _duplicate(ThemeProfile profile) async {
    await _openStudio(
      profile.copyWith(
        id: const Uuid().v4(),
        name: _copyName(profile.name),
        source: ThemeProfileSource.custom,
        draft: true,
      ),
    );
  }

  Future<void> _delete(ThemeProfile profile) async {
    final root = _root;
    if (root == null) return;
    final confirmed = await showHermesDialog<bool>(
      context: context,
      title: Strings.of(context).themesDeleteTitle,
      message: Strings.of(context).themesDeleteBody(profile.name),
      actions: [
        HermesDialogAction(
          label: MaterialLocalizations.of(context).cancelButtonLabel,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          label: Strings.of(context).themesDeleteAction,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    if (confirmed != true) return;
    await root.themeProfileStore.delete(profile.id);
    await root.refreshThemeProfiles(force: true);
  }

  Future<void> _export(ThemeProfile profile) async {
    try {
      final raw = ThemeProfileCodec.encode(profile);
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/${profile.id}.hermes-theme.json');
      await file.writeAsString(raw, flush: true);
      await Share.shareXFiles([
        XFile(
          file.path,
          mimeType: 'application/vnd.xpetalab.hermes-theme+json',
        ),
      ]);
    } on Object {
      if (mounted) {
        _message(_t('No se pudo exportar.', 'Could not export.'));
      }
    }
  }

  Future<void> _importTheme() async {
    final root = _root;
    if (root == null || _busy) return;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: false,
        withReadStream: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final selected = picked.files.single;
      final bytes = await readThemeImportBytes(selected);
      final decoded = ThemeProfileCodec.decodeBytes(bytes);
      final validation = ThemeProfileValidator.validate(decoded.profile);
      if (!mounted) return;
      final confirmed = await showHermesDialog<bool>(
        context: context,
        title: Strings.of(context).themesImport,
        message: [
          decoded.profile.name,
          validation.isActivatable
              ? Strings.of(context).themesImportValid
              : Strings.of(context).themesImportDraft,
          if (decoded.warnings.isNotEmpty)
            Strings.of(context).themesImportFallbacks(decoded.warnings.length),
        ].join('\n\n'),
        actions: [
          HermesDialogAction(
            label: MaterialLocalizations.of(context).cancelButtonLabel,
            value: false,
            style: HermesDialogActionStyle.cancel,
          ),
          HermesDialogAction(
            label: Strings.of(context).themesImport,
            value: true,
          ),
        ],
      );
      if (confirmed != true || !mounted) return;
      final raw = utf8.decode(bytes, allowMalformed: false);
      try {
        await root.themeProfileStore.importProfile(raw);
      } on ThemeProfileStoreException catch (error) {
        if (error.code != 'profile_limit' || !mounted) rethrow;
        final replaceId = await _chooseReplacement(
          root.themeProfiles.value.customProfiles,
        );
        if (replaceId == null) return;
        await root.themeProfileStore.importProfile(raw, replaceId: replaceId);
      }
      await root.refreshThemeProfiles(force: true);
      if (mounted) {
        _message(Strings.of(context).themesImported, FeedbackKind.routine);
      }
    } on UnsupportedThemeSchemaException {
      if (mounted) {
        _message(Strings.of(context).themesFutureSchema);
      }
    } on ThemeProfileCodecException catch (error) {
      if (mounted) _message(error.message);
    } on ThemeProfileStoreException catch (error) {
      if (mounted) _message(error.message);
    } on FormatException {
      if (mounted) {
        _message(Strings.of(context).themesInvalidUtf8);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _chooseReplacement(List<ThemeProfile> profiles) {
    return showHermesFloatingSurface<String>(
      context: context,
      surfaceKey: const ValueKey('theme-replacement-surface'),
      maxWidth: 480,
      maxHeightFactor: 0.82,
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        children: [
          ListTile(
            title: Text(Strings.of(context).themesLimitTitle),
            subtitle: Text(Strings.of(context).themesLimitBody),
          ),
          for (final profile in profiles)
            ListTile(
              leading: Icon(
                Icons.palette_outlined,
                color: ThemeProfileAdapter.colorsFromProfile(profile).accent,
              ),
              title: Text(profile.name),
              onTap: () => Navigator.of(sheetContext).pop(profile.id),
            ),
        ],
      ),
    );
  }

  void _message(String message, [FeedbackKind kind = FeedbackKind.error]) {
    AppFeedback.notify(context, kind, message);
  }

  @override
  Widget build(BuildContext context) {
    final testSnapshot = widget.snapshotForTesting;
    if (testSnapshot != null) return _buildScreen(testSnapshot);
    final root = _root;
    final fallback = ThemeProfileStoreSnapshot(
      customProfiles: const [],
      activeProfileId: AppTheme.defaultThemeId,
      activeComponentProfileId: ComponentProfiles.minimal.id,
    );
    if (root == null) return _buildScreen(fallback);
    return ValueListenableBuilder<ThemeProfileStoreSnapshot>(
      valueListenable: root.themeProfiles,
      builder: (_, snapshot, child) => _buildScreen(snapshot),
    );
  }

  Widget _buildScreen(ThemeProfileStoreSnapshot snapshot) {
    // One row per family (light + dark variant behind a mode selector):
    // Console's own families first, then the Hermes Desktop catalogue.
    Map<String, List<HermesThemePreset>> families({required bool desktop}) {
      final grouped = <String, List<HermesThemePreset>>{};
      for (final preset in AppTheme.presets) {
        if (preset.desktopOfficial != desktop) continue;
        grouped.putIfAbsent(preset.familyId, () => []).add(preset);
      }
      return grouped;
    }

    final consoleFamilies = families(desktop: false);
    final desktopFamilies = families(desktop: true);
    final activeCustom = snapshot.customById(snapshot.activeProfileId);
    final activeName =
        activeCustom?.name ??
        AppTheme.presetById(snapshot.activeProfileId).name;
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(Strings.of(context).themesTitle),
        actions: [
          IconButton(
            key: const Key('themes_create'),
            tooltip: Strings.of(context).themesCreate,
            onPressed: _busy ? null : () => _createTheme(snapshot),
            icon: const Icon(Icons.add_rounded),
          ),
          IconButton(
            key: const Key('themes_import'),
            tooltip: Strings.of(context).themesImport,
            onPressed: _busy ? null : _importTheme,
            icon: const Icon(Icons.file_download_outlined),
          ),
        ],
      ),
      body: ListView(
        clipBehavior: hermesUnderHeader,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _Intro(activeName: activeName),
          const SizedBox(height: 20),
          _SectionLabel(
            '${Strings.of(context).themesMyThemes} · '
            '${snapshot.customProfiles.length}',
          ),
          const SizedBox(height: 7),
          if (snapshot.customProfiles.isEmpty)
            HermesInfoBanner(
              Strings.of(context).themesEmptyCustom,
              icon: Icons.palette_outlined,
            )
          else
            _customGrid(snapshot.customProfiles, snapshot.activeProfileId),
          const SizedBox(height: 22),
          _SectionLabel(
            Strings.of(context).themesConsoleSection(consoleFamilies.length),
          ),
          const SizedBox(height: 8),
          _familyList(consoleFamilies, snapshot, 'console'),
          const SizedBox(height: 20),
          _SectionLabel(
            Strings.of(context).themesDesktopSection(desktopFamilies.length),
          ),
          const SizedBox(height: 7),
          _familyList(desktopFamilies, snapshot, 'desktop'),
        ],
      ),
    );
  }

  Widget _familyList(
    Map<String, List<HermesThemePreset>> families,
    ThemeProfileStoreSnapshot snapshot,
    String section,
  ) {
    final entries = families.entries.toList(growable: false);
    return Column(
      children: [
        for (var index = 0; index < entries.length; index++) ...[
          _ThemeFamilyRow(
            section: section,
            family: entries[index].key,
            variants: entries[index].value,
            activeId: snapshot.activeProfileId,
            followSystem: snapshot.followSystem,
            onSelect: _select,
          ),
          if (index != entries.length - 1)
            Divider(
              height: 1,
              color: Theme.of(context).hermes.divider.withValues(alpha: 0.55),
            ),
        ],
      ],
    );
  }

  Widget _customGrid(List<ThemeProfile> profiles, String activeId) {
    return Column(
      children: [
        for (var index = 0; index < profiles.length; index++) ...[
          _CustomThemeCard(
            profile: profiles[index],
            selected: profiles[index].id == activeId,
            onTap: profiles[index].draft
                ? () => _openStudio(profiles[index])
                : () => _select(profiles[index].id),
            onEdit: () => _openStudio(profiles[index]),
            onDuplicate: () => _duplicate(profiles[index]),
            onExport: () => _export(profiles[index]),
            onDelete: () => _delete(profiles[index]),
          ),
          if (index != profiles.length - 1)
            Divider(
              height: 1,
              color: Theme.of(context).hermes.divider.withValues(alpha: 0.55),
            ),
        ],
      ],
    );
  }
}

class _Intro extends StatelessWidget {
  final String activeName;
  const _Intro({required this.activeName});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_rounded, size: 16, color: colors.accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text.rich(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  TextSpan(
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: colors.textSecondary,
                    ),
                    children: [
                      TextSpan(text: Strings.of(context).themesActivePrefix),
                      TextSpan(
                        text: activeName,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) =>
      HermesSectionHeader(text, padding: const EdgeInsets.only(bottom: 8));
}

/// One theme family: a small swatch of the variant in use (or the dark one)
/// and a Light/Dark selector, the same for Console and Desktop families.
class _ThemeFamilyRow extends StatelessWidget {
  const _ThemeFamilyRow({
    required this.section,
    required this.family,
    required this.variants,
    required this.activeId,
    required this.followSystem,
    required this.onSelect,
  });

  /// `console` or `desktop`; part of the selector keys.
  final String section;
  final String family;
  final List<HermesThemePreset> variants;
  final String activeId;

  /// "Auto" is on for the active theme.
  final bool followSystem;
  final ThemeSelectCallback onSelect;

  HermesThemePreset? _variant(Brightness brightness) {
    for (final preset in variants) {
      if (preset.brightness == brightness) return preset;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final light = _variant(Brightness.light);
    final dark = _variant(Brightness.dark);
    final preview = variants.firstWhere(
      (preset) => preset.id == activeId,
      orElse: () => dark ?? light ?? variants.first,
    );
    final title = variants.first.name;
    final activeHere = variants.any((preset) => preset.id == activeId);
    final auto = followSystem && activeHere;
    Widget controls({required bool showLabels}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (light != null)
          _ThemeModeButton(
            key: ValueKey('$section-theme-$family-light'),
            icon: Icons.light_mode_outlined,
            label: Strings.of(context).themesLightChoice,
            showLabel: showLabels,
            selected: !auto && activeId == light.id,
            onTap: () => onSelect(light.id),
          ),
        if (light != null && dark != null) const SizedBox(width: 4),
        if (dark != null)
          _ThemeModeButton(
            key: ValueKey('$section-theme-$family-dark'),
            icon: Icons.dark_mode_outlined,
            label: Strings.of(context).themesDarkChoice,
            showLabel: showLabels,
            selected: !auto && activeId == dark.id,
            onTap: () => onSelect(dark.id),
          ),
        if (light != null && dark != null) ...[
          const SizedBox(width: 4),
          _ThemeModeButton(
            key: ValueKey('$section-theme-$family-auto'),
            icon: Icons.brightness_auto_outlined,
            label: Strings.of(context).themesAutoChoice,
            showLabel: showLabels,
            selected: auto,
            onTap: () => onSelect(
              MediaQuery.platformBrightnessOf(context) == Brightness.light
                  ? light.id
                  : dark.id,
              followSystem: true,
            ),
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final largeText = MediaQuery.textScalerOf(context).scale(12) >= 18;
          // Three segments (Light, Dark, Auto) fit beside the name only on
          // wide screens; phones put them under it.
          final stacked = constraints.maxWidth < 400 || largeText;
          final identity = Row(
            children: [
              _ThemeSwatch(colors: preview.colors),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      themeTagline(Strings.of(context), preview),
                      maxLines: stacked ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 10.5,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                identity,
                const SizedBox(height: 7),
                Align(
                  alignment: Alignment.centerRight,
                  child: controls(showLabels: !largeText),
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: identity),
              const SizedBox(width: 8),
              controls(showLabels: true),
            ],
          );
        },
      ),
    );
  }
}

class _ThemeModeButton extends StatelessWidget {
  const _ThemeModeButton({
    super.key,
    required this.icon,
    required this.label,
    this.showLabel = true,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool showLabel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 42),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? colors.accent.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected
                  ? colors.accent.withValues(alpha: 0.55)
                  : colors.divider.withValues(alpha: 0.65),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? colors.accent : colors.textSecondary,
              ),
              if (showLabel) ...[
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? colors.textPrimary : colors.textSecondary,
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({required this.colors});

  final HermesThemeColors colors;

  @override
  Widget build(BuildContext context) => Container(
    width: 34,
    height: 34,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: colors.background,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: colors.divider),
    ),
    child: Align(
      alignment: Alignment.bottomRight,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: colors.accent, shape: BoxShape.circle),
      ),
    ),
  );
}

enum _CustomThemeAction { edit, duplicate, export, delete }

class _CustomThemeCard extends StatelessWidget {
  final ThemeProfile profile;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  const _CustomThemeCard({
    required this.profile,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDuplicate,
    required this.onExport,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ThemeProfileAdapter.colorsFromProfile(profile);
    final appColors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      selected: selected,
      label: profile.name,
      child: InkWell(
        key: Key('custom_theme_${profile.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 9, 0, 9),
          child: Row(
            children: [
              _ThemeSwatch(colors: colors),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: appColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      profile.draft
                          ? Strings.of(context).themesDraft
                          : profile.brightness == ThemeProfileBrightness.dark
                          ? Strings.of(context).themesDarkChoice
                          : Strings.of(context).themesLightChoice,
                      style: TextStyle(
                        color: profile.draft
                            ? appColors.warning
                            : appColors.textSecondary,
                        fontSize: 10.5,
                        height: 1.25,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(
                    Icons.check_rounded,
                    size: 19,
                    color: appColors.accent,
                  ),
                ),
              SizedBox(
                width: 40,
                height: 48,
                child: HermesMenuButton<_CustomThemeAction>(
                  tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  iconColor: appColors.textSecondary,
                  onSelected: (action) {
                    switch (action) {
                      case _CustomThemeAction.edit:
                        onEdit();
                      case _CustomThemeAction.duplicate:
                        onDuplicate();
                      case _CustomThemeAction.export:
                        onExport();
                      case _CustomThemeAction.delete:
                        onDelete();
                    }
                  },
                  actions: (context) => [
                    HermesAction(
                      value: _CustomThemeAction.edit,
                      label: Strings.of(context).themesEdit,
                    ),
                    HermesAction(
                      value: _CustomThemeAction.duplicate,
                      label: Strings.of(context).themesDuplicate,
                    ),
                    HermesAction(
                      value: _CustomThemeAction.export,
                      label: Strings.of(context).themesExport,
                    ),
                    HermesAction(
                      value: _CustomThemeAction.delete,
                      label: Strings.of(context).themesDeleteAction,
                      destructive: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
