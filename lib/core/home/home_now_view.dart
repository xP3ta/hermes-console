import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../bots/ui/roster/living_bot_face.dart';
import '../theme/app_theme.dart';
import '../utils/relative_time.dart';
import '../widgets/hermes_premium_ui.dart';
import 'home_now.dart';

/// Motion of the light Home: one spring for the hero morph, short fades
/// elsewhere. Reduced motion commits every final state at once.
abstract final class HomeMotion {
  static const morph = Duration(milliseconds: 300);
  static const fade = Duration(milliseconds: 200);
  static const spring = Cubic(0.3, 1.25, 0.5, 1);
  static const check = Duration(milliseconds: 680);
  static const rowStagger = 50;
  static const rowDuration = Duration(milliseconds: 260);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// What the Home cards can do. Every action reuses an existing flow; the
/// screen wires them.
final class HomeNowActions {
  final Future<void> Function(HomeApprovalItem item, {required bool allow})
  answer;
  final void Function(HomeApprovalItem item) viewApproval;
  final void Function(HomeChatItem chat) openChat;
  final void Function(HomeRoomNews room) openRoom;
  final void Function(HomeTeamBot bot) openBot;
  final void Function(HomeAutomation automation) openAutomation;

  const HomeNowActions({
    required this.answer,
    required this.viewApproval,
    required this.openChat,
    required this.openRoom,
    required this.openBot,
    required this.openAutomation,
  });
}

String homeGreeting(Strings s, DateTime now) {
  final hour = now.hour;
  if (hour >= 6 && hour < 13) return s.homeGreetingMorning;
  if (hour >= 13 && hour < 21) return s.homeGreetingAfternoon;
  return s.homeGreetingNight;
}

/// «Forja», «Forja y Radar», «Forja, Radar y 2 más».
String homeJoinNames(Strings s, List<String> names) => switch (names.length) {
  0 => '',
  1 => names.single,
  2 => s.inicioNamesTwo(names[0], names[1]),
  _ => s.inicioNamesMore(names[0], names[1], names.length - 2),
};

String homeTeamSentence(Strings s, List<HomeTeamBot> team) {
  final waiting = [
    for (final bot in team)
      if (bot.state == HomeTeamState.waiting) bot.displayName,
  ];
  final working = [
    for (final bot in team)
      if (bot.state == HomeTeamState.working) bot.displayName,
  ];
  if (waiting.isEmpty) return s.inicioTeamWorking(homeJoinNames(s, working));
  if (working.isEmpty) {
    return s.inicioTeamWaiting(homeJoinNames(s, waiting), waiting.length);
  }
  return s.inicioTeamMixed(
    homeJoinNames(s, working),
    homeJoinNames(s, waiting),
  );
}

String homeStatusSentence(Strings s, HomeNow now) => switch (now.status.kind) {
  HomeStatusKind.calm => s.inicioStatusCalm,
  HomeStatusKind.needsYou => s.inicioStatusNeedsYou,
  HomeStatusKind.working => s.inicioStatusWorking(now.status.chatTitle!),
  HomeStatusKind.finished => s.inicioStatusFinished(now.status.chatTitle!),
  HomeStatusKind.team => homeTeamSentence(s, now.team),
};

/// Greeting, the one status sentence (crossfades when it changes) and, when
/// bots work or wait, their small faces with a line that opens the team.
class HomeStatusBlock extends StatelessWidget {
  final HomeNow now;
  final DateTime clock;
  final ValueChanged<HomeTeamBot> onOpenBot;

