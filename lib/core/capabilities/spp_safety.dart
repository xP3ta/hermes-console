// Skills, plugins and MCP: pure presentation and validation helpers.
//
// Nothing here talks to a server or runs anything. The phone only shows,
// checks and sends text; the server decides what is valid and runs it.
//
//  * masking: what a server list answers for an MCP server (URL, arguments,
//    environment) may carry a credential. Every place that shows it goes
//    through [sppSafeTarget]; the environment is never shown at all.
//  * validation: specific, early reasons for the MCP form and the skill
//    forms, mirroring the rules the server states.
import '../../l10n/app_localizations.dart' show Strings;
import '../utils/transport_privacy.dart';

/// What replaces a hidden value.
const String sppMask = '••••';

// ── Masking ────────────────────────────────────────────────────────────────

const Set<String> _secretWords = {
  'token',
  'secret',
  'password',
  'passwd',
  'passphrase',
  'pass',
  'pwd',
  'key',
  'apikey',
  'accesskey',
  'secretkey',
  'privatekey',
  'auth',
  'oauth',
  'authorization',
  'bearer',
  'credential',
  'credentials',
  'creds',
  'cookie',
  'session',
  'signature',
  'sig',
  'jwt',
  'dsn',
};

/// Names that hide a credential wherever they sit once the separators are
/// gone (`access_key_id`, `X-Api-Key`, `connectionString`).
const List<String> _secretParts = [
  'token',
  'secret',
  'password',
  'passwd',
  'passphrase',
  'apikey',
  'accesskey',
  'secretkey',
  'privatekey',
  'connectionstring',
  'credential',
  'cookie',
  'authorization',
];

final RegExp _camelBreak = RegExp(r'([a-z0-9])([A-Z])');

/// `--api-key`, `X_AUTH_TOKEN`, `password`, `AccessKeyId`… : the name of a
/// credential. `auth` is one, `author` is not.
bool sppIsSecretName(String name) {
  final lower = name
      .replaceAllMapped(_camelBreak, (m) => '${m[1]}_${m[2]}')
      .toLowerCase();
  final compact = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  for (final part in _secretParts) {
    if (compact.contains(part)) return true;
  }
  for (final word in lower.split(RegExp(r'[^a-z0-9]+'))) {
    if (_secretWords.contains(word)) return true;
  }
  return false;
}

final RegExp _tokenShaped = RegExp(
  r'^(?:sk-[A-Za-z0-9_-]{12,}'
  r'|gh[pousr]_[A-Za-z0-9]{20,}'
  r'|github_pat_[A-Za-z0-9_]{20,}'
  r'|xox[abprs]-[A-Za-z0-9-]{10,}'
  r'|AKIA[0-9A-Z]{16}'
  r'|eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]*'
  r'|(?=[A-Za-z0-9+/_=-]*\d)(?=[A-Za-z0-9+/_=-]*[A-Za-z])'
  r'[A-Za-z0-9][A-Za-z0-9+/_=-]{31,})$',
);

/// A value that looks like a credential by shape alone.
bool sppLooksLikeSecret(String value) => _tokenShaped.hasMatch(value.trim());

final RegExp _schemeHead = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*://');

/// `scheme://host[:port]/path` of a text that starts with a scheme: no user
/// info, no query values, no fragment. `null` when [text] does not start with
/// `scheme://`. A URL that cannot be parsed (a password with a slash in it)
/// shows only its scheme.
String? _cleanUrl(String text) {
  final head = _schemeHead.firstMatch(text);
  if (head == null) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasAuthority) return '${head.group(0)}$sppMask';
  final segments = [
    for (final segment in uri.pathSegments)
      sppLooksLikeSecret(segment) ? sppMask : segment,
  ];
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  final port = uri.hasPort ? ':${uri.port}' : '';
  final path = segments.isEmpty ? '' : '/${segments.join('/')}';
  final query = uri.hasQuery ? '?…' : '';
  return '${uri.scheme}://$host$port$path$query';
}

