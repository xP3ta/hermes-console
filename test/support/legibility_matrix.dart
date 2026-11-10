// The legibility matrix: every theme the app can wear (the catalogue's
// presets and the Look & Feel derivation, accent by accent and background by
// background), measured with the WCAG formulas of [ThemeContrast] on the
// colours the widgets really paint: text on every surface, the contour of a
// box, the divider between two rows, the outline of a control, the active
// and idle icons of the dock, the title over the glass header on the worst
// content, the disabled states.
//
// The tests of the matrix read these numbers; the markdown they print is
// the inventory, worst cases first.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hermes_android/core/design/glass_strip.dart';
import 'package:hermes_android/core/design/smoked_glass.dart';
import 'package:hermes_android/core/design/tokens.dart';
import 'package:hermes_android/core/models/dock_config.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/theme/box_fill.dart';
import 'package:hermes_android/core/theme/glass_look.dart';
import 'package:hermes_android/core/theme/lines.dart';
import 'package:hermes_android/core/theme/look_feel.dart';
import 'package:hermes_android/core/theme/theme_contrast.dart';
import 'package:hermes_android/core/widgets/dock_style.dart';
import 'package:hermes_android/core/widgets/frosted_backdrop.dart';
import 'package:hermes_android/core/widgets/hermes_app_bar.dart';

/// What a pair is for, and the ratio it has to reach.
enum PairKind {
  /// Text that is read: AA.
  text(4.5),

  /// An icon that informs, a link's glyph: 1.4.11.
  icon(3.0),

  /// The boundary of a control (a field, a switch, a segment): 1.4.11.
  control(3.0),

  /// The contour of a box: a group, a card.
  contour(HermesLines.contourRatio),

  /// The edge of a floating piece over any content (the dock, a header
  /// pill, a back button, a menu): a component's boundary, 1.4.11.
  edge(HermesLines.edgeRatio),

  /// The divider between the rows of a list, against the body it splits.
  divider(HermesLines.dividerRatio),

  /// A disabled control: exempt by WCAG, but it still has to be read.
  disabled(HermesLines.disabledRatio);

  const PairKind(this.target);

  final double target;
}

/// One theme of the matrix.
class MatrixTheme {
  const MatrixTheme({
    required this.id,
    required this.family,
    required this.dark,
    required this.theme,
  });

  /// `console`, `lf-gray-green`...
  final String id;

  /// `catalog` or `look-feel`.
  final String family;
  final bool dark;
  final ThemeData theme;

  HermesThemeColors get colors => theme.hermes;

  String get mode => dark ? 'dark' : 'light';
}

/// One measurement.
class MatrixPair {
  const MatrixPair(this.theme, this.kind, this.name, this.ratio);

  final MatrixTheme theme;
  final PairKind kind;

  /// `textSecondary on card`.
  final String name;
  final double ratio;

  bool get passes => ratio + 1e-9 >= kind.target;

  /// How far below (or above) its target, as a share: what the table sorts
  /// by, so a weak divider and a weak text compete on equal terms.
  double get margin => ratio / kind.target;

  @override
  String toString() =>
      '${theme.id} ${theme.mode} ${kind.name} $name '
      '${ratio.toStringAsFixed(2)} (>= ${kind.target})';
}

/// The 42 presets of the catalogue and the Look & Feel derivation: the ten
/// accents on each of the five backgrounds.
List<MatrixTheme> matrixThemes() {
  final out = <MatrixTheme>[];
  for (final preset in AppTheme.presets) {
    out.add(
      MatrixTheme(
        id: preset.id,
        family: 'catalog',
        dark: preset.isDark,
        theme: AppTheme.fromId(preset.id),
      ),
    );
  }
  final accents = [for (final a in LookFeel.accents) a.id, lookAccentCustomId];
  for (final background in LookLightBackground.values) {
    for (final accent in accents) {
      final settings = LookFeelSettings(
        source: LookFeelSource.derived,
        appearance: LookAppearance.light,
        accentId: accent,
        lightBackground: background,
      );
      out.add(
        MatrixTheme(
          id: 'lf-${background.name}-$accent',
          family: 'look-feel',
          dark: false,
          theme: LookFeel.themeData(settings, Brightness.light),
        ),
      );
    }
  }
  for (final background in LookDarkBackground.values) {
    for (final accent in accents) {
      final settings = LookFeelSettings(
        source: LookFeelSource.derived,
        appearance: LookAppearance.dark,
        accentId: accent,
        darkBackground: background,
      );
      out.add(
        MatrixTheme(
          id: 'lf-${background.name}-$accent',
          family: 'look-feel',
          dark: true,
          theme: LookFeel.themeData(settings, Brightness.dark),
        ),
      );
    }
  }
  return out;
}

