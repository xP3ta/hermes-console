import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/component_profile.dart';
import '../theme/theme_profile.dart';
import '../theme/theme_profile_codec.dart';
import '../theme/theme_profile_derivation.dart';
import '../theme/theme_profile_store.dart';
import '../theme/theme_profile_validator.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/theme_color_picker.dart';

class ThemeStudioScreen extends StatefulWidget {
  final ThemeProfile initialProfile;
  final ThemeProfileStore store;
  final Future<void> Function()? onChanged;

  const ThemeStudioScreen({
    required this.initialProfile,
    required this.store,
    this.onChanged,
    super.key,
  });

  @override
  State<ThemeStudioScreen> createState() => _ThemeStudioScreenState();
}

class _ThemeStudioScreenState extends State<ThemeStudioScreen> {
  late ThemeProfile _profile;
  late final TextEditingController _name;
  ThemePalette? _darkPalette;
  ThemePalette? _lightPalette;
  bool _advanced = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Component skins remain in the file format for compatibility, but the
    // Android UI has one coherent component system.
    _profile = widget.initialProfile.copyWith(
      componentProfileId: ComponentProfiles.minimal.id,
    );
    if (_profile.brightness == ThemeProfileBrightness.dark) {
      _darkPalette = _profile.palette;
    } else {
      _lightPalette = _profile.palette;
    }
    _name = TextEditingController(text: _profile.name);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  ThemeProfile get _candidate => _profile.copyWith(name: _name.text.trim());

  ThemeBasicSeeds get _basicSeeds => ThemeBasicSeeds(
    background: _profile.palette.background,
    surface: _profile.palette.surface,
    accent: _profile.palette.accent,
    secondary: _profile.palette.secondary,
    textPrimary: _profile.palette.textPrimary,
  );

  void _setBasicColor(String token, Color color) {
    final current = _basicSeeds;
    final seeds = ThemeBasicSeeds(
      background: token == 'background' ? color : current.background,
      surface: token == 'surface' ? color : current.surface,
      accent: token == 'accent' ? color : current.accent,
      secondary: token == 'secondary' ? color : current.secondary,
      textPrimary: token == 'text_primary' ? color : current.textPrimary,
    );
    final derived = ThemeProfileDeriver.deriveBasicPalette(
      seeds,
      brightness: _profile.brightness,
    );
    setState(() {
      _profile = _profile.copyWith(
        palette: derived.palette,
        metadata: _profile.metadata.copyWith(
          derivationVersion: ThemeProfileDeriver.currentDerivationVersion,
        ),
      );
    });
  }

  void _setAdvancedColor(String token, Color color) {
    setState(() {
      _profile = _profile.copyWith(
        palette: _profile.palette.withToken(token, color),
      );
    });
  }

  void _setBrightness(ThemeProfileBrightness brightness) {
    if (brightness == _profile.brightness) return;

    if (_profile.brightness == ThemeProfileBrightness.dark) {
      _darkPalette = _profile.palette;
    } else {
      _lightPalette = _profile.palette;
    }

    final cached = brightness == ThemeProfileBrightness.dark
        ? _darkPalette
        : _lightPalette;
    final palette =
        cached ??
        ThemeProfileDeriver.deriveBasicPalette(
          ThemeProfileDeriver.adaptBasicSeedsForBrightness(
            _basicSeeds,
            brightness: brightness,
          ),
          brightness: brightness,
        ).palette;
    setState(() {
      _profile = _profile.copyWith(
        brightness: brightness,
        palette: palette,
        metadata: _profile.metadata.copyWith(
          derivationVersion: ThemeProfileDeriver.currentDerivationVersion,
        ),
      );
    });
  }