  const HomeStatusBlock({
    required this.now,
    required this.clock,
    required this.onOpenBot,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final reduced = HomeMotion.reduced(context);
    final sentence = homeStatusSentence(s, now);
    final sentenceIsTeam = now.status.kind == HomeStatusKind.team;
    final sentenceStyle = TextStyle(
      fontSize: 16,
      height: 1.3,
      color: colors.textSecondary,
    );
    Widget sentenceText = Text(
      sentence,
      key: ValueKey('home-status-$sentence'),
      style: sentenceStyle,
    );
    if (sentenceIsTeam) {
      sentenceText = _TeamLine(
        key: const ValueKey('home-status-team'),
        team: now.team,
        text: sentence,
        style: sentenceStyle,
        onOpenBot: onOpenBot,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            homeGreeting(s, clock),
            key: const ValueKey('home-greeting'),
            style: TextStyle(
              fontSize: 30,
              height: 1.15,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: colors.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Semantics(
          liveRegion: true,
          child: AnimatedSwitcher(
            duration: reduced ? Duration.zero : HomeMotion.fade,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, ?current],
            ),
            child: KeyedSubtree(
              key: ValueKey('status-${now.status.kind.name}-$sentence'),
              child: sentenceText,
            ),
          ),
        ),
        if (now.showTeamRow) ...[
          const SizedBox(height: 4),
          _TeamLine(
            key: const ValueKey('home-team-row'),
            team: now.team,
            text: homeTeamSentence(s, now.team),
            style: TextStyle(fontSize: 14, color: colors.textSecondary),
            onOpenBot: onOpenBot,
          ),
        ],
      ],
    );
  }
}

/// Overlapping faces + the team sentence + a chevron: one 48 dp target
/// that opens a small sheet with each bot.
class _TeamLine extends StatelessWidget {
  final List<HomeTeamBot> team;
  final String text;
  final TextStyle style;
  final ValueChanged<HomeTeamBot> onOpenBot;

  const _TeamLine({
    required this.team,
    required this.text,
    required this.style,
    required this.onOpenBot,
    super.key,
  });

