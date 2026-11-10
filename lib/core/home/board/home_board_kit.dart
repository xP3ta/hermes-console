/// Shared pieces of the Home widgets: labels, identity hues, icons, the
/// actions the screen wires, and the soft card every widget sits on.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../design/gel_surface.dart';
import '../../design/tokens.dart' show HermesSpace;
import '../../theme/app_theme.dart';
import '../../theme/soft_tokens.dart';
import '../../design/ambient_backdrop.dart' show HermesGlassLook;
import '../launcher/launcher_widget_geometry.dart';
import '../launcher/launcher_widget_palette.dart';
import '../launcher/launcher_widget_text.dart';
import '../home_now.dart';
import 'home_board_data.dart';
import 'home_board_model.dart';

/// Live adapter over the launcher's palette. Sheets use the opaque surface;
/// cards keep the full glass material. No per-kind hue rotation is introduced.
final class HomePalette {
  HomePalette(this.widget);
  final LauncherWidgetPalette widget;

  static final _cache = Expando<HomePalette>('homeWidgetPalette');

  static HomePalette ofContext(BuildContext context) {
    final theme = Theme.of(context);
    return _cache[theme] ??= HomePalette(
      LauncherWidgetPalette.of(
        theme.hermes,
        fontFamily: theme.textTheme.bodyMedium?.fontFamily ?? 'Inter',
      ),
    );
  }

  Color get surface =>
      Color.alphaBlend(widget.veil, Color.alphaBlend(widget.card, widget.page));
  Color get hairline => widget.hair;
  Color get inset => widget.variant;
  Color get track => widget.variant;
  Color get text => widget.ink;
  Color get textMuted => widget.ink2;
  Color get faint => widget.ink3;
  Color get attention => widget.warn;
  Color get failure => widget.error;
  Color get ok => widget.ok;
  Color get primary => widget.accent;
  Color get onPrimary => widget.onAccent;

  SoftTint tint(SoftHue hue) => SoftTint(
    widget.variant,
    hue == SoftHue.neutral ? widget.ink2 : widget.accentText,
  );
}

/// What the widgets can do. Every action reuses an existing flow; the
/// screen wires them.
final class HomeBoardActions {
  final Future<void> Function(HomeApprovalItem item, {required bool allow})
  answer;

  /// Sends one of a question's own choices as its answer.
  final Future<void> Function(HomeQuestionItem item, String choice)
  answerQuestion;
  final void Function(HomeApprovalItem item) viewApproval;
  final void Function(HomeQuestionItem item) viewQuestion;
  final void Function(HomeChatItem chat) openChat;
  final void Function(String roomKey) openRoom;
  final void Function(HomeBoardBot bot) openBot;
  final void Function(HomeAutomation? job) openAutomation;

  /// Opens Tasks, on [task] when given.
  final void Function(HomeTaskItem? task) openTasks;
  final VoidCallback openServer;
  final VoidCallback openSessions;

  /// Reads again what a widget could not read.
  final VoidCallback retry;

  const HomeBoardActions({
    required this.answer,
    required this.viewApproval,
    required this.openChat,
    required this.openRoom,
    required this.openBot,
    required this.openAutomation,
    required this.openServer,
    required this.openSessions,
    this.answerQuestion = _noAnswer,
    this.viewQuestion = _noQuestion,
    this.openTasks = _noTasks,
    this.retry = _nothing,
  });

  static Future<void> _noAnswer(HomeQuestionItem item, String choice) async {}
  static void _noQuestion(HomeQuestionItem item) {}
  static void _noTasks(HomeTaskItem? task) {}
  static void _nothing() {}

  /// Opens what a row of the dock's Actividad summary points at.
  void openGlance(HomeGlanceItem item) => open(item.target);

  /// Opens the screen of [target]: the chat, bot, room, approval, question,
  /// automation or task a row is about.
  void open(Object target) {
    switch (target) {
      case final HomeApprovalItem a:
        viewApproval(a);
      case final HomeQuestionItem q:
        viewQuestion(q);
      case final HomeChatItem c:
        openChat(c);
      case final HomeBoardBot b:
        openBot(b);
      case final HomeBoardRoom r:
        openRoom(r.key);
      case final HomeAutomation j:
        openAutomation(j);
      case final HomeTaskItem t:
        openTasks(t);
    }
  }
}