  Future<void> _pickColor(
    String token,
    String label, {
    required bool basic,
  }) async {
    final before = _profile;
    void preview(Color color) {
      if (!mounted) return;
      if (basic) {
        _setBasicColor(token, color);
      } else {
        _setAdvancedColor(token, color);
      }
    }

    final selected = await showHermesColorPicker(
      context,
      initialColor: _profile.palette.colorForToken(token),
      title: label,
      invalidFormatLabel: Strings.of(context).themesColorFormatError,
      onPreviewChanged: preview,
    );
    if (!mounted) return;
    if (selected == null) {
      setState(() => _profile = before);
      return;
    }
    preview(selected);
  }

  Future<void> _openPaletteEditor() async {
    var advanced = _advanced;
    await showHermesFloatingSurface<void>(
      context: context,
      surfaceKey: const ValueKey('theme-palette-editor-surface'),
      maxWidth: 680,
      maxHeightFactor: 0.82,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.68,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        Strings.of(context).themesBaseColors,
                        style: TextStyle(
                          color: Theme.of(context).hermes.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      key: const Key('theme_studio_mode'),
                      onPressed: () {
                        advanced = !advanced;
                        setSheetState(() {});
                      },
                      icon: Icon(
                        advanced ? Icons.palette_outlined : Icons.tune_rounded,
                        size: 17,
                      ),
                      label: Text(
                        advanced
                            ? Strings.of(context).themesBasic
                            : Strings.of(context).themesAdvanced,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: advanced
                        ? _advancedEditor(onUpdated: () => setSheetState(() {}))
                        : _basicEditor(onUpdated: () => setSheetState(() {})),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: Text(
                    MaterialLocalizations.of(context).closeButtonLabel,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() => _advanced = advanced);
  }

  Future<void> _repairContrast() async {
    final candidate = _candidate;
    final proposal = ThemeProfileValidator.proposeRepair(candidate);
    if (proposal.isEmpty) {
      if (!ThemeProfileValidator.validate(candidate).isActivatable) {
        _showMessage(Strings.of(context).themesRepairIncomplete);
      }
      return;
    }
    if (!proposal.isComplete) {
      _showMessage(Strings.of(context).themesRepairIncomplete);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(Strings.of(context).themesRepairTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(Strings.of(context).themesRepairBody),
              const SizedBox(height: 12),
              for (final change in proposal.changes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${change.token}: '
                    '${ThemeProfileCodec.colorToCanonical(change.from)} → '
                    '${ThemeProfileCodec.colorToCanonical(change.to)} '
                    '(${change.ratioBefore.toStringAsFixed(2)} → '
                    '${change.ratioAfter.toStringAsFixed(2)})',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      letterSpacing: 0,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(Strings.of(context).themesRepairApply),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final repaired = proposal.applyTo(candidate);
    final repairedValidation = ThemeProfileValidator.validate(repaired);
    if (!repairedValidation.isActivatable) {
      _showMessage(Strings.of(context).themesRepairIncomplete);
      return;
    }
    setState(() => _profile = repaired);
    _showMessage(Strings.of(context).themesRepairApplied);
  }

  Future<void> _save({required bool activate}) async {
    if (_busy) return;
    var candidate = _candidate;
    final validation = ThemeProfileValidator.validate(candidate);
    if (!validation.isDraftSavable) {
      _showMessage(Strings.of(context).themesInvalidFields);
      return;
    }
    if (activate && !validation.isActivatable) {
      _showMessage(Strings.of(context).themesUnsafeContrast);
      return;
    }
    candidate = candidate.copyWith(draft: !activate);
    setState(() => _busy = true);
    try {
      final saved = await widget.store.save(candidate);
      if (activate) {
        await widget.store.activate(saved.id);
      }
      await widget.onChanged?.call();
      if (!mounted) return;
      if (activate) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _profile = saved);
        _showMessage(Strings.of(context).themesDraftSaved);
      }
    } on ThemeProfileStoreException catch (error) {
      if (mounted) _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    HermesNotice.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final candidate = _candidate;
    final validation = ThemeProfileValidator.validate(candidate);
    final previewTheme = AppTheme.fromProfile(
      candidate,
      componentProfile: ComponentProfiles.minimal,
    );
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(strings.themesStudioTitle),
        titleTextStyle: TextStyle(
          color: Theme.of(context).hermes.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            sliver: SliverToBoxAdapter(
              child: _StudioCard(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  key: const Key('theme_studio_name'),
                  controller: _name,
                  maxLength: 48,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: strings.themesNameLabel,
                    counterText: '',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 9),
                  ),
                ),
              ),
            ),
          ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _ThemePreviewHeaderDelegate(
              theme: previewTheme,
              name: candidate.name.isEmpty
                  ? strings.themesStudioTitle
                  : candidate.name,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _PaletteSummary(
                  title: strings.themesBaseColors,
                  subtitle: strings.themesPaletteSubtitle,
                  colors: [
                    _profile.palette.background,
                    _profile.palette.surface,
                    _profile.palette.accent,
                    _profile.palette.secondary,
                    _profile.palette.textPrimary,
                  ],
                  onTap: _openPaletteEditor,
                ),
                const SizedBox(height: 16),
                _typographyAndBrightness(),
                const SizedBox(height: 18),
                _ContrastPanel(
                  validation: validation,
                  onRepair: _repairContrast,
                ),
                const SizedBox(height: 110),
              ]),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _StudioSaveBar(
        busy: _busy,
        canActivate: validation.isActivatable,
        onSaveDraft: () => _save(activate: false),
        onSaveActivate: () => _save(activate: true),
      ),
    );
  }

  Widget _basicEditor({VoidCallback? onUpdated}) {
    final s = Strings.of(context);
    final entries = <_ColorEntry>[
      _ColorEntry(
        'background',
        s.themesBackground,
        _profile.palette.background,
      ),
      _ColorEntry('surface', s.themesSurface, _profile.palette.surface),
      _ColorEntry('accent', s.themesAccent, _profile.palette.accent),
      _ColorEntry('secondary', s.themesSecondary, _profile.palette.secondary),
      _ColorEntry(
        'text_primary',
        s.themesPrimaryText,
        _profile.palette.textPrimary,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StudioSectionTitle(
          title: s.themesBaseColors,
          subtitle: s.themesPaletteSubtitle,
        ),
        const SizedBox(height: 12),
        _ColorGrid(
          entries: entries,
          onTap: (entry) async {
            await _pickColor(entry.token, entry.label, basic: true);
            onUpdated?.call();
          },
        ),
        const SizedBox(height: 9),
        Text(
          s.themesDerivedHint,
          style: TextStyle(
            color: Theme.of(context).hermes.textDisabled,
            fontSize: 11.5,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Widget _advancedEditor({VoidCallback? onUpdated}) {
    const tokens = [
      'background',
      'surface',
      'surface_variant',
      'accent',
      'accent_hover',
      'accent_text',
      'secondary',
      'on_accent',
      'text_primary',
      'text_secondary',
      'text_disabled',
      'error',
      'success',
      'warning',
      'divider',
    ];
    final s = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StudioSectionTitle(
          title: s.themesAllTokens,
          subtitle: s.themesAdvancedSubtitle,
        ),
        const SizedBox(height: 12),
        _ColorGrid(
          entries: [
            for (final token in tokens)
              _ColorEntry(
                token,
                token.replaceAll('_', ' '),
                _profile.palette.colorForToken(token),
              ),
          ],
          onTap: (entry) async {
            await _pickColor(entry.token, entry.label, basic: false);
            onUpdated?.call();
          },
        ),
      ],
    );
  }

  Widget _typographyAndBrightness() {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final fonts = ThemeProfileCodec.packagedFontFamilies.toList()
      ..sort((left, right) => _fontLabel(left).compareTo(_fontLabel(right)));
    final stackFont = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final fontDropdown = DropdownButtonHideUnderline(
      child: SizedBox(
        width: stackFont ? double.infinity : 164,
        child: DropdownButton<String>(
          key: ValueKey('theme_studio_font_${_profile.typography.fontFamily}'),
          value: _profile.typography.fontFamily,
          isExpanded: true,
          menuMaxHeight: 360,
          dropdownColor: colors.surface,
          borderRadius: BorderRadius.circular(14),
          icon: Icon(
            Icons.unfold_more_rounded,
            size: 17,
            color: colors.textSecondary,
          ),
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
          ),
          items: [
            for (final font in fonts)
              DropdownMenuItem(
                value: font,
                child: Text(
                  _fontLabel(font),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: font,
                    color: colors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0,
                  ),
                ),
              ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _profile = _profile.copyWith(
                typography: _profile.typography.copyWith(fontFamily: value),
              );
            });
          },
        ),
      ),
    );
    final fontLabel = Text(
      s.themesTypography,
      style: TextStyle(
        color: colors.textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StudioSectionTitle(
          title: s.themesVisualCharacter,
          subtitle: s.themesTypographySubtitle,
        ),
        const SizedBox(height: 10),
        _StudioCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: stackFont ? 8 : 0,
                ),
                child: stackFont
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          fontLabel,
                          const SizedBox(height: 2),
                          fontDropdown,
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: fontLabel),
                          const SizedBox(width: 12),
                          fontDropdown,
                        ],
                      ),
              ),
              Divider(height: 1, color: colors.divider.withValues(alpha: 0.5)),
              Padding(
                padding: const EdgeInsets.all(10),
                child: _BrightnessSelector(
                  value: _profile.brightness,
                  darkLabel: s.themesDarkChoice,
                  lightLabel: s.themesLightChoice,
                  onChanged: _setBrightness,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _fontLabel(String family) => switch (family) {
    'JetBrainsMono' => 'JetBrains Mono',
    _ => family,
  };
}

class _PaletteSummary extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Color> colors;
  final VoidCallback onTap;

  const _PaletteSummary({
    required this.title,
    required this.subtitle,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final themeColors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: title,
      hint: subtitle,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('theme_studio_palette'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: _StudioCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: themeColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _StudioPaletteBar(colors: colors),
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: themeColors.textSecondary,
                          fontSize: 11,
                          height: 1.3,
                          letterSpacing: 0,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: themeColors.textDisabled,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StudioPaletteBar extends StatelessWidget {
  final List<Color> colors;

  const _StudioPaletteBar({required this.colors});

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).hermes.divider;
    return Container(
      height: 14,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: divider.withValues(alpha: 0.72)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          for (final color in colors)
            Expanded(
              child: ColoredBox(color: color, child: const SizedBox.expand()),
            ),
        ],
      ),
    );
  }
}

