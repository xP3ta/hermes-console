import 'voice_language.dart';

/// Representación oral, local y determinista de una respuesta Markdown.
///
/// La pantalla conserva el Markdown original. Este renderer solo produce la
/// proyección que llega al TTS: sin URLs, delimitadores visuales ni código, y
/// con fronteras semánticas que permiten introducir pausas cancelables.
enum NarrationPause {
  none,
  short,
  medium,
  long;

  Duration get duration => switch (this) {
    NarrationPause.none => Duration.zero,
    NarrationPause.short => const Duration(milliseconds: 120),
    NarrationPause.medium => const Duration(milliseconds: 250),
    NarrationPause.long => const Duration(milliseconds: 400),
  };
}

enum NarrationSourceKind {
  heading,
  paragraph,
  listItem,
  quote,
  tableRow,
  codeNotice,
}

class NarrationSegment {
  final String text;
  final NarrationSourceKind sourceKind;
  final NarrationPause pauseAfter;

  const NarrationSegment(this.text, this.sourceKind, this.pauseAfter);

  NarrationSegment copyWith({NarrationPause? pauseAfter}) =>
      NarrationSegment(text, sourceKind, pauseAfter ?? this.pauseAfter);
}

class SpeechRenderer {
  final String language;

  const SpeechRenderer({required this.language});

  VoiceSpeechGrammar get _speech => voiceLanguageFor(language).speech;
  String get _linkWord => _speech.linkWord;
  String get _codeNotice => _speech.codeNotice;