String homeWidgetName(Strings s, HomeWidgetKind kind) => switch (kind) {
  HomeWidgetKind.now => s.hwKindNow,
  HomeWidgetKind.team => s.hwKindTeam,
  HomeWidgetKind.bot => s.hwKindBot,
  HomeWidgetKind.room => s.hwKindRoom,
  HomeWidgetKind.chat => s.hwKindChat,
  HomeWidgetKind.continueChats => s.hwKindContinue,
  HomeWidgetKind.cron => s.hwKindCron,
  HomeWidgetKind.tasks => s.hwKindTasks,
  HomeWidgetKind.planLimits => s.hwKindLimits,
  HomeWidgetKind.server => s.hwKindServer,
  HomeWidgetKind.today => s.hwKindToday,
};

/// The name of a kind in «Añadir widget», where the list has to tell a bot
/// from the bots and a chat from the chats, and a long name has no room.
String homeWidgetAddName(Strings s, HomeWidgetKind kind) => switch (kind) {
  HomeWidgetKind.bot => s.hwAddBot,
  HomeWidgetKind.chat => s.hwAddChat,
  HomeWidgetKind.planLimits => s.hwAddLimits,
  _ => homeWidgetName(s, kind),
};

String homeSizeName(Strings s, HomeWidgetSize size) => switch (size) {
  HomeWidgetSize.small => s.hwSizeSmall,
  HomeWidgetSize.wide => s.hwSizeWide,
  HomeWidgetSize.large => s.hwSizeLarge,
};

IconData homeWidgetIcon(HomeWidgetKind kind) => switch (kind) {
  HomeWidgetKind.now => Icons.bolt_rounded,
  HomeWidgetKind.team => Icons.smart_toy_outlined,
  HomeWidgetKind.bot => Icons.smart_toy_outlined,
  HomeWidgetKind.room => Icons.forum_outlined,
  HomeWidgetKind.chat => Icons.chat_bubble_outline_rounded,
  HomeWidgetKind.continueChats => Icons.chat_bubble_outline_rounded,
  HomeWidgetKind.cron => Icons.schedule_rounded,
  HomeWidgetKind.tasks => Icons.view_kanban_outlined,
  HomeWidgetKind.planLimits => Icons.donut_large_rounded,
  HomeWidgetKind.server => Icons.dns_outlined,
  HomeWidgetKind.today => Icons.wb_sunny_outlined,
};

/// Identity hue of a kind (a role; the colour comes from the theme).
SoftHue homeWidgetHue(HomeWidgetKind kind) => switch (kind) {
  HomeWidgetKind.now => SoftHue.ember,
  HomeWidgetKind.team || HomeWidgetKind.bot => SoftHue.lavender,
  HomeWidgetKind.room => SoftHue.sky,
  HomeWidgetKind.chat || HomeWidgetKind.continueChats => SoftHue.sage,
  HomeWidgetKind.cron => SoftHue.sand,
  HomeWidgetKind.tasks => SoftHue.sage,
  HomeWidgetKind.planLimits => SoftHue.ember,
  HomeWidgetKind.server => SoftHue.sky,
  HomeWidgetKind.today => SoftHue.sage,
};

/// Tint of [item]: neutral when the user chose it for this widget or for
/// the whole board.
SoftTint homeWidgetTint(
  HomePalette palette,
  HomeWidgetInstance item, {
  required bool colorful,
}) => palette.tint(
  !colorful || item.stringOption('tint') == 'neutral'
      ? SoftHue.neutral
      : homeWidgetHue(item.kind),
);

/// Text styles of the widgets: one calm hierarchy. Every style states its
/// line height, so a widget knows how tall a line is at any text scale.
abstract final class HomeType {
  static TextStyle _role(HomePalette p, LwType type, Color ink) =>
      type.style(fontFamily: p.widget.fontFamily, color: ink);

