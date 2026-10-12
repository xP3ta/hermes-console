/// Shared pieces of the Home widgets: labels, identity hues, icons, the
/// actions the screen wires, and the soft card every widget sits on.
library;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme/soft_tokens.dart';
import '../home_now.dart';
import 'home_board_data.dart';
import 'home_board_model.dart';

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
  HomeWidgetKind.team => Icons.groups_2_outlined,
  HomeWidgetKind.bot => Icons.smart_toy_outlined,
  HomeWidgetKind.room => Icons.forum_outlined,
  HomeWidgetKind.chat => Icons.chat_bubble_outline_rounded,
  HomeWidgetKind.continueChats => Icons.history_rounded,
  HomeWidgetKind.cron => Icons.schedule_rounded,
  HomeWidgetKind.tasks => Icons.view_kanban_outlined,
  HomeWidgetKind.planLimits => Icons.donut_large_rounded,
  HomeWidgetKind.server => Icons.dns_outlined,
  HomeWidgetKind.today => Icons.today_outlined,
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
  SoftPalette palette,
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
  static TextStyle label(SoftPalette p) => TextStyle(
    fontSize: 13,
    height: 21 / 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    color: p.textMuted,
  );

  static TextStyle title(SoftPalette p) => TextStyle(
    fontSize: 17,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.35,
    color: p.text,
  );

  static TextStyle body(SoftPalette p) => TextStyle(
    fontSize: 14,
    height: 19 / 14,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.1,
    color: p.text,
  );

  /// The first line of a row: who or what.
  static TextStyle row(SoftPalette p) =>
      body(p).copyWith(fontWeight: FontWeight.w600);

  /// The second line of a row, and every quiet line.
  static TextStyle meta(SoftPalette p) => TextStyle(
    fontSize: 13,
    height: 17 / 13,
    fontWeight: FontWeight.w400,
    color: p.textMuted,
  );

  /// A time, a countdown, a count at the edge of a row.
  static TextStyle when(SoftPalette p) => TextStyle(
    fontSize: 12.5,
    height: 17 / 12.5,
    fontWeight: FontWeight.w400,
    color: faint(p),
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// A running clock.
  static TextStyle timer(SoftPalette p) => TextStyle(
    fontSize: 13,
    height: 17 / 13,
    fontWeight: FontWeight.w600,
    color: live(p),
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// A group heading inside a widget.
  static TextStyle section(SoftPalette p) => TextStyle(
    fontSize: 11,
    height: 16 / 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.4,
    color: faint(p),
  );

  static TextStyle figure(SoftPalette p, {double size = 34}) => TextStyle(
    fontSize: size,
    height: 1.11,
    fontWeight: FontWeight.w500,
    letterSpacing: -size * 0.02,
    color: p.text,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// Quieter than muted: times and counts.
  static Color faint(SoftPalette p) => p.textMuted.withValues(alpha: 0.82);

  /// The theme's accent as an ink readable on a card: what is alive.
  static Color live(SoftPalette p) => p.tint(SoftHue.ember).ink;

  /// Height of one line of [style] at the text scale of [context].
  static double line(BuildContext context, TextStyle style) =>
      MediaQuery.textScalerOf(context).scale(style.fontSize!) * style.height!;
}

/// The soft surface of one widget: neutral, hairline, squircle corners.
/// [hero] marks the widget that waits for the user.
class HomeCard extends StatelessWidget {
  /// One compact padding for every widget.
  static const contentPadding = EdgeInsets.fromLTRB(14, 12, 14, 12);

  const HomeCard({
    super.key,
    required this.child,
    this.padding = contentPadding,
    this.hero = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    final accent = HomeType.live(p);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: hero ? null : p.surface,
        gradient: hero
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.62],
                colors: [
                  Color.alphaBlend(accent.withValues(alpha: 0.07), p.surface),
                  p.surface,
                ],
              )
            : null,
        shape: SoftShapes.card(
          side: BorderSide(
            color: hero ? accent.withValues(alpha: 0.45) : p.hairline,
            width: hero ? 1 : 0.8,
          ),
        ),
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: SoftShapes.card()),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Header of a widget: a small tinted chip, the label, a trailing note.
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
  static double heightOf(BuildContext context, SoftPalette p) {
    final text = HomeType.line(context, HomeType.label(p));
    return text < 22 ? 22 : text;
  }

  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
    final title = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: HomeType.label(p),
    );
    return SizedBox(
      height: heightOf(context, p),
      child: Row(
        children: [
          DecoratedBox(
            decoration: ShapeDecoration(
              color: tint.wash,
              shape: SoftShapes.card(radius: 7),
            ),
            child: SizedBox.square(
              dimension: 21,
              child: Icon(icon, size: 14, color: tint.ink),
            ),
          ),
          const SizedBox(width: 9),
          // The label keeps its width; the note sits at the end when it
          // fits whole beside it, and is left out when it does not (it
          // wraps to a second line this row does not have).
          Expanded(
            child: trailing == null
                ? title
                : ClipRect(
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 64,
                      children: [title, trailing!],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Static loading placeholder (no shimmer, no frames).
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key, this.lines = 2});
  final int lines;

  @override
  Widget build(BuildContext context) {
    final p = SoftPalette.ofContext(context);
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
