import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/activity_snapshot.dart';
import '../theme/app_theme.dart';

/// Tone of an idle/override header pill.
enum FloatingHeaderTone {
  /// Nothing live: the name and a chevron.
  idle,

  /// Someone works (rooms): a green dot before the line.
  working,

  /// Needs you: amber.
  waiting,

  /// No connection: red.
  offline,
}

/// What the header's mascot slot shows. Integration seam: the mascot engine
/// (review/1215-mascot) maps it to `MascotSprite` / `MascotCluster`.
enum HeaderMascotState { idle, thinking, working, speaking, waiting, offline }

/// One request for the header's mascot slot.
@immutable
class HeaderMascotRequest {
  const HeaderMascotRequest({
    required this.identity,
    required this.state,
    this.members = const [],
    this.memberStates = const [],
    this.activity,
    this.error = false,
    this.justFinished = false,
    this.name,
    this.size = FloatingChatHeader.faceSize,
  });

  /// Profile or bot name (plain chat, bot chat); the room id in rooms.
  final String identity;
  final HeaderMascotState state;

  /// Rooms: the member identities, in cluster order. Empty elsewhere.
  final List<String> members;

  /// Rooms: each member's own state, parallel to [members]. Missing
  /// entries fall back to [state].
  final List<HeaderMascotState> memberStates;

  /// Chats: what is live now, so the engine can tell a tool from thinking
  /// and a pending permission from a running step. [state] still owns
  /// offline.
  final ActivitySnapshot? activity;

  /// The last turn failed.
  final bool error;

  /// The short "just finished" window after a turn.
  final bool justFinished;

  /// Screen-reader name; defaults to [identity].
  final String? name;
  final double size;

  bool get isRoom => members.isNotEmpty;
}

typedef HeaderMascotBuilder =
    Widget Function(BuildContext context, HeaderMascotRequest request);

/// fh1215 seam: provide a [HeaderMascotBuilder] above the chat screens to
/// replace the header's default face (living bot face, companion, member
/// cluster) without touching the header layout. Absent, the default stays.
class HeaderMascotScope extends InheritedWidget {
  const HeaderMascotScope({
    required this.builder,
    required super.child,
    super.key,
  });

  final HeaderMascotBuilder builder;

  static HeaderMascotBuilder? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HeaderMascotScope>()?.builder;

  @override
  bool updateShouldNotify(HeaderMascotScope oldWidget) =>
      builder != oldWidget.builder;
}

/// Floating chat header of every chat surface (1.2.15): plain chats, bot
/// chats and rooms.
///
/// No app bar band: the transcript scrolls UNDER it. A round button on the
/// left (back or menu), an optional round button on the right (new chat)
/// and, in the centre, the ACTIVITY PILL with the face(s) sitting on its top
/// edge. A gradient scrim (no blur: it would repaint every scroll frame)
/// keeps the controls legible over the text.
///
/// Its extent ([insetFor]) never depends on what the pill says, so a turn
/// starting or ending never moves the transcript.
class FloatingChatHeader extends StatelessWidget {
  const FloatingChatHeader({
    required this.faces,
    required this.pill,
    this.leading,
    this.trailing,
    this.mascot,
    this.headerMascotBuilder,
    super.key,
  });

  /// The default face (chat/bot) or overlapping cluster (room), [faceSize]
  /// tall. Shown unless a mascot builder takes the slot.
  final Widget faces;

  /// What the mascot slot should show; with no [mascot] the slot always
  /// shows [faces].
  final HeaderMascotRequest? mascot;

  /// Overrides the [HeaderMascotScope] builder for this header.
  final HeaderMascotBuilder? headerMascotBuilder;

  /// The activity pill (an `ActivityPill` while something is live, a
  /// [FloatingHeaderPill] otherwise).
  final Widget pill;
  final Widget? leading;
  final Widget? trailing;

  static const double faceSize = 30;

  /// How far the face sits down over the pill's top edge.
  static const double faceOverlap = 10;
  static const double buttonSize = 44;

  /// The pill's slot (the activity pill's 44 dp row).
  static const double pillHeight = 44;
  static const double _top = 4;
  static const double _bottom = 6;

  /// The scrim runs this far below the header's extent.
  static const double scrimTail = 20;

  /// Like an app bar title, the pill text follows the reader's size up to
  /// this factor; past it the semantics label carries the full text.
  static const double maxTextScale = 1.34;

  /// Height of the header below the top safe inset. The pill slot is a
  /// fixed 44 dp that fits its text up to [maxTextScale].
  static double heightFor(TextScaler textScaler) =>
      _top + faceSize - faceOverlap + pillHeight + _bottom;

