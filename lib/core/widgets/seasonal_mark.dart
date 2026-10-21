import 'package:flutter/widgets.dart';

import '../screens/onboarding/halloween.dart';
import '../screens/onboarding/onboarding_motion.dart';

/// The Console logo for a header (pumpkin or Rudolph in season): still, and
/// decorative for screen readers.
class SeasonalMark extends StatelessWidget {
  const SeasonalMark({this.size = 21, super.key});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ConsoleMark(size: size, season: seasonOf(seasonClock())),
  );
}