Color _over(Color top, Color under) => ThemeContrast.composite(top, under);

/// Every pair of one theme.
List<MatrixPair> measureTheme(MatrixTheme t) {
  final theme = t.theme;
  final c = t.colors;
  final out = <MatrixPair>[];
  void add(PairKind kind, String name, Color fg, Color bg) =>
      out.add(MatrixPair(t, kind, name, ThemeContrast.ratio(fg, bg)));

  final fill = HermesBoxFill.of(c);
  final page = fill.page;
  final glass = GlassMaterial.resolve(c, GlassLevel.full);
  final chrome = HermesChrome.of(c);
  final gel = HermesGel.of(c);
  final lines = HermesLines.of(c);
  final dock = resolveDockVisual(c, const DockStyle());
  final dockBody = _over(dock.background, page);
  final band = HermesAppBar.bandUnder(c, HermesAppBar.bandAlpha(c));
  final strip = HermesGlassStrip.worstUnder(c);
  final piece = glass == null ? fill.group : _over(glass.pieceFill, fill.group);
  final selectedPiece = glass == null
      ? _over(c.accent.withValues(alpha: 0.2), fill.group)
      : _over(glass.selected, piece);
  final fieldFill = _over(c.surfaceVariant.withValues(alpha: 0.3), fill.group);

  // ── Text on every surface it is read on ─────────────────────────────
  final surfaces = <String, Color>{
    'page': page,
    'glow': fill.glow,
    'surface': _over(c.surface, page),
    'surfaceVariant': _over(c.surfaceVariant, page),
    'group': fill.group,
    'card': fill.card,
    'banner': HermesBoxFill.banner(c, fill.card),
    'chrome': chrome.opaque,
    'pill': chrome.raised,
    'piece': piece,
    'field': fieldFill,
    'dock': dockBody,
  };
  for (final entry in surfaces.entries) {
    add(
      PairKind.text,
      'textPrimary on ${entry.key}',
      c.textPrimary,
      entry.value,
    );
    add(
      PairKind.text,
      'textSecondary on ${entry.key}',
      c.textSecondary,
      entry.value,
    );
    add(
      PairKind.text,
      'textTertiary on ${entry.key}',
      c.textTertiary,
      entry.value,
    );
  }
  for (final name in const [
    'page',
    'surface',
    'surfaceVariant',
    'group',
    'card',
  ]) {
    final bg = surfaces[name]!;
    add(PairKind.text, 'accentText on $name', c.accentText, bg);
    add(PairKind.text, 'error on $name', c.error, bg);
    add(PairKind.text, 'warning on $name', c.warning, bg);
    add(PairKind.text, 'success on $name', c.success, bg);
    add(PairKind.icon, 'accent on $name', c.accent, bg);
    add(PairKind.icon, 'icon textSecondary on $name', c.textSecondary, bg);
  }
  add(PairKind.text, 'onAccent on accent', c.onAccent, c.accent);
  // The hover shade is painted as an ink too (a count, a caption).
  add(PairKind.icon, 'accentHover ink on page', c.accentHover, page);
  add(PairKind.icon, 'accentHover ink on card', c.accentHover, fill.card);
  add(
    PairKind.text,
    'textPrimary on selected piece',
    c.textPrimary,
    selectedPiece,
  );
  add(PairKind.text, 'ink on glass header, worst', chrome.ink, band);
  add(PairKind.text, 'muted ink on chrome', chrome.mutedInk, chrome.opaque);
  add(PairKind.text, 'ink on glass strip, worst', chrome.ink, strip);
  add(
    PairKind.text,
    'textPrimary over selection',
    c.textPrimary,
    _over(
      theme.textSelectionTheme.selectionColor ??
          c.accent.withValues(alpha: 0.4),
      fieldFill,
    ),
  );

  // ── Icons ───────────────────────────────────────────────────────────
  add(PairKind.icon, 'dock idle icon', c.textSecondary, dockBody);
  // Behind the translucent dock the smoked tone bounds what can show
  // through ([HermesSmokedGlass.worstRatio]); where the tone cannot keep
  // the inks, the bar paints the opaque chrome instead.
  final dockTone = HermesSmokedGlass.dockOf(
    chrome,
  ).withVeilFloor(dock.background.a);
  final dockInks = HermesSmokedGlass.dockInks(c);
  final toned = dock.background.a < 1 && dockTone.readsFor(c, dockInks);
  out.add(
    MatrixPair(
      t,
      PairKind.icon,
      'dock idle icon, worst behind',
      toned
          ? dockTone.worstRatio(c.textSecondary, chrome)
          : ThemeContrast.ratio(c.textSecondary, chrome.opaque),
    ),
  );
  final glow = c.accent.withValues(alpha: HermesGel.dockGlowCertified(t.dark));
  add(PairKind.icon, 'dock active icon', c.accentText, _over(glow, dockBody));
  out.add(
    MatrixPair(
      t,
      PairKind.icon,
      'dock active icon, worst behind',
      toned
          ? dockTone.worstRatio(c.accentText, chrome, over: glow)
          : ThemeContrast.ratio(c.accentText, _over(glow, chrome.opaque)),
    ),
  );
  add(PairKind.icon, 'chevron textTertiary on card', c.textTertiary, fill.card);
  add(PairKind.icon, 'status ok dot on card', c.success, fill.card);
  add(PairKind.icon, 'status warn dot on card', c.warning, fill.card);
  add(PairKind.icon, 'status error dot on card', c.error, fill.card);

  // ── Contours ────────────────────────────────────────────────────────
  if (glass != null) {
    add(
      PairKind.contour,
      'group contour top on page',
      _over(glass.lineTop, page),
      page,
    );
    add(
      PairKind.contour,
      'group contour bottom on page',
      _over(glass.lineBottom, page),
      page,
    );
    add(
      PairKind.contour,
      'card contour (weak) on page',
      _over(glass.line, fill.card),
      page,
    );
    add(
      PairKind.contour,
      'piece line on group',
      _over(glass.line, piece),
      fill.group,
    );
    add(
      PairKind.contour,
      'selected line on piece',
      glass.selectedLine,
      selectedPiece,
    );
  }
  add(
    PairKind.edge,
    'chrome line on page',
    _over(chrome.line, chrome.opaque),
    page,
  );
  // The hairline runs on the outline of a gel piece: over its fill, against
  // the page outside.
  add(
    PairKind.edge,
    'gel hairline on page',
    _over(gel.hairline, _over(gel.glassFill, page)),
    page,
  );
  add(PairKind.edge, 'dock border on page', _over(dock.border, dockBody), page);
  // A header piece over the band on the theme's own page: bounded by its
  // hairline (the chrome's line) or by its own fill, whichever stands out
  // more from the band. (Over the worst content behind, white under a dark
  // theme, the band is chosen for the TITLE's AA; a white hairline cannot
  // also cut a piece out of a white band, and the piece's fill does it.)
  final ownBand = _over(
    c.background.withValues(alpha: HermesAppBar.bandAlpha(c)),
    page,
  );
  final pieceOnBand = _over(FrostedBackdrop.glassVeil(c), ownBand);
  out.add(
    MatrixPair(
      t,
      PairKind.edge,
      'header piece on band',
      math.max(
        ThemeContrast.ratio(_over(chrome.line, pieceOnBand), ownBand),
        ThemeContrast.ratio(pieceOnBand, ownBand),
      ),
    ),
  );

  // ── Controls ────────────────────────────────────────────────────────
  add(
    PairKind.control,
    'field outline on group',
    _over(lines.fieldBorder, fieldFill),
    fill.group,
  );
  add(
    PairKind.control,
    'field outline on page',
    _over(lines.fieldBorder, fieldFill),
    page,
  );
  final switchTheme = theme.switchTheme;
  final offTrack = switchTheme.trackColor?.resolve({}) ?? c.surfaceVariant;
  final offOutline =
      switchTheme.trackOutlineColor?.resolve({}) ?? c.textDisabled;
  final offThumb = switchTheme.thumbColor?.resolve({}) ?? c.textSecondary;
  final onThumb =
      switchTheme.thumbColor?.resolve({WidgetState.selected}) ?? Colors.white;
  add(
    PairKind.control,
    'switch off outline on group',
    _over(offOutline, fill.group),
    fill.group,
  );
  add(
    PairKind.control,
    'switch off outline on card',
    _over(offOutline, fill.card),
    fill.card,
  );
  add(
    PairKind.control,
    'switch off thumb on track',
    offThumb,
    _over(offTrack, fill.group),
  );
  add(PairKind.control, 'switch on thumb on accent', onThumb, c.accent);
  add(PairKind.control, 'switch on track on group', c.accent, fill.group);
  // The chosen segment: its accent ring on the track (the fill is a soft
  // tint and the label goes bold; the ring is the boundary 1.4.11 asks).
  add(
    PairKind.control,
    'segmented selected ring on track',
    glass?.selectedLine ?? c.accent,
    piece,
  );
  add(
    PairKind.control,
    'checkbox outline on card',
    _over(lines.control, fill.card),
    fill.card,
  );
  add(PairKind.control, 'focus ring on group', c.accent, fill.group);
  add(PairKind.control, 'slider active on group', c.accent, fill.group);
  add(
    PairKind.control,
    'chip outline on card',
    _over(lines.control, fill.card),
    fill.card,
  );

  // ── Dividers ────────────────────────────────────────────────────────
  add(
    PairKind.divider,
    'row divider on group',
    _over(lines.divider, fill.group),
    fill.group,
  );
  add(
    PairKind.divider,
    'row divider on card',
    _over(lines.dividerOn(fill.card), fill.card),
    fill.card,
  );
  add(
    PairKind.divider,
    'row divider on chrome',
    _over(lines.dividerOn(chrome.opaque), chrome.opaque),
    chrome.opaque,
  );
  // A bare Divider() takes the theme's divider colour.
  final bare = theme.dividerTheme.color ?? c.divider;
  add(PairKind.divider, 'bare Divider on page', _over(bare, page), page);
  add(
    PairKind.divider,
    'bare Divider on surface',
    _over(bare, _over(c.surface, page)),
    _over(c.surface, page),
  );

  // ── Disabled ────────────────────────────────────────────────────────
  final filled = theme.filledButtonTheme.style;
  final disabledBg =
      filled?.backgroundColor?.resolve({WidgetState.disabled}) ??
      c.textDisabled;
  final disabledFg =
      filled?.foregroundColor?.resolve({WidgetState.disabled}) ??
      c.textSecondary;
  add(
    PairKind.disabled,
    'filled button disabled label',
    disabledFg,
    _over(disabledBg, page),
  );
  add(PairKind.disabled, 'disabled row on card', c.textDisabled, fill.card);
  add(PairKind.disabled, 'disabled row on group', c.textDisabled, fill.group);
  add(PairKind.disabled, 'disabled ink on page', c.textDisabled, page);
  add(
    PairKind.disabled,
    'onboarding primary disabled label',
    lines.disabledInkOn(_over(c.surfaceVariant, page)),
    _over(c.surfaceVariant, page),
  );
  return out;
}

