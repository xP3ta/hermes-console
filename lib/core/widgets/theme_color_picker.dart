import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/theme_profile_codec.dart';
import 'hermes_premium_ui.dart';

Future<Color?> showHermesColorPicker(
  BuildContext context, {
  required Color initialColor,
  required String title,
  required String invalidFormatLabel,
  ValueChanged<Color>? onPreviewChanged,
}) => showHermesFloatingSurface<Color>(
  context: context,
  surfaceKey: const ValueKey('theme-color-picker-surface'),
  maxWidth: 520,
  maxHeightFactor: 0.9,
  builder: (_) => _HermesColorPickerSheet(
    initialColor: initialColor,
    title: title,
    invalidFormatLabel: invalidFormatLabel,
    onPreviewChanged: onPreviewChanged,
  ),
);

class _HermesColorPickerSheet extends StatefulWidget {
  final Color initialColor;
  final String title;
  final String invalidFormatLabel;
  final ValueChanged<Color>? onPreviewChanged;

  const _HermesColorPickerSheet({
    required this.initialColor,
    required this.title,
    required this.invalidFormatLabel,
    this.onPreviewChanged,
  });

  @override
  State<_HermesColorPickerSheet> createState() =>
      _HermesColorPickerSheetState();
}

class _HermesColorPickerSheetState extends State<_HermesColorPickerSheet> {
  late HSVColor _hsv;
  late final TextEditingController _hex;
  bool _hexValid = true;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    _hex = TextEditingController(
      text: ThemeProfileCodec.colorToCanonical(widget.initialColor),
    );
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Color get _color => _hsv.toColor();

  void _setHsv(HSVColor value) {
    final canonical = ThemeProfileCodec.colorToCanonical(value.toColor());
    setState(() {
      _hsv = value;
      _hexValid = true;
      _hex.value = TextEditingValue(
        text: canonical,
        selection: TextSelection.collapsed(offset: canonical.length),
      );
    });
    widget.onPreviewChanged?.call(value.toColor());
  }

