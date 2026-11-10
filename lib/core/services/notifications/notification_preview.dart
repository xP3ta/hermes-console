// The short, redacted line a notification may show of a reply or a title.
// Content stays on the phone: this only shapes what the tray displays.
import '../../utils/assistant_content.dart';
import '../../utils/plain_preview.dart';

/// One line without code, reasoning, control characters or Markdown. Redact
/// common credentials before truncating, so a cut cannot expose a partial key.
String notificationPreview(String? raw, {int max = 120}) {
  if (raw == null) return '';
  var text = finalizedPublicAssistantText(raw)
      .replaceAll(RegExp(r'```[\s\S]*?(?:```|$)'), ' ')
      .replaceAll(RegExp(r'~~~[\s\S]*?(?:~~~|$)'), ' ')
      .replaceAll(RegExp(r'^(?: {4}|\t)[^\n]*', multiLine: true), ' ')
      .replaceAll(RegExp(r'`[^`\n]*`'), ' ')
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(
        RegExp(
          r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',
        ),
        ' ',
      );
  text = text.replaceAll(
    RegExp(r'-----BEGIN [A-Z0-9 ]+-----[\s\S]*?(?:-----END [A-Z0-9 ]+-----|$)'),
    '[redacted]',
  );
  text = text.replaceAll(RegExp(r'(https?://)[^/\s@]+@'), '[redacted]@');
  // Secrets that travel in a URL's query: a signed link is a credential.
  text = text.replaceAllMapped(
    RegExp(
      r'([?&](?:key|sig|signature|code|token|access_token|secret|apikey|api_key|x-amz-signature)=)[^&\s#]+',
      caseSensitive: false,
    ),
    (m) => '${m[1]}[redacted]',
  );
  text = text.replaceAll(
    RegExp(r'\bBearer\s+[^\s]+', caseSensitive: false),
    'Bearer [redacted]',
  );
  text = text.replaceAll(
    RegExp(
      r'''["']?[\w-]*(?:api[_-]?key|token|password|passwd|secret|authorization)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)''',
      caseSensitive: false,
    ),
    '[redacted]',
  );
  text = text.replaceAll(
    RegExp(
      r'\b(?:sk-[A-Za-z0-9_-]{6,}|gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|xox[baprs]-[A-Za-z0-9-]+|(?:AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20,}|npm_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*)',
    ),
    '[redacted]',
  );
  return plainPreview(text, maxChars: max);
}

