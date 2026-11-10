import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';

import '../design/gel_surface.dart';
import '../design/glass_strip.dart';
import '../models/activity_snapshot.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
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
/// left (back or menu), an optional round button on the right and, in the
/// centre, the ISLAND with the face standing on its top edge: the pixel-art
/// companion, the bot's own face or a room's members, always still, fully
/// below the status bar. The header's band is solid down to its extent and
/// only then fades out: the owner saw the reply read through the island and the
/// buttons on the open Fold (APK 9708).
///
/// [glass] (Vistas v3, the owner: the header of the same glass as the composer)
/// frosts the pieces instead, as one [HermesGlassStrip]: the transcript
/// shows through them, blurred under the composer's veil, and the band is
/// the strip's soft fade. Where the device or the reader asks for no blur
/// the header is the solid one above.
///
/// With [trailingSecondary] the right-hand side holds two round buttons,
/// apart (Vistas v3: [Vistas] [Ajustes]), and the island is centred between
/// the left button and them, never touching either.
///
/// [compact] (the keyboard up on a short window) is one thin row: no face,
/// the island and the buttons at the top.
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
    this.trailingSecondary,
    this.mascot,
    this.headerMascotBuilder,
    this.compact = false,
    this.overlap = faceOverlap,
    this.faceHidden = false,
    this.faceHalo,
    this.glass = false,
    this.glassPriority = chatGlassPriority,
    super.key,
  });

  /// The pieces frosted as one strip ([HermesGlassStrip]) over the soft
  /// fade, rather than solid over a solid band.
  final bool glass;

  /// Of the header strips on screen only the highest blurs
  /// (`FrostedZone.top`). A chat's outranks a list's (`HermesAppBar`, 0):
  /// on the open Fold, the list and the chat side by side, the chat's
  /// frosts and the list's keeps the chrome of before (REVIEW-Q9-VISTAS3
  /// P2).
  final int glassPriority;

  /// A chat header's [glassPriority].
  static const int chatGlassPriority = 1;

  /// The face has gone down into the voice capsule (135 v2), which draws
  /// its own: the one standing on the island fades out, and its room stays
  /// so the island's top edge does not move. It comes back when the capsule
  /// is minimized or the voice ends.
  final bool faceHidden;

  /// Voz inline: the halo drawn behind the face (the voice's orb). It is
  /// laid around the face without taking room, so the face, the island and
  /// the side buttons keep their places with or without it.
  final Widget? faceHalo;

  /// How far [faces] reach below the island's top edge: [faceOverlap] for a
  /// chat's face, [roomFaceOverlap] for a room's cluster. The island's top
  /// edge is the same with either.
  final double overlap;

  /// One thin row: no face above the island ([heightFor] with `compact`).
  final bool compact;

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

  /// A second round button left of [trailing], apart from it (Vistas v3:
  /// «Vistas» beside «Ajustes»). The island keeps the centre: the same room
  /// is left on both sides.
  final Widget? trailingSecondary;

  /// How tall the face on the island is.
  static const double faceSize = 48;

  /// How far a chat's face reaches below the island's top edge. The face
  /// (the mascot, a bot's own face) is perched ON the pill, centred, its
  /// base overlapping the pill's top edge by this much, with no air between
  /// them (the owner, APK 9801: «apoyado»). The pill keeps the same room above
  /// its line ([IslandMetrics.faceReach]), so it never covers the text.
  static const double faceOverlap = IslandMetrics.faceReach;

  /// How far a room's faces reach below the island's top edge: the round
  /// members' faces of the cluster sit on it, a little into its edge, as
  /// the room's header has always drawn them.
  static const double roomFaceOverlap = 3;
  static const double buttonSize = HermesSize.iconButton;

  /// Above a face that does not reach into the island; one that does
  /// ([overlap]) starts that much lower, so the island's top edge never
  /// moves and neither does the header's extent.
  static const double _top = 1;
  static const double _bottom = 4;

  /// From the header's top to the island's top edge.
  static const double _islandTop = _top + faceSize;

  /// [compact]: from the header's top to the island's top edge.
  static const double _compactTop = 4;

  /// The scrim runs this far below the header's extent.
  static const double scrimTail = 20;

  /// Like an app bar title, the island's text follows the reader's size up
  /// to this factor; past it the semantics label carries the full text.
  static const double maxTextScale = 1.34;

  /// the owner (APK 9708): with the keyboard up on the open Fold the header, the
  /// composer and its attachment left no message in between. Below this
  /// much height above the keyboard the header is [compact].
  static const double compactBelowHeight = 560;

  /// Whether a window [height] dp tall with a keyboard [keyboard] dp tall
  /// gets the [compact] header.
  static bool compactFor({required double height, required double keyboard}) =>
      keyboard > 0 && height - keyboard < compactBelowHeight;

  /// Height of the header below the top safe inset: the face, and the
  /// island as tall as an event makes it. [compact]: the island alone.
  static double heightFor(TextScaler textScaler, {bool compact = false}) =>
      (compact ? _compactTop : _islandTop) +
      IslandMetrics.eventHeight +
      _bottom;

  /// Distance from the top of the screen to the header's bottom: what the
  /// transcript reserves above its first row and what a landing keeps
  /// clear. Reads only aspects the keyboard never changes (`viewPadding`,
  /// not `padding`, whose bottom follows the IME); the caller says when the
  /// header is [compact].
  static double insetFor(BuildContext context, {bool compact = false}) =>
      MediaQuery.viewPaddingOf(context).top +
      heightFor(MediaQuery.textScalerOf(context), compact: compact);

  /// Narrower than this between the same room on both sides, the island
  /// centres between its buttons instead: about what a name, a count and a
  /// timer take at the reader's text size.
  static const double minCentredIslandWidth = 240;

  /// The 44 dp round side buttons, on a 48 dp target. The circle under
  /// them is their face ([FloatingHeaderButton]), so the button itself is
  /// bare: it only draws its ink.
  static ButtonStyle buttonStyle(HermesThemeColors colors) =>
      IconButton.styleFrom(
        fixedSize: const Size.square(buttonSize),
        minimumSize: const Size.square(buttonSize),
        tapTargetSize: MaterialTapTargetSize.padded,
        foregroundColor: HermesChrome.of(colors).ink,
        shape: const CircleBorder(),
      );

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

  // Its own layer, whoever hosts it. Over a Scaffold body that makes room
  // for the keyboard, the body relays out on every keyboard frame, and a
  // relayout repaints its layer: without a boundary of its own the header
  // was repainted with it (gate gint41: 55 render objects on the first
  // frame, while nothing in it rebuilt). The chat screen had given it one
  // (QA 9494); a room's header (room_screen.dart, RoomHeaderBar in a bare
  // Positioned) had not.
  // With [glass], the header is its own strip, unless the screen already
  // put it in one (a chat whose pinned chip is a piece of the same strip):
  // then its pieces join that one, and the boundary is the strip's.
  @override
  Widget build(BuildContext context) {
    final header = _TopInset(child: Builder(builder: _buildHeader));
    if (!glass) return RepaintBoundary(child: header);
    if (HermesGlassStrip.contains(context)) return header;
    // No other repaint boundary between the strip and its pieces.
    return HermesGlassStrip(priority: glassPriority, child: header);
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final topPad = _TopInset.of(context);
    final height = heightFor(
      MediaQuery.textScalerOf(context),
      compact: compact,
    );
    final extent = topPad + height;
    final dark = theme.brightness == Brightness.dark;
    final bg = colors.background;
    // The side buttons line up with the island at rest.
    final islandTop = compact ? _compactTop : _islandTop;
    final buttonTop =
        topPad + islandTop + IslandMetrics.restHeight / 2 - _buttonSlot / 2;
    Widget side(Widget? button) => SizedBox.square(
      dimension: _buttonSlot,
      child: Center(child: button),
    );
    final secondary = trailingSecondary;
    // Each side keeps the room of its buttons (on the right one button, or
    // two apart); the island keeps the centre, the same room on both
    // sides, unless that leaves it narrower than [minCentredIslandWidth] (a
    // chat in a narrow panel, with «Vistas»): then it centres between its
    // buttons, in the room they leave. It never touches either.
    const leftRoom = _sideInset + _buttonSlot + _islandGap;
    final rightRoom =
        _sideInset + (secondary == null ? _buttonSlot : pairWidth) + _islandGap;
    final total = extent + scrimTail;
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
                  // Frosting: the strip's soft fade, never solid. Else
                  // solid to the header's extent, then the tail fades.
                  gradient: HermesGlassStrip.of(context) != null
                      ? HermesGlassStrip.fade(
                          page: bg,
                          statusInset: topPad,
                          extent: extent,
                        )
                      : LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [bg, bg, bg.withValues(alpha: 0)],
                          stops: [0, total <= 0 ? 1 : extent / total, 1],
                        ),
                ),
              ),
            ),
          ),
          Positioned(top: buttonTop, left: _sideInset, child: side(leading)),
          if (secondary == null)
            Positioned(top: buttonTop, right: _sideInset, child: side(trailing))
          else
            Positioned(
              top: buttonTop,
              right: _sideInset,
              child: Row(
                key: const ValueKey('floating-header-trailing-pair'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  side(secondary),
                  const SizedBox(width: pairGap),
                  side(trailing),
                ],
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              final centred =
                  constraints.maxWidth - rightRoom * 2 >= minCentredIslandWidth;
              return Padding(
                padding: EdgeInsets.fromLTRB(
                  centred ? rightRoom : leftRoom,
                  topPad + (compact ? _compactTop : _top + overlap),
                  rightRoom,
                  0,
                ),
                child: _island(context),
              );
            },
          ),
        ],
      ),
    );
  }

  /// The island and the face that stands on it. One thin row ([compact])
  /// has no face.
  Widget _island(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: maxTextScale,
    child: Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: [
        IslandHeadroom(height: compact ? 0 : faceSize - overlap, child: pill),
        // The face stands on the island; the island answers the touches
        // that land on it.
        if (!compact)
          Positioned(
            top: 0,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: AnimatedOpacity(
                  key: const ValueKey('floating-header-faces-visibility'),
                  opacity: faceHidden ? 0 : 1,
                  duration: HermesMotion.duration(context, HermesMotion.fast),
                  curve: HermesMotion.standard,
                  child: SizedBox(
                    key: const ValueKey('floating-header-faces'),
                    height: faceSize,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      widthFactor: 1,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          if (faceHalo != null)
                            Positioned(
                              key: const ValueKey('floating-header-face-halo'),
                              left: -faceHaloSpread,
                              right: -faceHaloSpread,
                              top: -faceHaloSpread,
                              bottom: -faceHaloSpread,
                              child: faceHalo!,
                            ),
                          _mascot(context),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  /// How far the voice halo reaches past the face on every side.
  static const double faceHaloSpread = 14;

  /// The 48 dp slot (touch target) of a side button.
  static const double _buttonSlot = 48;

  /// From the screen's edge to a side button's slot.
  static const double _sideInset = 8;

  /// Air between the island and the side buttons.
  static const double _islandGap = 6;

  /// Between the two right-hand buttons' targets (Vistas v3: 8 + 48 + 8 +
  /// 48 at the right edge).
  static const double pairGap = HermesSpace.x2;

  /// Width of the two right-hand buttons and the room between them.
  static const double pairWidth = 2 * _buttonSlot + pairGap;
}

/// The view as the header sees it: everything but its bottom edge.
///
/// A Scaffold that makes room for the keyboard lowers its body's
/// `viewPadding.bottom` on every keyboard frame (MediaQueryData
/// .removeViewInsets). Anything in the header that read the MediaQuery
/// then rebuilt on each frame: first the header itself (`viewPaddingOf`,
/// already fixed), then, as measured, the island's own Builder
/// from MediaQuery.withClampedTextScaling, which reads the whole data. That
/// Builder sits inside the island's LayoutBuilder, so its rebuild relaid the
/// LayoutBuilder out, and the paint climbed to the header's own boundary
/// (56 render objects in fh1215, 81 in kbp9494).
///
/// The header lives at the top: its bottom edges (padding, view padding,
/// keyboard inset) mean nothing to it. Here they are 0, so on a keyboard
/// frame the data below is equal to the last one and nothing under it is
/// notified. Only this widget rebuilds, with the same child. The top inset,
/// the text scale and the size still reach the header when they change (a
/// rotation, a cutout, the reader's text size).
class _TopInset extends StatelessWidget {
  const _TopInset({required this.child});

  final Widget child;

  static double of(BuildContext context) =>
      MediaQuery.viewPaddingOf(context).top;

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    return MediaQuery(
      data: data.copyWith(
        padding: data.padding.copyWith(bottom: 0),
        viewPadding: data.viewPadding.copyWith(bottom: 0),
        viewInsets: data.viewInsets.copyWith(bottom: 0),
      ),
      child: child,
    );
  }
}

/// A 44 dp round side button of the floating header (48 dp target): its
/// face is the circle in the tone of everything that floats, or, in a
/// frosting header ([HermesGlassStrip]), the composer's veil over the
/// strip's blur, with no shadow.
///
/// [toggled] makes it a switch that shows its state (Vistas v3: the
/// workspace is open): a soft accent fill and [selectedIcon]. With
/// [onLongPress] a small chevron in the circle says there is more, and a
/// screen reader gets it as the action [longPressLabel].
class FloatingHeaderButton extends StatelessWidget {
  const FloatingHeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.mirrored = false,
    this.selectedIcon,
    this.toggled,
    this.highlighted = false,
    this.onLongPress,
    this.longPressLabel,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Draws [icon] flipped left to right (a side panel on the left).
  final bool mirrored;

  /// The icon while [toggled] is on.
  final IconData? selectedIcon;

  /// Null: a plain button. Otherwise a switch, on or off.
  final bool? toggled;

  /// Shown as on (the soft accent face, [selectedIcon]) without being a
  /// switch: a button that opens a menu and says something is on (the owner's
  /// final «Vistas»: a panel beside the chat).
  final bool highlighted;
  final VoidCallback? onLongPress;
  final String? longPressLabel;

  /// The accent laid over the face of a button that is on.
  static const double _onTint = 0.16;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final chrome = HermesChrome.of(colors);
    final on = (toggled ?? false) || highlighted;
    // The glyph's colour is set here, so IconButton cannot dim it: a
    // button that cannot be used takes the muted ink (REVIEW-Q9-VISTAS3 P3).
    final glyph = Icon(
      on ? selectedIcon ?? icon : icon,
      size: HermesIcon.lg,
      color: onPressed == null
          ? chrome.mutedInk
          : on
          ? colors.accentText
          : chrome.ink,
    );
    final base = HermesGlassStrip.of(context)?.veil ?? chrome.fill;
    final face = DecoratedBox(
      key: const ValueKey('floating-header-button-face'),
      decoration: ShapeDecoration(
        color: on
            ? Color.alphaBlend(colors.accent.withValues(alpha: _onTint), base)
            : base,
        shape: CircleBorder(
          side: BorderSide(
            color: on ? colors.accent.withValues(alpha: 0.5) : chrome.line,
          ),
        ),
      ),
      child: const SizedBox.square(dimension: FloatingChatHeader.buttonSize),
    );
    final more = onLongPress;
    Widget button = IconButton(
      // A tooltip answers a long press too: with one of its own, the
      // button's name goes to the screen reader below instead.
      tooltip: more == null ? tooltip : null,
      onPressed: onPressed,
      icon: mirrored ? Transform.flip(flipX: true, child: glyph) : glyph,
      style: FloatingChatHeader.buttonStyle(colors),
    );
    if (more != null) {
      button = GestureDetector(onLongPress: more, child: button);
    }
    if (toggled != null || more != null) {
      button = MergeSemantics(
        child: Semantics(
          label: more == null ? null : tooltip,
          toggled: toggled,
          onLongPress: more,
          customSemanticsActions: more == null || longPressLabel == null
              ? null
              : {CustomSemanticsAction(label: longPressLabel!): more},
          child: button,
        ),
      );
    }
    // The gel of every round button (rims, sheen, a press that compresses
    // it) over the face: the same material as the list's buttons.
    return SizedBox.square(
      dimension: HermesSpace.tap,
      child: HermesGelSurface(
        key: const ValueKey('floating-header-button-gel'),
        inset: (HermesSpace.tap - FloatingChatHeader.buttonSize) / 2,
        child: Stack(
          alignment: Alignment.center,
          children: [
            HermesGlassPiece(shape: const CircleBorder(), child: face),
            button,
            if (more != null)
              PositionedDirectional(
                end: HermesSpace.x2,
                bottom: HermesSpace.x2,
                child: IgnorePointer(
                  child: Icon(
                    Icons.expand_more_rounded,
                    key: const ValueKey('floating-header-button-more'),
                    size: HermesSpace.x3,
                    color: on ? colors.accentText : chrome.mutedInk,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