/// Every `scheme://…` inside [text], cleaned the same way (any scheme:
/// postgres, redis, ssh, git+https…).
String _maskUrlsIn(String text) => text.replaceAllMapped(
  _urlInText,
  (match) => _cleanUrl(match.group(0)!) ?? match.group(0)!,
);

/// `scheme://host[:port]/path`: no user info, no query values, no fragment.
/// A query is replaced by `?…` so the reader knows something was cut; a path
/// segment that looks like a credential is masked. Any scheme counts, and a
/// URL after a prefix (`jdbc:postgresql://…`) is cleaned too.
String sppSafeEndpoint(String raw) {
  final text = raw.trim();
  if (!text.contains('://')) return text;
  return _cleanUrl(text) ?? _maskUrlsIn(text);
}

final RegExp _blank = RegExp(r'\s');

/// Blank-separated words of [text], keeping a quoted piece (`"a b"`) in one
/// word with its quotes. An unbalanced quote falls back to plain blanks.
List<String> sppSplitWords(String text) {
  final words = <String>[];
  final buffer = StringBuffer();
  String? quote;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quote != null) {
      buffer.write(ch);
      if (ch == quote) quote = null;
    } else if (ch == '"' || ch == "'") {
      quote = ch;
      buffer.write(ch);
    } else if (_blank.hasMatch(ch)) {
      if (buffer.isNotEmpty) words.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  if (quote != null) {
    return text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  }
  if (buffer.isNotEmpty) words.add(buffer.toString());
  return words;
}

String _unquote(String word) {
  if (word.length >= 2) {
    final first = word[0];
    if ((first == '"' || first == "'") && word.endsWith(first)) {
      return word.substring(1, word.length - 1);
    }
  }
  return word;
}

const Set<String> _authSchemes = {
  'bearer',
  'basic',
  'digest',
  'negotiate',
  'token',
};
final RegExp _assignName = RegExp(r'^-{0,2}[A-Za-z_][A-Za-z0-9_.\-]*$');
final RegExp _headerLine = RegExp(
  r'^([A-Za-z][A-Za-z0-9_\-]*)\s*:(?!//)\s*(\S.*)$',
);
final RegExp _basicValue = RegExp(r'^[A-Za-z0-9+/=._~\-]{8,}$');
final RegExp _bearerInline = RegExp(
  r'\b(bearer)\s+[^\s"\x27,;)}\]]+',
  caseSensitive: false,
);
final RegExp _basicInline = RegExp(
  r'\b(basic)\s+[A-Za-z0-9+/=._~\-]{8,}',
  caseSensitive: false,
);

/// A flag (or `NAME` of an assignment) whose value is a credential: the
/// credential names, headers (`-H`, `--header`), `-p`/`-P`, `--pass*`,
/// `--key*`.
bool _isSecretFlag(String name) {
  if (sppIsSecretName(name)) return true;
  if (!name.startsWith('-')) return false;
  if (name == '-H' || name == '-p' || name == '-P') return true;
  if (!name.startsWith('--')) return false;
  final bare = name.substring(2).toLowerCase();
  return bare.startsWith('pass') ||
      bare.startsWith('key') ||
      bare.endsWith('header') ||
      bare.endsWith('headers');
}

/// Credentials inside one piece of text: a secret header line, URLs, name /
/// value pairs with a credential name and `Bearer` / `Basic` values.
String _maskInline(String text) {
  final header = _headerLine.firstMatch(text);
  if (header != null && sppIsSecretName(header.group(1)!)) {
    return '${header.group(1)}: $sppMask';
  }
  var out = _maskUrlsIn(text);
  out = out.replaceAllMapped(_secretPair, _maskPair);
  out = out.replaceAllMapped(_bearerInline, (m) => '${m.group(1)} $sppMask');
  return out.replaceAllMapped(_basicInline, (m) => '${m.group(1)} $sppMask');
}

