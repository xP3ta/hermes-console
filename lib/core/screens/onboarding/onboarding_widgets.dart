import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../widgets/hermes_ui.dart' show PressableScale;
import 'onboarding_motion.dart';

/// One horizontal gutter for everything on a first-run screen.
const double kOnbGutter = 24;

const double kOnbPillHeight = 54;

TextStyle onbTitle(HermesThemeColors c, {double size = 28}) => TextStyle(
  fontSize: size,
  fontWeight: FontWeight.w700,
  height: 1.18,
  letterSpacing: -0.3,
  color: c.textPrimary,
);

/// Titles follow the system text size up to a point: at 2x a 28 sp title
/// would break words on a 320 dp phone.
TextScaler onbTitleScaler(BuildContext context) =>
    MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.35);

TextStyle onbBody(HermesThemeColors c) =>
    TextStyle(fontSize: 15, height: 1.45, color: c.textSecondary);

/// The primary action: a full-width pill, 54 dp, in the theme's accent.
/// [expand] grows it from a round button holding only its icon (0) to the
/// whole pill (1), for the opening.
class OnbPrimary extends StatelessWidget {
  const OnbPrimary({
    required this.label,
    required this.onTap,
    this.icon,
    this.expand = 1,
    super.key,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final double expand;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    final enabled = onTap != null;
    final fg = enabled ? c.onAccent : c.textDisabled;
    final full = MediaQuery.sizeOf(context).width - 2 * kOnbGutter;
    final factor = expand >= 1
        ? 1.0
        : ((kOnbPillHeight + (full - kOnbPillHeight) * expand) / full).clamp(
            0.1,
            1.0,
          );
    return FractionallySizedBox(
      widthFactor: factor,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        excludeSemantics: true,
        child: PressableScale(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: kOnbPillHeight),
            padding: EdgeInsets.symmetric(
              horizontal: expand > 0.6 ? 20 : 0,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              color: enabled ? c.accent : c.surfaceVariant,
              borderRadius: BorderRadius.circular(kOnbPillHeight / 2),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) Icon(icon, size: 20, color: fg),
                if (icon != null && expand > 0.6) const SizedBox(width: 9),
                if (expand > 0.6)
                  Flexible(
                    child: Opacity(
                      opacity: ((expand - 0.6) / 0.4).clamp(0.0, 1.0),
                      child: Text(
                        label,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: fg,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact pill: filled in the accent, or tonal.
class OnbSmallPill extends StatelessWidget {
  const OnbSmallPill({
    required this.label,
    required this.onTap,
    this.icon,
    this.filled = false,
    this.onDark = false,
    super.key,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool filled;

  /// Over the camera: a dark translucent pill with a hairline.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    final bg = filled
        ? c.accent
        : onDark
        ? const Color(0xE0272834)
        : c.surfaceVariant;
    final fg = filled
        ? c.onAccent
        : onDark
        ? const Color(0xFFF1EFE6)
        : c.textPrimary;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(22),
            border: onDark ? Border.all(color: const Color(0x1FFFFFFF)) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: Icon(icon, key: ValueKey(icon), size: 16, color: fg),
                ),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: fg,
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

/// A plain centred text action: no icon, no chevron, no divider.
class OnbTextButton extends StatelessWidget {
  const OnbTextButton({required this.label, required this.onTap, super.key});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        highlightShape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(23),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// The round back button: 40 dp, a hairline, a chevron.
class OnbBack extends StatelessWidget {
  const OnbBack({required this.onTap, this.onDark = false, super.key});
  final VoidCallback onTap;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: MaterialLocalizations.of(context).backButtonTooltip,
      excludeSemantics: true,
      child: InkResponse(
        key: const ValueKey('onboarding-back'),
        onTap: onTap,
        radius: 26,
        child: SizedBox.square(
          dimension: 48,
          child: Center(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: onDark ? const Color(0xB81F1F2B) : c.surface,
                border: Border.all(
                  color: onDark ? const Color(0x24FFFFFF) : c.divider,
                ),
              ),
              child: Icon(
                Icons.chevron_left_rounded,
                size: 24,
                color: onDark ? const Color(0xFFF1EFE6) : c.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The card the mockup uses for summaries and results.
class OnbCard extends StatelessWidget {
  const OnbCard({
    required this.child,
    this.tone,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    super.key,
  });
  final Widget child;
  final Color? tone;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: tone == null
            ? c.surface
            : Color.alphaBlend(tone!.withValues(alpha: .07), c.surface),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(
          color: tone?.withValues(alpha: .5) ?? c.divider.withValues(alpha: .8),
        ),
      ),
      child: child,
    );
  }
}

enum OnbCheck { wait, spin, ok, no }

/// One line of a checklist: a round badge (a tick that draws itself, a cross,
/// a spinner or an empty ring), a title and an optional note.
class OnbCheckRow extends StatelessWidget {
  const OnbCheckRow({
    required this.state,
    required this.title,
    this.note,
    this.last = false,
    super.key,
  });
  final OnbCheck state;
  final String title;
  final String? note;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    final reduced = OnboardingMotion.reduced(context);
    final badge = switch (state) {
      OnbCheck.ok => Container(
        key: const ValueKey('ok'),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.success.withValues(alpha: .16),
        ),
        child: DrawnCheck(size: 26, color: c.success, width: 2.6),
      ),
      OnbCheck.no => Container(
        key: const ValueKey('no'),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.error.withValues(alpha: .16),
        ),
        child: Icon(Icons.close_rounded, size: 16, color: c.error),
      ),
      OnbCheck.spin => Padding(
        key: const ValueKey('spin'),
        padding: const EdgeInsets.all(2),
        child: reduced
            ? SizedBox.square(
                dimension: 22,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: c.accent, width: 2.5),
                  ),
                ),
              )
            : CircularProgressIndicator(strokeWidth: 2.5, color: c.accent),
      ),
      OnbCheck.wait => Padding(
        key: const ValueKey('wait'),
        padding: const EdgeInsets.all(2),
        child: SizedBox.square(
          dimension: 22,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.divider, width: 2.5),
            ),
          ),
        ),
      ),
    };
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(color: c.divider.withValues(alpha: .6)),
              ),
            ),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 26,
            child: AnimatedSwitcher(
              duration: Duration(milliseconds: reduced ? 0 : 220),
              child: badge,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: state == OnbCheck.wait
                        ? FontWeight.w500
                        : FontWeight.w600,
                    color: state == OnbCheck.wait
                        ? c.textSecondary
                        : c.textPrimary,
                  ),
                ),
                if (note != null)
                  Text(
                    note!,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.3,
                      color: c.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The first line of the result card: the Hermes that was just connected, by
/// the icon of where it lives, its name and that place in words.
class OnbIdentityRow extends StatelessWidget {
  const OnbIdentityRow({
    required this.icon,
    required this.title,
    this.note,
    super.key,
  });
  final IconData icon;
  final String title;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: c.divider.withValues(alpha: .6)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.accent.withValues(alpha: .16),
            ),
            child: Icon(icon, size: 20, color: c.accentText),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
                if (note != null)
                  Text(
                    note!,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.3,
                      color: c.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A two-way switch whose thumb slides.
class OnbSegmented<T> extends StatelessWidget {
  const OnbSegmented({
    required this.value,
    required this.options,
    required this.onChanged,
    super.key,
  });
  final T value;
  final List<(T, String, Key)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    final index = options
        .indexWhere((o) => o.$1 == value)
        .clamp(0, options.length - 1);
    final reduced = OnboardingMotion.reduced(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: c.divider.withValues(alpha: .8)),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedAlign(
              duration: Duration(milliseconds: reduced ? 0 : 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment(
                options.length == 1 ? 0 : -1 + 2 * index / (options.length - 1),
                0,
              ),
              child: FractionallySizedBox(
                widthFactor: 1 / options.length,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.surfaceVariant,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: c.accent.withValues(alpha: .55)),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final (v, label, key) in options)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: v == value,
                    label: label,
                    excludeSemantics: true,
                    child: InkResponse(
                      key: key,
                      onTap: () => onChanged(v),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 40),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            label,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: v == value
                                  ? c.textPrimary
                                  : c.textSecondary,
                            ),
                          ),
                        ),
                      ),
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

/// The command in a rounded code block. It types itself in once (about 18 ms a
/// character, never more than 1.2 s) and is complete at once on a tap, with
/// reduced motion or with a screen reader.
class OnbCodeBlock extends StatefulWidget {
  const OnbCodeBlock({required this.command, super.key});
  final String command;

