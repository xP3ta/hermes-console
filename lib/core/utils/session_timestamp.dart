/// Hermes Console recibe timestamps de distintas fuentes (API REST, Dashboard,
/// Desktop, borradores locales, snapshots sintéticos) y, por errores históricos
/// o gateways antiguos, algunos llegan en segundos y otros en milisegundos.
///
/// Esta utilidad centraliza la reducción a una identidad temporal canónica:
/// segundos desde la época Unix. No muta valores ya normalizados y rechaza
/// valores inválidos/malformados para que el llamador decida el fallback.
library;

import '../../l10n/app_localizations.dart';

/// Umbral que separa segundos de milisegundos.
///
/// Un timestamp en segundos del año 2100 vale ~4.1e9; un timestamp en ms del
/// año 2001 vale ~9.8e11. Cualquier valor por encima de este umbral se trata
/// como ms y se divide por 1000. El valor 1e10 corresponde a ~2286 en segundos
/// o a ~1970+3 meses en ms; en la práctica real siempre indica ms.
const double _epochMsThreshold = 1e10;

/// Normaliza un valor temporal crudo a segundos desde la época Unix.
///
/// - null / no numérico / negativo / infinito / NaN → null
/// - 0 se devuelve como 0 (el llamador decide si es válido)
/// - valores por encima de [_epochMsThreshold] se asumen ms y se dividen
/// - el resto se asumen segundos y se devuelven tal cual
///
/// No redondea: se conserva la precisión fraccionaria del servidor.
double? normalizeEpochTimestamp(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  final seconds = value.toDouble();
  if (seconds == 0) return 0;
  if (seconds > _epochMsThreshold) return seconds / 1000.0;
  return seconds;
}

/// Devuelve el timestamp de actividad más reciente conocido para una sesión,
/// asumiendo que los campos ya están en segundos o han sido normalizados.
///
/// Selecciona el máximo valor entre `startedAt`, `endedAt` y `updatedAt`. Si
/// ninguno aporta señal, devuelve 0 (identidad "sin fecha" consistente con el
/// resto del modelo).
double sessionLastActivityAt({
  required double startedAt,
  required double? endedAt,
  required double? updatedAt,
}) {
  final candidates = [startedAt, endedAt, updatedAt].whereType<double>();
  return candidates.fold<double>(0, (a, b) => a > b ? a : b);
}

/// Comparador estable para ordenar sesiones por actividad reciente.
///
/// El orden descendente por `lastActivityAt` es el criterio principal. Cuando
/// dos sesiones empatan, se desempata por `id` de forma determinista para que
/// refrescos parciales no reordenen visualmente la lista.
int compareSessionsByRecentActivity(SessionSortKey a, SessionSortKey b) {
  final timeCompare = b.lastActivityAt.compareTo(a.lastActivityAt);
  if (timeCompare != 0) return timeCompare;
  return a.id.compareTo(b.id);
}

/// Interfaz mínima para cualquier objeto que pueda ordenarse con
/// [compareSessionsByRecentActivity]. Permite testear el comparador sin
/// depender del modelo [Session] completo.
abstract interface class SessionSortKey {
  String get id;
  double get lastActivityAt;
}

/// Tiempo relativo localizado para los tiles de la lista de sesiones.
///
/// Acepta timestamps en segundos o milisegundos y nunca devuelve "ahora" para
/// valores inválidos. Fechas futuras o dentro del último minuto se muestran
/// como "ahora", coherente con el comportamiento previo.
String formatSessionRelativeTime(double ts, Strings s, {DateTime? now}) {
  final canonicalTs = normalizeEpochTimestamp(ts) ?? 0;
  if (canonicalTs <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch((canonicalTs * 1000).toInt());
  final diff = (now ?? DateTime.now()).difference(dt);
  if (diff.isNegative || diff.inMinutes < 1) return s.slRelativeNow;
  if (diff.inHours < 1) return s.slRelativeMinutes(diff.inMinutes);
  if (diff.inDays < 1) return s.slRelativeHours(diff.inHours);
  if (diff.inDays < 7) return s.slRelativeDays(diff.inDays);
  return '${dt.day}/${dt.month}';
}
