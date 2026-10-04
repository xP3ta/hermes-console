import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../design/content.dart' show HermesStatusText;
import '../../../theme/app_theme.dart';
import '../../../widgets/mission_profile_avatar.dart';
import '../../../widgets/room_mirror_avatar.dart';
import '../room_avatar_tile.dart';
import 'living_bot_face.dart';
import 'roster_model.dart';

/// Row time like a messenger: "now", HH:mm today, "yesterday", weekday this
/// week, otherwise d MMM.
String rosterTime(BuildContext context, DateTime at, {DateTime? now}) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  final english = Localizations.localeOf(context).languageCode == 'en';
  final current = now ?? DateTime.now();
  final diff = current.difference(at);
  if (diff.inSeconds.abs() < 60) return english ? 'now' : 'ahora';
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(at.year, at.month, at.day);
  final days = today.difference(day).inDays;
  if (days <= 0) return DateFormat.Hm(locale).format(at);
  if (days == 1) return english ? 'yesterday' : 'ayer';
  if (days < 7) return DateFormat.E(locale).format(at);
  return DateFormat.MMMd(locale).format(at);
}

/// Bot row (spec 070 S1): living face with ONE state signal, name, time,
/// and line 2 = "Working · <title>" in accent when working, otherwise the
/// canonical Bot Chat preview. No presence dot, no unread dot.
class RosterBotRow extends StatelessWidget {
  final BotRosterEntry entry;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final DateTime? now;

