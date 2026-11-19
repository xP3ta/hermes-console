import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/services/font_size_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'fija la escala interna en 110 % aunque exista una preferencia antigua',
    () async {
      SharedPreferences.setMockInitialValues({'font_size_scale': 1.4});
      final service = FontSizeService(await SharedPreferences.getInstance());

      expect(service.scale, 1.10);
      expect(FontSizeService.fixedScale, 1.10);
    },
  );

  // Owner decision (2026-11-13): vuelve un control
  // de tamaño de texto. La densidad por defecto sigue siendo 110 % y es el
  // «100 %» del control; el factor del lector se guarda en una clave nueva.
  test('el factor del lector escala sobre la densidad por defecto', () async {
    SharedPreferences.setMockInitialValues({});
    final service = FontSizeService(await SharedPreferences.getInstance());

    await service.setFactor(1.1);

    expect(service.scale, closeTo(1.10 * 1.1, 1e-9));
    expect(FontSizeService.normalizeFactor(double.nan), 1.0);
  });
}
