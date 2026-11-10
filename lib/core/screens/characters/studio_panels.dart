import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../characters/blob_shape.dart';
import '../../characters/bot_character.dart';
import '../../characters/character_ai_request.dart';
import '../../characters/character_draft.dart';
import '../../characters/studio_catalog.dart';
import '../../characters/studio_eyes.dart';
import '../../characters/studio_painter.dart';
import '../../characters/studio_pieces.dart';
import '../../design/tokens.dart';
import '../../models/bot_visual_identity.dart';
import '../../theme/app_theme.dart';
import '../../widgets/hermes_premium_ui.dart';
import '../../widgets/hermes_ui.dart';
import 'studio_widgets.dart';

String studioFormLabel(BotForm form, Strings s) => switch (form) {
  BotForm.round => s.bstFormRound,
  BotForm.organic => s.bstFormOrganic,
  BotForm.boxy => s.bstFormBoxy,
  BotForm.rectangle => s.bstFormRectangle,
  BotForm.cloud => s.bstFormCloud,
};

String studioEyeLabel(BotEyeStyle style, Strings s) => switch (style) {
  BotEyeStyle.dot => s.bstEyeDot,
  BotEyeStyle.oval => s.bstEyeOval,
  BotEyeStyle.joy => s.bstEyeJoy,
  BotEyeStyle.dreamy => s.bstEyeDreamy,
  BotEyeStyle.glint => s.bstEyeGlint,
  BotEyeStyle.bold => s.bstEyeBold,
  BotEyeStyle.lantern => s.bstEyeLantern,
  BotEyeStyle.ring => s.bstEyeRing,
  BotEyeStyle.wink => s.bstEyeWink,
  BotEyeStyle.amazed => s.bstEyeAmazed,
  BotEyeStyle.narrow => s.bstEyeNarrow,
  BotEyeStyle.grumpy => s.bstEyeGrumpy,
  BotEyeStyle.slit => s.bstEyeSlit,
  BotEyeStyle.undead => s.bstEyeUndead,
  BotEyeStyle.heart => s.bstEyeHeart,
};

String studioPieceLabel(BotPieceKind kind, Strings s) => switch (kind) {
  BotPieceKind.catEars => s.bstPieceCatEars,
  BotPieceKind.bearEars => s.bstPieceBearEars,
  BotPieceKind.bunnyEars => s.bstPieceBunnyEars,
  BotPieceKind.crown => s.bstPieceCrown,
  BotPieceKind.horn => s.bstPieceHorn,
  BotPieceKind.halo => s.bstPieceHalo,
  BotPieceKind.swirl => s.bstPieceSwirl,
  BotPieceKind.sprout => s.bstPieceSprout,
  BotPieceKind.leaf => s.bstPieceLeaf,
  BotPieceKind.wing => s.bstPieceWing,
  BotPieceKind.tail => s.bstPieceTail,
  BotPieceKind.star => s.bstPieceStar,
  BotPieceKind.heart => s.bstPieceHeart,
  BotPieceKind.bow => s.bstPieceBow,
  BotPieceKind.paw => s.bstPiecePaw,
  BotPieceKind.fin => s.bstPieceFin,
  BotPieceKind.bolt => s.bstPieceBolt,
  BotPieceKind.flower => s.bstPieceFlower,
  BotPieceKind.moon => s.bstPieceMoon,
  BotPieceKind.drop => s.bstPieceDrop,
};

String studioFinishLabel(BotFinish finish, Strings s) => switch (finish) {
  BotFinish.flat => s.bstFinishFlat,
  BotFinish.matte => s.bstFinishMatte,
  BotFinish.soft => s.bstFinishSoft,
  BotFinish.glossy => s.bstFinishGlossy,
};

String studioGradientLabel(String id, Strings s) => switch (id) {
  'sunrise' => s.bstGradSunrise,
  'zest' => s.bstGradZest,
  'bay' => s.bstGradBay,
  'gumdrop' => s.bstGradGumdrop,
  'cinder' => s.bstGradCinder,
  'nightfall' => s.bstGradNightfall,
  'tide' => s.bstGradTide,
  'apricot' => s.bstGradApricot,
  'plum' => s.bstGradPlum,
  'spearmint' => s.bstGradSpearmint,
  'borealis' => s.bstGradBorealis,
  'sherbet' => s.bstGradSherbet,
  'petal' => s.bstGradPetal,
  _ => s.bstGradPearl,
};