/// One word of a command line. [hideNext] asks the caller to hide the word
/// (or words) that follow: the value of a credential flag, or the value of a
/// header whose name stands alone (`Authorization:` then `Bearer x`).
({String word, bool hideNext}) _maskWord(String word, {required bool first}) {
  final text = _unquote(word);
  final equals = text.indexOf('=');
  if (equals > 0 && _assignName.hasMatch(text.substring(0, equals))) {
    final name = text.substring(0, equals);
    final value = _unquote(text.substring(equals + 1));
    if (value.isEmpty) return (word: word, hideNext: false);
    final more =
        value.endsWith(':') || _authSchemes.contains(value.toLowerCase());
    if (_isSecretFlag(name)) {
      return (word: '$name=$sppMask', hideNext: more);
    }
    var cleaned = _maskInline(value);
    if (cleaned == value && sppLooksLikeSecret(value)) cleaned = sppMask;
    return (word: cleaned == value ? word : '$name=$cleaned', hideNext: more);
  }
  if (text.length > 1 &&
      text.endsWith(':') &&
      !_blank.hasMatch(text) &&
      sppIsSecretName(text.substring(0, text.length - 1))) {
    return (word: word, hideNext: true);
  }
  final header = _headerLine.firstMatch(text);
  if (header != null && sppIsSecretName(header.group(1)!)) {
    return (
      word: '${header.group(1)}: $sppMask',
      hideNext: _authSchemes.contains(header.group(2)!.toLowerCase()),
    );
  }
  final cleaned = _maskInline(text);
  if (cleaned != text) return (word: cleaned, hideNext: false);
  if (text.startsWith('-')) {
    return (word: word, hideNext: _isSecretFlag(text));
  }
  if (!first && sppLooksLikeSecret(text)) {
    return (word: sppMask, hideNext: false);
  }
  return (word: word, hideNext: false);
}

/// Masks the arguments of a command line: the value after a credential flag
/// (`--password x`, `-H "Authorization: …"`), `name=value` and
/// `--flag=value` pairs (a credential name hides the value; a URL value loses
/// its user info and query, whatever its scheme), environment assignments
/// before the command (`TOKEN=x node`), `Authorization:` and `Bearer` values,
/// URLs and anything shaped like a token. The command itself (first word)
/// stays unless it carries one of those.
List<String> sppMaskArgs(List<String> words) {
  final out = <String>[];
  var hide = false;
  var merge = false;
  var previous = '';
  for (var index = 0; index < words.length; index++) {
    final word = words[index];
    final text = _unquote(word);
    final flag = text.startsWith('-');
    if (hide && !flag) {
      // A header name alone or a scheme word: the credential comes after it.
      final more =
          text.endsWith(':') || _authSchemes.contains(text.toLowerCase());
      if (!merge) out.add(sppMask);
      hide = more;
      merge = more;
      previous = '';
      continue;
    }
    hide = false;
    merge = false;
    if (!flag &&
        (previous == 'bearer' ||
            previous == 'basic' && _basicValue.hasMatch(text))) {
      out.add(sppMask);
      previous = '';
      continue;
    }
    previous = text.toLowerCase();
    final masked = _maskWord(word, first: index == 0);
    out.add(masked.word);
    hide = masked.hideNext;
  }
  return out;
}

/// What the screens show for an MCP server's target: its URL or its command
/// line, with every credential hidden.
String sppSafeTarget(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return text;
  return sppMaskArgs(sppSplitWords(text)).join(' ');
}

