import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../characters/bot_motion.dart';
import '../feedback/haptics.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../theme/look_feel.dart';
import '../theme/theme_contrast.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_theme_reveal.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/theme_color_picker.dart';
import 'themes_screen.dart';

/// Look & Feel: the short list of appearance choices (mode, accent, light and
/// dark background, font) with the effect on the whole app at once. The 42
/// themes of the catalogue live one level down, in «Más temas».
///
/// The rule between the two: a theme chosen in «Más temas» is in force and
/// this screen says so («Tema: X» with a button back); touching Appearance,
/// Accent or Background puts the derived Look & Feel in force again.
class LookFeelScreen extends StatefulWidget {
  const LookFeelScreen({
    super.key,
    this.prefsForTesting,
    this.fontIdForTesting,
    this.onFontForTesting,
  });

  /// Tests drive the screen without a running [HermesApp].
  @visibleForTesting
  final LookFeelPrefs? prefsForTesting;
  @visibleForTesting
  final ValueNotifier<String>? fontIdForTesting;
  @visibleForTesting
  final Future<void> Function(String id)? onFontForTesting;

  @override
  State<LookFeelScreen> createState() => _LookFeelScreenState();
}

/// The name of the background of [settings] in [brightness] (the summary
/// line of Look & Feel in Settings).
String lookFeelBackgroundName(
  Strings strings,
  LookFeelSettings settings,
  Brightness brightness,
) => brightness == Brightness.light
    ? switch (settings.lightBackground) {
        LookLightBackground.white => strings.lflBgWhite,
        LookLightBackground.paper => strings.lflBgPaper,
      }
    : switch (settings.darkBackground) {
        LookDarkBackground.midnight => strings.lflBgMidnight,
        LookDarkBackground.black => strings.lflBgBlack,
        LookDarkBackground.gray => strings.lflBgGray,
      };

class _LookFeelScreenState extends State<LookFeelScreen> {
  final ValueNotifier<String> _fallbackFont = ValueNotifier(AppFonts.defaultId);

  HermesAppState? get _root =>
      context.findAncestorStateOfType<HermesAppState>();

  LookFeelPrefs? get _prefs => widget.prefsForTesting ?? _root?.lookFeel;

  ValueNotifier<String> get _fontId =>
      widget.fontIdForTesting ?? _root?.fontId ?? _fallbackFont;

  @override
  void dispose() {
    _fallbackFont.dispose();
    super.dispose();
  }

  /// Applies a change with the circle reveal (none with reduced motion).
  Future<void> _apply(Future<void> Function() change) {
    HermesHaptics.selection();
    return HermesThemeReveal.run(context, change);
  }

  Future<void> _pickFont(String id) async {
    HermesHaptics.selection();
    final custom = widget.onFontForTesting;
    if (custom != null) return custom(id);
    await _root?.setFontId(id);
  }

  Future<void> _pickCustomAccent(LookFeelPrefs prefs) async {
    final strings = Strings.of(context);
    // No live preview into the app: the whole app would rebuild on every
    // frame of the drag. The colour is applied once, when it is confirmed.
    final color = await showHermesColorPicker(
      context,
      initialColor: prefs.settings.customAccent,
      title: strings.lflAccentPickerTitle,
      invalidFormatLabel: strings.themesColorFormatError,
    );
    if (color == null || !mounted) return;
    await _apply(() => prefs.setCustomAccent(color));
  }