  List<NarrationSegment> render(String markdown) {
    var source = markdown
        .replaceAll(
          RegExp(
            r'\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), ' ');
    if (source.trim().isEmpty) return const [];

    final segments = <NarrationSegment>[];
    final paragraph = <String>[];
    var inFence = false;
    var fenceNoticeAdded = false;

    void elevateLastPause(NarrationPause pause) {
      if (segments.isEmpty) return;
      final current = segments.last;
      if (current.pauseAfter.index >= pause.index) return;
      segments[segments.length - 1] = current.copyWith(pauseAfter: pause);
    }

    void append(String raw, NarrationSourceKind kind, NarrationPause pause) {
      final clean = _cleanInline(raw);
      if (clean.isEmpty) return;
      segments.add(
        NarrationSegment(_speech.withTerminalPunctuation(clean), kind, pause),
      );
    }

    void flushParagraph([NarrationPause pause = NarrationPause.medium]) {
      if (paragraph.isEmpty) return;
      append(_speech.joinParagraph(paragraph), NarrationSourceKind.paragraph, pause);
      paragraph.clear();
    }

    for (final rawLine in source.split('\n')) {
      final trimmed = rawLine.trim();

      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        if (!inFence) {
          flushParagraph(NarrationPause.long);
          inFence = true;
          if (!fenceNoticeAdded) {
            segments.add(
              NarrationSegment(
                _codeNotice,
                NarrationSourceKind.codeNotice,
                NarrationPause.long,
              ),
            );
            fenceNoticeAdded = true;
          }
        } else {
          inFence = false;
        }
        continue;
      }
      if (inFence) continue;

      if (trimmed.isEmpty) {
        flushParagraph(NarrationPause.long);
        elevateLastPause(NarrationPause.long);
        continue;
      }

      if (_isNonNarrativeReferenceLine(trimmed)) {
        flushParagraph(NarrationPause.medium);
        continue;
      }

      if (RegExp(r'^\s*([-*_])(?:\s*\1){2,}\s*$').hasMatch(rawLine)) {
        flushParagraph(NarrationPause.long);
        elevateLastPause(NarrationPause.long);
        continue;
      }

      final heading = RegExp(r'^\s*#{1,6}\s*(.+)$').firstMatch(rawLine);
      if (heading != null) {
        flushParagraph(NarrationPause.long);
        append(
          heading.group(1) ?? '',
          NarrationSourceKind.heading,
          NarrationPause.long,
        );
        continue;
      }

      final list = RegExp(
        r'^\s*(?:[-*+] |\d+[.)]\s+)(.+)$',
      ).firstMatch(rawLine);
      if (list != null) {
        flushParagraph(NarrationPause.medium);
        append(
          list.group(1) ?? '',
          NarrationSourceKind.listItem,
          NarrationPause.medium,
        );
        continue;
      }

      final quote = RegExp(r'^\s*>+\s*(.+)$').firstMatch(rawLine);
      if (quote != null) {
        flushParagraph(NarrationPause.medium);
        append(
          quote.group(1) ?? '',
          NarrationSourceKind.quote,
          NarrationPause.medium,
        );
        continue;
      }

      if (trimmed.contains('|')) {
        flushParagraph(NarrationPause.medium);
        if (RegExp(r'^\|?\s*[: -]+(?:\|\s*[: -]+)+\|?$').hasMatch(trimmed)) {
          continue;
        }
        final cells = trimmed
            .split('|')
            .map((cell) => _cleanInline(cell))
            .where((cell) => cell.isNotEmpty)
            .toList();
        if (cells.isNotEmpty) {
          append(
            _speech.joinTableCells(cells),
            NarrationSourceKind.tableRow,
            NarrationPause.short,
          );
        }
        continue;
      }

      paragraph.add(trimmed);
    }
    flushParagraph(NarrationPause.long);
    elevateLastPause(NarrationPause.long);
    return List.unmodifiable(segments);
  }

  bool _isNonNarrativeReferenceLine(String raw) {
    var line = raw.trim();
    var previous = '';
    while (line != previous) {
      previous = line;
      line = line
          .replaceFirst(
            RegExp(r'^(?:>+\s*|#{1,6}\s*|(?:[-+*]|\d+[.)])\s+)'),
            '',
          )
          .trimLeft();
    }
    // This normalization is only used to classify narration. It deliberately
    // leaves the Markdown shown in the chat untouched.
    line = line.replaceAll(RegExp(r'[*_~`]'), '').trim();
    if (line.isEmpty) return false;
    if (RegExp(
      voiceReferenceHeadingPattern,
      caseSensitive: false,
    ).hasMatch(line)) {
      return true;
    }
    if (RegExp(
      r'^[^:\n]{1,80}:\s*(?:<?(?:https?://|www\.)\S+>?|\[[^\]]+\]\((?:https?://|www\.)[^)]+\))[.!?]?\s*$',
      caseSensitive: false,
    ).hasMatch(line)) {
      return true;
    }
    if (RegExp(
      r'^\[[^\]]+\]:\s*(?:https?://|www\.)\S+',
      caseSensitive: false,
    ).hasMatch(line)) {
      return true;
    }
    if (RegExp(r'^!?\[[^\]]*\]\([^)]+\)[.!?]?\s*$').hasMatch(line)) {
      return true;
    }
    return RegExp(
      r'^(?:<?(?:https?://|www\.)\S+>?)[.!?]?\s*$',
      caseSensitive: false,
    ).hasMatch(line);
  }

  String _cleanInline(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';

    final onlyUrl = RegExp(
      r'^\s*(?:(?:https?://)|(?:www\.))\S+[.!?]?\s*$',
      caseSensitive: false,
    );
    if (onlyUrl.hasMatch(text)) return '';

    text = text.replaceAllMapped(
      RegExp(r'!\[([^\]]*)\]\([^)]*\)'),
      (match) => match.group(1) ?? '',
    );
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]*\)'),
      (match) => match.group(1) ?? '',
    );
    text = text.replaceAll(
      RegExp(r'<(?:https?://|www\.)[^>]+>', caseSensitive: false),
      _linkWord,
    );
    // Una URL colgada al final ("míralo aquí: https://…") se OMITE: decir
    // "enlace" ahí no aporta nada al oyente (feedback físico 2026-07-24). En
    // mitad de la frase sí se sustituye por la palabra, porque quitarla
    // dejaría la frase coja.
    text = text.replaceAll(
      RegExp(
        r'\s*:?\s*(?:https?://|www\.)[^\s<>()]*[^\s<>().,!?…](?=[.,!?…]*\s*$)',
        caseSensitive: false,
      ),
      '',
    );
    text = text.replaceAll(
      RegExp(r'(?:https?://|www\.)[^\s<>()]+', caseSensitive: false),
      _linkWord,
    );

    text = text.replaceAllMapped(
      RegExp(r'`([^`]+)`'),
      (match) => _humanizeTechnical(match.group(1) ?? ''),
    );
    text = text.replaceAllMapped(
      RegExp(r'(\*\*|__|~~|\*|_)(.+?)\1'),
      (match) => match.group(2) ?? '',
    );
    text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');

    // Las cantidades se expanden antes que fechas y fracciones. Algunos motores
    // TTS interpretan `0,99€` como `99 €` y omiten el cero; al entregar palabras
    // explícitas preservamos tanto la parte entera como los céntimos.
    text = _speakCurrencies(text);
    text = _speakPercentages(text);
    text = _speakDecimals(text);
    text = _speech.speakDates(text);
    // Horas HH:MM (feedback físico 2026-07-24: el TTS leía los dos puntos de
    // forma rara). Solo horas plausibles: 0-23 con minutos de DOS cifras 00-59
    // — un marcador "2:1" o un código "45:99" quedan intactos.
    text = _speech.speakTimes(text);
    text = _speech.speakFractions(text);
    text = text.replaceAllMapped(RegExp(r'\b([\w.+-]+)@([\w.-]+\b)'), (match) {
      return '${match.group(1)}${_speech.emailAt}'
          '${match.group(2)!.replaceAll('.', _speech.emailDot)}';
    });

    text = _humanizeTechnical(text);
    text = text
        .replaceAll(RegExp(r'[─-◿⠀-⣿]'), ' ')
        .replaceAll(RegExp(r'[`*_#>|]'), ' ');
    text = _speech.speakConjunctions(text);
    text = text
        // Un slug o ruta relativa ("rusty4444/omniroute", "src/lib/main.dart")
        // se dice por su ÚLTIMO tramo: al oído importa el nombre del repo o
        // del archivo, no el dueño ni los directorios (feedback del owner:
        // preguntó qué era "omniroute" y la voz le leía el repo entero).
        .replaceAllMapped(
          RegExp(r'(?<![\w/\\.-])[\w@~.-]+(?:/[\w@~.-]+)+(?![\w/\\])'),
          (m) => m.group(0)!.split('/').where((s) => s.isNotEmpty).last,
        )
        .replaceAll(RegExp(r'[\\/]+'), ' ')
        .replaceAll(RegExp(r'\s*[→⇒➜]+\s*'), ', ')
        // Emojis y pictogramas: basura para un TTS (feedback físico
        // 2026-07-24, y el modelo los añade a los saludos). Fuera.
        .replaceAll(
          RegExp(r'[☀-➿⬀-⯿️]|[\u{1F000}-\u{1FAFF}]', unicode: true),
          ' ',
        )
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        // Colapsa el espacio que dejan los símbolos/emojis retirados justo
        // antes de un signo de puntuación. OJO: replaceAllMapped, no
        // replaceAll con '$1' — este último inserta el TEXTO "$1" literal y el
        // motor lo pronunciaba ("dólar uno") cada vez que quitábamos un emoji.
        .replaceAllMapped(RegExp(r'\s+([,.;:!?…])'), (m) => m.group(1)!)
        .replaceAll(RegExp(r'(?:,\s*){2,}'), ', ')
        .trim();
    return _speech.normalizeNarration(text);
  }

  String _speakCurrencies(String input) => _speech.speakCurrencies(input);

  String _speakPercentages(String input) => _speech.speakPercentages(input);
  String _speakDecimals(String input) => _speech.speakDecimals(input);

  String _humanizeTechnical(String raw) {
    var text = raw;
    text = text.replaceAllMapped(
      RegExp(r'([a-záéíóúüñ0-9])([A-ZÁÉÍÓÚÜÑ])'),
      (match) => '${match.group(1)} ${match.group(2)}',
    );
    text = text.replaceAllMapped(
      RegExp(r'([A-ZÁÉÍÓÚÜÑ])([A-ZÁÉÍÓÚÜÑ][a-záéíóúüñ])'),
      (match) => '${match.group(1)} ${match.group(2)}',
    );
    text = text.replaceAll(RegExp(r'[_]+'), ' ');
    text = text.replaceAllMapped(
      RegExp(r'([A-Za-zÁ-ÿ])\.([A-Za-zÁ-ÿ])'),
      (match) => '${match.group(1)} ${match.group(2)}',
    );
    text = text.replaceAllMapped(
      RegExp(r'([A-Za-zÁ-ÿ])[-]([A-Za-zÁ-ÿ])'),
      (match) => '${match.group(1)} ${match.group(2)}',
    );
    return text;
  }

}
