import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/profile_chat_mode.dart';

void main() {
  group('isValidProfileName', () {
    test('acepta nombres válidos (minúsculas/dígitos/guion/guion_bajo)', () {
      for (final n in [
        'demo',
        'work-bot',
        'agent_2',
        'a',
        'default',
        'x1-y_2',
      ]) {
        expect(isValidProfileName(n), isTrue, reason: n);
      }
    });

    test(
      'rechaza vacío, traversal, separadores y caracteres no permitidos',
      () {
        for (final n in [
          '',
          '   ',
          '..',
          '../etc',
          'a/b',
          'a\\b',
          'Demo', // mayúscula
          'demo profile', // espacio
          'demo!', // símbolo
          '-leading', // primer char no alfanumérico
          '_leading',
        ]) {
          expect(isValidProfileName(n), isFalse, reason: '"$n"');
        }
      },
    );

    test('rechaza nombres demasiado largos (>64)', () {
      expect(isValidProfileName('a' * 64), isTrue);
      expect(isValidProfileName('a' * 65), isFalse);
    });
  });

  group('profileRoutes', () {
    test('vacío y default no enrutan; un perfil válido sí', () {
      expect(profileRoutes(''), isFalse);
      expect(profileRoutes('default'), isFalse);
      expect(profileRoutes('demo'), isTrue);
    });
    test('nombre inválido no enruta (degrada a none)', () {
      expect(profileRoutes('../x'), isFalse);
    });
  });
}