  static const faceSize = 22.0;
  static const maxFaces = 3;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final faces = team.take(maxFaces).toList(growable: false);
    final stackWidth = faceSize + (faces.length - 1) * (faceSize * .62);
    return Semantics(
      button: true,
      label: text,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openSheet(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              SizedBox(
                width: stackWidth,
                height: faceSize + 4,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (var i = faces.length - 1; i >= 0; i--)
                      Positioned(
                        left: i * faceSize * .62,
                        top: 2,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colors.background,
                          ),
                          // Small faces hold the idle pose and share the
                          // rare list blink: the line says what they do,
                          // and an idle Home never produces frames.
                          child: LivingBotFace(
                            key: ValueKey(
                              'home-team-face-${faces[i].profileName}',
                            ),
                            profileName: faces[i].profileName,
                            signal: BotFaceSignal.idle,
                            size: faceSize,
                            entrance: false,
                            blink: LivingBotFaceBlink.shared,
                            style: LivingBotFaceStyle.dots,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSheet(BuildContext context) async {
    final s = Strings.of(context);
    final picked = await showHermesFloatingSurface<HomeTeamBot>(
      context: context,
      surfaceKey: const ValueKey('home-team-surface'),
      maxWidth: 420,
      maxHeightFactor: 0.72,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 18, 8, 12),
          child: Column(
            key: const ValueKey('home-team-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  s.inicioTeamSheetTitle,
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              for (final bot in team)
                ListTile(
                  key: ValueKey('home-team-bot-${bot.profileName}'),
                  minTileHeight: 56,
                  leading: LivingBotFace(
                    profileName: bot.profileName,
                    signal: bot.state == HomeTeamState.waiting
                        ? BotFaceSignal.attention
                        : BotFaceSignal.working,
                    size: 36,
                    entrance: false,
                    blink: LivingBotFaceBlink.shared,
                    style: LivingBotFaceStyle.dots,
                  ),
                  title: Text(bot.displayName),
                  subtitle: Text(
                    bot.state == HomeTeamState.waiting
                        ? s.inicioTeamBotWaiting
                        : bot.workingOn == null
                        ? s.inicioTeamBotWorking
                        : s.inicioTeamBotWorkingOn(bot.workingOn!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(sheetContext, bot),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onOpenBot(picked);
  }
}

/// The one card: its content morphs between states (size spring + cross
/// fade), keyed by what it shows so a refresh of the same thing never
/// restarts the animation.
class HomeHeroCard extends StatelessWidget {
  final HomeHero hero;
  final HomeNowActions actions;

  /// The «Pregunta a Hermes…» composer for the calm state.
  final Widget composer;
  final DateTime clock;

  /// Live clock of the working card's elapsed time.
  final DateTime Function() now;

  const HomeHeroCard({
    required this.hero,
    required this.actions,
    required this.composer,
    required this.clock,
    this.now = DateTime.now,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final reduced = HomeMotion.reduced(context);
    final child = KeyedSubtree(
      key: ValueKey('home-hero-${hero.key}'),
      child: switch (hero) {
        HomeHeroNeedsYou(:final approval) => _NeedsYouCard(
          approval: approval,
          actions: actions,
        ),
        HomeHeroWorking(:final chat) => _WorkingCard(
          chat: chat,
          actions: actions,
          now: now,
        ),
        HomeHeroFinished(:final chat) => _FinishedCard(
          chat: chat,
          actions: actions,
          clock: clock,
        ),
        HomeHeroCalm(:final starters) => _CalmCard(
          composer: composer,
          starters: starters,
          actions: actions,
        ),
      },
    );
    final switcher = AnimatedSwitcher(
      duration: reduced ? Duration.zero : HomeMotion.morph,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [...previous, ?current],
      ),
      child: child,
    );
    // A zero-length AnimatedSize can assert when its child resizes in the
    // same frame; with reduced motion the card simply takes its size.
    if (reduced) return switcher;
    return AnimatedSize(
      duration: HomeMotion.morph,
      curve: HomeMotion.spring,
      alignment: Alignment.topCenter,
      child: switcher,
    );
  }
}

Color _tint(BuildContext context, Color tone) {
  final colors = Theme.of(context).hermes;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return Color.alphaBlend(
    tone.withValues(alpha: dark ? .13 : .09),
    colors.surface,
  );
}

/// Soft tinted surface, no border.
class _HeroSurface extends StatelessWidget {
  final Color tone;
  final String semanticLabel;
  final Widget child;

  const _HeroSurface({
    required this.tone,
    required this.semanticLabel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: semanticLabel,
    child: DecoratedBox(
      key: const ValueKey('home-hero-surface'),
      decoration: BoxDecoration(
        color: _tint(context, tone),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: SizedBox(width: double.infinity, child: child),
      ),
    ),
  );
}

class _HeroLabel extends StatelessWidget {
  final Color tone;
  final String text;
  final Widget? leading;
  final Widget? trailing;

  const _HeroLabel({
    required this.tone,
    required this.text,
    this.leading,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Row(
      children: [
        leading ??
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
            ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: tone,
            ),
          ),
        ),
        if (trailing != null)
          DefaultTextStyle.merge(
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
            child: trailing!,
          ),
      ],
    );
  }
}

TextStyle _heroTitle(HermesThemeColors colors) => TextStyle(
  fontSize: 20,
  height: 1.25,
  fontWeight: FontWeight.w600,
  color: colors.textPrimary,
);

TextStyle _heroSub(HermesThemeColors colors) =>
    TextStyle(fontSize: 14, height: 1.3, color: colors.textSecondary);

ButtonStyle _filled(Color background, Color foreground) =>
    FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: foreground,
      minimumSize: const Size(64, 48),
      padding: const EdgeInsets.symmetric(horizontal: 26),
      shape: const StadiumBorder(),
      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    );

ButtonStyle _quiet(Color foreground) => TextButton.styleFrom(
  foregroundColor: foreground,
  minimumSize: const Size(48, 48),
  padding: const EdgeInsets.symmetric(horizontal: 14),
  textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
);

class _NeedsYouCard extends StatefulWidget {
  final HomeApprovalItem approval;
  final HomeNowActions actions;

  const _NeedsYouCard({required this.approval, required this.actions});

  @override
  State<_NeedsYouCard> createState() => _NeedsYouCardState();
}

class _NeedsYouCardState extends State<_NeedsYouCard> {
  bool _busy = false;

  Future<void> _answer(bool allow) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.actions.answer(widget.approval, allow: allow);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final approval = widget.approval;
    final tone = colors.warning;
    final title = approval.actor == null
        ? s.inicioNeedsYouTitle
        : s.inicioNeedsYouActorTitle(approval.actor!);
    return _HeroSurface(
      tone: tone,
      semanticLabel: s.inicioNeedsYouLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeroLabel(tone: tone, text: s.inicioNeedsYouLabel),
          const SizedBox(height: 12),
          Text(title, style: _heroTitle(colors)),
          if (approval.where.trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              s.inicioWhere(approval.where.trim()),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _heroSub(colors),
            ),
          ],
          if (approval.command.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              key: const ValueKey('home-approval-command'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: colors.background.withValues(alpha: .55),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                approval.command,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13.5,
                  height: 1.35,
                  color: colors.textPrimary,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (approval.canAllow)
                FilledButton(
                  key: const ValueKey('home-approval-allow'),
                  onPressed: _busy ? null : () => _answer(true),
                  style: _filled(tone, colors.background),
                  child: Text(s.inicioAllow),
                ),
              if (approval.canDeny)
                TextButton(
                  key: const ValueKey('home-approval-deny'),
                  onPressed: _busy ? null : () => _answer(false),
                  style: _quiet(colors.textSecondary),
                  child: Text(s.inicioDeny),
                ),
              TextButton(
                key: const ValueKey('home-approval-view'),
                onPressed: () => widget.actions.viewApproval(approval),
                style: _quiet(colors.textSecondary),
                child: Text(s.inicioView),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WorkingCard extends StatelessWidget {
  final HomeChatItem chat;
  final HomeNowActions actions;
  final DateTime Function() now;

  const _WorkingCard({
    required this.chat,
    required this.actions,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final tone = colors.accent;
    final since = chat.workingSince;
    return _HeroSurface(
      tone: tone,
      semanticLabel: s.inicioWorkingLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeroLabel(
            tone: tone,
            text: s.inicioWorkingLabel,
            trailing: since == null
                ? null
                : HomeElapsedText(since: since, now: now),
          ),
          const SizedBox(height: 12),
          Text(
            s.inicioWorkingTitle(chat.title),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: _heroTitle(colors),
          ),
          if (chat.step case final step? when step.trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              step,
              key: const ValueKey('home-working-step'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _heroSub(colors),
            ),
          ],
          const SizedBox(height: 14),
          FilledButton(
            key: const ValueKey('home-hero-open'),
            onPressed: () => actions.openChat(chat),
            style: _filled(tone, colors.onAccent),
            child: Text(s.inicioOpen),
          ),
        ],
      ),
    );
  }
}

class _FinishedCard extends StatelessWidget {
  final HomeChatItem chat;
  final HomeNowActions actions;
  final DateTime clock;

  const _FinishedCard({
    required this.chat,
    required this.actions,
    required this.clock,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final tone = colors.success;
    return _HeroSurface(
      tone: tone,
      semanticLabel: s.inicioFinishedLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeroLabel(
            tone: tone,
            text: s.inicioFinishedLabel,
            leading: HomeCheckMark(color: tone),
            trailing: Text(homeShortAgo(context, chat.at, clock)),
          ),
          const SizedBox(height: 12),
          Text(
            chat.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _heroTitle(colors),
          ),
          if (chat.preview.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              chat.preview,
              key: const ValueKey('home-finished-preview'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _heroSub(colors),
            ),
          ],
          const SizedBox(height: 14),
          FilledButton(
            key: const ValueKey('home-hero-open'),
            onPressed: () => actions.openChat(chat),
            style: _filled(colors.accent, colors.onAccent),
            child: Text(s.inicioOpen),
          ),
        ],
      ),
    );
  }
}

class _CalmCard extends StatelessWidget {
  final Widget composer;
  final List<HomeStarter> starters;
  final HomeNowActions actions;

  const _CalmCard({
    required this.composer,
    required this.starters,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        composer,
        for (final starter in starters)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('home-starter-${starter.key}'),
              onPressed: () => switch (starter) {
                HomeStarterContinue(:final chat) => actions.openChat(chat),
                HomeStarterReview(:final automation) => actions.openAutomation(
                  automation,
                ),
              },
              style: _quiet(
                starter is HomeStarterReview
                    ? colors.error
                    : colors.textSecondary,
              ),
              icon: Icon(
                starter is HomeStarterReview
                    ? Icons.error_outline_rounded
                    : Icons.subdirectory_arrow_right_rounded,
                size: 18,
              ),
              label: Text(
                switch (starter) {
                  HomeStarterContinue(:final chat) => s.inicioStarterContinue(
                    chat.title,
                  ),
                  HomeStarterReview(:final automation) => s.inicioStarterReview(
                    automation.name,
                  ),
                },
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );
  }
}

/// `m:ss` since [since], one tick per second while visible; a covered or
/// backgrounded Home ([TickerMode] off) or reduced motion stops the timer.
class HomeElapsedText extends StatefulWidget {
  final DateTime since;
  final DateTime Function() now;

  const HomeElapsedText({
    required this.since,
    this.now = DateTime.now,
    super.key,
  });

  static String format(Duration elapsed) {
    final total = math.max(0, elapsed.inSeconds);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final sec = (total % 60).toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$sec';
    return '$m:$sec';
  }

  @override
  State<HomeElapsedText> createState() => _HomeElapsedTextState();
}

class _HomeElapsedTextState extends State<HomeElapsedText> {
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final run = TickerMode.valuesOf(context).enabled;
    if (run && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!run) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    HomeElapsedText.format(widget.now().difference(widget.since)),
    key: const ValueKey('home-working-elapsed'),
    style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
  );
}

/// A check that draws itself once (circle, then the mark).
class HomeCheckMark extends StatelessWidget {
  final Color color;
  final double size;

  const HomeCheckMark({required this.color, this.size = 16, super.key});

  @override
  Widget build(BuildContext context) {
    final reduced = HomeMotion.reduced(context);
    return TweenAnimationBuilder<double>(
      key: const ValueKey('home-check'),
      tween: Tween(begin: reduced ? 1 : 0, end: 1),
      duration: reduced ? Duration.zero : HomeMotion.check,
      builder: (context, t, _) => CustomPaint(
        size: Size.square(size),
        painter: _CheckPainter(color: color, progress: t),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  final Color color;
  final double progress;
  const _CheckPainter({required this.color, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .11
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final rect = Offset.zero & size;
    final circle = (progress / .56).clamp(0.0, 1.0);
    canvas.drawArc(
      rect.deflate(paint.strokeWidth / 2),
      -math.pi / 2,
      2 * math.pi * circle,
      false,
      paint,
    );
    final mark = ((progress - .56) / .44).clamp(0.0, 1.0);
    if (mark <= 0) return;
    final path = Path()
      ..moveTo(size.width * .3, size.height * .52)
      ..lineTo(size.width * .45, size.height * .67)
      ..lineTo(size.width * .72, size.height * .38);
    final metric = path.computeMetrics().first;
    canvas.drawPath(metric.extractPath(0, metric.length * mark), paint);
  }

  @override
  bool shouldRepaint(_CheckPainter old) =>
      old.progress != progress || old.color != color;
}

/// The small time of a row, the same wording as the other session lists.
String homeShortAgo(BuildContext context, DateTime at, DateTime now) =>
    relativeTime(
      at.millisecondsSinceEpoch / 1000,
      languageCode: Localizations.localeOf(context).languageCode,
      now: now,
    );

/// «Retomar»: at most three quiet text rows; a room with news is a row.
/// Rows slide in once, the first time the section appears.
class HomeRetomarSection extends StatefulWidget {
  final List<HomeRetomarRow> rows;
  final HomeNowActions actions;
  final DateTime clock;

  const HomeRetomarSection({
    required this.rows,
    required this.actions,
    required this.clock,
    super.key,
  });

  @override
  State<HomeRetomarSection> createState() => _HomeRetomarSectionState();
}

class _HomeRetomarSectionState extends State<HomeRetomarSection> {
  /// Keys present at the first paint: only those stagger in.
  Set<String>? _entering;

  @override
  void initState() {
    super.initState();
    _entering = {for (final row in widget.rows) row.key};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _entering = const {};
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final reduced = HomeMotion.reduced(context);
    final entering = _entering ?? const {};
    return Column(
      key: const ValueKey('home-retomar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              s.homeResume,
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
          ),
        ),
        for (var i = 0; i < widget.rows.length; i++)
          _RowEntrance(
            key: ValueKey('home-retomar-entrance-${widget.rows[i].key}'),
            animate: !reduced && entering.contains(widget.rows[i].key),
            delay: Duration(milliseconds: i * HomeMotion.rowStagger),
            child: _RetomarRow(
              row: widget.rows[i],
              actions: widget.actions,
              clock: widget.clock,
            ),
          ),
      ],
    );
  }
}

class _RowEntrance extends StatelessWidget {
  final bool animate;
  final Duration delay;
  final Widget child;

  const _RowEntrance({
    required this.animate,
    required this.delay,
    required this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (!animate) return child;
    final total = HomeMotion.rowDuration + delay;
    final start = delay.inMilliseconds / total.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - t)),
          child: child,
        ),
      ),
    );
  }
}

class _RetomarRow extends StatelessWidget {
  final HomeRetomarRow row;
  final HomeNowActions actions;
  final DateTime clock;

  const _RetomarRow({
    required this.row,
    required this.actions,
    required this.clock,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final (title, news, preview, at, onTap) = switch (row) {
      HomeRetomarChat(:final chat) => (
        chat.title,
        null as String?,
        chat.preview,
        chat.at as DateTime?,
        () => actions.openChat(chat),
      ),
      HomeRetomarRoom(:final room) => (
        room.title,
        s.inicioRoomNews(room.count),
        '',
        room.at,
        () => actions.openRoom(room),
      ),
    };
    final time = at == null ? '' : homeShortAgo(context, at, clock);
    return Semantics(
      button: true,
      label: [title, ?news, if (preview.isNotEmpty) preview, time].join(', '),
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('home-retomar-${row.key}'),
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          text: title,
                          children: [
                            if (news != null)
                              TextSpan(
                                text: ' · $news',
                                style: TextStyle(color: colors.accent),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          height: 1.25,
                          fontWeight: FontWeight.w500,
                          color: colors.textPrimary,
                        ),
                      ),
                      if (preview.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            preview,
                            // Same key as the Conversations-parity tests
                            // read on the old Home row.
                            key: ValueKey('preview-$preview'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.25,
                              color: colors.textSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    time,
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
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

/// «Próximo»: one tiny line, red when an automation failed.
class HomeProximoLine extends StatelessWidget {
  final HomeProximo proximo;
  final String when;
  final ValueChanged<HomeAutomation> onTap;

  const HomeProximoLine({
    required this.proximo,
    required this.when,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final failed = proximo.failed;
    final color = failed ? colors.error : colors.textSecondary;
    final text = failed
        ? s.inicioFailed(proximo.automation.name)
        : s.inicioNext(proximo.automation.name, when);
    return Semantics(
      button: true,
      label: text,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey(failed ? 'home-proximo-failed' : 'home-proximo'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => onTap(proximo.automation),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Icon(
                failed ? Icons.error_outline_rounded : Icons.schedule_rounded,
                size: 15,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
