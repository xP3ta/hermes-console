/// The Home widgets themselves: one builder per kind. A widget fills the
/// cell the board gives it (the grid never grows): the same subject at
/// every size, and more of it when the cell is bigger. Each one declares
/// the height of its pieces at the current text scale and shows the ones
/// that fit, so nothing overflows and nothing is cut in half.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../bots/ui/roster/living_bot_face.dart';
import '../../design/schedule_model.dart' show HermesSchedule;
import '../../design/tokens.dart' show HermesSpace, HermesType;
import '../../services/connection_status.dart';
import '../../theme/soft_tokens.dart';
import '../../utils/relative_time.dart';
import '../../widgets/profile_face.dart' show ProfileFace;
import '../../widgets/provider_logo.dart';
import '../../widgets/face_marks.dart';
import '../../widgets/activity_pill.dart' show formatTurnElapsed;
import '../home_now.dart';
import '../launcher/launcher_widget_geometry.dart';
import '../launcher/launcher_widget_words.dart';
import '../launcher/launcher_widget_palette.dart';
import 'home_limits.dart';
import 'home_board_data.dart';
import 'home_board_kit.dart';
import 'home_board_model.dart';

part 'home_board_tiles_classic.dart';

/// Inputs every widget body gets.
final class HomeTileContext {
  final HomeWidgetInstance item;
  final HomeBoardData data;
  final HomeBoardActions actions;
  final SoftTint tint;

  /// Edit mode: content is inert.
  final bool editing;

  /// Wall clock for elapsed and countdown text.
  final DateTime Function() clock;

  const HomeTileContext({
    required this.item,
    required this.data,
    required this.actions,
    required this.tint,
    required this.editing,
    required this.clock,
  });

  HomeWidgetSize get size => item.size;
}

/// Whether the card of [item] is marked as waiting for the user: «Ahora»
/// while something needs an answer.
bool homeWidgetHero(HomeWidgetInstance item, HomeBoardData data) =>
    item.kind == HomeWidgetKind.now && data.nowBoard.asks.isNotEmpty;

/// Body of a widget, by kind.
class HomeWidgetBody extends StatelessWidget {
  const HomeWidgetBody(this.t, {super.key});
  final HomeTileContext t;

  @override
  Widget build(BuildContext context) => switch (t.item.kind) {
    HomeWidgetKind.now => _NowTile(t),
    HomeWidgetKind.continueChats => _ChatsTile(t),
    HomeWidgetKind.team => _BotsTile(t),
    HomeWidgetKind.room => _RoomsTile(t),
    HomeWidgetKind.cron => _CronTile(t),
    HomeWidgetKind.tasks => _TasksTile(t),
    HomeWidgetKind.bot => _BotTile(t),
    HomeWidgetKind.chat => _ChatTile(t),
    HomeWidgetKind.planLimits => _LimitsTile(t),
    HomeWidgetKind.server => _ServerTile(t),
    HomeWidgetKind.today => _TodayTile(t),
  };
}

// ── time and words ─────────────────────────────────────────────────────

String homeAgo(BuildContext context, DateTime at, DateTime now) => relativeTime(
  at.millisecondsSinceEpoch / 1000,
  languageCode: Localizations.localeOf(context).languageCode,
  now: now,
);

/// «hace 20 min», «há 20 min», «20m ago»: [homeAgo] as a phrase.
String homeSince(BuildContext context, DateTime at, DateTime now) {
  final diff = now.difference(at);
  final strings = Strings.of(context);
  if (diff.isNegative || diff.inMinutes < 1 || diff.inDays >= 7) {
    return homeAgo(context, at, now);
  }
  if (diff.inHours < 1) return strings.i18n131SinceMinutes(diff.inMinutes);
  if (diff.inDays < 1) return strings.i18n131SinceHours(diff.inHours);
  return strings.i18n131SinceDays(diff.inDays);
}

LwWords _words(BuildContext context, DateTime now) => LwWords(
  Strings.of(context),
  locale: Localizations.localeOf(context),
  use24h: MediaQuery.alwaysUse24HourFormatOf(context),
  nowMs: now.millisecondsSinceEpoch,
);

String _time(BuildContext context, DateTime at) =>
    _words(context, at).time(at.millisecondsSinceEpoch);

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// «lun 12».
String homeDayLabel(Strings s, DateTime at) =>
    '${HermesSchedule.weekdayAbbr(s, at.weekday)} ${at.day}';

/// When something happened, at the edge of a row: «ahora» within the
/// minute, the time today, the weekday and day within a week, the date
/// before that.
String homeWhen(BuildContext context, DateTime at, DateTime now) {
  if (now.difference(at).abs() < const Duration(minutes: 1)) {
    return homeAgo(context, now, now);
  }
  if (_sameDay(at, now)) return _time(context, at);
  if (now.difference(at).inDays.abs() < 7) {
    return homeDayLabel(Strings.of(context), at);
  }
  return MaterialLocalizations.of(context).formatShortMonthDay(at);
}

String homeElapsed(Duration d) =>
    formatTurnElapsed(d.isNegative ? Duration.zero : d);

/// The launcher calendar's exact hours and minutes, in the app's locale.
String homeCountdown(BuildContext context, Duration d) {
  final now = DateTime.fromMillisecondsSinceEpoch(0);
  return _words(context, now).inTime(math.max(0, d.inMilliseconds)) ??
      Strings.of(context).lwpInMinutes(0);
}

/// Elapsed time that ticks once a second on its own (only this text
/// rebuilds), and only while it is on screen (TickerMode).
class HomeElapsed extends StatefulWidget {
  const HomeElapsed({
    super.key,
    required this.since,
    required this.clock,
    this.style,
    this.prefix,
  });
  final DateTime since;
  final DateTime Function() clock;
  final TextStyle? style;

  /// Text before the time (e.g. a separator), clipped with it.
  final String? prefix;

  @override
  State<HomeElapsed> createState() => _HomeElapsedState();
}

class _HomeElapsedState extends State<HomeElapsed> {
  Timer? _timer;
  int? _paintedSecond;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A clock is information, including with reduced motion enabled.
    final run = TickerMode.valuesOf(context).enabled;
    if (run && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted &&
            widget.clock().millisecondsSinceEpoch ~/ 1000 != _paintedSecond) {
          setState(() {});
        }
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
  Widget build(BuildContext context) {
    final now = widget.clock();
    _paintedSecond = now.millisecondsSinceEpoch ~/ 1000;
    final time = homeElapsed(now.difference(widget.since));
    final style = (widget.style ?? const TextStyle()).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // A clock is whole or not there: without its prefix when the line has
    // no room for it (it grew a digit), and left out when it has none for
    // the time itself.
    return LayoutBuilder(
      builder: (context, box) {
        bool fits(String text) =>
            _lineWidth(context, text, style) <= box.maxWidth + 0.5;
        final prefix = widget.prefix;
        final shown = prefix != null && fits('$prefix$time')
            ? '$prefix$time'
            : time;
        if (!fits(shown)) return const SizedBox.shrink();
        return Text(
          shown,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: style,
        );
      },
    );
  }
}

// ── faces ──────────────────────────────────────────────────────────────

/// Colour of a bot's state dot: none while idle (calm), the one accent
/// while it works or waits for the user (the ring tells the two apart).
Color? homeBotDotColor(HomePalette p, HomeBotState state) => switch (state) {
  HomeBotState.idle => null,
  HomeBotState.working || HomeBotState.waiting => HomeType.live(p),
};

/// Whether the face of a bot in [state] wears the accent ring: the one
/// that waits for the user («te espera»).
bool homeFaceRinged(HomeBotState state) => state == HomeBotState.waiting;

/// Stroke of the ring and the gap between it and the face, as the profile
/// faces wear it.
const double _ringWidth = ProfileFace.ringWidth;
const double _ringGap = ProfileFace.ringGap;

/// Room a ringed face needs around its box (the ring hangs outside it),
/// rounded up to the spacing grid.
const double _ringRoom = HermesSpace.x1;

/// How a Home widget face moves for [state].
BotFaceSignal homeBotFaceSignal(HomeBotState state) => switch (state) {
  HomeBotState.idle => BotFaceSignal.idle,
  HomeBotState.working => BotFaceSignal.working,
  HomeBotState.waiting => BotFaceSignal.attention,
};

/// The original bot face inside widgets: alive like on the Bots home
/// (idle breath and blinks, working scan, a nudge while it waits) on the
/// shared face clocks, only while its tile is on screen. Its state is a
/// small dot at the corner and, while it waits for the user, the accent
/// ring the profile faces wear; never a glow. The ring hangs outside the
/// face's box, so the face keeps its size and place whatever its state.
class HomeFace extends StatelessWidget {
  const HomeFace({
    super.key,
    required this.profileName,
    required this.data,
    this.state = HomeBotState.idle,
    this.size = 36,
    this.dot = true,
  });
  final String profileName;
  final HomeBoardData data;
  final HomeBotState state;
  final double size;

  /// The state dot at its corner. Off where the row beside it already
  /// says the state; the face still moves with it.
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.ofContext(context);
    final bot = data.bot(profileName);
    final dot = this.dot ? homeBotDotColor(p, state) : null;
    final face = LivingBotFace(
      key: ValueKey('home-face-$profileName'),
      profileName: profileName,
      profile: data.profileFor(profileName),
      avatarCache: data.avatarCache,
      size: size,
      entrance: false,
      style: LivingBotFaceStyle.dots,
      // The dot below marks the state; the face only moves with it.
      stateMark: false,
      signal: homeBotFaceSignal(state),
      semanticLabel: bot?.displayName ?? profileName,
    );
    final ringed = homeFaceRinged(state);
    if (dot == null && !ringed) return face;
    final d = math.max(7.0, (size * 0.22).roundToDouble());
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (ringed)
            Positioned(
              left: -(_ringWidth + _ringGap),
              top: -(_ringWidth + _ringGap),
              right: -(_ringWidth + _ringGap),
              bottom: -(_ringWidth + _ringGap),
              child: DecoratedBox(
                key: ValueKey('home-face-ring-$profileName'),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: HomeType.live(p),
                    width: _ringWidth,
                  ),
                ),
              ),
            ),
          face,
          if (dot != null)
            PositionedDirectional(
              end: -1,
              bottom: -1,
              // A plain dot, no ring in the card colour (QA 9494: the same
              // face sits in sheets and on other cards, where it read as a
              // dark halo).
              child: FaceStateDot(
                key: ValueKey('home-face-dot-$profileName'),
                color: dot,
                size: d + 1,
              ),
            ),
        ],
      ),
    );
  }
}

/// The face of a row: who it is about, or a calm icon when no profile
/// owns it.
class _Who extends StatelessWidget {
  const _Who({
    required this.profile,
    required this.t,
    this.size = 30,
    this.icon = Icons.chat_bubble_outline_rounded,
  });
  final String? profile;
  final HomeTileContext t;
  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final name = profile;
    if (name != null && name.isNotEmpty) {
      return HomeFace(profileName: name, data: t.data, size: size);
    }
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: t.tint.wash,
        shape: SoftShapes.card(radius: size / 3),
      ),
      child: SizedBox.square(
        dimension: size,
        child: Icon(icon, size: size * 0.52, color: t.tint.ink),
      ),
    );
  }
}

/// A row of overlapping faces, with «+N» for the rest.
class _FaceStack extends StatelessWidget {
  const _FaceStack({required this.profiles, required this.t, this.size = 20});
  final List<String> profiles;
  final HomeTileContext t;
  final double size;