class _StudioSectionTitle extends StatelessWidget {
  final String title;
  final String subtitle;

  const _StudioSectionTitle({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: 11.5,
            height: 1.35,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _StudioCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _StudioCard({
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.divider.withValues(alpha: 0.48)),
      ),
      child: child,
    );
  }
}

class _ColorEntry {
  final String token;
  final String label;
  final Color color;

  const _ColorEntry(this.token, this.label, this.color);
}

class _ColorGrid extends StatelessWidget {
  final List<_ColorEntry> entries;
  final ValueChanged<_ColorEntry> onTap;

  const _ColorGrid({required this.entries, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return _StudioCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var index = 0; index < entries.length; index++) ...[
            _ColorTile(
              entry: entries[index],
              onTap: () => onTap(entries[index]),
            ),
            if (index != entries.length - 1)
              Divider(
                height: 1,
                indent: 14,
                endIndent: 14,
                color: colors.divider.withValues(alpha: 0.42),
              ),
          ],
        ],
      ),
    );
  }
}

class _ColorTile extends StatelessWidget {
  final _ColorEntry entry;
  final VoidCallback onTap;

  const _ColorTile({required this.entry, required this.onTap});

  String get _displayHex {
    final canonical = ThemeProfileCodec.colorToCanonical(entry.color);
    return canonical.startsWith('#FF')
        ? '#${canonical.substring(3)}'
        : canonical;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: entry.label,
      value: ThemeProfileCodec.colorToCanonical(entry.color),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('theme_color_${entry.token}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 92,
                  child: Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                Expanded(child: _ColorRibbon(color: entry.color)),
                const SizedBox(width: 10),
                Text(
                  _displayHex,
                  style: TextStyle(
                    color: colors.textDisabled,
                    fontSize: 10,
                    fontFamily: 'monospace',
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 17,
                  color: colors.textDisabled,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorRibbon extends StatelessWidget {
  final Color color;

  const _ColorRibbon({required this.color});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final hsv = HSVColor.fromColor(color);
    return Container(
      height: 18,
      constraints: const BoxConstraints(minWidth: 54, maxWidth: 120),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            hsv
                .withSaturation(
                  (hsv.saturation * 0.42).clamp(0.0, 1.0).toDouble(),
                )
                .toColor(),
            color,
            hsv
                .withValue((hsv.value * 0.66).clamp(0.0, 1.0).toDouble())
                .toColor(),
          ],
        ),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: colors.divider.withValues(alpha: 0.72)),
      ),
    );
  }
}