  void _setHex(String raw) {
    final normalized = raw.trim();
    final match = RegExp(r'^#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$');
    if (!match.hasMatch(normalized)) {
      setState(() => _hexValid = false);
      return;
    }
    final canonical = normalized.length == 7
        ? 'FF${normalized.substring(1)}'
        : normalized.substring(1);
    final parsed = int.tryParse(canonical, radix: 16);
    if (parsed == null || (parsed >> 24) == 0) {
      setState(() => _hexValid = false);
      return;
    }
    final color = Color(parsed);
    setState(() {
      _hsv = HSVColor.fromColor(color);
      _hexValid = true;
    });
    widget.onPreviewChanged?.call(color);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final material = MaterialLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                Semantics(
                  label: widget.title,
                  value: ThemeProfileCodec.colorToCanonical(_color),
                  child: Container(
                    key: const Key('theme_color_preview'),
                    width: 88,
                    height: 14,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          HSVColor.fromColor(_color)
                              .withSaturation(
                                (HSVColor.fromColor(_color).saturation * 0.4)
                                    .clamp(0.0, 1.0)
                                    .toDouble(),
                              )
                              .toColor(),
                          _color,
                          HSVColor.fromColor(_color)
                              .withValue(
                                (HSVColor.fromColor(_color).value * 0.62)
                                    .clamp(0.0, 1.0)
                                    .toDouble(),
                              )
                              .toColor(),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: colors.divider),
                      boxShadow: [
                        BoxShadow(
                          color: _color.withValues(alpha: 0.18),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _ColorSpectrumBar(
              hsv: _hsv,
              label: widget.title,
              onChanged: _setHsv,
            ),
            const SizedBox(height: 10),
            _ShadePalette(hsv: _hsv, label: widget.title, onChanged: _setHsv),
            const SizedBox(height: 14),
            TextField(
              key: const Key('theme_color_hex'),
              controller: _hex,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                LengthLimitingTextInputFormatter(9),
                FilteringTextInputFormatter.allow(RegExp(r'[#0-9A-Fa-f]')),
              ],
              onChanged: _setHex,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
              ),
              decoration: InputDecoration(
                labelText: 'HEX · #AARRGGBB',
                errorText: _hexValid ? null : widget.invalidFormatLabel,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(material.cancelButtonLabel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('theme_color_confirm'),
                  onPressed: _hexValid
                      ? () => Navigator.of(context).pop(_color)
                      : null,
                  child: Text(material.okButtonLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A single tactile spectrum replaces the technical H/S sliders and the color
/// wheel. Horizontal movement selects hue; vertical movement controls
/// saturation. Tone remains a small, discrete choice below it.
class _ColorSpectrumBar extends StatelessWidget {
  final HSVColor hsv;
  final String label;
  final ValueChanged<HSVColor> onChanged;

  const _ColorSpectrumBar({
    required this.hsv,
    required this.label,
    required this.onChanged,
  });

  void _select(Offset localPosition, Size size) {
    final hue = (localPosition.dx / size.width).clamp(0.0, 1.0) * 360;
    final saturation = (localPosition.dy / size.height).clamp(0.0, 1.0);
    onChanged(
      HSVColor.fromAHSV(
        hsv.alpha,
        hue,
        saturation,
        hsv.value < 0.12 ? 0.85 : hsv.value,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    value: ThemeProfileCodec.colorToCanonical(hsv.toColor()),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, 38);
        return GestureDetector(
          key: const Key('theme_color_spectrum'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _select(details.localPosition, size),
          onPanStart: (details) => _select(details.localPosition, size),
          onPanUpdate: (details) => _select(details.localPosition, size),
          child: SizedBox(
            height: size.height,
            child: CustomPaint(painter: _ColorSpectrumPainter(hsv)),
          ),
        );
      },
    ),
  );
}

class _ColorSpectrumPainter extends CustomPainter {
  final HSVColor hsv;

  const _ColorSpectrumPainter(this.hsv);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(13));
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    if (hsv.value < 1) {
      canvas.drawRect(
        rect,
        Paint()..color = Colors.black.withValues(alpha: 1 - hsv.value),
      );
    }
    canvas.restore();

    canvas.drawRRect(
      rrect.deflate(0.75),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0x55000000),
    );

    final rawCursor = Offset(
      (hsv.hue / 360).clamp(0.0, 1.0) * size.width,
      hsv.saturation.clamp(0.0, 1.0) * size.height,
    );
    final cursor = Offset(
      rawCursor.dx.clamp(7.0, size.width - 7),
      rawCursor.dy.clamp(12.0, size.height - 12),
    );
    final indicator = RRect.fromRectAndRadius(
      Rect.fromCenter(center: cursor, width: 5, height: 24),
      const Radius.circular(2.5),
    );
    canvas.drawRRect(
      indicator.inflate(1.5),
      Paint()..color = const Color(0x66000000),
    );
    canvas.drawRRect(indicator, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_ColorSpectrumPainter oldDelegate) =>
      oldDelegate.hsv != hsv;
}

class _ShadePalette extends StatelessWidget {
  static const values = [1.0, 0.66, 0.34, 0.08];

  final HSVColor hsv;
  final String label;
  final ValueChanged<HSVColor> onChanged;

  const _ShadePalette({
    required this.hsv,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          for (var index = 0; index < values.length; index++)
            Expanded(
              child: Semantics(
                button: true,
                selected: (hsv.value - values[index]).abs() < 0.04,
                label: '$label ${(values[index] * 100).round()}%',
                child: InkWell(
                  key: Key('theme_color_shade_$index'),
                  onTap: () => onChanged(hsv.withValue(values[index])),
                  borderRadius: BorderRadius.circular(10),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: hsv.withValue(values[index]).toColor(),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: (hsv.value - values[index]).abs() < 0.04
                            ? colors.textPrimary
                            : colors.divider.withValues(alpha: 0.7),
                        width: (hsv.value - values[index]).abs() < 0.04 ? 2 : 1,
                      ),
                    ),
                    child: (hsv.value - values[index]).abs() < 0.04
                        ? Icon(
                            HIcons.check_rounded,
                            size: 18,
                            color:
                                ThemeData.estimateBrightnessForColor(
                                      hsv.withValue(values[index]).toColor(),
                                    ) ==
                                    Brightness.dark
                                ? Colors.white
                                : Colors.black,
                          )
                        : null,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
