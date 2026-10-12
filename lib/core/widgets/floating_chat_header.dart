import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/tokens.dart';
import '../models/activity_snapshot.dart';
import '../theme/app_theme.dart';
import 'island.dart';

/// How a room's one status line reads. The island turns it into its dot.
enum FloatingHeaderTone {
  /// Nothing live.
  idle,

  /// Someone works.
  working,

  /// Needs you.
  waiting,

  /// No connection.
  offline,
}

extension FloatingHeaderToneIsland on FloatingHeaderTone {
  IslandStatus get islandStatus => switch (this) {
    FloatingHeaderTone.idle => IslandStatus.idle,
    FloatingHeaderTone.working => IslandStatus.working,
    FloatingHeaderTone.waiting => IslandStatus.needsYou,
    FloatingHeaderTone.offline => IslandStatus.offline,
  };
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
    this.originalFace = false,
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

  /// The header's `faces` are this identity's ORIGINAL face (QA 9493): a
  /// bot's own face, a profile's custom avatar or companion. The header then
  /// shows them as they are and never asks the mascot builder, which could
  /// only draw a sprite nobody chose.
  final bool originalFace;

  bool get isRoom => members.isNotEmpty;

  /// Whether the header keeps its own `faces`. A room always does: its
  /// members are known bots, drawn with the same faces as the round sheet.
  bool get keepsOriginalFace => originalFace || isRoom;
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
/// and, in the centre, the ISLAND with the face standing on its top edge:
/// the pixel-art companion, the bot's own face or a room's members, always
/// still, fully below the status bar. A gradient scrim (no blur: it would
/// repaint every scroll frame) keeps the controls legible over the text.
///
/// The island's top edge never moves: at rest it is a small pill, and an
/// event makes it grow downwards and sideways, so the face stays where it
/// is. The header's extent ([insetFor]) is that of an island showing an
/// event and never depends on what the island says, so a turn starting or
/// ending never moves the transcript.
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

  /// The face (chat, bot) or overlapping cluster (room) that stands on the
  /// island, up to [faceSize] tall. Shown unless a mascot builder takes the
  /// slot. An empty box leaves the island with nothing on it.
  final Widget faces;

  /// What the mascot slot should show; with no [mascot] the slot always
  /// shows [faces].
  final HeaderMascotRequest? mascot;

  /// Overrides the [HeaderMascotScope] builder for this header.
  final HeaderMascotBuilder? headerMascotBuilder;

  /// The island (a `ChatIsland`). It finds the room it must leave above
  /// itself for the face through [IslandHeadroom].
  final Widget pill;
  final Widget? leading;
  final Widget? trailing;

  /// How tall the face on the island is.
  static const double faceSize = 48;

  /// How far the face's feet reach below the island's top edge.
  static const double faceOverlap = 3;
  static const double buttonSize = 44;
  static const double _top = 4;
  static const double _bottom = 4;

  /// From the header's top to the island's top edge.
  static const double _islandTop = _top + faceSize - faceOverlap;

  /// The scrim runs this far below the header's extent.
  static const double scrimTail = 20;

  /// Like an app bar title, the island's text follows the reader's size up
  /// to this factor; past it the semantics label carries the full text.
  static const double maxTextScale = 1.34;

  /// Height of the header below the top safe inset: the face, and the
  /// island as tall as an event makes it.
  static double heightFor(TextScaler textScaler) =>
      _islandTop + IslandMetrics.eventHeight + _bottom;

  /// Distance from the top of the screen to the header's bottom: what the
  /// transcript reserves above its first row and what a landing keeps
  /// clear. Reads only aspects the keyboard never changes (`viewPadding`,
  /// not `padding`, whose bottom follows the IME).
  static double insetFor(BuildContext context) =>
      MediaQuery.viewPaddingOf(context).top +
      heightFor(MediaQuery.textScalerOf(context));

  /// The 44 dp round side buttons, in the tone of everything that floats.
  static ButtonStyle buttonStyle(HermesThemeColors colors) {
    final chrome = HermesChrome.of(colors);
    return IconButton.styleFrom(
      fixedSize: const Size.square(buttonSize),
      minimumSize: const Size.square(buttonSize),
      tapTargetSize: MaterialTapTargetSize.padded,
      backgroundColor: chrome.fill,
      foregroundColor: chrome.ink,
      shape: CircleBorder(side: BorderSide(color: chrome.line)),
    );
  }

  Widget _mascot(BuildContext context) {
    final request = mascot;
    final builder = headerMascotBuilder ?? HeaderMascotScope.maybeOf(context);
    if (request == null || builder == null || request.keepsOriginalFace) {
      return faces;
    }
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
    // The side buttons line up with the island at rest.
    final buttonTop =
        topPad + _islandTop + IslandMetrics.restHeight / 2 - _buttonSlot / 2;
    Widget side(Widget? button) => SizedBox.square(
      dimension: _buttonSlot,
      child: Center(child: button),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      ),
      // The stack is as tall as the header, or as an island opened to read
      // an event in full: that one may reach further down, and it must
      // still take its touches there.
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          SizedBox(
            key: const ValueKey('floating-header'),
            width: double.infinity,
            height: extent + scrimTail,
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
          Positioned(top: buttonTop, left: 8, child: side(leading)),
          Positioned(top: buttonTop, right: 8, child: side(trailing)),
          Padding(
            padding: EdgeInsets.fromLTRB(
              8 + _buttonSlot + 6,
              topPad + _top,
              8 + _buttonSlot + 6,
              0,
            ),
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: maxTextScale,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.topCenter,
                children: [
                  IslandHeadroom(height: faceSize - faceOverlap, child: pill),
                  // The face stands on the island; the island answers the
                  // touches that land on it.
                  Positioned(
                    top: 0,
                    child: IgnorePointer(
                      child: ExcludeSemantics(
                        child: SizedBox(
                          key: const ValueKey('floating-header-faces'),
                          height: faceSize,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            widthFactor: 1,
                            child: _mascot(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The 48 dp slot (touch target) of a side button.
  static const double _buttonSlot = 48;
}

/// A 44 dp round side button of the floating header (48 dp target).
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