  const RosterBotRow({
    super.key,
    required this.entry,
    required this.avatarCache,
    required this.onTap,
    required this.onLongPress,
    this.now,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final profile = entry.profile;
    final working = entry.working;
    final line = rosterBotLine(s, entry);
    final at = entry.at;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Material(
        key: ValueKey('mission-bot-row-${profile.name}'),
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('mission-bot-${profile.name}'),
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                LivingBotFace(
                  profileName: profile.name,
                  profile: profile,
                  avatarCache: avatarCache,
                  signal: entry.signal,
                  size: 48,
                  semanticLabel: entry.title,
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.1,
                              ),
                            ),
                          ),
                          if (profile.botHidden) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.visibility_off_outlined,
                              size: 14,
                              color: colors.textDisabled,
                            ),
                          ],
                          if (at != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              rosterTime(context, at, now: now),
                              key: ValueKey('roster-time-${profile.name}'),
                              style: TextStyle(
                                color: colors.textDisabled,
                                fontSize: 11.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        line,
                        key: ValueKey('roster-line-${profile.name}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: working
                              ? colors.accentText
                              : entry.needsYou
                              ? colors.warning
                              : colors.textSecondary,
                          fontSize: 13,
                          fontWeight: working
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Line 2 of a bot: what it is doing, else its last preview.
String rosterBotLine(Strings s, BotRosterEntry entry) => switch (entry.signal) {
  BotFaceSignal.working || BotFaceSignal.thinking || BotFaceSignal.speaking
      when entry.workingOn != null =>
    s.rosterWorkingOn(entry.workingOn!),
  BotFaceSignal.attention when entry.workingOn != null => s.rosterWaitingFor(
    entry.workingOn!,
  ),
  BotFaceSignal.working => s.rosterWorking,
  BotFaceSignal.thinking => s.rosterThinking,
  BotFaceSignal.speaking => s.rosterSpeaking,
  _ => entry.preview.isEmpty ? s.rosterNoPreview : entry.preview,
};

/// Pinned bot: living face with its name.
///
/// Two layouts share one visual size: [compact] (face beside the name, used
/// when only one or two bots are pinned so the strip does not leave a wide
/// empty area) and the default strip tile (name centred under the face).
/// A raster avatar fills its whole box while a procedural face draws its body
/// at ~74 % of it, so rasters are inset to [rasterScale] for equal weight.
class RosterPinnedTile extends StatelessWidget {
  final BotRosterEntry entry;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool compact;

  const RosterPinnedTile({
    super.key,
    required this.entry,
    required this.avatarCache,
    required this.onTap,
    required this.onLongPress,
    this.compact = false,
  });

  static const double faceSize = 60;
  static const double compactFaceSize = 44;
  static const double tileWidth = 76;
  static const double rasterScale = .76;
  static const double _nameFontSize = 12.5;
  static const double _nameHeight = 1.3;

  /// Exact tile height for the pinned strip: top padding + face + gap +
  /// one name line at the current text scale + bottom padding.
  static double heightFor(BuildContext context) =>
      4 +
      faceSize +
      8 +
      MediaQuery.textScalerOf(context).scale(_nameFontSize) * _nameHeight +
      4;

  /// Height of a compact tile at the current text scale (48 dp minimum).
  static double compactHeightFor(BuildContext context) {
    final text =
        MediaQuery.textScalerOf(context).scale(14.5) * 1.3 +
        MediaQuery.textScalerOf(context).scale(12.5) * 1.3;
    return (text > compactFaceSize ? text : compactFaceSize) + 12;
  }

  bool get _raster => entry.profile.botPaintsPhoto && avatarCache != null;

  Widget _face(double box) {
    final size = _raster ? (box * rasterScale).roundToDouble() : box;
    return SizedBox.square(
      dimension: box,
      child: Center(
        child: LivingBotFace(
          profileName: entry.profile.name,
          profile: entry.profile,
          avatarCache: avatarCache,
          signal: entry.signal,
          size: size,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final emphasis = entry.needsYou || entry.working;
    final nameStyle = TextStyle(
      color: emphasis ? colors.textPrimary : colors.textSecondary,
      fontSize: _nameFontSize,
      height: _nameHeight,
      fontWeight: FontWeight.w600,
    );
    if (compact) {
      final status = rosterBotLine(Strings.of(context), entry).trim();
      return Semantics(
        container: true,
        button: true,
        label: entry.title,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _face(compactFaceSize),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 14.5,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (status.isNotEmpty)
                        Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: entry.working
                                ? colors.accentText
                                : colors.textSecondary,
                            fontSize: 12.5,
                            height: 1.3,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Semantics(
      container: true,
      button: true,
      label: entry.title,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: tileWidth,
          child: Column(
            children: [
              const SizedBox(height: 4),
              _face(faceSize),
              const SizedBox(height: 8),
              Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: nameStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Room row: room avatar tile (member faces grid), name, time, "You:/@x: preview",
/// needs-you badge and the "Desktop" label for projection rooms.
class RosterRoomRow extends StatelessWidget {
  final RoomRosterEntry entry;
  final MissionProfileAvatarCache? avatarCache;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final DateTime? now;

  const RosterRoomRow({
    super.key,
    required this.entry,
    required this.avatarCache,
    required this.onTap,
    this.onLongPress,
    this.now,
  });

  Widget _tile() => RoomAvatarTile(
    members: [
      for (final m in entry.members) RoomAvatarTileMember(m.handle, m.profile),
    ],
    avatarCache: avatarCache,
    size: 48,
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final preview = entry.preview;
    final line = preview.isEmpty
        ? s.rosterRoomMembers(entry.members.length)
        : entry.previewFromUser
        ? s.rosterYouSaid(preview)
        : entry.previewAuthor != null
        ? s.rosterMemberSaid(entry.previewAuthor!, preview)
        : preview;
    final at = entry.at;
    final id = entry.publicKey;
    return Material(
      key: ValueKey('roster-room-row-$id'),
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              if (entry.image case final image?)
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: RoomMirrorAvatar(image: image, fallback: _tile()),
                )
              else
                _tile(),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The title takes every pixel the time column does not
                    // need (a Flexible + Spacer pair split the row in half and
                    // truncated "Hermes Cons…" early) and may wrap to a
                    // second line for long room names.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(text: entry.title),
                            key: ValueKey('roster-room-title-$id'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (at != null) ...[
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              rosterTime(context, at, now: now),
                              style: TextStyle(
                                color: colors.textDisabled,
                                fontSize: 11.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        // Spec 080: projection rooms say so inline on the
                        // preview line (dot + "Desktop · read only"), never
                        // as a bordered box next to the title.
                        if (entry.desktopOnly) ...[
                          Flexible(
                            flex: 0,
                            child: HermesStatusText(
                              key: ValueKey('roster-room-desktop-$id'),
                              label: s.rosterDesktopLabel,
                              meta: s.statusReadOnly,
                              maxLines: 1,
                            ),
                          ),
                          if (line.isNotEmpty)
                            Text(
                              ' · ',
                              style: TextStyle(
                                color: colors.textDisabled,
                                fontSize: 13,
                              ),
                            ),
                        ],
                        Expanded(
                          child: Text(
                            line,
                            key: ValueKey('roster-room-line-$id'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: entry.working
                                  ? colors.accentText
                                  : colors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (entry.needsYou) ...[
                          const SizedBox(width: 8),
                          _Tag(
                            key: ValueKey('roster-room-needs-you-$id'),
                            label: s.rosterNeedsYouBadge,
                            color: colors.warning,
                            filled: true,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  final bool filled;

  const _Tag({
    super.key,
    required this.label,
    required this.color,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: filled ? color.withValues(alpha: .14) : Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: .45)),
    ),
    child: Text(
      label,
      maxLines: 1,
      style: TextStyle(
        color: color,
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