  /// Faces shown before «+N».
  static const max = 3;

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.ofContext(context);
    final shown = profiles.take(max).toList();
    final more = profiles.length - shown.length;
    const overlap = 5.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: shown.isEmpty
              ? 0
              : size + (shown.length - 1) * (size - overlap),
          height: size,
          child: Stack(
            children: [
              for (final (i, profile) in shown.indexed)
                PositionedDirectional(
                  start: i * (size - overlap),
                  child: LivingBotFace(
                    profileName: profile,
                    profile: t.data.profileFor(profile),
                    avatarCache: t.data.avatarCache,
                    size: size,
                    entrance: false,
                    animate: false,
                    stateMark: false,
                    style: LivingBotFaceStyle.dots,
                    signal: BotFaceSignal.idle,
                  ),
                ),
            ],
          ),
        ),
        if (more > 0) ...[
          const SizedBox(width: 3),
          _Badge('+$more', color: p.track, ink: p.textMuted),
        ],
      ],
    );
  }
}

// ── shared bits ────────────────────────────────────────────────────────

class _Tap extends StatelessWidget {
  const _Tap({required this.onTap, required this.child, this.label});
  final VoidCallback? onTap;
  final Widget child;
  final String? label;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: child,
    ),
  );
}

/// Runs [action] unless the board is being edited.
VoidCallback? _act(HomeTileContext t, VoidCallback action) =>
    t.editing ? null : action;

Widget _header(HomeTileContext t, BuildContext context, {Widget? trailing}) =>
    HomeCardHeader(
      icon: homeWidgetIcon(t.item.kind),
      label: homeWidgetName(Strings.of(context), t.item.kind),
      tint: t.tint,
      trailing: trailing,
    );

/// The note at the end of a header («1 PARA TI», «2 EN MARCHA»): the same
/// small capitals as the label, a step quieter, never a capsule. [color]
/// is the state it speaks of (what asks, what failed); without one it is
/// faint. A [dot] before it says the same without the colour.
class _HeadNote extends StatelessWidget {
  const _HeadNote(this.text, {this.dot, this.color, super.key});
  final String text;
  final Color? dot;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.ofContext(context);
    final ink = color ?? HomeType.faint(p);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot != null) ...[
          _Dot(dot!, size: 5),
          const SizedBox(width: HermesSpace.x1 + 1),
        ],
        Flexible(
          child: Text(
            text.toUpperCase(),
            semanticsLabel: text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            textScaler: _capped(context, 1.3),
            style: HomeType.badge(p, ink),
          ),
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color, {this.size = 7, super.key});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// A small count or tag («3», «1 para ti», «+2»).
class _Badge extends StatelessWidget {
  const _Badge(this.text, {required this.color, required this.ink});
  final String text;
  final Color color;
  final Color ink;

  static TextStyle _style(BuildContext context, Color ink) =>
      HomeType.badge(HomePalette.ofContext(context), ink);

  static double heightOf(BuildContext context) {
    final style = _style(context, HomePalette.ofContext(context).text);
    return math.max(
      HermesSpace.x5,
      (_capped(context, HomeType.hugeScale).scale(style.fontSize!) *
                  style.height!)
              .ceilToDouble() +
          HermesSpace.x1 / 2,
    );
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
    child: SizedBox(
      height: heightOf(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HermesSpace.x1),
        child: Center(
          widthFactor: 1,
          child: Text(
            text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            textScaler: _capped(context, HomeType.hugeScale),
            style: _style(context, ink),
          ),
        ),
      ),
    ),
  );
}

/// What a status line starts with.
enum _Mark { none, live, done, failed, draft, asks }

/// One quiet line with its mark: a live dot, a check, a cross.
class _Status extends StatelessWidget {
  const _Status(
    this.text, {
    this.mark = _Mark.none,
    this.ink = false,
    this.timer,
    this.clock,
    this.suffix,
  });
  final String text;
  final _Mark mark;

  /// Quiet text after everything else («luego, Astra»).
  final String? suffix;

  /// Text colour instead of muted (what is alive, what asks).
  final bool ink;