final RegExp _urlInText = RegExp(
  r'''[A-Za-z][A-Za-z0-9+.\-]*://'''
  r'''(?:\[[0-9A-Fa-f:.]*\][^\s'"<>)\]]*|[^\s'"<>)\]]+)''',
);
final RegExp _authHeader = RegExp(
  r'(authorization["\x27]?\s*[:=]\s*["\x27]?)(?:(?:bearer|basic|token)\s+)?[^\s"\x27,;]+',
  caseSensitive: false,
);
final RegExp _bearerWord = RegExp(
  r'\b(bearer)\s+[A-Za-z0-9._~+/=\-]{8,}',
  caseSensitive: false,
);

/// `name = value`, `name: value` and `"name": "value"` with a credential
/// name. Group 1 is everything up to the value, 2 the quote of a quoted
/// value (which may hold blanks), 3 the quoted text and 4 a bare value.
final RegExp _secretPair = RegExp(
  r'([A-Za-z0-9_.\-]*(?:token|secret|passw(?:or)?d|passphrase|api[_\-]?key'
  r'|credential|cookie|private[_\-]?key|access[_\-]?key|secret[_\-]?key'
  r'|connection[_\-]?string|session[_\-]?id|jwt'
  r'|(?<![A-Za-z])(?:pass|pwd|session|auth|oauth|authorization|dsn|key|creds)'
  r'(?![A-Za-z]))'
  r'''[A-Za-z0-9_.\-]*["']?\s*[:=]\s*)'''
  r'''(?:(["'])(.*?)\2|["']?(?:(?:bearer|basic|digest)\s+)?([^\s"',;)}\]]+))''',
  caseSensitive: false,
);

String _maskPair(Match m) {
  final quote = m.group(2);
  return quote == null
      ? '${m.group(1)}$sppMask'
      : '${m.group(1)}$quote$sppMask$quote';
}

/// `--password x`, `--api-key x` in a command line printed in a log.
final RegExp _secretFlag = RegExp(
  r'(?<![\w-])(--(?:pass(?:word|wd|phrase)?|pwd|secret[\w-]*|token[\w-]*'
  r'|api-?key|access-?key|private-?key)\s+)'
  r'(?:"[^"]*"|\x27[^\x27]*\x27|[^\s-]\S*)',
  caseSensitive: false,
);
final RegExp _tokenWord = RegExp(
  r'\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}'
  r'|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}'
  r'|AKIA[0-9A-Z]{16}'
  r'|eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]*)',
);

/// One line of a server log with its credentials hidden: URLs lose user info
/// and query values, `Authorization` / `Bearer` values, `name=value` pairs
/// with a credential name and token-shaped words become [sppMask]. The log is
/// the server's; what the phone shows of it is cleaned here.
String sppMaskLogLine(String line) {
  var out = line.replaceAllMapped(_urlInText, (match) {
    final raw = match.group(0)!;
    final tail = RegExp(r'[.,;:]+$').firstMatch(raw)?.group(0) ?? '';
    return sppSafeEndpoint(raw.substring(0, raw.length - tail.length)) + tail;
  });
  out = out.replaceAllMapped(_authHeader, (m) => '${m.group(1)}$sppMask');
  out = out.replaceAllMapped(_bearerWord, (m) => '${m.group(1)} $sppMask');
  out = out.replaceAllMapped(_secretPair, _maskPair);
  out = out.replaceAllMapped(_secretFlag, (m) => '${m.group(1)}$sppMask');
  return out.replaceAll(_tokenWord, sppMask);
}

// ── MCP form checks ────────────────────────────────────────────────────────

enum SppMcpIssue {
  nameEmpty,
  nameChars,
  urlEmpty,
  urlScheme,
  urlHost,
  urlUserInfo,
  urlQuery,
  urlFragment,
  commandEmpty,
  commandControl,
  commandTooLong,
  commandSpaces,
  commandShell,
}

final RegExp _mcpName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final RegExp _control = RegExp(r'[\u0000-\u001F\u007F]');

/// The server addresses a server by name in a URL path, so a name keeps to a
/// small safe alphabet.
SppMcpIssue? sppCheckMcpName(String name) {
  final text = name.trim();
  if (text.isEmpty) return SppMcpIssue.nameEmpty;
  return _mcpName.hasMatch(text) ? null : SppMcpIssue.nameChars;
}