String _percent(double value) => '${(value * 100).round()} %';

/// A painter of one of the editor's small previews.
final class _PreviewPainter extends CustomPainter {
  final void Function(Canvas canvas, Size size) draw;
  final Object signature;

  const _PreviewPainter(this.draw, this.signature);

  @override
  void paint(Canvas canvas, Size size) => draw(canvas, size);

  @override
  bool shouldRepaint(_PreviewPainter old) => old.signature != signature;
}

Widget _preview(void Function(Canvas, Size) draw, Object signature) =>
    CustomPaint(size: Size.infinite, painter: _PreviewPainter(draw, signature));

// ── Shape ──────────────────────────────────────────────────────────────────

/// The silhouette: five bodies, how far (range) and how strongly (strength)
/// the outline bends, and the seed that decides how.
class StudioShapePanel extends StatefulWidget {
  final CharacterDraft draft;
  final String profileName;
  final VoidCallback onRandomSeed;

  const StudioShapePanel({
    super.key,
    required this.draft,
    required this.profileName,
    required this.onRandomSeed,
  });

  @override
  State<StudioShapePanel> createState() => _StudioShapePanelState();
}

class _StudioShapePanelState extends State<StudioShapePanel> {
  late final TextEditingController _seed = TextEditingController(
    text: widget.draft.value.seed,
  );
  final FocusNode _focus = FocusNode();
  bool _invalid = false;

  CharacterDraft get _draft => widget.draft;

  @override
  void initState() {
    super.initState();
    _draft.addListener(_follow);
    _focus.addListener(() {
      if (!_focus.hasFocus) _draft.endGesture();
    });
  }