  /// A running clock after the text.
  final DateTime? timer;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.ofContext(context);
    final color = mark == _Mark.failed
        ? p.failure
        : ink
        ? p.text
        : p.textMuted;
    final style = HomeType.meta(p).copyWith(color: color);
    final lead = switch (mark) {
      _Mark.none => null,
      _Mark.live => _Dot(HomeType.live(p)),
      _Mark.done => Icon(Icons.check_rounded, size: 14, color: p.ok),
      _Mark.failed => Icon(Icons.close_rounded, size: 14, color: p.failure),
      _Mark.draft => Icon(Icons.edit_outlined, size: 13, color: p.textMuted),
      _Mark.asks => Icon(Icons.help_rounded, size: 14, color: HomeType.live(p)),
    };
    return LayoutBuilder(
      builder: (context, box) {
        final room = box.maxWidth.isFinite
            ? math.max(0.0, box.maxWidth - (lead == null ? 0 : 20))
            : double.infinity;
        // The clock keeps its width and the words give way to it. Where
        // the line has no room for « · 0:42», the clock stands alone;
        // where it has none for «0:42», the line keeps its words (and the
        // clock, should it grow a digit, gives up its prefix on its own).
        var withWords = true;
        var withClock = false;
        if (timer case final since? when clock != null) {
          final now = homeElapsed(clock!().difference(since));
          final clockStyle = style.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          );
          bool fits(String s) =>
              _lineWidth(context, s, clockStyle) <= room + 0.5;
          if (text.isNotEmpty && fits(' · $now')) {
            withClock = true;
          } else if (fits(now)) {
            withClock = true;
            withWords = text.isEmpty;
          }
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (lead != null) ...[lead, const SizedBox(width: 6)],
            if (withWords)
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            if (withClock)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: room),
                child: HomeElapsed(
                  since: timer!,
                  clock: clock!,
                  prefix: withWords && text.isNotEmpty ? ' · ' : null,
                  style: style,
                ),
              ),
            if (suffix != null && withWords)
              Flexible(
                child: Text(
                  ' · $suffix',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style.copyWith(color: p.textMuted),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A capsule: the action of a row, or an answer ([HomeGelPill]).
class _Pill extends StatelessWidget {
  const _Pill(
    this.label, {
    this.icon,
    this.primary = false,
    this.height = 28,
    this.onTap,
    this.enabled = true,
    this.expand = false,
    super.key,
  });
  final String label;
  final IconData? icon;
  final bool primary;
  final double height;

  /// Null: the pill only names what its row does (the row is the target).
  final VoidCallback? onTap;
  final bool enabled;
  final bool expand;

  @override
  Widget build(BuildContext context) => HomeGelPill(
    label,
    icon: icon,
    primary: primary,
    height: height,
    onTap: onTap,
    enabled: enabled,
    expand: expand,
  );
}

/// The text scale of [context], no larger than [max]: a capsule keeps its
/// height, so its label grows less than the text around it.
TextScaler _capped(BuildContext context, double max) =>
    MediaQuery.textScalerOf(context).clamp(maxScaleFactor: max);

/// [text] continuing a line: its first letter in lower case.
String _lowerFirst(String text) =>
    text.isEmpty ? text : text[0].toLowerCase() + text.substring(1);

/// Text is scaled enough that a second line no longer fits where one was
/// designed.
bool _bigText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(14) / 14 > 1.3;

// ── fitting ────────────────────────────────────────────────────────────

/// A piece of a widget and the height it takes at the current text scale.
final class _Piece {
  const _Piece(
    this.height,
    this.child, {
    this.gap = 0,
    this.rule = false,
    this.withNext = false,
    this.center = false,
    this.or,
    bool? row,
  }) : row = row ?? (rule && center);
  final double height;
  final Widget child;

  /// A row of a list (by default, a centred piece under a hairline): it
  /// may give up a little of its height when that lets one more row in.
  final bool row;

  /// The least height it can take.
  double get least => height;

  /// A shorter version of this piece, shown when it does not fit.
  final _Piece? or;

  /// Space above it (not above the first piece).
  final double gap;

  /// A hairline above it (not above the first piece).
  final bool rule;

  /// Shown only together with the piece after it (a heading).
  final bool withNext;

  /// Centres its content in [height] (a row); otherwise it starts at the
  /// top.
  final bool center;
}

/// Shows, top to bottom, the pieces that fit in the height it is given,
/// and [footer] at the bottom. Whatever does not fit whole is left out,
/// never cut (a cell with no room for one line shows its header alone).
class _Fit extends StatelessWidget {
  const _Fit({required this.pieces, this.footer, this.design});
  final List<_Piece> pieces;
  final _Piece? footer;

  /// The height the pieces were designed for (the cell of a 152 dp row).
  /// In a shorter one the rows tighten to show what they show there.
  final double? design;

  /// The version of [footer] to show: the fullest one that fits in [max]
  /// under the shortest version of the first piece; none when even its
  /// shortest does not.
  static _Piece? footerFor(List<_Piece> pieces, double max, _Piece? footer) {
    var first = 0.0;
    if (pieces.isNotEmpty) {
      var shortest = pieces.first;
      while (shortest.or != null) {
        shortest = shortest.or!;
      }
      first = shortest.height;
    }
    for (var foot = footer; foot != null; foot = foot.or) {
      if (first + foot.gap + foot.height <= max + 0.5) return foot;
    }
    return null;
  }

  /// The pieces of [pieces] that fit in [max], with [footer] kept too.
  static List<_Piece> keep(List<_Piece> pieces, double max, _Piece? footer) {
    final reserved = footer == null ? 0.0 : footer.gap + footer.height;
    final kept = <_Piece>[];
    var used = 0.0;
    for (var i = 0; i < pieces.length; i++) {
      _Piece? fitting;
      for (_Piece? piece = pieces[i]; piece != null; piece = piece.or) {
        var need = (kept.isEmpty ? 0 : piece.gap) + piece.height;
        if (piece.withNext) {
          if (i + 1 >= pieces.length) break;
          need += pieces[i + 1].gap + pieces[i + 1].height;
        }
        if (used + need + reserved <= max + 0.5) {
          fitting = piece;
          break;
        }
        // A first piece whose shortest version has no room is left out
        // too: the card keeps its header and says less, never a cut line.
      }
      if (fitting == null) break;
      used += (kept.isEmpty ? 0 : fitting.gap) + fitting.height;
      kept.add(fitting);
    }
    return kept;
  }

  /// The pieces to show in [max] and the height each one takes: those
  /// that fit at their own height ([keep]). In a cell shorter than the
  /// [design] one, the rows give up some of their air so that it still
  /// shows the rows the designed cell shows, all sharing what there is.
  static List<(_Piece, double)> fitted(
    List<_Piece> pieces,
    double max,
    _Piece? footer, {
    double? design,
  }) {
    final kept = keep(pieces, max, footer);
    if (design == null || max >= design - 0.5) {
      return [for (final p in kept) (p, p.height)];
    }
    final target = keep(pieces, design, footer).length;
    final reserved = footer == null ? 0.0 : footer.gap + footer.height;
    _Piece at(int i) => i < kept.length ? kept[i] : pieces[i];
    double total(int count, double Function(_Piece) height) {
      var sum = 0.0;
      for (var i = 0; i < count; i++) {
        sum += (i == 0 ? 0 : at(i).gap) + height(at(i));
      }
      return sum;
    }

    var count = kept.length;
    while (count < target) {
      // A heading comes with the row under it.
      final step = pieces[count].withNext ? 2 : 1;
      if (count + step > target ||
          !pieces[count + step - 1].row ||
          total(count + step, (p) => p.least) + reserved > max + 0.5) {
        break;
      }
      count += step;
    }
    if (count == kept.length) return [for (final p in kept) (p, p.height)];
    final least = total(count, (p) => p.least);
    final give = total(count, (p) => p.height) - least;
    final share = give <= 0
        ? 0.0
        : ((max - reserved - least) / give).clamp(0.0, 1.0);
    return [
      for (var i = 0; i < count; i++)
        (at(i), at(i).least + (at(i).height - at(i).least) * share),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.ofContext(context);
    return LayoutBuilder(
      builder: (context, box) {
        final max = box.maxHeight;
        final foot = footerFor(pieces, max, footer);
        final rows = fitted(pieces, max, foot, design: design);
        var used = 0.0;
        for (final (i, (piece, height)) in rows.indexed) {
          used += (i == 0 ? 0 : piece.gap) + height;
        }
        final showFoot =
            foot != null && used + foot.gap + foot.height <= max + 0.5;
        final spare = math.max(
          0.0,
          max - used - (showFoot ? foot.gap + foot.height : 0),
        );
        final list = rows.isNotEmpty && rows.every((r) => r.$1.row);
        // All sizes keep complete rows. Lists share the available height;
        // a sparse non-list body is centred as a group under its heading.
        final extra = list ? spare / rows.length : 0.0;
        Widget box0(_Piece piece, [double? height]) => SizedBox(
          height: height ?? piece.height,
          child: ClipRect(
            child: OverflowBox(
              alignment: piece.center
                  ? AlignmentDirectional.centerStart
                  : AlignmentDirectional.topStart,
              minHeight: 0,
              maxHeight: double.infinity,
              child: piece.child,
            ),
          ),
        );
        // What fits within the half-pixel rounding allowance above may
        // still be that much taller than the box: the column gets its room
        // and the clip takes the fraction.
        final content = used + (showFoot ? foot.gap + foot.height : 0);
        return ClipRect(
          child: OverflowBox(
            alignment: AlignmentDirectional.topStart,
            minHeight: max,
            maxHeight: math.max(max, content),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!list && spare > 0) SizedBox(height: spare / 2),
                for (final (i, (piece, height)) in rows.indexed) ...[
                  if (i > 0 && piece.gap > 0) SizedBox(height: piece.gap),
                  if (i > 0 && piece.rule)
                    SizedBox(
                      height: 0,
                      child: OverflowBox(
                        maxHeight: 1,
                        child: ColoredBox(
                          color: p.hairline,
                          child: const SizedBox(
                            height: 1,
                            width: double.infinity,
                          ),
                        ),
                      ),
                    ),
                  box0(piece, height + extra),
                ],
                if (!list && spare > 0) SizedBox(height: spare / 2),
                if (showFoot) ...[SizedBox(height: foot.gap), box0(foot)],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A widget: its header, then the pieces that fit.
class _Body extends StatelessWidget {
  const _Body({
    required this.t,
    required this.pieces,
    this.footer,
    this.trailing,
    this.onHeader,
    this.gap = 6,
    this.faded,
    super.key,
  });
  final HomeTileContext t;
  final List<_Piece> pieces;
  final _Piece? footer;
  final Widget? trailing;

  /// What a tap on the header opens (the whole list).
  final VoidCallback? onHeader;
  final double gap;

  /// The pieces step back (old data while the server does not answer).
  /// By default, whenever the board is offline; a card that only says so
  /// keeps its line at full strength.
  final bool? faded;

  /// How far the pieces step back while offline.
  static const double stale = LauncherWidgetPalette.dimOpacity;

  @override
  Widget build(BuildContext context) {
    final header = _header(t, context, trailing: trailing);
    final rows = t.size.rows;
    final design =
        HomeBoardGridRule.rowHeight * rows +
        HomeBoardGridRule.gap * (rows - 1) -
        HomeCard.contentPadding.vertical -
        HomeCardHeader.heightOf(context, HomePalette.ofContext(context)) -
        gap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!t.editing && onHeader == null)
          header
        else if (!t.editing)
          _Tap(onTap: _act(t, onHeader!), child: header),
        if (!t.editing) SizedBox(height: gap),
        Expanded(
          child: Opacity(
            opacity: (faded ?? t.data.offline) ? stale : 1,
            child: _Fit(pieces: pieces, footer: footer, design: design),
          ),
        ),
      ],
    );
  }
}

/// One line of quiet text as a piece.
_Piece _quietPiece(BuildContext context, String text, {int lines = 2}) {
  final p = HomePalette.ofContext(context);
  final style = HomeType.meta(p);
  return _Piece(
    HomeType.line(context, style) * lines,
    Text(text, maxLines: lines, overflow: TextOverflow.ellipsis, style: style),
    gap: 2,
    or: lines > 1 ? _quietPiece(context, text, lines: 1) : null,
  );
}

/// A widget that has nothing to list: one calm line under its header.
Widget _quiet(HomeTileContext t, BuildContext context, String text) =>
    _Body(t: t, pieces: [_quietPiece(context, text)], faded: false);

/// A widget still waiting for its first read.
Widget _loading(HomeTileContext t, BuildContext context, {Key? key}) =>
    t.data.offline
    ? _quiet(t, context, Strings.of(context).hwServerOffline)
    : _Body(
        t: t,
        pieces: [_Piece(28, HomeSkeleton(key: key), gap: 2)],
      );

/// A widget whose read failed: it says so and offers the read again.
Widget _unread(HomeTileContext t, BuildContext context) {
  final s = Strings.of(context);
  if (t.data.offline) return _quiet(t, context, s.hwServerOffline);
  return _Body(
    key: const ValueKey('home-widget-unread'),
    t: t,
    faded: false,
    pieces: [_quietPiece(context, s.hwUnread, lines: 1)],
    footer: _Piece(
      48,
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: _Pill(
          s.hwRetry,
          height: 28,
          key: const ValueKey('home-widget-retry'),
          onTap: _act(t, t.actions.retry),
        ),
      ),
    ),
  );
}

/// The target of a single-target widget is gone.
class _Missing extends StatelessWidget {
  const _Missing(this.t);
  final HomeTileContext t;
  @override
  Widget build(BuildContext context) => _Body(
    key: const ValueKey('home-widget-missing'),
    t: t,
    faded: false,
    pieces: [_quietPiece(context, Strings.of(context).hwMissing)],
  );
}

/// A two-line row: a face or mark, a title line, a status line, and what
/// sits at its end.
class _Row2 extends StatelessWidget {
  const _Row2({
    required this.title,
    required this.status,
    this.lead,
    this.end,
    this.gap = 11,
  });
  final Widget title;
  final Widget status;
  final Widget? lead;
  final Widget? end;
  final double gap;

  /// Height of a two-line row at the text scale of [context].
  static double heightOf(
    BuildContext context,
    HomePalette p, {
    double pad = 12,
    int titleLines = 1,
  }) => math.max(
    least,
    HomeType.line(context, HomeType.row(p)) * titleLines +
        HomeType.line(context, HomeType.meta(p)) +
        pad,
  );

  /// The least a row is: a touch target.
  static const double least = HermesSpace.tap;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: least),
    child: Row(
      children: [
        if (lead != null) ...[lead!, SizedBox(width: gap)],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              _Ends(gap: 8, share: 0.45, start: status, end: end),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Two things on one line: [end] keeps its own width, up to [share] of the
/// line, and [start] takes the rest. Whatever the text size, the line
/// never asks for more width than it has.
class _Ends extends StatelessWidget {
  const _Ends({
    required this.start,
    required this.end,
    this.gap = 8,
    this.share = 1,
  });
  final Widget start;
  final Widget? end;
  final double gap;
  final double share;

  @override
  Widget build(BuildContext context) {
    final last = end;
    if (last == null) return start;
    return LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          Expanded(child: start),
          SizedBox(width: gap),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.max(0.0, (box.maxWidth - gap) * share),
            ),
            child: last,
          ),
        ],
      ),
    );
  }
}

/// Width of [text] on one line in [style] (over the ambient one), at the
/// text scale of [context].
double _lineWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// [items] joined with « · » on lines no wider than [width]: a line breaks
/// between two items, never after a separator (an item wider than the
/// line keeps a line of its own and its ellipsis).
String _sepLines(
  BuildContext context,
  List<String> items,
  TextStyle style,
  double width,
) {
  final lines = <String>[];
  for (final item in items) {
    final joined = lines.isEmpty ? item : '${lines.last} · $item';
    if (lines.isNotEmpty && _lineWidth(context, joined, style) <= width) {
      lines[lines.length - 1] = joined;
    } else {
      lines.add(item);
    }
  }
  return lines.join('\n');
}

/// The first of [texts] that fits its width whole on one line; nothing
/// when none does (the line keeps what is before it).
class _FirstFit extends StatelessWidget {
  const _FirstFit(this.texts, {required this.style});
  final List<String> texts;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      for (final text in texts) {
        if (_lineWidth(context, text, style) <= box.maxWidth) {
          return Text(
            text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: style,
          );
        }
      }
      return const SizedBox.shrink();
    },
  );
}

Text _title(
  BuildContext context,
  String text, {
  int lines = 1,
  TextStyle? style,
}) {
  final shown = style ?? HomeType.row(HomePalette.ofContext(context));
  return Text(
    text,
    maxLines: lines,
    overflow: TextOverflow.ellipsis,
    style: shown,
    // Every line exactly as tall as the style says, whatever its glyphs
    // (an emoji, a fallback font): the rows are measured with it.
    strutStyle: StrutStyle(
      fontSize: shown.fontSize,
      height: shown.height,
      forceStrutHeight: true,
    ),
  );
}

int _titleLines(BuildContext context, String text, double width) {
  final painter = TextPainter(
    // Measured in the style the title paints with (the ambient one too).
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(
        context,
      ).style.merge(HomeType.row(HomePalette.ofContext(context))),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 2,
  )..layout(maxWidth: math.max(1.0, width));
  final lines = painter.computeLineMetrics().length.clamp(1, 2).toInt();
  painter.dispose();
  return lines;
}