/// Why [raw] cannot be an MCP endpoint. Credentials never go in the URL.
SppMcpIssue? sppCheckMcpUrl(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return SppMcpIssue.urlEmpty;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.hasScheme ||
      !{'http', 'https'}.contains(uri.scheme.toLowerCase())) {
    return SppMcpIssue.urlScheme;
  }
  if (uri.host.isEmpty) return SppMcpIssue.urlHost;
  if (uri.userInfo.isNotEmpty) return SppMcpIssue.urlUserInfo;
  if (uri.hasQuery) return SppMcpIssue.urlQuery;
  if (uri.hasFragment) return SppMcpIssue.urlFragment;
  return null;
}

/// Hard reasons a stdio command cannot be sent.
SppMcpIssue? sppCheckMcpCommand(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return SppMcpIssue.commandEmpty;
  if (_control.hasMatch(text)) return SppMcpIssue.commandControl;
  if (text.length > 800) return SppMcpIssue.commandTooLong;
  return null;
}

/// A reminder, not a block: the server starts the program itself, without a
/// shell, so arguments belong in their own field.
SppMcpIssue? sppMcpCommandHint(String raw) {
  final text = raw.trim();
  if (RegExp(r'[;|&`$<>]').hasMatch(text)) return SppMcpIssue.commandShell;
  if (RegExp(r'\s').hasMatch(text)) return SppMcpIssue.commandSpaces;
  return null;
}

/// `true` when the endpoint would travel without TLS over a network the user
/// does not control. Only a warning: the phone never connects to it.
bool sppMcpUrlIsPublicCleartext(String raw) =>
    TransportPrivacy.classify(raw) == TransportPrivacyClass.publicCleartext &&
    raw.trim().toLowerCase().startsWith('http://');

/// `true` for any `http://` endpoint (private or not), for a softer note.
bool sppMcpUrlIsCleartext(String raw) =>
    raw.trim().toLowerCase().startsWith('http://');

// ── Skill checks ───────────────────────────────────────────────────────────

enum SppSkillIssue {
  nameEmpty,
  nameChars,
  nameTooLong,
  categoryChars,
  descriptionEmpty,
  descriptionTooLong,
  contentEmpty,
  contentNoFrontmatter,
  contentUnclosed,
  contentNoName,
  contentNoDescription,
  contentNoBody,
  contentTooLong,
  contentNul,
}

/// The server's own limits.
const int sppSkillNameMax = 64;
const int sppSkillContentMax = 100000;

/// A NEW skill's description must fit the system-prompt budget.
const int sppSkillNewDescriptionMax = 60;

final RegExp _skillName = RegExp(r'^[a-z0-9][a-z0-9._-]*$');

SppSkillIssue? sppCheckSkillName(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return SppSkillIssue.nameEmpty;
  if (text.length > sppSkillNameMax) return SppSkillIssue.nameTooLong;
  return _skillName.hasMatch(text) ? null : SppSkillIssue.nameChars;
}

/// Empty is fine (no category). A category is one directory name.
SppSkillIssue? sppCheckSkillCategory(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (text.length > sppSkillNameMax || !_skillName.hasMatch(text)) {
    return SppSkillIssue.categoryChars;
  }
  return null;
}

/// A SKILL.md split into the shallow `key: value` lines of its frontmatter and
/// the body after it. [closed] is false when the opening `---` has no closing
/// line (then the whole text is [body]).
final class SppSkillText {
  final bool hasFrontmatter;
  final bool closed;
  final Map<String, String> fields;
  final String body;

  const SppSkillText({
    required this.hasFrontmatter,
    required this.closed,
    required this.fields,
    required this.body,
  });
}

final RegExp _frontmatterEnd = RegExp(r'\n---\s*\n');