class _BrightnessSelector extends StatelessWidget {
  final ThemeProfileBrightness value;
  final String darkLabel;
  final String lightLabel;
  final ValueChanged<ThemeProfileBrightness> onChanged;

  const _BrightnessSelector({
    required this.value,
    required this.darkLabel,
    required this.lightLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _BrightnessOption(
            key: const Key('theme_studio_brightness_dark'),
            label: darkLabel,
            icon: Icons.dark_mode_rounded,
            selected: value == ThemeProfileBrightness.dark,
            onTap: () => onChanged(ThemeProfileBrightness.dark),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _BrightnessOption(
            key: const Key('theme_studio_brightness_light'),
            label: lightLabel,
            icon: Icons.light_mode_rounded,
            selected: value == ThemeProfileBrightness.light,
            onTap: () => onChanged(ThemeProfileBrightness.light),
          ),
        ),
      ],
    );
  }
}

class _BrightnessOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _BrightnessOption({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 170),
          constraints: const BoxConstraints(minHeight: 38),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? colors.accent.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? colors.accentHover : colors.textSecondary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? colors.textPrimary : colors.textSecondary,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContrastPanel extends StatelessWidget {
  final ThemeValidationResult validation;
  final VoidCallback onRepair;

  const _ContrastPanel({required this.validation, required this.onRepair});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final ready = validation.contrastFailures.isEmpty;
    final tone = ready ? colors.success : colors.warning;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tone.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(
            ready ? Icons.check_circle_outline_rounded : Icons.contrast_rounded,
            size: 18,
            color: tone,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              ready
                  ? strings.themesContrastReady
                  : strings.themesContrastPending(
                      validation.contrastFailures.length,
                    ),
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 11.5,
                height: 1.3,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
              ),
            ),
          ),
          if (!ready)
            TextButton(
              key: const Key('theme_studio_repair'),
              onPressed: onRepair,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 40),
                padding: const EdgeInsets.symmetric(horizontal: 9),
              ),
              child: Text(
                strings.themesProposeRepair,
                style: const TextStyle(fontSize: 11.5, letterSpacing: 0),
              ),
            ),
        ],
      ),
    );
  }
}