  static TextStyle label(HomePalette p) => cap(p);
  static TextStyle title(HomePalette p) => _role(p, LwType.titleSmall, p.text);
  static TextStyle body(HomePalette p) => _role(p, LwType.line, p.text);
  static TextStyle row(HomePalette p) => _role(p, LwType.rowTitle, p.text);
  static TextStyle meta(HomePalette p) => _role(p, LwType.rowLine, p.textMuted);
  static TextStyle when(HomePalette p) =>
      _role(p, LwType.captionTabular, faint(p));
  static TextStyle timer(HomePalette p) => when(p).copyWith(color: live(p));
  static TextStyle cap(HomePalette p) => _role(p, LwType.eyebrow, p.textMuted);
  static TextStyle badge(HomePalette p, Color ink) =>
      _role(p, LwType.captionTabular, ink);
  static TextStyle unit(HomePalette p) => meta(p);

  static TextStyle huge(BuildContext context, HomePalette p, {double? size}) =>
      _role(p, LwType.big.at(size ?? hugeSize), p.text);

  static const double hugeSize = LwGrid.big;
  static const double hugeScale = 1.3;
  static TextStyle section(HomePalette p) => cap(p).copyWith(color: faint(p));
  static Color faint(HomePalette p) => p.faint;
  static Color live(HomePalette p) => p.widget.accentText;

  /// Reserve a complete scaled line, including paragraph rounding.
  static double line(BuildContext context, TextStyle style) =>
      (MediaQuery.textScalerOf(context).scale(style.fontSize!) * style.height!)
          .ceilToDouble();
}

/// The launcher's card geometry with the app's native glass material.
/// [hero] marks the widget that waits
/// for the user: an accent hairline, nothing louder. [outlined] is the
/// edit mode's quiet accent outline.
class HomeCard extends StatelessWidget {
  /// One compact padding for every widget.
  static const contentPadding = EdgeInsets.all(LwGrid.pad);

  const HomeCard({
    super.key,
    required this.child,
    this.padding = contentPadding,
    this.hero = false,
    this.outlined = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool hero;
  final bool outlined;

  /// How much of the accent the hairline of a [hero] card carries.
  static const double heroLine = 0.45;

  /// ... and the one of an [outlined] card.
  static const double outlinedLine = 0.4;

  /// The corners of the card, for what is drawn around it (selection ring,
  /// lifted shadow).
  static BorderRadius radiusOf(BuildContext context) =>
      BorderRadius.circular(LwGrid.radius);

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.ofContext(context);
    final line = hero
        ? HomeType.live(p).withValues(alpha: heroLine)
        : outlined
        ? HomeType.live(p).withValues(alpha: outlinedLine)
        : p.hairline;
    final content = Padding(
      padding: padding.subtract(const EdgeInsets.all(LwGrid.hairline)),
      child: child,
    );
    final glass = HermesGlassLook.of(context);
    if (glass != null) {
      return HermesGlassLook.body(
        glass,
        radiusOf(context),
        fill: p.surface,
        line: line,
        lifted: true,
        compact: true,
        child: content,
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: radiusOf(context),
        border: Border.all(color: line, width: LwGrid.hairline),
      ),
      child: content,
    );
  }
}

/// A big figure and, on its baseline, the unit it counts («3 en curso»).
/// The figure keeps its size past [HomeType.hugeScale] (the unit grows with
/// the text); whatever the scale, the line never asks for more width than
/// it has: the unit gives way first, then the figure uses a smaller shared role.
class HomeFigure extends StatelessWidget {
  const HomeFigure(
    this.figure, {
    super.key,
    this.unit,
    this.size,
    this.ink,
    this.semanticsLabel,
  });

  final String figure;
  final String? unit;
  final double? size;

  /// Colour of the figure; the palette's text by default.
  final Color? ink;
  final String? semanticsLabel;

  /// Height of the line at the text scale of [context]: the figure's,
  /// capped; the unit never stands taller than it.
  static double heightOf(BuildContext context, {double? size}) {
    final p = HomePalette.ofContext(context);
    final style = HomeType.huge(context, p, size: size);
    final capped = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: HomeType.hugeScale);
    final unit = HomeType.unit(p);
    // The unit sits on the figure's baseline: its descent may reach a
    // little under the figure's tight line; the slack keeps it whole.
    return math.max(
          capped.scale(style.fontSize!) * style.height!,
          HomeType.line(context, unit),
        ) +
        baselineSlack;
  }

