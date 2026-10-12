import 'package:flutter/widgets.dart';

/// One rule for every bot face in the app (QA 9494): a face is drawn
/// straight on whatever surface holds it — no separator ring, no backing
/// disc or squircle, no shadow. Overlapping faces simply overlap (the one
/// in front covers the next one), and a face's state is a plain coloured
/// dot ([FaceStateDot]).
///
/// A ring painted in a theme colour (page, card, pill) only disappears on
/// that exact colour; faces sit on pills, cards, sheets, drawers and the
/// transcript scrim, so anywhere else it reads as a black (or white) halo.
class FaceStateDot extends StatelessWidget {
  const FaceStateDot({required this.color, required this.size, super.key});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
  );
}
