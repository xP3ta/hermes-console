import 'package:flutter/material.dart';

import '../widgets/hermes_app_bar.dart' show hermesUnderHeader;

/// Ends a page's body at its lower edge and at its sides, but not at the
/// top: a list inside it that does not clip itself (`hermesUnderHeader`)
/// keeps painting upwards, under the floating header.
///
/// For a body that stops above something of its own (the dock, a row of
/// buttons): without it, rows waiting below the list's edge would show there
/// too.
class HermesOpenTopClip extends StatelessWidget {
  const HermesOpenTopClip({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ClipRect(clipper: const _OpenTop(), child: child);
}

class _OpenTop extends CustomClipper<Rect> {
  const _OpenTop();

  /// Far more than any header: status bar, toolbar and a second row.
  static const double reach = 400;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, -reach, size.width, size.height);

  @override
  Rect getApproximateClipRect(Size size) => getClip(size);

  @override
  bool shouldReclip(_OpenTop oldClipper) => false;
}

/// The lower edge of a list that ends before something floating: its rows
/// dissolve into the page instead of being cut by a line. Static, and it
/// never takes a touch.
///
/// Place it over the last [extent] of the list. A list keeps its last row
/// readable with a bottom padding of its own; the fade is nearly clear over
/// the upper half of its height.
class HermesBottomFade extends StatelessWidget {
  const HermesBottomFade({this.extent = defaultExtent, this.color, super.key});

  static const double defaultExtent = 36;

  final double extent;

  /// The page colour; the scaffold's by default.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final page = color ?? Theme.of(context).scaffoldBackgroundColor;
    return IgnorePointer(
      child: SizedBox(
        height: extent,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                page.withValues(alpha: 0),
                page.withValues(alpha: 0.35),
                page,
              ],
              stops: const [0, 0.5, 1],
            ),
          ),
        ),
      ),
    );
  }
}

/// One page scroll: the page's own controls (a search field, a filter) first,
/// then its content, so the controls leave with the rows instead of staying
/// as a band that cuts them.
///
/// The controls keep their place in the tree whatever follows them (rows, a
/// loader, an empty state), so a field among them keeps the focus while its
/// results change. The scroll paints under the floating header.
class HermesControlsScroll extends StatelessWidget {
  const HermesControlsScroll({
    required this.controls,
    required this.slivers,
    this.onRefresh,
    this.refreshColor,
    this.controller,
    this.scrollKey,
    super.key,
  });

  /// The controls, laid out as a column at the top of the scroll.
  final List<Widget> controls;

  /// The content, as slivers. See [fill] and [list].
  final List<Widget> slivers;

  final Future<void> Function()? onRefresh;
  final Color? refreshColor;
  final ScrollController? controller;
  final Key? scrollKey;

  /// A state that takes what the controls leave free (a loader, an empty
  /// state, an error), centred by its own child.
  static Widget fill(Widget child) =>
      SliverFillRemaining(hasScrollBody: false, child: child);

  /// Rows built on demand, with the padding a `ListView.builder` would have.
  static Widget list({
    required int itemCount,
    required NullableIndexedWidgetBuilder itemBuilder,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
  }) => HermesSliverRows(
    itemCount: itemCount,
    itemBuilder: itemBuilder,
    padding: padding,
  );

  /// Rows given at once, with the padding a `ListView` would have.
  static Widget children(
    List<Widget> children, {
    EdgeInsetsGeometry padding = EdgeInsets.zero,
  }) => SliverPadding(
    padding: padding,
    sliver: SliverList.list(children: children),
  );

  @override
  Widget build(BuildContext context) {
    final scroll = CustomScrollView(
      key: scrollKey,
      controller: controller,
      clipBehavior: hermesUnderHeader,
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: controls,
          ),
        ),
        ...slivers,
      ],
    );
    final refresh = onRefresh;
    return refresh == null
        ? scroll
        : RefreshIndicator(
            color: refreshColor,
            onRefresh: refresh,
            child: scroll,
          );
  }
}