class _StudioSaveBar extends StatelessWidget {
  final bool busy;
  final bool canActivate;
  final VoidCallback onSaveDraft;
  final VoidCallback onSaveActivate;

  const _StudioSaveBar({
    required this.busy,
    required this.canActivate,
    required this.onSaveDraft,
    required this.onSaveActivate,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final stack = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final draft = TextButton(
      key: const Key('theme_studio_save_draft'),
      onPressed: busy ? null : onSaveDraft,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      child: Text(
        Strings.of(context).themesSaveDraft,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13, letterSpacing: 0),
      ),
    );
    final activate = FilledButton(
      key: const Key('theme_studio_save_activate'),
      onPressed: busy || !canActivate ? null : onSaveActivate,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(
        Strings.of(context).themesSaveActivate,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13, letterSpacing: 0),
      ),
    );
    return Material(
      color: colors.surface.withValues(alpha: 0.97),
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 7, 16, 9),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: colors.divider.withValues(alpha: 0.65)),
            ),
          ),
          child: stack
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: double.infinity, child: activate),
                    const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: draft),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(child: draft),
                    const SizedBox(width: 8),
                    Flexible(child: activate),
                  ],
                ),
        ),
      ),
    );
  }
}

class _ThemePreviewHeaderDelegate extends SliverPersistentHeaderDelegate {
  final ThemeData theme;
  final String name;