SppSkillText sppSplitSkill(String content) {
  final text = content.startsWith('﻿') ? content.substring(1) : content;
  if (!text.startsWith('---')) {
    return SppSkillText(
      hasFrontmatter: false,
      closed: false,
      fields: const {},
      body: text,
    );
  }
  final end = _frontmatterEnd.firstMatch(text.substring(3));
  if (end == null) {
    return SppSkillText(
      hasFrontmatter: true,
      closed: false,
      fields: const {},
      body: text,
    );
  }
  final head = text.substring(3, end.start + 3);
  final fields = <String, String>{};
  for (final line in head.split('\n')) {
    final match = RegExp(
      r'^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$',
    ).firstMatch(line.trimRight());
    if (match == null) continue;
    var value = match.group(2)!.trim();
    if (value.length >= 2 &&
        (value.startsWith('"') && value.endsWith('"') ||
            value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    fields.putIfAbsent(match.group(1)!, () => value);
  }
  return SppSkillText(
    hasFrontmatter: true,
    closed: true,
    fields: fields,
    body: text.substring(end.end + 3).trimLeft(),
  );
}

SppSkillIssue? sppCheckSkillDescription(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return SppSkillIssue.descriptionEmpty;
  return text.length > sppSkillNewDescriptionMax
      ? SppSkillIssue.descriptionTooLong
      : null;
}

/// The same checks the server makes on a SKILL.md, in the same order.
SppSkillIssue? sppCheckSkillContent(String content) {
  if (content.trim().isEmpty) return SppSkillIssue.contentEmpty;
  if (content.contains('\u0000')) return SppSkillIssue.contentNul;
  if (content.length > sppSkillContentMax) return SppSkillIssue.contentTooLong;
  final parts = sppSplitSkill(content);
  if (!parts.hasFrontmatter) return SppSkillIssue.contentNoFrontmatter;
  if (!parts.closed) return SppSkillIssue.contentUnclosed;
  if (!parts.fields.containsKey('name')) return SppSkillIssue.contentNoName;
  if (!parts.fields.containsKey('description')) {
    return SppSkillIssue.contentNoDescription;
  }
  if (parts.body.trim().isEmpty) return SppSkillIssue.contentNoBody;
  return null;
}

/// A starting SKILL.md. [body] is the localized first paragraph.
String sppSkillTemplate({
  required String name,
  required String description,
  required String body,
}) {
  final safe = description
      .replaceAll('\\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .trim();
  return '---\nname: ${name.trim()}\ndescription: "$safe"\n---\n\n$body\n';
}

/// Text the server wrote for a row (a description, a name) with what must not
/// be shown taken out: a host path becomes a neutral word and anything that
/// looks like an API token is covered.
String sppRedactHostText(String value, Strings strings) {
  var result = value;
  final unixHostPath = RegExp(
    r'(^|[\s(\[])/(?:home|private|users|root|srv|var|etc|opt|mnt|tmp|data|run)(?:/[^\s)\],;]+)+',
    caseSensitive: false,
    multiLine: true,
  );
  result = result.replaceAllMapped(
    unixHostPath,
    (match) =>
        '${match.group(1) ?? ''}${strings.desktopCenterServerPathRedacted}',
  );
  final windowsHostPath = RegExp(
    r'(^|[\s(\[])[a-z]:\\(?:[^\s)\],;]+\\)*[^\s)\],;]+',
    caseSensitive: false,
    multiLine: true,
  );
  result = result.replaceAllMapped(
    windowsHostPath,
    (match) =>
        '${match.group(1) ?? ''}${strings.desktopCenterServerPathRedacted}',
  );
  return result.replaceAll(
    RegExp(
      r'\b(?:sk|ghp|glpat|xoxb|xoxp|xoxa|xoxr)[-_][a-z0-9_-]{6,}\b',
      caseSensitive: false,
    ),
    strings.desktopCenterSecretRedacted,
  );
}