/// A view switch (or another small control) that stays in place, floating,
/// over a list that scrolls under it and under the header.
///
/// [child] is the page's content; a list in it adds [extent] to its top
/// padding so its first row rests below the controls, and passes
/// `hermesUnderHeader` as its `clipBehavior`. [controls] should be floating
/// pieces (`HermesFloatingSurface`, a floating segmented control).
class HermesStickyControls extends StatelessWidget {
  const HermesStickyControls({
    required this.controls,
    required this.child,
    super.key,
  });

  /// Room the controls take at the top of the content.
  static const double extent = 56;

  final Widget controls;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final page = Theme.of(context).scaffoldBackgroundColor;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        // The header's scrim, carried on behind the controls.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: extent + 14,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    page.withValues(alpha: 0.6),
                    page.withValues(alpha: 0.45),
                    page.withValues(alpha: 0),
                  ],
                  stops: const [0, 0.6, 1],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 14,
          right: 14,
          height: extent,
          child: RepaintBoundary(child: Center(child: controls)),
        ),
      ],
    );
  }
}

/// The foot of a page whose content keeps scrolling behind floating pieces
/// that have no band of their own (the chat's composer and the status pill
/// under it). Behind those pieces, and only there, what passes dissolves
/// into the page: clear at their upper edge, at full strength by their
/// lowest row and down to the screen's edge, so a line of text never reads
/// through a piece or beside the labels of the last row. The mirror of the
/// header's scrim. Static, no blur, and it never takes a touch.
///
/// Give it exactly the area of the pieces. Nothing is painted above them.
class HermesBottomScrim extends StatelessWidget {
  const HermesBottomScrim({this.foot = 52, this.color, super.key});

  /// How much of the page colour covers what is behind the lowest row. Text
  /// behind it stays under 1.6:1 against the page, light theme or dark.
  static const double strength = 0.86;

  /// The least height the dissolve takes, however low the pieces are.
  static const double minRamp = 36;

  /// Height of the lowest row of pieces with its margins, above the system
  /// inset: the part that gets the full [strength].
  final double foot;

  /// The page colour; the scaffold's by default.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final page = color ?? Theme.of(context).scaffoldBackgroundColor;
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _BottomScrimPainter(
            page,
            foot + MediaQuery.paddingOf(context).bottom,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _BottomScrimPainter extends CustomPainter {
  const _BottomScrimPainter(this.page, this.foot);

  final Color page;
  final double foot;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final least = size.height < HermesBottomScrim.minRamp
        ? size.height
        : HermesBottomScrim.minRamp;
    final rampHeight = size.height - foot > least ? size.height - foot : least;
    final full = page.withValues(alpha: HermesBottomScrim.strength);
    final ramp = Rect.fromLTWH(0, 0, size.width, rampHeight);
    canvas.drawRect(
      ramp,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [page.withValues(alpha: 0), full],
        ).createShader(ramp),
    );
    if (size.height > rampHeight) {
      canvas.drawRect(
        Rect.fromLTRB(0, rampHeight, size.width, size.height),
        Paint()..color = full,
      );
    }
  }

  @override
  bool shouldRepaint(_BottomScrimPainter oldDelegate) =>
      oldDelegate.page != page || oldDelegate.foot != foot;
}

/// A scroll that ends above the page's own buttons (Guardar, Crear…): its
/// rows dissolve into the page there instead of being cut by a band, and it
/// stays open upwards, under the floating header.
///
/// The buttons are not laid over it: they sit below, on the page itself, so
/// they ride above the keyboard with the rest of the page and never cover
/// the field being edited.
class HermesFadedEnd extends StatelessWidget {
  const HermesFadedEnd({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      HermesOpenTopClip(child: child),
      const Positioned(left: 0, right: 0, bottom: 0, child: HermesBottomFade()),
    ],
  );
}

/// The rows of a [HermesControlsScroll], built on demand: a padded sliver
/// list. A widget of its own so a rebuild of the rows can be told apart from
/// a rebuild of the page.
class HermesSliverRows extends StatelessWidget {
  const HermesSliverRows({
    required this.itemCount,
    required this.itemBuilder,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => SliverPadding(
    padding: padding,
    sliver: SliverList.builder(itemCount: itemCount, itemBuilder: itemBuilder),
  );
}