  /// Room under the line for the unit's descent.
  static const double baselineSlack = 2;

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.ofContext(context);
    final scaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: HomeType.hugeScale);
    return Semantics(
      label: semanticsLabel ?? [figure, ?unit].join(' '),
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, box) {
          double width(String text, TextStyle style, TextScaler scale) {
            final painter = TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: Directionality.of(context),
              textScaler: scale,
              maxLines: 1,
            )..layout();
            final result = painter.width;
            painter.dispose();
            return result;
          }

          final wanted = size ?? HomeType.hugeSize;
          TextStyle style = HomeType.huge(context, p, size: wanted);
          // Whole figures, as in the raster: try the shared smaller roles
          // before simplifying. A time must never fade halfway through a digit.
          for (final candidate in [
            wanted,
            LwGrid.bigSmall,
            LwGrid.titleSmall,
          ]) {
            if (candidate > wanted) continue;
            style = HomeType.huge(
              context,
              p,
              size: candidate,
            ).copyWith(color: ink ?? p.text);
            if (width(figure, style, scaler) <= box.maxWidth) break;
          }
          if (width(figure, style, scaler) > box.maxWidth) {
            return const SizedBox.shrink();
          }
          final unitStyle = HomeType.unit(p);
          final unit = this.unit;
          final showUnit =
              unit != null &&
              width(figure, style, scaler) +
                      LwGrid.gapTight +
                      width(
                        unit,
                        unitStyle,
                        MediaQuery.textScalerOf(context),
                      ) <=
                  box.maxWidth;
          if (!showUnit &&
              unit != null &&
              width(unit, unitStyle, MediaQuery.textScalerOf(context)) <=
                  box.maxWidth) {
            // A narrow cell puts the unit below the whole figure rather
            // than clipping a fixed word. Keep the same reserved height.
            for (final candidate in [LwGrid.bigSmall, LwGrid.titleSmall]) {
              if (candidate > style.fontSize!) continue;
              final compact = HomeType.huge(
                context,
                p,
                size: candidate,
              ).copyWith(color: ink ?? p.text);
              if (scaler.scale(candidate) + HomeType.line(context, unitStyle) <=
                      heightOf(context, size: size) &&
                  width(figure, compact, scaler) <= box.maxWidth) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      figure,
                      maxLines: 1,
                      softWrap: false,
                      textScaler: scaler,
                      style: compact,
                    ),
                    Text(unit, maxLines: 1, softWrap: false, style: unitStyle),
                  ],
                );
              }
            }
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                figure,
                maxLines: 1,
                softWrap: false,
                textScaler: scaler,
                style: style,
              ),
              if (showUnit) ...[
                const SizedBox(width: LwGrid.gapTight),
                Text(unit, maxLines: 1, softWrap: false, style: unitStyle),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// A capsule button of the board: the gel of the app's buttons. The
/// primary one is the only accent on a card; the other is neutral glass.
/// Its label never wraps and grows less than the text around it, so the
/// capsule keeps its height.
class HomeGelPill extends StatelessWidget {
  const HomeGelPill(
    this.label, {
    super.key,
    this.icon,
    this.primary = false,
    this.height = defaultHeight,
    this.onTap,
    this.enabled = true,
    this.expand = false,
  });

  final String label;
  final IconData? icon;
  final bool primary;
  final double height;

  /// Null: the pill only names what its row does (the row is the target).
  final VoidCallback? onTap;
  final bool enabled;
  final bool expand;

  /// The capsule as designed; its touch area is [HermesSpace.tap].
  static const double defaultHeight = LwGrid.buttonSmall;

  /// How much its label grows with the text, at most.
  static const double labelScale = 1.3;

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.ofContext(context);
    final colors = Theme.of(context).hermes;
    final ink = primary ? colors.onAccent : p.text;
    final scaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: labelScale);
    final text = Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      textScaler: scaler,
      style: LwType.button.style(fontFamily: p.widget.fontFamily, color: ink),
    );
    final pill = Opacity(
      opacity: enabled ? 1 : 0.5,
      child: HermesGelSurface(
        shape: const StadiumBorder(),
        tone: primary ? HermesGelTone.accent : HermesGelTone.glass,
        ink: ink,
        paintFill: !primary,
        hairline: !primary,
        glow: false,
        pressable: false,
        enabled: enabled,
        child: SizedBox(
          height: height,
          width: expand ? double.infinity : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x3),
            child: Center(
              widthFactor: expand ? null : 1,
              child: icon == null
                  ? text
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 15, color: ink),
                        const SizedBox(width: HermesSpace.x1 + 2),
                        Flexible(child: text),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
    if (onTap == null && enabled) return ExcludeSemantics(child: pill);
    return Semantics(
      button: true,
      enabled: enabled && onTap != null,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        // The capsule is [height] tall; the touch area takes the room
        // around it.
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: HermesSpace.tap,
            minWidth: HermesSpace.tap,
          ),
          child: Center(widthFactor: 1, child: pill),
        ),
      ),
    );
  }
}

