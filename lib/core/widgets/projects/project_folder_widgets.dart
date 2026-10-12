import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/desktop_control_center.dart';
import '../../theme/app_theme.dart';
import '../profile_face.dart';
import 'project_actions.dart';
import 'project_appearance.dart';

/// Calm tint of a project folder from its Desktop colour; null when it has
/// none (the glyph then uses the theme accent, softened).
Color? projectFolderTint(ProjectNode project) {
  final own = parseProjectColor(project.color);
  return own == null ? null : softFolderTint(own);
}

/// A plain folder shape (back sheet with a tab, lighter front sheet) in a
/// soft, low-chroma colour: the project's own hue when it has one, else
/// the theme accent's. [neutral] folders (chats without a project) are
/// graphite. No glyph inside: the name says what it is.
class ProjectFolderGlyph extends StatelessWidget {
  final Color? tint;
  final bool neutral;
  final double width;

  const ProjectFolderGlyph({
    required this.tint,
    this.neutral = false,
    this.width = 44,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.hermes;
    final dark = theme.brightness == Brightness.dark;
    final base = neutral
        ? colors.textSecondary
        : softFolderTint(tint ?? colors.accent);
    final ground = colors.background;
    final back = Color.lerp(base, ground, dark ? 0.6 : 0.55)!;
    final front = Color.lerp(base, ground, dark ? 0.38 : 0.3)!;
    return ExcludeSemantics(
      child: SizedBox(
        width: width,
        height: width * 0.8,
        child: CustomPaint(
          painter: _FolderPainter(back: back, front: front),
        ),
      ),
    );
  }
}

/// The calm version of any colour: same hue, low chroma, mid lightness.
Color softFolderTint(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withSaturation(hsl.saturation.clamp(0.0, 0.3))
      .withLightness(0.6)
      .toColor();
}

class _FolderPainter extends CustomPainter {
  final Color back;
  final Color front;

  const _FolderPainter({required this.back, required this.front});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = w * 0.12;
    final tabW = w * 0.42;
    final tabH = h * 0.16;
    // Back sheet: rounded rect from the tab line down, plus the tab itself.
    final body = RRect.fromLTRBR(0, tabH, w, h, Radius.circular(r));
    final tab = RRect.fromLTRBAndCorners(
      0,
      0,
      tabW,
      tabH + r,
      topLeft: Radius.circular(r * 0.8),
      topRight: Radius.circular(r * 0.8),
    );
    final paintBack = Paint()..color = back;
    canvas.drawRRect(tab, paintBack);
    canvas.drawRRect(body, paintBack);
    // Front sheet, slightly lower, lighter.
    final frontRect = RRect.fromLTRBR(
      0,
      tabH + h * 0.16,
      w,
      h,
      Radius.circular(r),
    );
    canvas.drawRRect(frontRect, Paint()..color = front);
  }

  @override
  bool shouldRepaint(_FolderPainter old) =>
      old.back != back || old.front != front;
}

/// One folder row of the Projects browser: glyph, name, one short summary
/// line and a chevron. Long-press (and a TalkBack custom action) opens the
/// owner's actions; there is no per-row overflow button.
class ProjectFolderRow extends StatelessWidget {
  final Key rowKey;
  final Widget glyph;
  final String title;
  final String summary;

  final bool dimmed;
  final VoidCallback onTap;
  final VoidCallback? onOptions;
  final String? optionsLabel;

  const ProjectFolderRow({
    required this.rowKey,
    required this.glyph,
    required this.title,
    required this.summary,
    required this.onTap,
    this.onOptions,
    this.optionsLabel,
    this.dimmed = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final options = onOptions;
    return Semantics(
      key: rowKey,
      container: true,
      button: true,
      label: strings.pb1215FolderSemantics(title, summary),
      customSemanticsActions: options == null
          ? null
          : {
              CustomSemanticsAction(
                label: optionsLabel ?? strings.pb1215FolderOptions,
              ): options,
            },
      child: ExcludeSemantics(
        child: Opacity(
          opacity: dimmed ? 0.55 : 1,
          child: InkWell(
            onTap: onTap,
            onLongPress: options,
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    glyph,
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.textDisabled,
                      size: 22,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A chat inside a folder: the profile's face, title, preview and when.
class ProjectChatRow extends StatelessWidget {
  final ProjectSessionPreview session;

  /// Extra context under the title (the project, in search results).
  final String? context;
  final VoidCallback onTap;

  const ProjectChatRow({
    required this.session,
    required this.onTap,
    this.context,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    final title = session.title.isNotEmpty
        ? session.title
        : (session.preview.isNotEmpty
              ? session.preview
              : strings.projectsCenterConversationFallback);
    final second = <String>[
      ?this.context,
      if (session.title.isNotEmpty && session.preview.isNotEmpty)
        session.preview,
    ].join(' · ');
    final when = projectAgo(strings, session.lastActive);
    return InkWell(
      key: ValueKey('pb1215-chat-${session.id}'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              ProfileFace(
                profileName: session.profile.isEmpty
                    ? 'default'
                    : session.profile,
                size: 32,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (second.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        second,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (when.isNotEmpty) ...[
                const SizedBox(width: 10),
                Text(
                  when,
                  style: TextStyle(color: colors.textTertiary, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Inset hairline between rows of an open list (no boxed cards).
class ProjectRowDivider extends StatelessWidget {
  final double indent;

  const ProjectRowDivider({this.indent = 74, super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 0.5,
    indent: indent,
    endIndent: 16,
    color: Theme.of(context).hermes.divider.withValues(alpha: 0.5),
  );
}

/// Calm, centered empty state with an optional single action.
class ProjectEmptyState extends StatelessWidget {
  final Key? stateKey;
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  const ProjectEmptyState({
    required this.icon,
    required this.title,
    required this.body,
    this.stateKey,
    this.action,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 36, 32, 16),
      child: Column(
        key: stateKey,
        children: [
          Icon(icon, size: 40, color: colors.textDisabled),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
          ),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    );
  }
}

/// Lower-case, accent-free text for forgiving search matches.
String projectSearchFold(String value) {
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const to = 'aaaaaeeeeiiiiooooouuuunc';
  final lower = value.toLowerCase();
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    final index = from.indexOf(char);
    out.write(index < 0 ? char : to[index]);
  }
  return out.toString();
}
