import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/session_timestamp.dart';

class _FakeSession implements SessionSortKey {
  _FakeSession(this.id, this.lastActivityAt);

  @override
  final String id;

  @override
  final double lastActivityAt;
}

void main() {
  group('normalizeEpochTimestamp', () {
    test('mantiene timestamps canónicos en segundos', () {
      expect(
        normalizeEpochTimestamp(1781186907.9),
        closeTo(1781186907.9, 0.001),
      );
      expect(normalizeEpochTimestamp(0), 0.0);
    });

    test('detecta y corrige timestamps históricos en milisegundos', () {
      final ms = DateTime(2026, 7, 26, 21).millisecondsSinceEpoch;
      expect(
        normalizeEpochTimestamp(ms.toDouble()),
        closeTo(ms / 1000.0, 0.001),
      );
    });

    test('rechaza valores ausentes, negativos o malformados', () {
      expect(normalizeEpochTimestamp(null), isNull);
      expect(normalizeEpochTimestamp('hoy'), isNull);
      expect(normalizeEpochTimestamp(-1), isNull);
      expect(normalizeEpochTimestamp(double.nan), isNull);
      expect(normalizeEpochTimestamp(double.infinity), isNull);
    });

    test('no confunde segundos lejanos con ms', () {
      // Año 2100 en segundos: sigue siendo segundos, no se divide.
      expect(normalizeEpochTimestamp(4102444800.0), 4102444800.0);
    });
  });

  group('sessionLastActivityAt', () {
    test('devuelve el timestamp más reciente entre los candidatos', () {
      expect(
        sessionLastActivityAt(startedAt: 100, endedAt: 200, updatedAt: 150),
        200,
      );
      expect(
        sessionLastActivityAt(startedAt: 100, endedAt: null, updatedAt: 150),
        150,
      );
    });

    test('resiste timestamps ausentes/malformados', () {
      expect(
        sessionLastActivityAt(startedAt: 100, endedAt: null, updatedAt: null),
        100,
      );
      expect(
        sessionLastActivityAt(startedAt: 0, endedAt: null, updatedAt: null),
        0,
      );
    });
  });

  group('compareSessionsByRecentActivity', () {
    test('ordena descendente por actividad', () {
      final a = _FakeSession('a', 100);
      final b = _FakeSession('b', 200);
      expect(compareSessionsByRecentActivity(a, b), greaterThan(0));
      expect(compareSessionsByRecentActivity(b, a), lessThan(0));
    });

    test('desempata por id de forma estable y determinista', () {
      final a = _FakeSession('a', 100);
      final b = _FakeSession('b', 100);
      expect(compareSessionsByRecentActivity(a, b), lessThan(0));
      expect(compareSessionsByRecentActivity(b, a), greaterThan(0));
      // Consistente: invertir dos veces vuelve al mismo signo.
      expect(
        compareSessionsByRecentActivity(a, b),
        -compareSessionsByRecentActivity(b, a),
      );
    });
  });
}