/// Header of a widget: a small neutral icon, the label in small capitals
/// and, at the end, a quiet note.
class HomeCardHeader extends StatelessWidget {
  const HomeCardHeader({
    super.key,
    required this.icon,
    required this.label,
    required this.tint,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final SoftTint tint;
  final Widget? trailing;

  /// Height of the header at the text scale of [context].
  static double heightOf(BuildContext context, HomePalette p) {
    // The band keeps the height the widgets were laid out for; the
    // capitals sit centred in it.
    final text = HomeType.line(context, HomeType.cap(p));
    return math.max(HermesSpace.x5, text);
  }

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.ofContext(context);
    // Small capitals with tracking; the screen reader keeps the name as
    // written.
    final title = Text(
      label.toUpperCase(),
      semanticsLabel: label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: HomeType.cap(p),
    );
    return SizedBox(
      height: heightOf(context, p),
      child: Row(
        children: [
          // A neutral line icon, not a coloured chip: the widget's name and
          // what it says carry the meaning, the colour is kept for state.
          // Faint, one weight under the label, centred on its line.
          SizedBox.square(
            dimension: HermesSpace.x5,
            child: Icon(icon, size: HermesSpace.x4, color: HomeType.faint(p)),
          ),
          const SizedBox(width: HermesSpace.x1 + 2),
          // The label keeps its width; the note sits at the end when it
          // fits whole beside it, and is left out when it does not. Both
          // stay centred on the band's line either way.
          Expanded(
            child: trailing == null
                ? title
                : ClipRect(
                    child: CustomMultiChildLayout(
                      delegate: _HeaderLine(Directionality.of(context)),
                      children: [
                        LayoutId(id: _HeaderPart.title, child: title),
                        LayoutId(id: _HeaderPart.note, child: trailing!),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

enum _HeaderPart { title, note }

/// The header's label at the start and its note at the end, both centred
/// on the line; the note is laid out of sight (and clipped) when it does
/// not fit whole beside the label.
class _HeaderLine extends MultiChildLayoutDelegate {
  _HeaderLine(this.direction);
  final TextDirection direction;

  /// Least room between the label and the note.
  static const double gap = 6;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    final title = layoutChild(_HeaderPart.title, loose);
    final note = layoutChild(_HeaderPart.note, loose);
    double start(double left, double width) =>
        direction == TextDirection.ltr ? left : size.width - left - width;
    positionChild(
      _HeaderPart.title,
      Offset(start(0, title.width), (size.height - title.height) / 2),
    );
    final fits = title.width + gap + note.width <= size.width + 0.5;
    positionChild(
      _HeaderPart.note,
      fits
          ? Offset(
              start(size.width - note.width, note.width),
              (size.height - note.height) / 2,
            )
          : Offset(0, size.height + note.height),
    );
  }

  @override
  bool shouldRelayout(_HeaderLine oldDelegate) =>
      oldDelegate.direction != direction;
}

/// Static loading placeholder (no shimmer, no frames).
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key, this.lines = 2});
  final int lines;

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.ofContext(context);
    return Column(
      key: const ValueKey('home-widget-skeleton'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < lines; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          FractionallySizedBox(
            widthFactor: i == 0 ? 0.7 : 0.45,
            child: Container(
              height: 10,
              decoration: ShapeDecoration(
                color: p.track,
                shape: const StadiumBorder(),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
