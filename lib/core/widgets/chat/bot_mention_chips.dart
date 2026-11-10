import 'package:flutter/widgets.dart';

import '../../bots/ui/room/room_models.dart' show roomMemberColor;
import '../../models/bot_mention.dart';
import '../../services/bot_mention_roster.dart';
import '../mission_profile_avatar.dart';
import 'mention_chips.dart';

/// Mentions of a 1:1 chat: the profiles of the connection (every profile the
/// server lists, Bot Mode on or off), resolved with [BotMentionResolver]
/// (Desktop `resolveRosterMentions`): `@token` after the start or a space,
/// the chat's own profile excluded, ambiguous forms left as text. A tap does
/// nothing, as in Desktop, and as the other chips of a 1:1 chat.
///
/// An inline code span that is exactly a profile's id (`` `pi` ``) is a chip
/// too: the server's «Messaging other agents» section lists teammates to the
/// model as `` - `handle` ``, so a reply that delegates names them that way.
/// Only the bare id or handle, written exactly, of two or more characters:
/// friendly titles, `default`/`hermes` (also a command name) and anything a
/// sentence might quote stay code. A profile's id written as a plain word
/// («pi», «sol») is never a chip: ids are common words in several languages
/// and no context rule tells the agent from the word reliably.
class BotMentionChips extends MentionChipResolver {
  BotMentionChips(this.resolver);

  final BotMentionResolver resolver;

  static final RegExp _pattern = RegExp(
    r'(?<!\S)@([a-z0-9][a-z0-9_-]*)',
    caseSensitive: false,
  );

  /// A profile id as the server spells it, at least two characters long.
  static final RegExp _id = RegExp(r'^[a-z0-9][a-z0-9_-]{1,63}$');

  static const Set<String> _reserved = {
    'all',
    'everyone',
    'user',
    'default',
    'hermes',
  };

  @override
  RegExp get pattern => _pattern;

  @override
  MentionChipTarget? lookup(String token) => _target(resolver.lookup(token));

  @override
  MentionChipTarget? lookupName(String code) {
    if (!_id.hasMatch(code) || _reserved.contains(code)) return null;
    final bot = resolver.lookup(code);
    // Exactly the id or the handle: a title's slug is a mention form, not
    // what the server calls the profile.
    if (bot == null || (bot.profile != code && bot.handle != code)) {
      return null;
    }
    return _target(bot);
  }

  MentionChipTarget? _target(BotMention? bot) {
    if (bot == null) return null;
    final profile = bot.avatarProfile;
    final name = [
      bot.title,
      bot.displayName,
      bot.handle,
    ].map(botMentionProse).firstWhere((n) => n.isNotEmpty, orElse: () => '');
    return MentionChipTarget(
      kind: MentionChipKind.agent,
      name: name,
      color: roomMemberColor(bot.handle, profile: profile),
      avatar: (size) => MissionProfileAvatar(
        profileName: bot.profile,
        hasAvatar: false,
        cache: null,
        connectionId: bot.connectionId,
        size: size,
        shape: profile?.botShape,
        colorHex: profile?.botFaceColorHex,
      ),
    );
  }
}

/// [MentionChipScope] for one chat: rebuilt only when the roster changes, so
/// the messages below re-parse then and never per frame.
class BotMentionChipScope extends StatefulWidget {
  const BotMentionChipScope({
    super.key,
    required this.connectionId,
    required this.profile,
    required this.child,
    this.roster,
  });

  final String connectionId;

  /// The chat's profile ('' = default): never a chip for itself.
  final String profile;
  final Widget child;

  /// Tests inject their own; [BotMentionRoster.shared] otherwise.
  final BotMentionRoster? roster;

  @override
  State<BotMentionChipScope> createState() => _BotMentionChipScopeState();
}

class _BotMentionChipScopeState extends State<BotMentionChipScope> {
  BotMentionChips? _chips;
  bool _resolved = false;
  String? _signature;

  BotMentionRoster get _roster => widget.roster ?? BotMentionRoster.shared;

  @override
  void initState() {
    super.initState();
    _roster.addListener(_rosterChanged);
  }

  @override
  void didUpdateWidget(BotMentionChipScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldRoster = oldWidget.roster ?? BotMentionRoster.shared;
    if (!identical(oldRoster, _roster)) {
      oldRoster.removeListener(_rosterChanged);
      _roster.addListener(_rosterChanged);
      _resolved = false;
    }
    if (oldWidget.connectionId != widget.connectionId ||
        oldWidget.profile != widget.profile) {
      _resolved = false;
    }
  }

  void _rosterChanged() {
    if (mounted) setState(() => _resolved = false);
  }

  String _rosterSignature() => [
    widget.connectionId,
    widget.profile,
    for (final bot in _roster.bots(widget.connectionId))
      [
        bot.identity,
        bot.handle,
        bot.title,
        bot.displayName,
        bot.alternateTitle,
        bot.avatarProfile?.botShape,
        bot.avatarProfile?.botFaceColorHex,
      ].join('\u0001'),
  ].join('\u0000');

  @override
  void dispose() {
    _roster.removeListener(_rosterChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_resolved) {
      _resolved = true;
      // The roster notifies on every publish; only a change in what a
      // mention resolves to, or how it looks, re-parses the messages.
      final signature = _rosterSignature();
      if (signature != _signature) {
        _signature = signature;
        final resolver = _roster.resolver(widget.connectionId, widget.profile);
        // No bots: no scope work at all for the messages below.
        _chips = resolver.isEmpty ? null : BotMentionChips(resolver);
      }
    }
    return MentionChipScope(resolver: _chips, child: widget.child);
  }
}