  @override
  void dispose() {
    _draft.removeListener(_follow);
    _seed.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _follow() {
    if (!_focus.hasFocus && _seed.text != _draft.value.seed) {
      _seed.text = _draft.value.seed;
    }
  }

  void _onSeed(String raw) {
    final value = raw.trim().toLowerCase();
    final valid = BotCharacter.isValidSeed(value);
    setState(() => _invalid = !valid);
    if (!valid) return;
    _draft.beginGesture();
    _draft.update(_draft.value.copyWith(seed: value));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return ListenableBuilder(
      listenable: _draft,
      builder: (context, _) {
        final c = _draft.value;
        final seed = c.visual(widget.profileName).seed;
        final body = studioBodyColor(c, c.visual(widget.profileName).headColor);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HermesSectionHeader(s.botFaceSilhouette),
            Wrap(
              spacing: HermesSpace.x2,
              runSpacing: HermesSpace.x3,
              children: [
                for (final form in BotForm.values)
                  StudioTile(
                    key: ValueKey('studio-form-${form.name}'),
                    label: studioFormLabel(form, s),
                    selected: c.form == form,
                    onTap: () => _draft.apply(c.copyWith(form: form)),
                    preview: _preview((canvas, size) {
                      canvas.scale(size.width / 100, size.height / 100);
                      canvas.drawPath(
                        BlobShape.body(
                          form: form,
                          range: c.range,
                          strength: c.strength,
                          seed: seed,
                        ),
                        Paint()..color = body,
                      );
                    }, (form, c.range, c.strength, seed, body)),
                  ),
              ],
            ),
            StudioSliderRow(
              key: const ValueKey('studio-range'),
              label: s.bstRange,
              valueText: _percent(c.range),
              value: c.range,
              onStart: _draft.beginGesture,
              onEnd: _draft.endGesture,
              onChanged: (v) => _draft.update(_draft.value.copyWith(range: v)),
            ),
            StudioSliderRow(
              key: const ValueKey('studio-strength'),
              label: s.bstStrength,
              valueText: _percent(c.strength),
              value: c.strength,
              onStart: _draft.beginGesture,
              onEnd: _draft.endGesture,
              onChanged: (v) =>
                  _draft.update(_draft.value.copyWith(strength: v)),
            ),
            HermesSectionHeader(s.charactersSectionSeed),
            TextField(
              key: const ValueKey('character-seed-field'),
              controller: _seed,
              focusNode: _focus,
              onChanged: _onSeed,
              onSubmitted: (_) => _draft.endGesture(),
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 64,
              style: HermesType.style(HermesType.text, colors.textPrimary),
              decoration: InputDecoration(
                hintText: s.charactersSeedHint,
                counterText: '',
                errorText: _invalid ? s.charactersSeedInvalid : null,
              ),
            ),
            const SizedBox(height: HermesSpace.x2),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: StudioPill(
                key: const ValueKey('character-seed-random'),
                label: s.botFaceRandom,
                icon: Icons.casino_outlined,
                onTap: () {
                  setState(() => _invalid = false);
                  widget.onRandomSeed();
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Colour picker ──────────────────────────────────────────────────────────

/// Hue, saturation and brightness sliders for a custom colour.
class StudioColorPicker extends StatelessWidget {
  final Color color;
  final ValueChanged<Color> onChanged;
  final VoidCallback onStart;
  final VoidCallback onEnd;

  const StudioColorPicker({
    super.key,
    required this.color,
    required this.onChanged,
    required this.onStart,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final hsv = HSVColor.fromColor(color);
    Widget row(
      String label,
      double value,
      double max,
      String text,
      HSVColor Function(double) apply,
    ) => StudioSliderRow(
      label: label,
      valueText: text,
      value: value,
      max: max,
      onStart: onStart,
      onEnd: onEnd,
      onChanged: (v) => onChanged(apply(v).toColor()),
    );
    return Column(
      key: const ValueKey('studio-color-picker'),
      children: [
        row(
          s.bstHue,
          hsv.hue,
          360,
          '${hsv.hue.round()}°',
          (v) => hsv.withHue(v),
        ),
        row(
          s.bstSaturation,
          hsv.saturation,
          1,
          _percent(hsv.saturation),
          (v) => hsv.withSaturation(v),
        ),
        row(
          s.bstBrightness,
          hsv.value,
          1,
          _percent(hsv.value),
          (v) => hsv.withValue(v),
        ),
      ],
    );
  }
}

// ── Eyes ───────────────────────────────────────────────────────────────────

String _colorName(String hex, Strings s) => switch (hex) {
  '#111827' => s.bstColorInk,
  '#ffffff' => s.bstColorWhite,
  '#7c3aed' => s.bstColorViolet,
  '#2563eb' => s.bstColorBlue,
  '#dc2626' => s.bstColorRed,
  _ => s.bstColorGreen,
};

/// Eye styles, their colour and their size.
class StudioEyesPanel extends StatefulWidget {
  final CharacterDraft draft;
  final String profileName;

  const StudioEyesPanel({
    super.key,
    required this.draft,
    required this.profileName,
  });

  @override
  State<StudioEyesPanel> createState() => _StudioEyesPanelState();
}

class _StudioEyesPanelState extends State<StudioEyesPanel> {
  bool _custom = false;

  CharacterDraft get _draft => widget.draft;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return ListenableBuilder(
      listenable: _draft,
      builder: (context, _) {
        final c = _draft.value;
        final seeded = c.visual(widget.profileName).headColor;
        final body = studioBodyColor(c, seeded);
        final ink = c.eyeColor == null
            ? bestInk(body)
            : colorFromHex(c.eyeColor!);
        final isSwatch =
            c.eyeColor != null && botEyeSwatches.contains(c.eyeColor);
        final customActive = c.eyeColor != null && (!isSwatch || _custom);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HermesSectionHeader(s.charactersSectionEyes),
            Wrap(
              spacing: HermesSpace.x2,
              runSpacing: HermesSpace.x3,
              children: [
                for (final style in BotEyeStyle.values)
                  StudioTile(
                    key: ValueKey('studio-eyes-${style.name}'),
                    label: studioEyeLabel(style, s),
                    selected: c.eyeStyle == style,
                    onTap: () => _draft.apply(c.copyWith(eyeStyle: style)),
                    preview: ColoredBox(
                      color: body,
                      child: _preview(
                        (canvas, size) =>
                            paintEyeStylePreview(canvas, size, style, ink),
                        (style, ink),
                      ),
                    ),
                  ),
              ],
            ),
            StudioSliderRow(
              key: const ValueKey('studio-eye-size'),
              label: s.bstEyeSize,
              valueText: _percent(c.eyeSize),
              value: c.eyeSize,
              min: BotStudioLimits.eyeSizeMin,
              max: BotStudioLimits.eyeSizeMax,
              onStart: _draft.beginGesture,
              onEnd: _draft.endGesture,
              onChanged: (v) =>
                  _draft.update(_draft.value.copyWith(eyeSize: v)),
            ),
            HermesSectionHeader(s.bstEyeColor),
            Wrap(
              spacing: HermesSpace.x2,
              runSpacing: HermesSpace.x3,
              children: [
                StudioTile(
                  key: const ValueKey('studio-eye-color-auto'),
                  label: s.bstColorAuto,
                  selected: c.eyeColor == null,
                  onTap: () {
                    setState(() => _custom = false);
                    _draft.apply(c.copyWith(eyeColor: null));
                  },
                  preview: StudioSwatch(
                    color: bestInk(body),
                    child: Icon(
                      Icons.contrast_rounded,
                      size: HermesSpace.x5,
                      color: body,
                    ),
                  ),
                ),
                for (final hex in botEyeSwatches)
                  StudioTile(
                    key: ValueKey('studio-eye-color-$hex'),
                    label: _colorName(hex, s),
                    selected: c.eyeColor == hex && !_custom,
                    onTap: () {
                      setState(() => _custom = false);
                      _draft.apply(c.copyWith(eyeColor: hex));
                    },
                    preview: StudioSwatch(color: colorFromHex(hex)),
                  ),
                StudioTile(
                  key: const ValueKey('studio-eye-color-custom'),
                  label: s.bstColorCustom,
                  selected: customActive,
                  onTap: () {
                    setState(() => _custom = true);
                    if (c.eyeColor == null) {
                      _draft.apply(c.copyWith(eyeColor: hexFromColor(ink)));
                    }
                  },
                  preview: const StudioSwatch(gradient: _rainbow),
                ),
              ],
            ),
            if (customActive)
              StudioColorPicker(
                color: ink,
                onStart: _draft.beginGesture,
                onEnd: _draft.endGesture,
                onChanged: (color) => _draft.update(
                  _draft.value.copyWith(eyeColor: hexFromColor(color)),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Black or white, whichever reads on [background].
Color bestInk(Color background) => background.computeLuminance() > 0.4
    ? colorFromHex('#111827')
    : colorFromHex('#ffffff');

const SweepGradient _rainbow = SweepGradient(
  colors: [
    Colors.red,
    Colors.yellow,
    Colors.green,
    Colors.cyan,
    Colors.blue,
    Colors.purple,
    Colors.red,
  ],
);

// ── Pieces ─────────────────────────────────────────────────────────────────

/// Pieces to add, the ones already placed, and the controls of the selected
/// one.
class StudioPiecesPanel extends StatefulWidget {
  final CharacterDraft draft;
  final String profileName;
  final ValueNotifier<int?> selection;

  const StudioPiecesPanel({
    super.key,
    required this.draft,
    required this.profileName,
    required this.selection,
  });

  @override
  State<StudioPiecesPanel> createState() => _StudioPiecesPanelState();
}

class _StudioPiecesPanelState extends State<StudioPiecesPanel> {
  bool _positionOpen = false;

  CharacterDraft get _draft => widget.draft;

  void _add(BotPieceKind kind) {
    final pieces = _draft.value.pieces;
    if (pieces.length >= BotStudioLimits.maxPieces) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        SnackBar(content: Text(Strings.of(context).bstPiecesLimit)),
      );
      return;
    }
    _draft.apply(
      _draft.value.copyWith(pieces: [...pieces, BotPiece.placed(kind)]),
    );
    widget.selection.value = pieces.length;
  }

  void _remove(int index) {
    final pieces = [..._draft.value.pieces]..removeAt(index);
    widget.selection.value = null;
    _draft.apply(_draft.value.copyWith(pieces: pieces));
  }

  void _change(int index, BotPiece Function(BotPiece) edit) {
    final pieces = [..._draft.value.pieces];
    if (index >= pieces.length) return;
    pieces[index] = edit(pieces[index]);
    _draft.update(_draft.value.copyWith(pieces: pieces));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return ListenableBuilder(
      listenable: Listenable.merge([_draft, widget.selection]),
      builder: (context, _) {
        final c = _draft.value;
        final body = studioBodyColor(c, c.visual(widget.profileName).headColor);
        final index = widget.selection.value;
        final selected = index != null && index < c.pieces.length
            ? c.pieces[index]
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HermesSectionHeader(s.bstPiecesAdd),
            Wrap(
              spacing: HermesSpace.x2,
              runSpacing: HermesSpace.x3,
              children: [
                for (final kind in BotPieceKind.values)
                  StudioTile(
                    key: ValueKey('studio-piece-add-${kind.name}'),
                    label: studioPieceLabel(kind, s),
                    onTap: () => _add(kind),
                    preview: _preview((canvas, size) {
                      final box = StudioPieces.of(kind).bounds;
                      final k =
                          size.shortestSide *
                          0.78 /
                          math.max(box.width, box.height);
                      canvas
                        ..translate(size.width / 2, size.height / 2)
                        ..scale(k)
                        ..translate(-box.center.dx - 50, -box.center.dy - 50);
                      StudioPieces.paint(
                        canvas,
                        BotPiece.placed(kind).copyWith(x: 0.5, y: 0.5),
                        body,
                      );
                    }, (kind, body)),
                  ),
              ],
            ),
            HermesSectionHeader(s.bstPiecesPlaced),
            if (c.pieces.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: HermesSpace.x2),
                child: Text(
                  s.bstPiecesNone,
                  style: HermesType.style(
                    HermesType.support,
                    colors.textSecondary,
                  ),
                ),
              )
            else
              Wrap(
                spacing: HermesSpace.x2,
                children: [
                  for (var i = 0; i < c.pieces.length; i++)
                    StudioPill(
                      key: ValueKey('studio-piece-placed-$i'),
                      label: studioPieceLabel(c.pieces[i].kind, s),
                      selected: i == index,
                      accent: i == index,
                      onTap: () => widget.selection.value = i,
                    ),
                ],
              ),
            if (selected != null && index != null) ...[
              const SizedBox(height: HermesSpace.x2),
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        studioPieceLabel(selected.kind, s),
                        style: HermesType.style(
                          HermesType.title,
                          colors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  StudioPill(
                    key: const ValueKey('studio-piece-delete'),
                    label: s.bstPieceDelete,
                    icon: Icons.delete_outline_rounded,
                    onTap: () => _remove(index),
                  ),
                ],
              ),
              StudioSliderRow(
                key: const ValueKey('studio-piece-rotation'),
                label: s.bstPieceRotation,
                valueText: '${selected.rotation.round()}°',
                value: selected.rotation,
                min: BotStudioLimits.pieceRotationMin,
                max: BotStudioLimits.pieceRotationMax,
                onStart: _draft.beginGesture,
                onEnd: _draft.endGesture,
                onChanged: (v) =>
                    _change(index, (p) => p.copyWith(rotation: v)),
              ),
              StudioSliderRow(
                key: const ValueKey('studio-piece-size'),
                label: s.bstPieceSize,
                valueText: _percent(selected.scale),
                value: selected.scale,
                min: BotStudioLimits.pieceScaleMin,
                max: BotStudioLimits.pieceScaleMax,
                onStart: _draft.beginGesture,
                onEnd: _draft.endGesture,
                onChanged: (v) => _change(index, (p) => p.copyWith(scale: v)),
              ),
              HermesSwitchTile(
                key: const ValueKey('studio-piece-flip'),
                contentPadding: EdgeInsets.zero,
                title: s.bstPieceFlip,
                value: selected.flip,
                onChanged: (v) => _draft.apply(
                  _draft.value.copyWith(
                    pieces: [
                      for (var i = 0; i < c.pieces.length; i++)
                        i == index
                            ? c.pieces[i].copyWith(flip: v)
                            : c.pieces[i],
                    ],
                  ),
                ),
              ),
              Semantics(
                button: true,
                expanded: _positionOpen,
                label: s.bstPiecePosition,
                excludeSemantics: true,
                onTap: () => setState(() => _positionOpen = !_positionOpen),
                child: InkWell(
                  key: const ValueKey('studio-piece-position'),
                  onTap: () => setState(() => _positionOpen = !_positionOpen),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: HermesSpace.tap,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            s.bstPiecePosition,
                            style: HermesType.style(
                              HermesType.body,
                              colors.textPrimary,
                            ),
                          ),
                        ),
                        Icon(
                          _positionOpen
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          color: colors.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_positionOpen) ...[
                StudioSliderRow(
                  key: const ValueKey('studio-piece-across'),
                  label: s.bstPieceAcross,
                  valueText: _percent(selected.x),
                  value: selected.x,
                  onStart: _draft.beginGesture,
                  onEnd: _draft.endGesture,
                  onChanged: (v) => _change(index, (p) => p.copyWith(x: v)),
                ),
                StudioSliderRow(
                  key: const ValueKey('studio-piece-height'),
                  label: s.bstPieceHeight,
                  valueText: _percent(selected.y),
                  value: selected.y,
                  onStart: _draft.beginGesture,
                  onEnd: _draft.endGesture,
                  onChanged: (v) => _change(index, (p) => p.copyWith(y: v)),
                ),
              ],
            ],
          ],
        );
      },
    );
  }
}

// ── Colour ─────────────────────────────────────────────────────────────────

/// Fur, finish, solid colours (and a custom one) and the gradients.
class StudioColorPanel extends StatefulWidget {
  final CharacterDraft draft;
  final String profileName;

  const StudioColorPanel({
    super.key,
    required this.draft,
    required this.profileName,
  });

  @override
  State<StudioColorPanel> createState() => _StudioColorPanelState();
}

class _StudioColorPanelState extends State<StudioColorPanel> {
  bool _custom = false;

  CharacterDraft get _draft => widget.draft;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final swatches = ClassicFaceIdentity.colors.toList();
    return ListenableBuilder(
      listenable: _draft,
      builder: (context, _) {
        final c = _draft.value;
        final seeded = c.visual(widget.profileName).headColor;
        final solid = c.gradient == null ? (c.bodyColor ?? c.colorHex) : null;
        final customActive =
            c.gradient == null &&
            c.bodyColor != null &&
            (_custom || !swatches.contains(c.bodyColor));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HermesSwitchTile(
              key: const ValueKey('studio-fur'),
              contentPadding: EdgeInsets.zero,
              title: s.bstFur,
              value: c.fur,
              onChanged: (v) => _draft.apply(c.copyWith(fur: v)),
            ),
            HermesSectionHeader(s.bstFinish),
            HermesSegmentedControl<BotFinish>(
              key: const ValueKey('studio-finish'),
              value: c.finish,
              semanticLabel: s.bstFinish,
              onChanged: (v) => _draft.apply(c.copyWith(finish: v)),
              segments: [
                for (final finish in BotFinish.values)
                  HermesSegment(
                    key: ValueKey('studio-finish-${finish.name}'),
                    value: finish,
                    label: studioFinishLabel(finish, s),
                  ),
              ],
            ),
            HermesSectionHeader(s.bstSolidColors),
            Wrap(
              key: const ValueKey('character-color-palette'),
              spacing: HermesSpace.x2,
              runSpacing: HermesSpace.x3,
              children: [
                StudioTile(
                  key: const ValueKey('character-color-auto'),
                  label: s.bstColorOriginal,
                  selected:
                      c.gradient == null &&
                      c.bodyColor == null &&
                      c.colorHex == null,
                  onTap: () {
                    setState(() => _custom = false);
                    _draft.apply(
                      c.copyWith(
                        bodyColor: null,
                        colorHex: null,
                        gradient: null,
                      ),
                    );
                  },
                  preview: StudioSwatch(color: seeded),
                ),
                for (var i = 0; i < swatches.length; i++)
                  StudioTile(
                    key: ValueKey('character-color-${swatches[i]}'),
                    label: '${s.botFaceColor} ${i + 1}',
                    selected: solid == swatches[i] && !customActive,
                    onTap: () {
                      setState(() => _custom = false);
                      _draft.apply(
                        c.copyWith(
                          bodyColor: swatches[i],
                          colorHex: null,
                          gradient: null,
                        ),
                      );
                    },
                    preview: StudioSwatch(color: colorFromHex(swatches[i])),
                  ),
                StudioTile(
                  key: const ValueKey('studio-color-custom'),
                  label: s.bstBodyColor,
                  selected: customActive,
                  onTap: () {
                    setState(() => _custom = true);
                    if (c.bodyColor == null || c.gradient != null) {
                      _draft.apply(
                        c.copyWith(
                          bodyColor: hexFromColor(studioBodyColor(c, seeded)),
                          colorHex: null,
                          gradient: null,
                        ),
                      );
                    }
                  },
                  preview: const StudioSwatch(gradient: _rainbow),
                ),
              ],
            ),
            if (customActive)
              StudioColorPicker(
                color: colorFromHex(c.bodyColor!),
                onStart: _draft.beginGesture,
                onEnd: _draft.endGesture,
                onChanged: (color) => _draft.update(
                  _draft.value.copyWith(
                    bodyColor: hexFromColor(color),
                    colorHex: null,
                    gradient: null,
                  ),
                ),
              ),
            HermesSectionHeader(s.bstGradients),
            Wrap(
              spacing: HermesSpace.x2,
              runSpacing: HermesSpace.x3,
              children: [
                for (final gradient in botGradients)
                  StudioTile(
                    key: ValueKey('studio-gradient-${gradient.id}'),
                    label: studioGradientLabel(gradient.id, s),
                    selected: c.gradient == gradient.id,
                    onTap: () {
                      setState(() => _custom = false);
                      _draft.apply(c.copyWith(gradient: gradient.id));
                    },
                    preview: StudioSwatch(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          for (final stop in gradient.stops) colorFromHex(stop),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

// ── Generate ───────────────────────────────────────────────────────────────

/// Opens a chat of the profile with [prompt] already written. Provided by the
/// screen that knows the connection (see `studio_ask_agent.dart`); null when
/// the connection is read-only or no profile is active.
typedef StudioAskAgent =
    Future<void> Function(BuildContext context, String prompt);

enum _GenerateStatus { none, copied, applied, invalid, empty, needPhrase }

/// "Generate": a phrase for the profile's AI to turn into a character.
///
/// There is no cheap, tool-less path to the profile's model (see
/// `character_ai_request.dart`), so the request goes through a normal chat of
/// that profile: [askAgent] opens it with the prompt, and "Paste reply" takes
/// the answer back through the strict validator into the draft as ONE undo
/// step. Without [askAgent] the block is off and says why. The editor itself
/// never logs the phrase or the reply and keeps neither outside the draft (the
/// chat it opens keeps what it is sent, like any chat).
class StudioGenerateBlock extends StatefulWidget {
  final CharacterDraft? draft;
  final String profileName;
  final StudioAskAgent? askAgent;

  /// Called after a reply was applied (the editor clears its selection).
  final VoidCallback? onApplied;

  const StudioGenerateBlock({
    this.draft,
    this.profileName = '',
    this.askAgent,
    this.onApplied,
    super.key,
  });

  @override
  State<StudioGenerateBlock> createState() => _StudioGenerateBlockState();
}

class _StudioGenerateBlockState extends State<StudioGenerateBlock> {
  final TextEditingController _phrase = TextEditingController();
  _GenerateStatus _status = _GenerateStatus.none;
  bool _busy = false;

  bool get _available => widget.askAgent != null && widget.draft != null;

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  void _show(_GenerateStatus status) {
    if (mounted) setState(() => _status = status);
  }

  /// The request, or null (with the status set) when there is no phrase.
  String? _request() {
    final clean = BotCharacterAiRequest.cleanPhrase(_phrase.text);
    if (clean.isEmpty) {
      _show(_GenerateStatus.needPhrase);
      return null;
    }
    return BotCharacterAiRequest.buildPrompt(clean);
  }

  Future<void> _ask() async {
    final ask = widget.askAgent;
    final prompt = _request();
    if (ask == null || prompt == null || _busy) return;
    _busy = true;
    _show(_GenerateStatus.none);
    try {
      await ask(context, prompt);
    } finally {
      _busy = false;
    }
  }

  Future<void> _copy() async {
    final prompt = _request();
    if (prompt == null || _busy) return;
    _busy = true;
    try {
      await Clipboard.setData(ClipboardData(text: prompt));
      _show(_GenerateStatus.copied);
    } finally {
      _busy = false;
    }
  }

  Future<void> _paste() async {
    final draft = widget.draft;
    if (draft == null || _busy) return;
    _busy = true;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.trim().isEmpty) {
        _show(_GenerateStatus.empty);
        return;
      }
      final result = BotCharacterAiRequest.readReply(text);
      if (result == null) {
        _show(_GenerateStatus.invalid);
        return;
      }
      // One history step; the motion seed of the draft stays.
      draft.apply(result.character.copyWith(seed: draft.value.seed));
      _show(_GenerateStatus.applied);
      widget.onApplied?.call();
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final status = switch (_status) {
      _GenerateStatus.none => null,
      _GenerateStatus.copied => s.sagStatusCopied,
      _GenerateStatus.applied => s.sagStatusApplied,
      _GenerateStatus.invalid => s.sagStatusInvalid,
      _GenerateStatus.empty => s.sagStatusEmpty,
      _GenerateStatus.needPhrase => s.sagStatusNeedPhrase,
    };
    final failed =
        _status == _GenerateStatus.invalid ||
        _status == _GenerateStatus.empty ||
        _status == _GenerateStatus.needPhrase;
    return Column(
      key: const ValueKey('studio-generate'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HermesSectionHeader(s.bstGenerateTitle),
        TextField(
          key: const ValueKey('studio-generate-field'),
          controller: _phrase,
          enabled: _available,
          maxLength: BotCharacterAiRequest.maxPhraseChars,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          textInputAction: TextInputAction.done,
          style: HermesType.style(HermesType.text, colors.textPrimary),
          decoration: InputDecoration(
            hintText: s.bstGenerateHint,
            counterText: '',
          ),
        ),
        const SizedBox(height: HermesSpace.x2),
        HermesPrimaryButton(
          key: const ValueKey('studio-generate-button'),
          label: s.sagAsk,
          onTap: _available ? _ask : null,
        ),
        const SizedBox(height: HermesSpace.x2),
        Row(
          children: [
            Expanded(
              child: HermesSecondaryButton(
                key: const ValueKey('studio-generate-copy'),
                label: s.sagCopy,
                onTap: _available ? _copy : null,
              ),
            ),
            const SizedBox(width: HermesSpace.x2),
            Expanded(
              child: HermesSecondaryButton(
                key: const ValueKey('studio-generate-paste'),
                label: s.sagPaste,
                onTap: _available ? _paste : null,
              ),
            ),
          ],
        ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: HermesSpace.x2),
            child: Semantics(
              liveRegion: true,
              child: Text(
                status,
                key: const ValueKey('studio-generate-status'),
                style: HermesType.style(
                  HermesType.support,
                  failed ? colors.error : colors.textSecondary,
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: HermesSpace.x2),
          child: Text(
            _available ? s.sagHelp(widget.profileName) : s.sagOffWhy,
            key: const ValueKey('studio-generate-why'),
            style: HermesType.style(HermesType.support, colors.textSecondary),
          ),
        ),
      ],
    );
  }
}
