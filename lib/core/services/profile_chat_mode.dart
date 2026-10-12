// Nombre de un perfil de agente: validación y decisión de si pide el canal
// propio de Hermes. Lógica PURA (sin I/O) para poder testearla a fondo.

/// Valida el NOMBRE de un perfil antes de usarlo en cualquier ruta/ejecución.
/// Lista blanca estricta (coincide con la validación de la UI de creación):
/// minúsculas, dígitos, guion y guion bajo; primer carácter alfanumérico; hasta
/// 64 chars. Rechaza vacío, rutas (`/`, `\`), `..` y cualquier intento de path
/// traversal. `default` es un nombre válido (aunque no requiera routing especial).
bool isValidProfileName(String name) {
  final n = name.trim();
  if (n.isEmpty || n.length > 64) return false;
  // Defensa explícita anti path-traversal además de la lista blanca.
  if (n.contains('..') || n.contains('/') || n.contains('\\')) return false;
  return RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(n);
}

/// ¿El perfil indica un agente NO-default que merece routing especial?
/// Vacío o `default` → no (camino actual).
bool profileRoutes(String profile) {
  final p = profile.trim();
  return p.isNotEmpty && p != 'default' && isValidProfileName(p);
}