  void _openMoreThemes() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ThemesScreen()));
  }

  /// Name of the theme in force when it is one of the list.
  String _listThemeName() {
    final snapshot = _root?.themeProfiles.value;
    if (snapshot == null) return AppTheme.presetById(null).name;
    return snapshot.customById(snapshot.activeProfileId)?.name ??
        AppTheme.presetById(snapshot.activeProfileId).name;
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    final root = _root;
    return ListenableBuilder(
      listenable: Listenable.merge([
        ?prefs,
        ?root?.themeProfiles,
        BotMotionPrefs.shared,
        HapticPrefs.shared,
        _fontId,
      ]),
      builder: (context, _) =>
          _buildScreen(context, prefs?.settings ?? const LookFeelSettings()),
    );
  }

  Widget _buildScreen(BuildContext context, LookFeelSettings settings) {
    final strings = Strings.of(context);
    final prefs = _prefs;
    final inForce = settings.derived;
    // The brightness in view: the appearance, or the system's when it is
    // followed (a live dependency, so a system switch while the screen is
    // open moves the screen too). Only the background of that brightness is
    // offered; the other choice stays stored and comes back with it.
    final brightness = settings.resolveBrightness(
      MediaQuery.platformBrightnessOf(context),
    );
    return Scaffold(
      appBar: HermesAppBar(title: Text(strings.lflTitle)),
      body: ListView(
        clipBehavior: hermesUnderHeader,
        padding: const EdgeInsets.fromLTRB(
          HermesSpace.pageH,
          HermesSpace.x2,
          HermesSpace.pageH,
          HermesSpace.x8,
        ),
        children: [
          if (!inForce && prefs != null)
            _ListThemeBanner(
              name: _listThemeName(),
              onReturn: () => _apply(prefs.returnToLookFeel),
            ),
          HermesSectionHeader(strings.lflAppearance),
          HermesSegmentedControl<LookAppearance>(
            key: const ValueKey('lfl-appearance'),
            semanticLabel: strings.lflAppearance,
            value: settings.appearance,
            segments: [
              HermesSegment(
                key: const ValueKey('lfl-appearance-system'),
                value: LookAppearance.system,
                label: strings.lflAppearanceSystem,
              ),
              HermesSegment(
                key: const ValueKey('lfl-appearance-light'),
                value: LookAppearance.light,
                label: strings.lflAppearanceLight,
              ),
              HermesSegment(
                key: const ValueKey('lfl-appearance-dark'),
                value: LookAppearance.dark,
                label: strings.lflAppearanceDark,
              ),
            ],
            onChanged: (value) {
              if (prefs != null) _apply(() => prefs.setAppearance(value));
            },
          ),
          HermesSectionHeader(strings.lflAccent),
          _AccentGrid(
            settings: settings,
            brightness: brightness,
            onPick: (id) {
              if (prefs != null) _apply(() => prefs.setAccent(id));
            },
            onCustom: () {
              if (prefs != null) unawaited(_pickCustomAccent(prefs));
            },
          ),
          if (brightness == Brightness.light) ...[
            HermesSectionHeader(strings.lflLightBackground),
            _GroundRow(
              accent: LookFeel.accentShown(
                settings,
                settings.accentId,
                Brightness.light,
              ),
              cards: [
                for (final bg in LookLightBackground.values)
                  _GroundChoice(
                    key: ValueKey('lfl-light-${bg.name}'),
                    label: switch (bg) {
                      LookLightBackground.white => strings.lflBgWhite,
                      LookLightBackground.paper => strings.lflBgPaper,
                    },
                    page: LookFeel.lightSwatch(bg).$1,
                    surface: LookFeel.lightSwatch(bg).$2,
                    selected: settings.lightBackground == bg,
                    onTap: () {
                      if (prefs != null) {
                        _apply(() => prefs.setLightBackground(bg));
                      }
                    },
                  ),
              ],
            ),
          ] else ...[
            HermesSectionHeader(strings.lflDarkBackground),
            _GroundRow(
              accent: LookFeel.accentShown(
                settings,
                settings.accentId,
                Brightness.dark,
              ),
              cards: [
                for (final bg in LookDarkBackground.values)
                  _GroundChoice(
                    key: ValueKey('lfl-dark-${bg.name}'),
                    label: switch (bg) {
                      LookDarkBackground.midnight => strings.lflBgMidnight,
                      LookDarkBackground.black => strings.lflBgBlack,
                      LookDarkBackground.gray => strings.lflBgGray,
                    },
                    page: LookFeel.darkSwatch(bg).$1,
                    surface: LookFeel.darkSwatch(bg).$2,
                    selected: settings.darkBackground == bg,
                    onTap: () {
                      if (prefs != null) {
                        _apply(() => prefs.setDarkBackground(bg));
                      }
                    },
                  ),
              ],
            ),
          ],
          // The faces that travel inside the app (AppFonts: Inter, Montserrat,
          // Nunito and JetBrains Mono) plus the system one; no font is ever
          // downloaded. Still to package before they can be offered: Manrope
          // and Lora (OFL; add the .ttf under assets/fonts, declare them in
          // pubspec `fonts:` and in AppFonts / ThemeProfileCodec) and, for a
          // system serif, an AppFonts entry that is not a packaged family.
          HermesSectionHeader(strings.lflFont),
          HermesGroup(
            children: [
              for (final font in AppFonts.all)
                _FontRow(
                  key: ValueKey('lfl-font-${font.id}'),
                  option: font,
                  selected: AppFonts.byId(_fontId.value).id == font.id,
                  onTap: () => unawaited(_pickFont(font.id)),
                ),
            ],
          ),
          const SizedBox(height: HermesSpace.x4),
          HermesGroup(
            children: [
              // The group paints its body: the tile's ink needs a Material.
              Material(
                type: MaterialType.transparency,
                child: HermesSwitchTile(
                  controlKey: const ValueKey('lfl-animate-bots'),
                  title: strings.charactersAnimateTitle,
                  subtitle: strings.charactersAnimateSubtitle,
                  value: BotMotionPrefs.shared.animate,
                  onChanged: (value) =>
                      unawaited(BotMotionPrefs.shared.setAnimate(value)),
                ),
              ),
            ],
          ),
          const SizedBox(height: HermesSpace.x4),
          HermesGroup(
            children: [
              Material(
                type: MaterialType.transparency,
                child: HermesSwitchTile(
                  controlKey: const ValueKey('lfl-haptics'),
                  title: strings.lflHapticsTitle,
                  subtitle: strings.lflHapticsSubtitle,
                  value: HapticPrefs.shared.enabled,
                  onChanged: (value) {
                    unawaited(HapticPrefs.shared.setEnabled(value));
                    // The switch answers with the tick it was just turned on
                    // for (a silent one when it is turned off).
                    if (value) HermesHaptics.selection();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: HermesSpace.x4),
          HermesGroup(
            children: [
              HermesNavRow(
                key: const ValueKey('lfl-more-themes'),
                icon: Icons.palette_outlined,
                title: strings.lflMoreThemes,
                subtitle: strings.lflMoreThemesBody(AppTheme.presets.length),
                onTap: _openMoreThemes,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// «Tema: X» with the way back, shown while a theme of the list is in force.
class _ListThemeBanner extends StatelessWidget {
  const _ListThemeBanner({required this.name, required this.onReturn});

  final String name;
  final Future<void> Function() onReturn;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: HermesSpace.x2),
      child: DecoratedBox(
        key: const ValueKey('lfl-list-banner'),
        decoration: BoxDecoration(
          border: Border.all(color: colors.divider),
          borderRadius: BorderRadius.circular(HermesRadius.row),
        ),
        child: Padding(
          padding: const EdgeInsets.all(HermesSpace.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                strings.lflThemeBanner(name),
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: HermesType.bodySize,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: HermesSpace.x1),
              Text(
                strings.lflThemeBannerBody,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: HermesType.supportSize,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: HermesSpace.x3),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton(
                  key: const ValueKey('lfl-return'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(HermesSize.tap, HermesSize.tap),
                  ),
                  onPressed: () => unawaited(onReturn()),
                  child: Text(strings.lflReturn),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The ten circles: nine fixed accents and the free colour. Each circle shows
/// the colour the app will really paint on the background in force.
class _AccentGrid extends StatelessWidget {
  const _AccentGrid({
    required this.settings,
    required this.brightness,
    required this.onPick,
    required this.onCustom,
  });

  final LookFeelSettings settings;
  final Brightness brightness;
  final ValueChanged<String> onPick;
  final VoidCallback onCustom;

  String _name(Strings strings, String id) => switch (id) {
    'terracotta' => strings.lflAccentTerracotta,
    'orange' => strings.lflAccentOrange,
    'rose' => strings.lflAccentRose,
    'violet' => strings.lflAccentViolet,
    'indigo' => strings.lflAccentIndigo,
    'blue' => strings.lflAccentBlue,
    'teal' => strings.lflAccentTeal,
    'green' => strings.lflAccentGreen,
    'slate' => strings.lflAccentSlate,
    _ => strings.lflAccentCustom,
  };

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Wrap(
      alignment: WrapAlignment.start,
      children: [
        for (final accent in LookFeel.accents)
          _AccentDot(
            key: ValueKey('lfl-accent-${accent.id}'),
            label: _name(strings, accent.id),
            color: LookFeel.accentShown(settings, accent.id, brightness),
            selected: settings.accentId == accent.id,
            onTap: () => onPick(accent.id),
          ),
        _AccentDot(
          key: const ValueKey('lfl-accent-custom'),
          label: strings.lflAccentCustom,
          color: LookFeel.accentShown(settings, lookAccentCustomId, brightness),
          rainbow: true,
          selected: settings.accentId == lookAccentCustomId,
          onTap: onCustom,
        ),
      ],
    );
  }
}

class _AccentDot extends StatelessWidget {
  const _AccentDot({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    this.rainbow = false,
  });

  final String label;
  final Color color;
  final bool selected;
  final bool rainbow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final ink = ThemeContrast.bestBlackOrWhite(color);
    final disc = Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: rainbow ? null : color,
        gradient: rainbow
            ? SweepGradient(
                colors: [
                  for (var hue = 0; hue <= 360; hue += 60)
                    HSVColor.fromAHSV(1, hue.toDouble(), 0.85, 0.95).toColor(),
                ],
              )
            : null,
      ),
      alignment: Alignment.center,
      // The free colour shows the chosen colour in its middle when it is the
      // one in force; the check reads on it.
      child: rainbow && selected
          ? Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              child: Icon(Icons.check_rounded, size: HermesIcon.md, color: ink),
            )
          : selected
          ? Icon(Icons.check_rounded, size: HermesIcon.lg, color: ink)
          : null,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkResponse(
        onTap: onTap,
        radius: HermesSize.tap / 2,
        child: SizedBox(
          width: HermesSize.tap,
          height: HermesSize.tap,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? colors.textPrimary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(HermesSpace.x1),
                child: disc,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A choice of background: [page] and [surface] drawn as a small page.
class _GroundChoice {
  const _GroundChoice({
    required this.key,
    required this.label,
    required this.page,
    required this.surface,
    required this.selected,
    required this.onTap,
  });

  final Key key;
  final String label;
  final Color page;
  final Color surface;
  final bool selected;
  final VoidCallback onTap;
}

/// A row of background cards; with big text they stack in one column so the
/// names are never cut.
class _GroundRow extends StatelessWidget {
  const _GroundRow({required this.cards, required this.accent});

  final List<_GroundChoice> cards;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final stacked = scale >= 1.3;
    final tiles = [
      for (final card in cards)
        _GroundCard(
          key: card.key,
          choice: card,
          accent: accent,
          label: card.label,
        ),
    ];
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final tile in tiles) ...[
            tile,
            const SizedBox(height: HermesSpace.x2),
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: HermesSpace.x2),
          Expanded(child: tiles[i]),
        ],
      ],
    );
  }
}

class _GroundCard extends StatelessWidget {
  const _GroundCard({
    super.key,
    required this.choice,
    required this.accent,
    required this.label,
  });

  final _GroundChoice choice;
  final Color accent;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final radius = BorderRadius.circular(HermesRadius.control);
    final selected = choice.selected;
    final line = ThemeContrast.bestBlackOrWhite(choice.page);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: choice.onTap,
      child: InkWell(
        onTap: choice.onTap,
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HermesSize.tap),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: selected ? colors.accent : colors.divider,
                width: selected ? 2 : 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(HermesSpace.x2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The page in miniature: its surface and the accent.
                  Container(
                    height: 56,
                    decoration: BoxDecoration(
                      color: choice.page,
                      borderRadius: BorderRadius.circular(HermesRadius.chip),
                      border: Border.all(color: line.withValues(alpha: 0.18)),
                    ),
                    padding: const EdgeInsets.all(HermesSpace.x2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Container(
                            height: 24,
                            decoration: BoxDecoration(
                              color: choice.surface,
                              borderRadius: BorderRadius.circular(
                                HermesRadius.chip,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: HermesSpace.x2),
                        Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: HermesSpace.x2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: HermesType.valueSize,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(
                          Icons.check_rounded,
                          size: HermesIcon.md,
                          color: colors.accentText,
                        ),
                    ],
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

/// One font: its name in its own typeface, what it is like, and the check.
class _FontRow extends StatelessWidget {
  const _FontRow({
    super.key,
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final AppFontOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final family = AppFonts.resolvedFamily(option);
    final name = option.id == AppFonts.defaultId
        ? strings.lflFontSystem
        : option.label;
    final description = switch (option.id) {
      'inter' => strings.lflFontInterDesc,
      'montserrat' => strings.lflFontMontserratDesc,
      'nunito' => strings.lflFontNunitoDesc,
      'jetbrains' => strings.lflFontMonoDesc,
      _ => strings.lflFontSystemDesc,
    };
    return Semantics(
      button: true,
      selected: selected,
      label: '$name. $description',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: HermesSize.tap),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HermesSpace.x4,
              vertical: HermesSpace.x3,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontFamily: family,
                          color: colors.textPrimary,
                          fontSize: HermesType.bodySize,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: HermesSpace.x1),
                      Text(
                        description,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: HermesType.supportSize,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: HermesSpace.x3),
                  Icon(
                    Icons.check_rounded,
                    size: HermesIcon.lg,
                    color: colors.accentText,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