/// «Who · where» on one line: the name in ink, the place muted.
Widget _whoWhere(BuildContext context, String who, String? where) {
  final p = HomePalette.ofContext(context);
  final place = where == null || where.isEmpty || where == who ? null : where;
  return Text.rich(
    TextSpan(
      children: [
        TextSpan(text: who.isEmpty ? (place ?? '') : who),
        if (who.isNotEmpty && place != null)
          TextSpan(
            text: ' · $place',
            style: TextStyle(fontWeight: FontWeight.w400, color: p.textMuted),
          ),
      ],
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: HomeType.row(p),
  );
}

// ── Ahora ──────────────────────────────────────────────────────────────
//
// What needs the user first (a question or an approval, answered from
// here); else what is running (who, where, what, for how long); else calm,
// with the last things that finished. Large: everything alive, what is
// for the user first.

class _NowTile extends StatefulWidget {
  const _NowTile(this.t);
  final HomeTileContext t;

  @override
  State<_NowTile> createState() => _NowTileState();
}

class _NowTileState extends State<_NowTile> {
  final Set<String> _sending = {};

  HomeTileContext get t => widget.t;

  Future<void> _send(String key, Future<void> Function() answer) async {
    if (_sending.contains(key)) return;
    setState(() => _sending.add(key));
    try {
      await answer();
    } finally {
      if (mounted) setState(() => _sending.remove(key));
    }
  }

  String _name(String who) => who.isEmpty ? t.data.mainName : who;

  /// «Astra te pregunta», «Forja pide permiso».
  String _askLine(Strings s, HomeNowAsk ask) {
    final who = _name(ask.who);
    return switch (ask.kind) {
      HomeNowAskKind.approval =>
        who.isEmpty ? s.hwItemApproval : s.hwNextApprovalBy(who),
      HomeNowAskKind.question =>
        who.isEmpty ? s.hwItemQuestion : s.hwNowAsks(who),
      HomeNowAskKind.waiting => s.hwNowWaits(who),
      HomeNowAskKind.pausedQueue => s.hwItemQueuePaused(ask.count),
      HomeNowAskKind.failed =>
        who.isEmpty ? s.hwNextFailedTurn : s.hwNowFailed(who),
    };
  }

  /// The short verb under a name («te pregunta», «pide permiso»).
  String _askVerb(Strings s, HomeNowAsk ask) => switch (ask.kind) {
    HomeNowAskKind.approval => s.hwNowVerbPermission,
    HomeNowAskKind.question => s.hwNowVerbAsks,
    HomeNowAskKind.waiting => s.hwBotWaiting,
    HomeNowAskKind.pausedQueue => s.hwItemQueuePaused(ask.count),
    HomeNowAskKind.failed => s.hwItemFailed.toLowerCase(),
  };

  /// What the user does about [ask] when it opens its screen.
  String _askAction(Strings s, HomeNowAsk ask) => switch (ask.kind) {
    HomeNowAskKind.question || HomeNowAskKind.waiting => s.hwNextActReply,
    _ => s.hwNextActView,
  };

  /// The body of an ask: its question or command, else where it happens.
  String? _askText(HomeNowAsk ask) => ask.text ?? ask.where;

  void _open(Object target) => t.actions.open(target);

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final now = t.data.nowBoard;
    final small = t.size == HomeWidgetSize.small;
    final large = t.size == HomeWidgetSize.large;
    final notes = [
      if (now.asks.length > 1 || (large && now.asks.isNotEmpty))
        s.hwNowForYou(now.asks.length),
      if (now.running.isNotEmpty) s.hwNowRunning(now.running.length),
    ];
    final p = HomePalette.ofContext(context);
    final trailing = small || notes.isEmpty
        ? null
        : _HeadNote(
            notes.join(' · '),
            key: const ValueKey('home-now-note'),
            color: now.asks.isNotEmpty ? p.attention : null,
            dot: now.asks.isNotEmpty && now.running.isNotEmpty && !large
                ? HomeType.live(p)
                : null,
          );
    if (small) return _small(context, now);
    if (now.asks.isNotEmpty) {
      final ask = now.asks.first;
      return _Body(
        key: ValueKey('home-now-ask-${ask.key}'),
        t: t,
        trailing: trailing,
        gap: 8,
        pieces: [
          _askPiece(context, ask),
          if (large) ...[
            _answersPiece(context, ask, gap: 10),
            for (final (i, other) in now.asks.skip(1).indexed)
              _askRow(context, other, first: i == 0),
            for (final (i, run) in now.running.indexed)
              _runRow(
                context,
                run,
                first: i == 0 && now.asks.length == 1,
                height: 46,
              ),
          ],
        ],
        footer: large ? null : _answersPiece(context, ask),
      );
    }
    if (now.running.isNotEmpty) {
      return _Body(
        key: const ValueKey('home-now-running'),
        t: t,
        trailing: trailing,
        gap: 4,
        pieces: [
          for (final run in now.running)
            _runRow(context, run, height: large ? 46 : 48),
          if (large)
            for (final (i, done) in now.recent.indexed)
              _doneRow(context, done, gap: i == 0 ? 8 : 0),
        ],
      );
    }
    return _Body(
      key: const ValueKey('home-now-calm'),
      t: t,
      gap: 9,
      pieces: [
        _calmPiece(context),
        if (large)
          for (final (i, done) in now.recent.indexed)
            _doneRow(context, done, gap: i == 0 ? 10 : 0),
      ],
      footer: large || now.recent.isEmpty
          ? null
          : _recentFooter(context, now.recent.take(2).toList()),
    );
  }

  // The small widget: one thing, its face and one action.
  Widget _small(BuildContext context, HomeNow now) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    _Piece who(String? profile, String name, String sub) {
      final one = HomeType.line(context, HomeType.row(p));
      final two = one + HomeType.line(context, HomeType.meta(p));
      _Piece row({required bool both}) => _Piece(
        math.max(30.0, both ? two : one) + 4,
        Row(
          children: [
            _Who(profile: profile, t: t),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _title(context, name),
                  if (both)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HomeType.meta(p),
                    ),
                ],
              ),
            ),
          ],
        ),
        center: true,
        or: both ? row(both: false) : null,
      );
      return row(both: true);
    }

    if (now.asks.isNotEmpty) {
      final ask = now.asks.first;
      final name = _name(ask.who);
      return _Tap(
        onTap: _act(t, () => _open(ask.target)),
        label: _askLine(s, ask),
        child: _Body(
          key: ValueKey('home-now-ask-${ask.key}'),
          t: t,
          gap: 4,
          pieces: [
            who(
              ask.profileName,
              name.isEmpty ? (ask.where ?? '') : name,
              _askVerb(s, ask),
            ),
          ],
          footer: _Piece(
            32,
            _Pill(_askAction(s, ask), primary: true, height: 32, expand: true),
          ),
        ),
      );
    }
    if (now.running.isNotEmpty) {
      final run = now.running.first;
      final name = _name(run.who);
      final meta = HomeType.meta(p);
      return _Tap(
        onTap: _act(t, () => _open(run.target)),
        label: name,
        child: _Body(
          key: const ValueKey('home-now-running'),
          t: t,
          gap: 4,
          pieces: [
            who(
              run.profileName,
              name.isEmpty ? (run.where ?? '') : name,
              name.isEmpty ? s.hwItemWorking : (run.where ?? s.hwItemWorking),
            ),
          ],
          footer: _Piece(
            HomeType.line(context, meta),
            _Status(
              _runWhat(s, run),
              mark: _Mark.live,
              ink: true,
              timer: run.since,
              clock: t.clock,
            ),
          ),
        ),
      );
    }
    final last = now.recent.firstOrNull;
    final meta = HomeType.meta(p);
    return _Tap(
      onTap: last == null ? null : _act(t, () => _open(last.target)),
      label: s.hwNowCalm,
      child: _Body(
        key: const ValueKey('home-now-calm'),
        t: t,
        gap: 9,
        pieces: [_calmPiece(context, small: true)],
        footer: last == null
            ? null
            : _Piece(
                HomeType.line(context, meta) * 2,
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _doneLine(s, last, short: true),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: meta,
                    ),
                    Text(
                      homeSince(context, last.at, t.clock()),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: meta,
                    ),
                  ],
                ),
                or: _Piece(
                  HomeType.line(context, meta),
                  Text(
                    _doneLine(s, last, short: true),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: meta,
                  ),
                ),
              ),
      ),
    );
  }

  String _runWhat(Strings s, HomeNowRun run) =>
      run.what ??
      (run.target is HomeBoardRoom ? s.hwNowReplying : s.hwItemWorking);

  String _doneLine(Strings s, HomeNowDone done, {bool short = false}) {
    final who = _name(done.who);
    if (short) return who.isEmpty ? done.what : s.hwNowFinished(who);
    return who.isEmpty ? done.what : '${s.hwNowFinished(who)} · ${done.what}';
  }

  _Piece _calmPiece(BuildContext context, {bool small = false}) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final style = small ? HomeType.row(p) : HomeType.title(p);
    final mark = small ? 22.0 : 26.0;
    return _Piece(
      math.max(mark, HomeType.line(context, style)),
      Row(
        children: [
          DecoratedBox(
            decoration: ShapeDecoration(
              color: p.ok.withValues(alpha: 0.16),
              shape: const CircleBorder(),
            ),
            child: SizedBox.square(
              dimension: mark,
              child: Icon(Icons.check_rounded, size: mark * 0.6, color: p.ok),
            ),
          ),
          SizedBox(width: small ? 8 : 10),
          Expanded(
            child: Text(
              s.hwNowCalm,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
      center: true,
    );
  }

  /// The ask in full: who asks, and the question or command on two lines.
  _Piece _askPiece(BuildContext context, HomeNowAsk ask) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final small = HomeType.title(p);
    final big = HomeType.meta(p);
    final text = _askText(ask);
    final command = ask.kind == HomeNowAskKind.approval && ask.text != null;
    final lines = text == null
        ? 0
        : _bigText(context)
        ? 1
        : 2;
    final body = command
        ? big.copyWith(
            fontFamily: HermesType.monoFamily,
            fontSize: LwGrid.rowLine,
            height: 1.2,
            fontWeight: FontWeight.w500,
          )
        : big;
    // [who]: the line that says who asks, over [lines] of what is asked;
    // with less room, one line; with the least, only what is asked (the
    // face still says who).
    _Piece piece({required bool who, int lines = 2}) => _Piece(
      math.max(
        who ? LwGrid.faceMedium : LwGrid.faceSmall,
        (who ? HomeType.line(context, small) : 0) +
            HomeType.line(context, big) * (who ? lines : math.min(lines, 1)),
      ),
      _Tap(
        onTap: _act(t, () => _open(ask.target)),
        label: [_askLine(s, ask), ?text].join(', '),
        child: Row(
          crossAxisAlignment: who
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            _Who(
              profile: ask.profileName,
              t: t,
              size: who ? LwGrid.faceMedium : LwGrid.faceSmall,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (who)
                    Text(
                      _askLine(s, ask),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small,
                    ),
                  if (text != null)
                    Text(
                      text.trim().split('\n').first,
                      maxLines: who ? lines : 1,
                      overflow: TextOverflow.ellipsis,
                      style: body,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      or: who && text != null
          ? (lines > 1 ? piece(who: true, lines: 1) : piece(who: false))
          : null,
    );
    return piece(who: true, lines: lines);
  }

  /// The answers of an ask: an approval's Permitir / Rechazar, a
  /// question's own choices, and the way to its screen.
  _Piece _answersPiece(BuildContext context, HomeNowAsk ask, {double gap = 0}) {
    final s = Strings.of(context);
    final busy = _sending.contains(ask.key) || t.editing;
    // The answers (label, key, what it does, primary, its mark).
    final answers = <(String, String, VoidCallback, bool, IconData?)>[];
    switch (ask.target) {
      case final HomeApprovalItem approval:
        if (approval.canAllow) {
          answers.add((
            s.inicioAllow,
            'allow',
            () => _send(ask.key, () => t.actions.answer(approval, allow: true)),
            true,
            Icons.check_rounded,
          ));
        }
        if (approval.canDeny) {
          answers.add((
            s.inicioDeny,
            'deny',
            () =>
                _send(ask.key, () => t.actions.answer(approval, allow: false)),
            false,
            Icons.close_rounded,
          ));
        }
      case final HomeQuestionItem question:
        for (final (i, choice) in question.choices.take(2).indexed) {
          answers.add((
            choice,
            'choice$i',
            () => _send(
              ask.key,
              () => t.actions.answerQuestion(question, choice),
            ),
            i == 0,
            null,
          ));
        }
      default:
        break;
    }
    final open = _Pill(
      _askAction(s, ask),
      key: ValueKey('home-now-open-${ask.key}'),
      primary: answers.isEmpty,
      height: 32,
      onTap: _act(t, () => _open(ask.target)),
    );
    return _Piece(
      48,
      LayoutBuilder(
        builder: (context, box) {
          // The marks only where the line has room for them: not with big
          // text, not on the narrowest cell.
          final marks = !_bigText(context) && box.maxWidth >= _answersMarksFrom;
          final row = Row(
            children: [
              for (final (i, (label, key, onTap, primary, icon))
                  in answers.indexed) ...[
                if (i > 0) const SizedBox(width: 7),
                Flexible(
                  child: _Pill(
                    label,
                    key: ValueKey('home-now-$key-${ask.key}'),
                    icon: marks ? icon : null,
                    primary: primary,
                    height: 34,
                    enabled: !busy,
                    onTap: onTap,
                  ),
                ),
              ],
            ],
          );
          if (answers.isEmpty) {
            return Align(
              alignment: AlignmentDirectional.centerStart,
              child: open,
            );
          }
          // The way to the screen keeps its own width (up to a third of
          // the line); the answers share the rest.
          return _Ends(gap: 7, share: 0.34, start: row, end: open);
        },
      ),
      gap: gap,
      center: true,
    );
  }

  /// Another ask, as a row of the large widget.
  _Piece _askRow(BuildContext context, HomeNowAsk ask, {required bool first}) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final name = _name(ask.who);
    return _Piece(
      _Row2.heightOf(context, p, pad: 10),
      _Tap(
        onTap: _act(t, () => _open(ask.target)),
        label: _askLine(s, ask),
        child: _Row2(
          lead: _Who(profile: ask.profileName, t: t),
          title: _whoWhere(context, name, ask.where),
          status: _Status(
            _askText(ask) == null || name.isEmpty
                ? _askLine(s, ask)
                : '${_askVerb(s, ask)} · ${_askText(ask)!}',
            mark: ask.kind == HomeNowAskKind.failed ? _Mark.failed : _Mark.asks,
            ink: true,
          ),
          end: _Pill(_askAction(s, ask), primary: true),
        ),
      ),
      gap: first ? 11 : 0,
      rule: true,
      center: true,
    );
  }

  /// Something running: who · where, what it does and for how long.
  _Piece _runRow(
    BuildContext context,
    HomeNowRun run, {
    bool first = false,
    double height = 48,
  }) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final name = _name(run.who);
    return _Piece(
      math.max(height, _Row2.heightOf(context, p, pad: 12, titleLines: 3)),
      _Tap(
        onTap: _act(t, () => _open(run.target)),
        label: [name, ?run.where, _runWhat(s, run)].join(', '),
        child: KeyedSubtree(
          key: ValueKey('home-now-run-${run.key}'),
          child: _Row2(
            lead: _Who(
              profile: run.profileName,
              t: t,
              icon: run.target is HomeBoardRoom
                  ? Icons.forum_outlined
                  : Icons.chat_bubble_outline_rounded,
            ),
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (name.isNotEmpty)
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HomeType.meta(p),
                  ),
                _title(context, run.where ?? name, lines: 2),
              ],
            ),
            status: _Status(
              _runWhat(s, run),
              mark: _Mark.live,
              timer: run.since,
              clock: t.clock,
            ),
            end: _Pill(s.hwNextActView),
          ),
        ),
      ),
      gap: first ? 11 : 0,
      rule: true,
      center: true,
    );
  }

  /// One of the last things that finished: who, what and when.
  Widget _doneLineRow(BuildContext context, HomeNowDone done) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final who = _name(done.who);
    return _Tap(
      onTap: _act(t, () => _open(done.target)),
      label: _doneLine(s, done),
      child: Row(
        key: ValueKey('home-now-done-${done.key}'),
        children: [
          _Who(profile: done.profileName, t: t, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: _Ends(
              share: 0.5,
              start: Text.rich(
                TextSpan(
                  children: [
                    if (who.isNotEmpty) ...[
                      TextSpan(
                        text: who,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: p.text,
                        ),
                      ),
                      TextSpan(text: ' ${s.hwNowFinishedVerb} · '),
                    ],
                    TextSpan(text: done.what),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HomeType.meta(p),
              ),
              // «hace 20 min», else «21:40» where the phrase has no room,
              // else nothing: a time is never cut.
              end: _FirstFit([
                homeSince(context, done.at, t.clock()),
                homeWhen(context, done.at, t.clock()),
              ], style: HomeType.when(p)),
            ),
          ),
        ],
      ),
    );
  }

  double _doneHeight(BuildContext context) => math.max(
    25.0,
    HomeType.line(context, HomeType.meta(HomePalette.ofContext(context))) + 8,
  );

  _Piece _doneRow(BuildContext context, HomeNowDone done, {double gap = 0}) =>
      _Piece(
        _doneHeight(context),
        _doneLineRow(context, done),
        gap: gap,
        center: true,
      );

  _Piece _recentFooter(BuildContext context, List<HomeNowDone> recent) {
    final h = _doneHeight(context);
    return _Piece(
      h * recent.length,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final done in recent)
            SizedBox(height: h, child: _doneLineRow(context, done)),
        ],
      ),
    );
  }
}

