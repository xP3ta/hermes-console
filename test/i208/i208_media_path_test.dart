import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/generated_media_service.dart';

void main() {
  // Uri.decodeComponent throws ArgumentError (not FormatException) for a raw
  // non-ASCII character or a truncated escape; the parser must withhold the
  // directive instead of letting the error escape.
  test('MEDIA path with a non-ASCII segment does not throw', () {
    const text = 'Listo.\nMEDIA:/workspace/Askøy/informe.pdf\nFin';
    late List<GeneratedMediaSegment> segments;
    expect(
      () => segments = GeneratedMediaService.parseSegments(text),
      returnsNormally,
    );
    expect(GeneratedMediaService.stripDirectives(text), isNotEmpty);
    expect(segments, isNotEmpty);
  });

  test('MEDIA path with a truncated percent escape does not throw', () {
    const text = 'Listo.\nMEDIA:/workspace/a%2/informe.pdf\nFin';
    expect(() => GeneratedMediaService.parseSegments(text), returnsNormally);
    expect(() => GeneratedMediaService.stripDirectives(text), returnsNormally);
  });
}