/// Every pair of every theme.
List<MatrixPair> measureMatrix([List<MatrixTheme>? themes]) => [
  for (final theme in themes ?? matrixThemes()) ...measureTheme(theme),
];

/// The failures, worst first.
List<MatrixPair> failing(List<MatrixPair> pairs) =>
    pairs.where((p) => !p.passes).toList()
      ..sort((a, b) => a.margin.compareTo(b.margin));

/// The inventory as markdown: the [worst] rows by margin to their target,
/// then one line per kind with how many pass.
String matrixMarkdown(List<MatrixPair> pairs, {int worst = 40, String? title}) {
  final sorted = [...pairs]..sort((a, b) => a.margin.compareTo(b.margin));
  final themes = pairs.map((p) => p.theme.id).toSet().length;
  final b = StringBuffer();
  if (title != null) b.writeln('## $title\n');
  b.writeln(
    '${pairs.length} pares medidos en $themes temas '
    '(${pairs.where((p) => p.theme.family == 'catalog').map((p) => p.theme.id).toSet().length} del catálogo, '
    '${pairs.where((p) => p.theme.family == 'look-feel').map((p) => p.theme.id).toSet().length} de Look & Feel).\n',
  );
  b.writeln('| # | tema | modo | tipo | par | ratio | objetivo |');
  b.writeln('|---|---|---|---|---|---|---|');
  var i = 0;
  for (final p in sorted.take(worst)) {
    i++;
    b.writeln(
      '| $i | ${p.theme.id} | ${p.theme.mode} | ${p.kind.name} | ${p.name} '
      '| ${p.ratio.toStringAsFixed(2)} | ${p.kind.target.toStringAsFixed(1)} |',
    );
  }
  b.writeln('\n| tipo | objetivo | pares | por debajo | peor |');
  b.writeln('|---|---|---|---|---|');
  for (final kind in PairKind.values) {
    final mine = pairs.where((p) => p.kind == kind).toList()
      ..sort((a, b) => a.ratio.compareTo(b.ratio));
    if (mine.isEmpty) continue;
    final below = mine.where((p) => !p.passes).length;
    final w = mine.first;
    b.writeln(
      '| ${kind.name} | ${kind.target.toStringAsFixed(1)} | ${mine.length} '
      '| $below | ${w.ratio.toStringAsFixed(2)} (${w.theme.id} ${w.theme.mode}, ${w.name}) |',
    );
  }
  return b.toString();
}

/// Writes [markdown] where `LEGIBILITY_MATRIX` (a `--dart-define` or an
/// environment variable) points, if anywhere.
void writeMatrix(String markdown) {
  const defined = String.fromEnvironment('LEGIBILITY_MATRIX');
  final path = defined.isNotEmpty
      ? defined
      : Platform.environment['LEGIBILITY_MATRIX'];
  if (path == null || path.isEmpty) return;
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(markdown);
}