// ── Chats ──────────────────────────────────────────────────────────────
//
// The recent chats with their live state: working (and for how long),
// asks you, an unsent draft, finished.

/// The state line of a chat, and what sits at the end of its row.
({String text, _Mark mark, bool ink}) _chatState(
  BuildContext context,
  HomeChatItem chat,
  HomeBoardData data, {
  bool short = false,
}) {
  final s = Strings.of(context);
  String join(String head, String? tail) =>
      short || tail == null || tail.isEmpty ? head : '$head · $tail';
  if (chat.working) {
    return (text: chat.step ?? s.hwItemWorking, mark: _Mark.live, ink: true);
  }
  if (chat.waitingForUser) {
    return (
      text: join(s.hwChatAsks, data.questionOf(chat.key)?.question),
      mark: _Mark.asks,
      ink: true,
    );
  }
  if (chat.failed) {
    return (text: s.hwItemFailed, mark: _Mark.failed, ink: false);
  }
  if (chat.draft) {
    return (
      text: join(s.hwChatDraft, chat.preview),
      mark: _Mark.draft,
      ink: false,
    );
  }
  final reply = chat.lastReply ?? (chat.preview.isEmpty ? null : chat.preview);
  return (text: join(s.hwChatDone, reply), mark: _Mark.done, ink: chat.unread);
}

/// The least width of the answers line that shows the marks (the check,
/// the cross) beside Permitir and Rechazar.
const double _answersMarksFrom = 300;

/// A row of the chats list: two of them fit the wide cell as designed.
const double _chatRow = HermesSpace.rowMin;

/// The face at the start of a chats row.
const double _chatFace = LwGrid.faceSmall;

class _ChatsTile extends StatelessWidget {
  const _ChatsTile(this.t);
  final HomeTileContext t;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final chats = t.data.chats;
    if (chats.isEmpty) {
      // Only the recents are still unknown on a cold start without a
      // snapshot: this widget waits, the rest of Home is already there.
      if (!t.data.chatsLoaded) {
        return _loading(
          t,
          context,
          key: const ValueKey('home-initial-loading'),
        );
      }
      return _quiet(t, context, s.hwContinueEmpty);
    }
    if (t.size == HomeWidgetSize.small) return _small(context, chats.first);
    return LayoutBuilder(
      builder: (context, box) => _Body(
        t: t,
        gap: 2,
        onHeader: t.actions.openSessions,
        trailing: Icon(
          Icons.chevron_right_rounded,
          size: 18,
          color: p.textMuted,
        ),
        pieces: [
          for (final chat in chats)
            _chatPiece(
              context,
              chat,
              _titleLines(context, chat.title, box.maxWidth - _chatFace - 10),
            ),
        ],
      ),
    );
  }

  /// A chat's row as a piece. The title takes the lines it was measured
  /// for, never one more (a second line would sit on the state under it);
  /// with less room, one line of title (large text keeps a row in the
  /// card instead of an empty one).
  _Piece _chatPiece(BuildContext context, HomeChatItem chat, int lines) =>
      _Piece(
        math.max(
          _chatRow,
          _Row2.heightOf(
            context,
            HomePalette.ofContext(context),
            titleLines: lines,
          ),
        ),
        _row(context, chat, lines: lines),
        rule: true,
        center: true,
        or: lines > 1 ? _chatPiece(context, chat, 1) : null,
      );

  Widget _row(BuildContext context, HomeChatItem chat, {int lines = 2}) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final state = _chatState(context, chat, t.data);
    final when = _FirstFit([
      homeWhen(context, chat.at, t.clock()),
    ], style: HomeType.when(p));
    final Widget end = chat.working
        ? (chat.workingSince == null
              ? const SizedBox.shrink()
              : HomeElapsed(
                  since: chat.workingSince!,
                  clock: t.clock,
                  style: HomeType.timer(p),
                ))
        : chat.waitingForUser
        ? _Pill(s.hwNextActReply, primary: true)
        : !chat.unread
        ? when
        // Unread: the time and the one accent dot after it.
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: when),
              const SizedBox(width: HermesSpace.x1 + 2),
              _Dot(
                HomeType.live(p),
                size: 8,
                key: ValueKey('home-chat-unread-${chat.key}'),
              ),
            ],
          );
    return _Tap(
      onTap: _act(t, () => t.actions.openChat(chat)),
      label: '${chat.title}, ${state.text}',
      child: KeyedSubtree(
        key: ValueKey('home-continue-${chat.key}'),
        child: _Row2(
          // Whose chat it is: the face of its bot (the main agent's own
          // face when it has no bot).
          lead: _Who(profile: chat.profileName, t: t, size: _chatFace),
          gap: 10,
          title: _title(context, chat.title, lines: lines),
          status: KeyedSubtree(
            key: _chatStateKey(chat),
            child: _Status(state.text, mark: state.mark, ink: state.ink),
          ),
          end: end,
        ),
      ),
    );
  }

  Widget _small(BuildContext context, HomeChatItem chat) {
    final p = HomePalette.ofContext(context);
    final state = _chatState(context, chat, t.data, short: true);
    final titleStyle = HomeType.row(p);
    final lines = _bigText(context) ? 2 : 3;
    final meta = HomeType.meta(p);
    return _Tap(
      onTap: _act(t, () => t.actions.openChat(chat)),
      label: '${chat.title}, ${state.text}',
      child: _Body(
        key: ValueKey('home-continue-${chat.key}'),
        t: t,
        gap: 8,
        pieces: [
          _Piece(
            HomeType.line(context, titleStyle) * lines,
            _title(context, chat.title, lines: lines, style: titleStyle),
          ),
        ],
        footer: _Piece(
          HomeType.line(context, meta),
          _chatFoot(context, t, chat),
        ),
      ),
    );
  }
}

/// Key of a chat's state line: its working state by chat, its preview by
/// text (what the Conversations list paints for the same chat).
Key? _chatStateKey(HomeChatItem chat) => chat.working
    ? ValueKey('home-chat-working-${chat.key}')
    : chat.waitingForUser || chat.failed || chat.preview.isEmpty
    ? null
    : ValueKey('preview-${chat.preview}');

/// The last line of a chat in a small widget: its state, and its clock
/// while it works or when it last moved.
Widget _chatFoot(BuildContext context, HomeTileContext t, HomeChatItem chat) {
  final p = HomePalette.ofContext(context);
  final state = _chatState(context, chat, t.data, short: true);
  return _Ends(
    start: KeyedSubtree(
      key: _chatStateKey(chat),
      child: _Status(state.text, mark: state.mark, ink: state.ink),
    ),
    end: chat.working && chat.workingSince != null
        ? HomeElapsed(
            since: chat.workingSince!,
            clock: t.clock,
            style: HomeType.timer(p),
          )
        : !chat.working && !chat.waitingForUser
        ? _FirstFit([
            homeWhen(context, chat.at, t.clock()),
          ], style: HomeType.when(p))
        : null,
  );
}

// ── Bots ───────────────────────────────────────────────────────────────
//
// Small and wide: the faces with their state. Large: one row per bot
// with what it does now, or the last thing it did and when.

String _botState(Strings s, HomeBotState state) => switch (state) {
  HomeBotState.idle => s.hwBotIdle,
  HomeBotState.working => s.hwBotWorking,
  HomeBotState.waiting => s.hwBotWaiting,
};

/// Ink of a bot's state word: the one accent for «te espera», the text ink
/// for «trabaja», faint for «libre».
Color _botStateColor(HomePalette p, HomeBotState state) => switch (state) {
  HomeBotState.working => p.text,
  HomeBotState.waiting => HomeType.live(p),
  HomeBotState.idle => HomeType.faint(p),
};

class _BotsTile extends StatelessWidget {
  const _BotsTile(this.t);
  final HomeTileContext t;