  @override
  State<OnbCodeBlock> createState() => _OnbCodeBlockState();
}

class _OnbCodeBlockState extends State<OnbCodeBlock>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;
  bool _typed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_typed) return;
    _typed = true;
    if (OnboardingMotion.reduced(context) ||
        MediaQuery.accessibleNavigationOf(context)) {
      return;
    }
    final ms = (widget.command.length * 18).clamp(0, 1200);
    _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: ms),
    )..forward();
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  void _finish() => _c?.value = 1;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).hermes;
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.5,
      color: c.accentText,
    );
    final full = Text(widget.command, style: style);
    final controller = _c;
    return GestureDetector(
      onTap: _finish,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: Color.lerp(c.background, Colors.black, .22),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.divider.withValues(alpha: .8)),
        ),
        child: controller == null
            ? SelectionArea(child: Text(widget.command, style: style))
            : AnimatedBuilder(
                animation: controller,
                builder: (_, _) {
                  final done = controller.value >= 1;
                  if (done) {
                    return SelectionArea(
                      child: Text(widget.command, style: style),
                    );
                  }
                  final n = (widget.command.length * controller.value).floor();
                  return Stack(
                    children: [
                      // The full text holds the block's height.
                      Opacity(opacity: 0, child: full),
                      Text('${widget.command.substring(0, n)}█', style: style),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

Future<void> onbCopy(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (_) {}
}
