import '../../l10n/app_localizations.dart';

/// An execution target is decision-critical: preserve Unix/Windows paths.
/// Never expand the gateway's already-redacted command or serialize arguments.
String approvalDisplayText(Object? value, Strings strings) {
  final hidden = strings.desktopCenterSecretRedacted;
  var text = (value ?? '').toString().replaceAll(
    RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
    '',
  );
  text = text.replaceAllMapped(
    RegExp(r'([a-z][a-z0-9+.-]*://)[^\s/]+@', caseSensitive: false),
    (m) => '${m[1]}$hidden@',
  );
  text = text.replaceAll(
    RegExp(r'''\b(?:Bearer|Basic)\s+[^\s"']+''', caseSensitive: false),
    hidden,
  );
  const header =
      r'(?:authorization|proxy-authorization|cookie|set-cookie|(?:x[-_])?(?:api[-_]?key|access[-_]?key))';
  // A quoted -H value can contain spaces/semicolons. Cover the whole value,
  // but do not consume following command arguments or execution targets.
  text = text.replaceAll(
    RegExp(
      '''"$header[ \t]*:[^"\r\n]*"|'$header[ \t]*:[^'\r\n]*' '''.trim(),
      caseSensitive: false,
    ),
    hidden,
  );
  text = text.replaceAll(
    RegExp(
      '^[ \t]*$header[ \t]*:[^\r\n]*',
      caseSensitive: false,
      multiLine: true,
    ),
    hidden,
  );
  text = text.replaceAll(
    RegExp(
      '''["']?$header["']?\\s*[:=]\\s*(?:"[^"]*"|'[^']*'|[^\\s,;}\\]"']+)''',
      caseSensitive: false,
    ),
    hidden,
  );
  const key =
      r'[\w-]*(?:api[_-]?key|access[_-]?key|token|password|passwd|secret)[\w-]*';
  const quotedOrValue = r'''(?:"[^"]*"|'[^']*'|(?:\\.|[^\s,;}\]"'])+)''';
  text = text.replaceAll(
    RegExp(
      '''["']?$key["']?\\s*[:=]\\s*$quotedOrValue''',
      caseSensitive: false,
    ),
    hidden,
  );
  text = text.replaceAll(
    RegExp('--$key\\s+$quotedOrValue', caseSensitive: false),
    hidden,
  );
  // Short flags are credentials only for their owning command. In particular,
  // do not hide the target of an unrelated command's -p or -u option.
  text = text.replaceAllMapped(
    RegExp(r'''\b(curl|sshpass|mysql)\b(?:[^"';&|\r\n]|"[^"]*"|'[^']*')*'''),
    (command) {
      final flags = command[1] == 'curl' ? 'uU' : 'p';
      final option = RegExp(
        '''(^|[ \\t])(-[$flags])(?:[ \\t]+)?("[^"]*"|'[^']*'|(?:\\\\.|[^\\s"';&|-])(?:\\\\.|[^\\s"';&|])*)''',
      );
      String cover(Match m) => '${m[1]}${m[2]} $hidden';
      return command[1] == 'curl'
          ? command[0]!.replaceAllMapped(option, cover)
          : command[0]!.replaceFirstMapped(option, cover);
    },
  );
  text = text.replaceAll(
    RegExp(r'''\b(?:Bearer|Basic)\s+[^\s"']+''', caseSensitive: false),
    hidden,
  );
  text = text.replaceAll(
    RegExp(
      r'\b(?:(?:sk|glpat|xox[baprs])-[A-Za-z0-9_-]{6,}|gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)\b',
      caseSensitive: false,
    ),
    hidden,
  );
  return text.trim();
}
