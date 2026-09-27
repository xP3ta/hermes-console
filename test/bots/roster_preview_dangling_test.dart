import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/bots/ui/roster/roster_model.dart';

void main() {
  test('server-truncated previews never show dangling markdown markers', () {
    expect(
      rosterPreviewText('Reviewed. Summary: **Failure today (16:20:21)'),
      'Reviewed. Summary: Failure today (16:20:21)',
    );
    expect(rosterPreviewText('Uso `flutter test y'), 'Uso flutter test y');
    expect(rosterPreviewText('Estado __abierto'), 'Estado abierto');
  });

  test('balanced markdown and normal punctuation stay intact', () {
    expect(rosterPreviewText('**Hecho** en 2*3 pasos'), 'Hecho en 2*3 pasos');
    expect(rosterPreviewText('snake_case_name ok'), 'snake_case_name ok');
    expect(rosterPreviewText('#tag y C#'), '#tag y C#');
  });
}
