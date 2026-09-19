import 'agent_profile.dart';

export '../utils/bot_mention_text.dart';

String botMentionProse(String value) => String.fromCharCodes(
  value
      .replaceAll(
        RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069]'),
        ' ',
      )
      .replaceAll(RegExp(r'["`\[\]\\]'), "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .runes
      .take(128),
);

List<String> mentionNameForms(String value) {
  final name = value.trim().toLowerCase();
  return {
        name
            .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
            .replaceAll(RegExp(r'^-+|-+$'), ''),
        name.replaceAll(RegExp(r'[^a-z0-9_-]+'), ''),
      }
      .where(
        (form) =>
            RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(form) &&
            !const {
              'all',
              'everyone',
              'user',
              'default',
              'hermes',
            }.contains(form),
      )
      .toList();
}

final class BotMention {
  final String connectionId;
  final String profile;
  final String handle;
  final String title;
  final String displayName;
  final String alternateTitle;
  final String connectionLabel;
  final bool remote;
  final AgentProfile? avatarProfile;

  const BotMention({
    required this.connectionId,
    required this.profile,
    required this.handle,
    this.title = '',
    this.displayName = '',
    this.alternateTitle = '',
    this.connectionLabel = '',
    this.remote = false,
    this.avatarProfile,
  });

  String get identity => '$connectionId\u0000$profile';
  String get target => remote
      ? '$profile@$connectionId'
      : profile.trim().toLowerCase() == 'default'
      ? 'hermes'
      : profile;
  Iterable<String> get forms => {
    profile.toLowerCase(),
    handle.toLowerCase(),
    ...mentionNameForms(title),
    ...mentionNameForms(displayName),
    ...mentionNameForms(alternateTitle),
  };

  Map<String, dynamic> toJson() => {
    'connection_id': connectionId,
    'profile': profile,
    'handle': handle,
    'title': title,
    'display_name': displayName,
    'alternate_title': alternateTitle,
    'connection_label': connectionLabel,
    'remote': remote,
  };
  factory BotMention.fromJson(Map<String, dynamic> json) => BotMention(
    connectionId: json['connection_id'] as String,
    profile: json['profile'] as String,
    handle: json['handle'] as String,
    title: json['title'] as String? ?? '',
    displayName: json['display_name'] as String? ?? '',
    alternateTitle: json['alternate_title'] as String? ?? '',
    connectionLabel: json['connection_label'] as String? ?? '',
    remote: json['remote'] == true,
  );
}

final class BotMentionResolver {
  final Map<String, BotMention?> _byForm = {};
  BotMentionResolver(
    Iterable<BotMention> roster, {
    required String connectionId,
    required String profile,
  }) {
    for (final bot in roster) {
      if (!RegExp(
            r'^[a-z0-9][a-z0-9_-]{0,63}$',
            caseSensitive: false,
          ).hasMatch(bot.profile) ||
          !RegExp(
            r'^[a-z0-9][a-z0-9_.:-]{0,255}$',
            caseSensitive: false,
          ).hasMatch(bot.connectionId) ||
          (bot.connectionId == connectionId && bot.profile == profile)) {
        continue;
      }
      for (final form in bot.forms) {
        if (_byForm.containsKey(form)) {
          if (_byForm[form]?.identity != bot.identity) _byForm[form] = null;
        } else {
          _byForm[form] = bot;
        }
      }
    }
  }

  List<BotMention> resolve(String text) {
    final prose = text
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
        .replaceAll(RegExp(r'`[^`\n]*`'), ' ');
    final seen = <String>{};
    return [
      for (final match in RegExp(
        r'(^|\s)@([a-z0-9][a-z0-9_-]*)',
        caseSensitive: false,
      ).allMatches(prose))
        if (_byForm[match.group(2)!.toLowerCase()] case final bot?)
          if (seen.add(bot.identity)) bot,
    ];
  }

  List<BotMention> suggestions(String query) {
    final seen = <String>{};
    final q = query.toLowerCase();
    return [
      for (final bot in _byForm.values)
        if (bot != null &&
            seen.add(bot.identity) &&
            _byForm[bot.handle.toLowerCase()]?.identity == bot.identity &&
            RegExp(
              r'^[a-z0-9][a-z0-9_-]*$',
              caseSensitive: false,
            ).hasMatch(bot.handle) &&
            (bot.forms.any((form) => form.startsWith(q)) ||
                bot.title.toLowerCase().startsWith(q) ||
                bot.displayName.toLowerCase().startsWith(q)))
          bot,
    ];
  }
}

String buildBotMentionAnnotation(List<BotMention> bots) {
  if (bots.isEmpty) return '';
  final lines = bots.map((bot) {
    final title = botMentionProse(bot.title);
    final where = bot.remote
        ? ' — on ${botMentionProse(bot.connectionLabel.isEmpty ? bot.connectionId : bot.connectionLabel)} (message_agent target: "${bot.target}")'
        : bot.handle != bot.target
        ? ' (message_agent target: "${bot.target}")'
        : '';
    final handle =
        RegExp(
          r'^[a-z0-9][a-z0-9_-]*$',
          caseSensitive: false,
        ).hasMatch(bot.handle)
        ? bot.handle
        : botMentionProse(bot.handle);
    return '@$handle = agent profile "${bot.profile}"${title.isEmpty ? '' : ' ("$title")'}$where';
  });
  // Keep the upstream template literal for byte-for-byte review.
  // ignore: prefer_interpolation_to_compose_strings
  return '\n\n[@mentions resolved from the Bot Mode roster — the user is referring to: ' +
      lines.join('; ') +
      '. If they want one of these agents contacted, compose your own message and send it with your message_agent tool (agents on other connected machines are reachable too — the Desktop relays it); never forward the user\u2019s text verbatim. If this session has no message_agent tool, agent messaging is unavailable here — say so.]';
}