  /// Distance from the top of the screen to the header's bottom: what the
  /// transcript reserves above its first row and what a landing keeps
  /// clear. Reads only aspects the keyboard never changes (`viewPadding`,
  /// not `padding`, whose bottom follows the IME).
  static double insetFor(BuildContext context) =>
      MediaQuery.viewPaddingOf(context).top +
      heightFor(MediaQuery.textScalerOf(context));

  /// The 44 dp round surface-tinted look of the side buttons.
  static ButtonStyle buttonStyle(HermesThemeColors colors) =>
      IconButton.styleFrom(
        fixedSize: const Size.square(buttonSize),
        minimumSize: const Size.square(buttonSize),
        tapTargetSize: MaterialTapTargetSize.padded,
        backgroundColor: colors.surfaceVariant.withValues(alpha: 0.92),
        foregroundColor: colors.textPrimary,
        shape: CircleBorder(
          side: BorderSide(color: colors.divider.withValues(alpha: 0.6)),
        ),
      );

  Widget _mascot(BuildContext context) {
    final request = mascot;
    final builder = headerMascotBuilder ?? HeaderMascotScope.maybeOf(context);
    if (request == null || builder == null) return faces;
    // The engine gets a fixed box: a square face, or a cluster as wide as
    // its overlapping faces, so an expanding sprite never takes the row.
    return SizedBox(
      key: const ValueKey('floating-header-mascot-box'),
      width: mascotWidthFor(request),
      height: request.size,
      child: builder(context, request),
    );
  }

  /// Width of the mascot slot for [request]: one face is square; a room
  /// cluster shows up to four faces overlapping by 40 %.
  static double mascotWidthFor(HeaderMascotRequest request) {
    final count = request.members.length.clamp(1, 4);
    return request.size + request.size * 0.6 * (count - 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final height = heightFor(MediaQuery.textScalerOf(context));
    final extent = topPad + height;
    final dark = theme.brightness == Brightness.dark;
    final bg = colors.background;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      ),
      child: SizedBox(
        key: const ValueKey('floating-header'),
        height: extent + scrimTail,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey('floating-header-scrim'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        bg.withValues(alpha: 0.85),
                        bg.withValues(alpha: 0.7),
                        bg.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.55, 1],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: topPad + _top,
              left: 8,
              right: 8,
              height: height - _top - _bottom,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SizedBox(
                    width: 48,
                    height: pillHeight + 4,
                    child: Center(child: leading),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: MediaQuery.withClampedTextScaling(
                          maxScaleFactor: maxTextScale,
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.topCenter,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: faceSize - faceOverlap,
                                ),
                                child: SizedBox(
                                  height: pillHeight,
                                  child: Center(child: pill),
                                ),
                              ),
                              // The face sits ON the pill, over its top edge.
                              IgnorePointer(
                                child: ExcludeSemantics(
                                  child: SizedBox(
                                    key: const ValueKey(
                                      'floating-header-faces',
                                    ),
                                    height: faceSize,
                                    child: _mascot(context),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    height: pillHeight + 4,
                    child: Center(child: trailing),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The header pill when no activity pill applies: the name with a chevron
/// (idle), or a one-line state (rooms working, needs you, offline). Same
/// stadium surface as the activity pill.
class FloatingHeaderPill extends StatelessWidget {
  const FloatingHeaderPill({
    required this.text,
    required this.semanticsLabel,
    this.tone = FloatingHeaderTone.idle,
    this.onTap,
    this.onLongPress,
    this.hint,
    super.key,
  });

  final String text;
  final FloatingHeaderTone tone;
  final String semanticsLabel;
  final String? hint;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final ink = switch (tone) {
      FloatingHeaderTone.idle => colors.textPrimary,
      FloatingHeaderTone.working => colors.textPrimary,
      FloatingHeaderTone.waiting => colors.warning,
      FloatingHeaderTone.offline => colors.error,
    };
    final dot = switch (tone) {
      FloatingHeaderTone.idle => null,
      FloatingHeaderTone.working => colors.success,
      FloatingHeaderTone.waiting => colors.warning,
      FloatingHeaderTone.offline => colors.error,
    };
    return Semantics(
      container: true,
      header: true,
      button: onTap != null,
      label: semanticsLabel,
      hint: hint,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: Material(
        color: colors.surface,
        shape: StadiumBorder(
          side: BorderSide(color: colors.divider, width: 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.3),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: EdgeInsets.fromLTRB(dot == null ? 16 : 12, 6, 10, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (dot != null) ...[
                    SizedBox.square(
                      key: ValueKey('floating-header-dot-${tone.name}'),
                      dimension: 7,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: dot,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                  ],
                  Flexible(
                    child: Text(
                      text,
                      key: const ValueKey('floating-header-text'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: colors.textSecondary,
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

/// A 44 dp round side button of the floating header (48 dp target).
class FloatingHeaderButton extends StatelessWidget {
  const FloatingHeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 20),
    style: FloatingChatHeader.buttonStyle(Theme.of(context).hermes),
  );
}
