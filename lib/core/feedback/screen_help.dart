import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_premium_ui.dart';

/// Small (?) button that keeps a screen's explanation out of the way.
///
/// Explanatory paragraphs used to sit at the top of screens permanently. They
/// now live behind this button (usually in the app bar): the screen stays
/// clean and the help is one tap away for whoever wants it.
class ScreenHelpButton extends StatelessWidget {
  const ScreenHelpButton({
    required this.paragraphs,
    this.title,
    this.helpKey,
    super.key,
  });

  /// Text shown in the help surface, one paragraph per entry.
  final List<String> paragraphs;

  /// Optional heading of the help surface (usually the screen title).
  final String? title;

  /// Key of the help surface (tests open and find it by this key).
  final Key? helpKey;

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return IconButton(
      key: const ValueKey('screen-help-button'),
      tooltip: s.kanbanHelpTooltip,
      icon: const Icon(Icons.help_outline_rounded),
      onPressed: () => showScreenHelp(
        context,
        paragraphs: paragraphs,
        title: title,
        helpKey: helpKey,
      ),
    );
  }
}

/// Opens the help surface of [ScreenHelpButton] directly.
Future<void> showScreenHelp(
  BuildContext context, {
  required List<String> paragraphs,
  String? title,
  Key? helpKey,
}) {
  final colors = Theme.of(context).hermes;
  return showHermesFloatingSurface<void>(
    context: context,
    surfaceKey: helpKey ?? const ValueKey('screen-help-surface'),
    builder: (_) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
          ],
          for (var i = 0; i < paragraphs.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            Text(
              paragraphs[i],
              style: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
