import 'package:flutter/widgets.dart';

/// From this text scale on, a one-line label may take [labelMaxLines]'s
/// second line.
const double largeTextScale = 1.3;

/// Lines a one-line label may take: one at normal sizes and [large] once
/// the text is enlarged, so at 200 % a long name wraps instead of being cut
/// to a few letters. TalkBack reads the whole text either way.
///
/// A wrap rather than a tooltip: many of these rows already use the long
/// press (copy, menus), which a tooltip would take over.
int labelMaxLines(BuildContext context, {int large = 2}) {
  final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
  return scale >= largeTextScale ? large : 1;
}