  /// The bots this widget shows: the chosen ones, those that need the
  /// user first, then the ones working.
  List<HomeBoardBot> _bots() {
    final chosen = t.item.listOption('bots');
    final onlyWorking = t.item.boolOption('onlyWorking');
    final bots = [
      for (final b in t.data.bots)
        if ((chosen == null || chosen.contains(b.profileName)) &&
            (!onlyWorking || b.state != HomeBotState.idle))
          b,
    ];
    int rank(HomeBoardBot b) => switch (b.state) {
      HomeBotState.waiting => 0,
      HomeBotState.working => 1,
      HomeBotState.idle => 2,
    };
    final at = {for (final (i, b) in bots.indexed) b.profileName: i};
    return bots..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      if (a.state == HomeBotState.idle) {
        final ta = a.lastAt?.millisecondsSinceEpoch ?? 0;
        final tb = b.lastAt?.millisecondsSinceEpoch ?? 0;
        if (ta != tb) return tb.compareTo(ta);
      }
      return at[a.profileName]!.compareTo(at[b.profileName]!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    if (!t.data.botsLoaded && t.data.bots.isEmpty) {
      return t.data.offline
          ? _quiet(t, context, s.hwServerOffline)
          : _loading(t, context);
    }
    final bots = _bots();
    if (bots.isEmpty) {
      return _quiet(
        t,
        context,
        t.data.bots.isEmpty ? s.hwTeamEmpty : s.hwTeamCalm,
      );
    }
    final working = bots.where((b) => b.state == HomeBotState.working).length;
    final waiting = bots.where((b) => b.state == HomeBotState.waiting).length;
    final notes = [
      if (working > 0) s.hwTeamWorkingCount(working),
      if (waiting > 0) s.hwTeamWaitingCount(waiting),
    ];
    final trailing = notes.isEmpty
        ? null
        : _HeadNote(notes.join(' · '), key: const ValueKey('home-bots-note'));
    switch (t.size) {
      case HomeWidgetSize.small:
        return _small(context, bots);
      case HomeWidgetSize.wide:
        final name = HomeType.row(p);
        final state = HomeType.meta(p);
        // By their original order here: the faces keep their place while
        // their state changes.
        final shown = _inOrder(bots).take(4).toList();
        // With the ring's room above the faces; with less height, without
        // the state, then without the names.
        _Piece faces({required bool withName, required bool withState}) =>
            _Piece(
              _ringRoom +
                  30 +
                  (withName ? 7 + HomeType.line(context, name) : _ringRoom) +
                  (withState ? HomeType.line(context, state) : 0),
              Padding(
                padding: const EdgeInsets.only(top: _ringRoom),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final b in shown)
                      Expanded(
                        child: _BotColumn(
                          bot: b,
                          t: t,
                          withName: withName,
                          withState: withState,
                        ),
                      ),
                    for (var i = shown.length; i < 4; i++) const Spacer(),
                  ],
                ),
              ),
              or: withState
                  ? faces(withName: true, withState: false)
                  : withName
                  ? faces(withName: false, withState: false)
                  : null,
            );
        return _Body(
          t: t,
          trailing: trailing,
          gap: 9,
          pieces: [faces(withName: true, withState: true)],
        );
      case HomeWidgetSize.large:
        final rowH = math.max(52.0, _Row2.heightOf(context, p, pad: 16));
        return _Body(
          t: t,
          trailing: trailing,
          gap: 1,
          pieces: [
            for (final b in bots)
              _Piece(rowH, _row(context, b), rule: true, center: true),
          ],
        );
    }
  }

  List<HomeBoardBot> _inOrder(List<HomeBoardBot> bots) {
    final at = {for (final (i, b) in t.data.bots.indexed) b.profileName: i};
    return [...bots]
      ..sort((a, b) => at[a.profileName]!.compareTo(at[b.profileName]!));
  }

  Widget _small(BuildContext context, List<HomeBoardBot> bots) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final faces = _inOrder(bots).take(4).toList();
    final waiting = bots.where((b) => b.state == HomeBotState.waiting);
    final working = bots.where((b) => b.state == HomeBotState.working);
    final idle = bots.where((b) => b.lastAt != null).toList()
      ..sort((a, b) => b.lastAt!.compareTo(a.lastAt!));
    final String headline;
    Widget? second;
    HomeBoardBot? target;
    if (waiting.isNotEmpty) {
      target = waiting.first;
      headline = s.hwNowWaits(target.displayName);
      final busy = working.firstOrNull;
      if (busy != null) {
        second = _Status(
          s.hwBotWorksNow(busy.displayName),
          mark: _Mark.live,
          timer: busy.since,
          clock: t.clock,
        );
      }
    } else if (working.isNotEmpty) {
      target = working.first;
      headline = working.length == 1
          ? s.hwBotWorksNow(target.displayName)
          : s.hwTeamWorkingCount(working.length);
      second = _Status(
        target.room ?? target.step ?? s.hwItemWorking,
        mark: _Mark.live,
        timer: target.since,
        clock: t.clock,
      );
    } else {
      headline = s.hwTeamCalm;
      final last = idle.firstOrNull;
      if (last != null) {
        target = last;
        second = _Status(
          '${last.displayName} · '
          '${homeSince(context, last.lastAt!, t.clock())}',
        );
      }
    }
    final head = HomeType.row(p);
    final meta = HomeType.meta(p);
    final open = target;
    return _Tap(
      onTap: open == null ? null : _act(t, () => t.actions.openBot(open)),
      label: headline,
      child: _Body(
        t: t,
        gap: 9,
        pieces: [
          // 28 dp faces with the ring's room around them, so a ring is
          // never cut by the piece's edge.
          _Piece(
            28 + 2 * _ringRoom,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _ringRoom),
              child: LayoutBuilder(
                builder: (context, box) {
                  // Four faces across, a little smaller on a narrow phone.
                  final size = math.min(28.0, (box.maxWidth - 9) / 4);
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final b in faces)
                        HomeFace(
                          profileName: b.profileName,
                          data: t.data,
                          state: b.state,
                          size: size,
                        ),
                      for (var i = faces.length; i < 4; i++)
                        SizedBox.square(dimension: size),
                    ],
                  );
                },
              ),
            ),
            center: true,
          ),
        ],
        footer: _Piece(
          HomeType.line(context, head) +
              (second == null ? 0 : HomeType.line(context, meta)),
          Column(
            key: const ValueKey('home-bots-summary'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title(context, headline, style: head),
              ?second,
            ],
          ),
          or: second == null
              ? null
              : _Piece(
                  HomeType.line(context, head),
                  _title(context, headline, style: head),
                ),
        ),
      ),
    );
  }

  /// One bot: what it does now, or the last thing it did and when.
  Widget _row(BuildContext context, HomeBoardBot b) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final ask = t.data.nowBoard.asks
        .where((a) => a.profileName == b.profileName)
        .firstOrNull;
    final Widget title;
    final Widget status;
    Widget? end;
    switch (b.state) {
      case HomeBotState.waiting:
        title = Text.rich(
          TextSpan(
            children: [
              TextSpan(text: b.displayName),
              TextSpan(
                text: '  ${_waitTag(s, ask)}',
                style: TextStyle(fontSize: 12, color: HomeType.live(p)),
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: HomeType.row(p),
        );
        status = _Status(ask?.text ?? b.step ?? s.hwBotWaiting, ink: true);
      case HomeBotState.working:
        title = _title(context, b.displayName);
        final what = [?b.step, ?b.room];
        status = _Status(
          what.isEmpty ? s.hwItemWorking : what.join(' · '),
          mark: _Mark.live,
        );
        if (b.since case final since?) {
          end = HomeElapsed(
            since: since,
            clock: t.clock,
            style: HomeType.timer(p),
          );
        }
      case HomeBotState.idle:
        title = _title(
          context,
          b.displayName,
          style: b.lastTitle == null
              ? HomeType.row(p).copyWith(color: p.textMuted)
              : null,
        );
        status = b.lastTitle == null
            ? Text(
                s.hwBotIdle,
                maxLines: 1,
                style: HomeType.meta(p).copyWith(color: HomeType.faint(p)),
              )
            : _Status(b.lastTitle!, mark: _Mark.done);
        if (b.lastAt case final at?) {
          end = _FirstFit([
            homeWhen(context, at, t.clock()),
          ], style: HomeType.when(p));
        }
    }
    return _Tap(
      onTap: _act(t, () => t.actions.openBot(b)),
      label: '${b.displayName}, ${_botState(s, b.state)}',
      child: KeyedSubtree(
        key: ValueKey('home-bot-row-${b.profileName}'),
        child: _Row2(
          // The ring's room before the face: the row's clip starts at
          // the card's content edge.
          lead: Padding(
            padding: const EdgeInsetsDirectional.only(start: _ringRoom),
            child: HomeFace(
              profileName: b.profileName,
              data: t.data,
              state: b.state,
              size: 32,
              dot: false,
            ),
          ),
          gap: 12 - _ringRoom,
          title: title,
          status: status,
          end: end,
        ),
      ),
    );
  }

  String _waitTag(Strings s, HomeNowAsk? ask) => switch (ask?.kind) {
    HomeNowAskKind.approval => s.hwNowVerbPermission,
    HomeNowAskKind.question => s.hwNowVerbAsks,
    _ => s.hwBotWaiting,
  };
}

class _BotColumn extends StatelessWidget {
  const _BotColumn({
    required this.bot,
    required this.t,
    this.withName = true,
    this.withState = true,
  });
  final HomeBoardBot bot;
  final HomeTileContext t;
  final bool withName;
  final bool withState;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final quiet = bot.state == HomeBotState.idle;
    return _Tap(
      onTap: _act(t, () => t.actions.openBot(bot)),
      label: '${bot.displayName}, ${_botState(s, bot.state)}',
      child: Column(
        key: ValueKey('home-team-bot-${bot.profileName}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          HomeFace(
            profileName: bot.profileName,
            data: t.data,
            state: bot.state,
            size: 30,
          ),
          if (withName) ...[
            const SizedBox(height: 7),
            Text(
              bot.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HomeType.row(p),
            ),
          ],
          if (withName && withState)
            Text(
              _botState(s, bot.state),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HomeType.meta(p).copyWith(
                color: _botStateColor(p, bot.state),
                fontWeight: quiet ? FontWeight.w400 : FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

// ── Salas ──────────────────────────────────────────────────────────────
//
// Who is replying now and for how long, who is next, what is unread or
// for the user, and the last line.

class _RoomsTile extends StatelessWidget {
  const _RoomsTile(this.t);
  final HomeTileContext t;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final rooms = t.data.roomsFor(t.item);
    if (rooms.isEmpty) {
      // «No rooms» is a fact only after an answer that says so; the roster
      // being live proves nothing about the rooms read.
      switch (t.data.roomsState) {
        case HomeRoomsState.unknown:
          return _loading(t, context);
        case HomeRoomsState.unavailable:
          // The read failed and nothing is cached: skeleton, then the read
          // again offered once a second read has failed.
          return t.data.roomsFailedReads >= 2
              ? _unread(t, context)
              : _loading(t, context);
        case HomeRoomsState.unsupported:
        case HomeRoomsState.known:
          // Rooms were chosen and none of them is there any more.
          if (t.item.roomKeys.isNotEmpty) return _Missing(t);
          return _quiet(t, context, s.hwRoomsEmpty);
      }
    }
    final live = rooms.where((r) => r.live).length;
    final trailing = live == 0
        ? null
        : _HeadNote(
            s.hwRoomRespondingMany(live),
            key: const ValueKey('home-rooms-note'),
          );
    switch (t.size) {
      case HomeWidgetSize.small:
        return _small(context, rooms.first);
      case HomeWidgetSize.wide:
        final rowH = math.max(50.0, _Row2.heightOf(context, p));
        return _Body(
          t: t,
          trailing: trailing,
          gap: 2,
          pieces: [
            for (final room in rooms)
              _Piece(rowH, _wideRow(context, room), rule: true, center: true),
          ],
        );
      case HomeWidgetSize.large:
        return _Body(
          t: t,
          trailing: trailing,
          gap: 1,
          pieces: [for (final room in rooms) _block(context, room)],
        );
    }
  }

  void _open(HomeBoardRoom room) => t.actions.openRoom(room.key);

  Widget _count(BuildContext context, HomeBoardRoom room) {
    final p = HomePalette.ofContext(context);
    return KeyedSubtree(
      key: const ValueKey('home-room-unread'),
      child: _Badge('${room.unread}', color: p.track, ink: p.text),
    );
  }

  String _replying(Strings s, HomeBoardRoom room) => room.responding.length == 1
      ? s.hwRoomResponding(room.responding.single)
      : s.hwRoomRespondingMany(room.responding.length);

  /// The newest line: «Astra: Lo reviso cuando acabe Forja.»
  Widget? _lastLine(BuildContext context, HomeBoardRoom room, {int lines = 1}) {
    final p = HomePalette.ofContext(context);
    final line = room.lines.lastOrNull;
    if (line == null) return null;
    return Text.rich(
      TextSpan(
        children: [
          if (line.author.isNotEmpty)
            TextSpan(
              text: '${line.author}: ',
              style: TextStyle(fontWeight: FontWeight.w600, color: p.text),
            ),
          TextSpan(text: line.text),
        ],
      ),
      key: ValueKey('home-room-last-${room.key}'),
      maxLines: lines,
      overflow: TextOverflow.ellipsis,
      style: HomeType.meta(p),
    );
  }

  Widget _small(BuildContext context, HomeBoardRoom room) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final head = HomeType.row(p);
    final meta = HomeType.meta(p);
    final last = room.lines.lastOrNull;
    final lines = <Widget>[
      if (room.live)
        _Status(_replying(s, room), mark: _Mark.live, ink: true)
      else if (room.mentions > 0)
        _Status(s.hwNextReplies(room.mentions), ink: true)
      else if (room.unread > 0)
        _Status(s.hwNextNews(room.unread))
      else if (last != null)
        _lastLine(context, room)!
      else
        _Status(s.hwRoomQuiet),
      if (room.live && room.next != null)
        _Status(s.hwRoomNext(room.next!))
      else if (!room.live &&
          (room.mentions > 0 || room.unread > 0) &&
          last != null)
        _Status(
          [
            if (last.author.isNotEmpty) last.author,
            if (room.lastAt != null) homeWhen(context, room.lastAt!, t.clock()),
          ].join(' · '),
        ),
    ];
    _Piece foot(int count) => _Piece(
      math.max(
            HomeType.line(context, head),
            room.unread > 0 ? _Badge.heightOf(context) : 0,
          ) +
          HomeType.line(context, meta) * count,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(child: _title(context, room.title, style: head)),
              if (room.unread > 0) ...[
                const SizedBox(width: 6),
                _count(context, room),
              ],
            ],
          ),
          ...lines.take(count),
        ],
      ),
      or: count > 0 ? foot(count - 1) : null,
    );
    return _Tap(
      onTap: _act(t, () => _open(room)),
      label: room.title,
      child: _Body(
        key: ValueKey('home-room-${room.key}'),
        t: t,
        gap: 9,
        pieces: [
          _Piece(
            math.max(22.0, HomeType.line(context, HomeType.timer(p))),
            Row(
              children: [
                _FaceStack(profiles: room.memberProfiles, t: t),
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: switch (room.respondingSince) {
                      final since? when room.live => HomeElapsed(
                        since: since,
                        clock: t.clock,
                        style: HomeType.timer(p),
                      ),
                      _ => const SizedBox.shrink(),
                    },
                  ),
                ),
              ],
            ),
            center: true,
          ),
        ],
        // The room and what happens in it; with less room, fewer of its
        // lines, the room's name last.
        footer: foot(lines.length),
      ),
    );
  }

  Widget _wideRow(BuildContext context, HomeBoardRoom room) {
    final s = Strings.of(context);
    final last = _lastLine(context, room);
    return _Tap(
      onTap: _act(t, () => _open(room)),
      label: room.title,
      child: Column(
        key: ValueKey('home-room-${room.key}'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _FaceStack(profiles: room.memberProfiles, t: t, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: _Ends(
                  share: 0.5,
                  start: _named(context, room),
                  end: room.live
                      ? _Status(
                          room.responding.first,
                          mark: _Mark.live,
                          ink: true,
                          timer: room.respondingSince,
                          clock: t.clock,
                        )
                      : switch (room.lastAt) {
                          final at? => _edge(
                            context,
                            homeWhen(context, at, t.clock()),
                          ),
                          null => null,
                        },
                ),
              ),
            ],
          ),
          _Ends(
            share: 0.45,
            start: last ?? _Status(s.hwRoomQuiet),
            end: room.live && room.next != null
                ? _edge(context, _lowerFirst(s.hwRoomNext(room.next!)))
                : null,
          ),
        ],
      ),
    );
  }

  /// A quiet word at the end of a line (a time, who is next).
  Widget _edge(BuildContext context, String text) => Text(
    text,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.fade,
    style: HomeType.when(HomePalette.ofContext(context)),
  );

  /// The room's name with what is unread and, when [mentions], what is
  /// for the user.
  Widget _named(
    BuildContext context,
    HomeBoardRoom room, {
    bool mentions = false,
  }) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final name = Row(
      children: [
        Flexible(child: _title(context, room.title)),
        if (room.unread > 0) ...[
          const SizedBox(width: 8),
          _count(context, room),
        ],
      ],
    );
    if (!mentions || room.mentions == 0) return name;
    // The badge keeps its own width (up to half the line); the name gives
    // way to it.
    return _Ends(
      gap: 6,
      share: 0.5,
      start: name,
      end: KeyedSubtree(
        key: const ValueKey('home-room-mentions'),
        child: _Badge(
          s.hwNowForYou(room.mentions),
          color: HomeType.live(p).withValues(alpha: 0.14),
          ink: HomeType.live(p),
        ),
      ),
    );
  }

  /// A room of the large widget: its name and counts, who replies and who
  /// is next, and the last line on two lines.
  _Piece _block(BuildContext context, HomeBoardRoom room) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final meta = HomeType.meta(p);
    final lastLines = room.lines.isEmpty || _bigText(context) ? 1 : 2;
    final last = _lastLine(context, room, lines: lastLines);
    final h =
        math.max(21.0, HomeType.line(context, HomeType.row(p))) +
        3 +
        (room.live ? HomeType.line(context, meta) + 3 : 0) +
        HomeType.line(context, meta) * lastLines +
        19;
    return _Piece(
      h,
      _Tap(
        onTap: _act(t, () => _open(room)),
        label: room.title,
        child: Column(
          key: ValueKey('home-room-${room.key}'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _FaceStack(profiles: room.memberProfiles, t: t),
                const SizedBox(width: 8),
                Expanded(
                  child: _Ends(
                    share: 0.35,
                    start: _named(context, room, mentions: true),
                    end: switch (room.lastAt) {
                      final at? => _edge(
                        context,
                        homeWhen(context, at, t.clock()),
                      ),
                      null => null,
                    },
                  ),
                ),
              ],
            ),
            if (room.live) ...[
              const SizedBox(height: 3),
              _Status(
                _replying(s, room),
                mark: _Mark.live,
                ink: true,
                timer: room.respondingSince,
                clock: t.clock,
                suffix: room.next == null
                    ? null
                    : _lowerFirst(s.hwRoomNext(room.next!)),
              ),
            ],
            const SizedBox(height: 3),
            last ?? _Status(s.hwRoomQuiet),
          ],
        ),
      ),
      rule: true,
      center: true,
    );
  }
}