  const _ThemePreviewHeaderDelegate({required this.theme, required this.name});

  @override
  double get minExtent => 72;

  @override
  double get maxExtent => 144;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final compact = shrinkOffset > 34;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, compact ? 5 : 7, 16, 7),
        child: _ThemePreview(
          theme: theme,
          name: name,
          compact: compact,
          elevated: overlapsContent,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_ThemePreviewHeaderDelegate oldDelegate) => true;
}

class _ThemePreview extends StatelessWidget {
  final ThemeData theme;
  final String name;
  final bool compact;
  final bool elevated;

  const _ThemePreview({
    required this.theme,
    required this.name,
    required this.compact,
    required this.elevated,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Semantics(
      container: true,
      label: strings.themesLivePreview,
      child: Theme(
        data: theme,
        child: Builder(
          builder: (previewContext) {
            final colors = Theme.of(previewContext).hermes;
            final bodyStyle =
                Theme.of(previewContext).textTheme.bodyMedium ??
                TextStyle(color: colors.textPrimary);
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                // This is a miniature visual canvas, not primary reading
                // content. Fixed scaling keeps it representative while every
                // real control outside remains fully accessible.
                textScaler: const TextScaler.linear(1),
              ),
              child: DefaultTextStyle(
                style: bodyStyle.copyWith(color: colors.textPrimary),
                child: AnimatedContainer(
                  key: const Key('theme_studio_preview'),
                  duration: const Duration(milliseconds: 190),
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.all(compact ? 10 : 11),
                  decoration: BoxDecoration(
                    color: colors.background,
                    borderRadius: BorderRadius.circular(compact ? 15 : 17),
                    border: Border.all(
                      color: colors.divider.withValues(alpha: 0.72),
                    ),
                    boxShadow: [
                      if (elevated)
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                    ],
                  ),
                  child: compact
                      ? _CompactPreview(name: name)
                      : _FullPreview(name: name),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CompactPreview extends StatelessWidget {
  final String name;

  const _CompactPreview({required this.name});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Row(
      children: [
        SizedBox(
          width: 78,
          child: _StudioPaletteBar(
            colors: [
              colors.background,
              colors.surface,
              colors.accent,
              colors.secondary,
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ),
      ],
    );
  }
}

class _FullPreview extends StatelessWidget {
  final String name;

  const _FullPreview({required this.name});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Column(
      children: [
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 12,
                color: colors.accentText,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ),
            SizedBox(
              width: 58,
              child: _StudioPaletteBar(
                colors: [colors.surface, colors.accent, colors.secondary],
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Row(
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 11,
                color: colors.accentText,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                strings.themesPreviewAssistant,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 10.5,
                  letterSpacing: 0,
                ),
              ),
            ),
            const SizedBox(width: 7),
            Container(
              constraints: const BoxConstraints(maxWidth: 120),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                strings.themesPreviewUser,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 9.5,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ),
        const Spacer(),
        Container(
          height: 31,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.divider),
          ),
          child: Row(
            children: [
              Icon(Icons.add_rounded, size: 14, color: colors.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  strings.themesPreviewInput,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textDisabled,
                    fontSize: 9.5,
                    letterSpacing: 0,
                  ),
                ),
              ),
              Container(
                width: 21,
                height: 21,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(
                  Icons.arrow_upward_rounded,
                  size: 12,
                  color: colors.onAccent,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