// ── Cron ───────────────────────────────────────────────────────────────
//
// Small: the next run (or one fixed job). Wide: the next three. Large:
// every job by next run, with its last result. A failed last run shows on
// the header at every size.

class _CronTile extends StatelessWidget {
  const _CronTile(this.t);
  final HomeTileContext t;

  /// The day of a run that is neither today nor within the next hours.
  String? _day(Strings s, DateTime at, DateTime now) =>
      _sameDay(at, now) || at.difference(now) <= const Duration(hours: 6)
      ? null
      : homeDayLabel(s, at);

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final jobs = t.data.automations;
    if (t.data.automationsFailed) return _unread(t, context);
    if (jobs == null) {
      return t.data.automationsFailed
          ? _unread(t, context)
          : _loading(t, context);
    }
    final now = t.clock();
    final pinned = t.item.stringOption('job');
    final failed = jobs.where((j) => j.failed).length;
    final trailing = failed == 0
        ? null
        : _HeadNote(
            s.hwCronFailed(failed),
            key: const ValueKey('home-auto-failed'),
            dot: p.failure,
            color: p.failure,
          );
    if (jobs.isEmpty) {
      return _Tap(
        onTap: _act(t, () => t.actions.openAutomation(null)),
        child: _quiet(t, context, s.hwAutoEmpty),
      );
    }
    final ordered = HomeBoardData.cronOrder(jobs, now, jobKey: pinned);
    switch (t.size) {
      case HomeWidgetSize.small:
        final job = HomeBoardData.nextAutomation(jobs, now, jobKey: pinned);
        if (job == null) {
          if (pinned != null) return _Missing(t);
          return _Tap(
            onTap: _act(t, () => t.actions.openAutomation(null)),
            child: _Body(
              t: t,
              trailing: trailing,
              pieces: [_quietPiece(context, s.hwNextNone)],
            ),
          );
        }
        return _small(context, job, now, trailing);
      case HomeWidgetSize.wide:
        final row = HomeType.body(p);
        final rowH = math.max(48.0, HomeType.line(context, row) + 13);
        return _Body(
          t: t,
          trailing: trailing,
          gap: 4,
          onHeader: () => t.actions.openAutomation(null),
          pieces: [
            for (final job in ordered)
              _Piece(
                rowH,
                _wideRow(context, job, now),
                rule: true,
                center: true,
              ),
          ],
        );
      case HomeWidgetSize.large:
        final rowH = math.max(52.5, _Row2.heightOf(context, p, pad: 16));
        return _Body(
          t: t,
          trailing: trailing,
          gap: 1,
          onHeader: () => t.actions.openAutomation(null),
          pieces: [
            for (final job in ordered)
              _Piece(
                rowH,
                _largeRow(context, job, now),
                rule: true,
                center: true,
              ),
          ],
        );
    }
  }

  Widget _small(
    BuildContext context,
    HomeAutomation job,
    DateTime now,
    Widget? trailing,
  ) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final next = job.nextRun;
    final day = next == null ? null : _day(s, next, now);
    final name = HomeType.row(p);
    final meta = HomeType.meta(p);
    final lines = _bigText(context) ? 1 : 2;
    final countdown0 = next == null
        ? s.hwNextPaused
        : homeCountdown(context, next.difference(now));
    final when = next == null ? '—' : (day ?? _time(context, next));
    // A day («lun 12») is words, not a figure: a size under the time.
    final figureSize = day == null ? HomeType.hugeSize : HermesType.displaySize;
    // The time, big, the name right under it (on up to two lines) and how
    // long is left; with less room, without the last line; with the least,
    // the time and the name on one line.
    _Piece flow({required bool countdown}) => _Piece(
      HomeFigure.heightOf(context, size: figureSize) +
          HermesSpace.x1 +
          HomeType.line(context, name) * lines +
          (countdown ? HomeType.line(context, meta) : 0),
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HomeFigure(
            when,
            size: figureSize,
            ink: next == null ? HomeType.faint(p) : null,
          ),
          const SizedBox(height: HermesSpace.x1),
          Text(
            job.name,
            maxLines: lines,
            overflow: TextOverflow.ellipsis,
            style: name,
          ),
          if (countdown)
            Text(
              day == null
                  ? countdown0
                  : '${_time(context, next!)} · $countdown0',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: meta,
            ),
        ],
      ),
      or: countdown
          ? flow(countdown: false)
          : _Piece(
              HomeType.line(context, name),
              Text(
                '$when · ${job.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: name,
              ),
            ),
    );
    return _Tap(
      onTap: _act(t, () => t.actions.openAutomation(job)),
      label: job.name,
      child: _Body(
        key: ValueKey('home-next-${job.key}'),
        t: t,
        trailing: trailing,
        gap: 6,
        pieces: [flow(countdown: true)],
      ),
    );
  }

  Widget _wideRow(BuildContext context, HomeAutomation job, DateTime now) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final next = job.enabled ? job.nextRun : null;
    final day = next == null ? null : _day(s, next, now);
    final off = next == null;
    final time = next == null ? '—' : _time(context, next);
    final style = HomeType.row(p).copyWith(
      color: off ? HomeType.faint(p) : null,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return _Tap(
      onTap: _act(t, () => t.actions.openAutomation(job)),
      label: job.name,
      child: Row(
        key: ValueKey('home-run-${job.key}'),
        children: [
          SizedBox(
            width: math.max(
              MediaQuery.textScalerOf(context).scale(LwGrid.tap),
              _lineWidth(context, time, style),
            ),
            child: Text(time, maxLines: 1, softWrap: false, style: style),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _Ends(
              gap: 10,
              share: 0.55,
              start: Text(
                job.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HomeType.body(p).copyWith(
                  fontWeight: FontWeight.w500,
                  color: off ? HomeType.faint(p) : null,
                ),
              ),
              end: job.failed
                  ? Icon(Icons.close_rounded, size: 14, color: p.failure)
                  : Text(
                      next == null
                          ? s.hwNextPaused
                          : [
                              ?day,
                              homeCountdown(context, next.difference(now)),
                            ].join(' · '),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: HomeType.when(p).copyWith(fontSize: 13),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// «cada 6 h», «cada 30 min».
  String _every(Strings s, int minutes) => minutes % 60 == 0
      ? s.hwCronEveryHours(minutes ~/ 60)
      : s.hwCronEveryMinutes(minutes);

  Widget _largeRow(BuildContext context, HomeAutomation job, DateTime now) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final next = job.enabled ? job.nextRun : null;
    final day = next == null ? null : _day(s, next, now);
    final off = next == null;
    final last = job.lastRunAt;
    final lastWhen = last == null ? null : homeWhen(context, last, now);
    final Widget result = !job.enabled
        ? _Status(s.hwNextPaused)
        : job.failed
        ? _Status([s.hwItemFailed, ?lastWhen].join(' · '), mark: _Mark.failed)
        : last == null
        ? _Status(s.hwAutoNotRun)
        : _Status([s.hwAutoOk, ?lastWhen].join(' · '), mark: _Mark.done);
    final time = HomeType.row(p).copyWith(
      color: off ? HomeType.faint(p) : null,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return _Tap(
      onTap: _act(t, () => t.actions.openAutomation(job)),
      label: '${job.name}, ${job.failed ? s.hwItemFailed : s.hwAutoOk}',
      child: Row(
        key: ValueKey('home-run-${job.key}'),
        children: [
          SizedBox(
            width: math.max(
              MediaQuery.textScalerOf(context).scale(LwGrid.tap),
              _lineWidth(
                context,
                next == null ? '—' : _time(context, next),
                time,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  next == null ? '—' : _time(context, next),
                  maxLines: 1,
                  softWrap: false,
                  style: time,
                ),
                if (day != null)
                  Text(
                    day,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: HomeType.when(
                      p,
                    ).copyWith(fontSize: HermesType.subtitleSize, height: 1.2),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _Ends(
              gap: 10,
              share: 0.45,
              start: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _title(
                    context,
                    [
                      job.name,
                      if (job.everyMinutes case final m?) _every(s, m),
                    ].join(' · '),
                    style: off
                        ? HomeType.row(p).copyWith(color: HomeType.faint(p))
                        : null,
                  ),
                  result,
                ],
              ),
              end: next == null
                  ? null
                  : Text(
                      homeCountdown(context, next.difference(now)),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: HomeType.when(p).copyWith(fontSize: 13),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tareas ─────────────────────────────────────────────────────────────
//
// The Kanban board Tasks opens on. Small: what is in progress, and how
// many wait. Wide: the tasks in progress. Large: En curso and Pendiente,
// each with its count.

class _TasksTile extends StatelessWidget {
  const _TasksTile(this.t);
  final HomeTileContext t;

  String _assignee(String profile) =>
      t.data.bot(profile)?.displayName ?? profile;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final tasks = t.data.tasks;
    if (t.data.tasksFailed) return _unread(t, context);
    if (tasks == null) {
      return t.data.tasksFailed ? _unread(t, context) : _loading(t, context);
    }
    if (tasks.isEmpty) {
      return _Tap(
        onTap: _act(t, () => t.actions.openTasks(null)),
        child: _quiet(t, context, s.hwTasksEmpty),
      );
    }
    final running = tasks.running;
    final pending = tasks.pending;
    final notes = [
      if (running.isNotEmpty) s.hwTasksRunning(running.length),
      if (pending.isNotEmpty) s.hwTasksPending(pending.length),
    ];
    final row = HomeType.body(p);
    final rowH = math.max(48.0, HomeType.line(context, row) + 13);
    switch (t.size) {
      case HomeWidgetSize.small:
        return _small(context, tasks);
      case HomeWidgetSize.wide:
        return _Body(
          t: t,
          gap: 4,
          onHeader: () => t.actions.openTasks(null),
          trailing: _HeadNote(
            notes.join(' · '),
            key: const ValueKey('home-tasks-note'),
          ),
          pieces: [
            for (final task in running)
              _Piece(
                rowH,
                _row(context, task, running: true),
                rule: true,
                center: true,
              ),
            for (final task in pending)
              _Piece(
                rowH,
                _row(context, task, running: false),
                rule: true,
                center: true,
              ),
          ],
        );
      case HomeWidgetSize.large:
        final section = HomeType.section(p);
        final sectionH = HomeType.line(context, section) + 8;
        _Piece heading(String label, int count, String key) => _Piece(
          sectionH,
          Align(
            alignment: AlignmentDirectional.bottomStart,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text.rich(
                key: ValueKey('home-tasks-$key'),
                TextSpan(
                  children: [
                    TextSpan(text: label.toUpperCase()),
                    TextSpan(
                      text: '  $count',
                      style: TextStyle(letterSpacing: 0, color: p.textMuted),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: section,
              ),
            ),
          ),
          withNext: true,
        );
        return _Body(
          t: t,
          gap: 0,
          onHeader: () => t.actions.openTasks(null),
          pieces: [
            if (running.isNotEmpty) ...[
              heading(s.hwTasksInProgress, running.length, 'running'),
              for (final (i, task) in running.indexed)
                _Piece(
                  rowH,
                  _row(context, task, running: true),
                  rule: i > 0,
                  center: true,
                  row: true,
                ),
            ],
            if (pending.isNotEmpty) ...[
              heading(s.hwTasksWaiting, pending.length, 'pending'),
              for (final (i, task) in pending.indexed)
                _Piece(
                  rowH,
                  _row(context, task, running: false),
                  rule: i > 0,
                  center: true,
                  row: true,
                ),
            ],
          ],
        );
    }
  }

  Widget _row(
    BuildContext context,
    HomeTaskItem task, {
    required bool running,
  }) {
    final p = HomePalette.ofContext(context);
    final assignee = task.assignee;
    return _Tap(
      onTap: _act(t, () => t.actions.openTasks(task)),
      label: task.title,
      child: Row(
        key: ValueKey('home-task-${task.key}'),
        children: [
          Icon(
            running
                ? Icons.data_usage_rounded
                : task.attention
                ? Icons.error_outline_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 15,
            color: running
                ? HomeType.live(p)
                : task.attention
                ? p.attention
                : p.textMuted,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: running
                  ? HomeType.body(p).copyWith(fontWeight: FontWeight.w500)
                  : HomeType.body(p).copyWith(color: p.textMuted),
            ),
          ),
          if (running && assignee != null) ...[
            const SizedBox(width: 8),
            HomeFace(profileName: assignee, data: t.data, size: 18),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 84),
              child: Text(
                _assignee(assignee),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HomeType.meta(p),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _small(BuildContext context, HomeTasks tasks) {
    final s = Strings.of(context);
    final p = HomePalette.ofContext(context);
    final meta = HomeType.meta(p);
    final running = tasks.running;
    final pending = tasks.pending;
    if (running.isEmpty) {
      final first = pending.first;
      final lines = _bigText(context) ? 1 : 2;
      return _Tap(
        onTap: _act(t, () => t.actions.openTasks(null)),
        label: s.hwTasksPending(pending.length),
        child: _Body(
          key: const ValueKey('home-tasks-idle'),
          t: t,
          gap: 6,
          pieces: [
            _Piece(
              HomeFigure.heightOf(context),
              HomeFigure(
                '${pending.length}',
                unit: s.hwTasksPendingWord(pending.length).trim(),
              ),
            ),
          ],
          footer: _Piece(
            HomeType.line(context, meta) * lines,
            Text(
              first.title,
              maxLines: lines,
              overflow: TextOverflow.ellipsis,
              style: meta,
            ),
          ),
        ),
      );
    }
    final task = running.first;
    final title = HomeType.row(p);
    final lines = _bigText(context) ? 1 : 2;
    final assignee = task.assignee;
    return _Tap(
      onTap: _act(t, () => t.actions.openTasks(task)),
      label: task.title,
      child: _Body(
        key: ValueKey('home-task-${task.key}'),
        t: t,
        gap: 6,
        trailing: _HeadNote(
          s.hwTasksRunning(running.length),
          key: const ValueKey('home-tasks-note'),
        ),
        pieces: [
          _Piece(
            HomeFigure.heightOf(context),
            HomeFigure('${running.length}', unit: s.lwpTasksInProgressUnit),
          ),
          // The destination stays visible when its full assignee row has
          // no room under the figure. The tile still opens this exact task.
          _Piece(
            HomeType.line(context, title) * lines +
                HermesSpace.x1 +
                HomeType.line(context, meta),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _title(context, task.title, lines: lines, style: title),
                const SizedBox(height: HermesSpace.x1),
                Text(
                  [
                    if (assignee != null) _assignee(assignee),
                    s.lwpTasksInProgressUnit,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: meta,
                ),
              ],
            ),
            gap: LwGrid.gapTight,
            or: _Piece(
              HomeType.line(context, title),
              _title(context, task.title, style: title),
              gap: LwGrid.gapTight,
            ),
          ),
        ],
        // How many wait and, under it, the board as one thin bar: what runs
        // in the accent, what waits in the track. With less room, the
        // words alone.
        footer: pending.isEmpty
            ? null
            : _Piece(
                HomeType.line(context, meta) +
                    HermesSpace.x1 +
                    _SplitBar.height,
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      s.hwTasksPending(pending.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: meta,
                    ),
                    const SizedBox(height: HermesSpace.x1),
                    _SplitBar(
                      key: const ValueKey('home-tasks-bar'),
                      first: running.length,
                      second: pending.length,
                    ),
                  ],
                ),
                or: _Piece(
                  HomeType.line(context, meta),
                  Text(
                    s.hwTasksPending(pending.length),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: meta,
                  ),
                ),
              ),
      ),
    );
  }
}

/// A thin bar in two parts: [first] in the accent, [second] in the track,
/// each as wide as its share. Decoration only: the words above it say the
/// same.
class _SplitBar extends StatelessWidget {
  const _SplitBar({super.key, required this.first, required this.second});
  final int first;
  final int second;

  static const double height = 5;

  @override
  Widget build(BuildContext context) {
    final p = HomePalette.ofContext(context);
    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: Row(
            // Each part fills the bar's height (a box with nothing in it
            // would be as tall as nothing).
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (first > 0)
                Expanded(
                  flex: first,
                  child: ColoredBox(color: HomeType.live(p)),
                ),
              if (first > 0 && second > 0) const SizedBox(width: 2),
              if (second > 0)
                Expanded(
                  flex: second,
                  child: ColoredBox(color: p.track),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
