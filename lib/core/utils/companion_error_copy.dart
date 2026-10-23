import '../../l10n/app_localizations.dart';

/// Translate local pet-validation copy at its UI boundary. Schema field names
/// and file paths stay unchanged; backend-provided unknown messages are data.
String companionErrorCopy(Strings s, String message) {
  final fixed = switch (message) {
    "el archivo está vacío" => s.i18n131P6PetEmpty('ZIP'),
    "el ZIP supera el tamaño máximo permitido" => s.i18n131P6PetTooLarge('ZIP'),
    "no es un ZIP válido" => s.i18n131P6PetInvalid('ZIP'),
    "el ZIP no contiene \"pet.json\"" => s.i18n131P6PetMissing('pet.json'),
    "\"pet.json\" es demasiado grande" => s.i18n131P6PetTooLarge('pet.json'),
    "\"pet.json\" no es UTF-8 válido" => s.i18n131P6PetInvalid('pet.json (UTF-8)'),
    "\"pet.json\": la raíz no es un objeto" => s.i18n131P6PetFieldType('pet.json', 'Map'),
    "la raíz no es un objeto JSON" => s.i18n131P6PetFieldType('pet.json', 'Map'),
    "\"pet.json\" no es JSON válido" => s.i18n131P6PetInvalid('pet.json (JSON)'),
    "nombre de spritesheet inválido" => s.i18n131P6PetInvalid('spritesheet'),
    "el spritesheet debe ser .webp o .png" => s.i18n131P6PetImageFormat,
    "el spritesheet no es un WebP/PNG válido" => s.i18n131P6PetImageFormat,
    "el spritesheet remoto no es un PNG/WebP válido" => s.i18n131P6PetImageFormat,
    "el ZIP no contiene ningún spritesheet (.webp/.png)" => s.i18n131P6PetMissing('spritesheet (.webp/.png)'),
    "el spritesheet está vacío" => s.i18n131P6PetEmpty('spritesheet'),
    "el spritesheet supera el tamaño máximo" => s.i18n131P6PetTooLarge('spritesheet'),
    "el spritesheet remoto supera el tamaño máximo" => s.i18n131P6PetTooLarge('spritesheet'),
    "slug inválido o no permitido" => s.i18n131P6PetInvalid('slug'),
    "slug con caracteres no permitidos" => s.i18n131P6PetInvalid('slug'),
    "la mascota no define \"idle\"" => s.i18n131P6PetMissing('states.idle'),
    "la mascota remota no define idle" => s.i18n131P6PetMissing('states.idle'),
    "\"states\" debe incluir \"idle\"" => s.i18n131P6PetMissing('states.idle'),
    "el pet.json no es un formato reconocido (sin grid/states ni id válido)" => s.i18n131P6PetFormat,
    "no se pudieron leer las dimensiones del spritesheet" => s.i18n131P6PetInvalid('grid'),
    "rejilla de spritesheet inválida" => s.i18n131P6PetInvalid('grid'),
    "dimensiones de \"grid\" inválidas" => s.i18n131P6PetInvalid('grid'),
    "las dimensiones del atlas remoto son inválidas" => s.i18n131P6PetInvalid('grid'),
    "la geometría de frame remota es inválida" => s.i18n131P6PetInvalid('grid'),
    "falta \"slug\"" => s.i18n131P6PetMissing('slug'),
    "falta \"grid\"" => s.i18n131P6PetMissing('grid'),
    "falta \"spritesheet\"" => s.i18n131P6PetMissing('spritesheet'),
    "falta \"states\"" => s.i18n131P6PetMissing('states'),
    "\"fps\" debe ser > 0" => s.i18n131P6PetOutOfRange('fps (> 0)'),
    "importación no disponible" => s.i18n131P6PetImportUnavailable,
    "la mascota remota no tiene identidad revisionada" => s.i18n131P6PetInvalid('revision'),
    "identidad remota inválida" => s.i18n131P6PetInvalid('revision'),
    "el spritesheet remoto está ausente o supera el límite" => s.i18n131P6PetInvalid('spritesheet (0 < bytes <= 8388608)'),
    "el spritesheet remoto debe usar base64 sin prefijo" => s.i18n131P6PetBase64,
    "el spritesheet remoto no es base64 válido" => s.i18n131P6PetBase64,
    "el MIME remoto no coincide con sus magic bytes" => s.i18n131P6PetMismatch('MIME', 'PNG/WebP'),
    "no se pudo validar el atlas remoto" => s.i18n131P6PetInvalid('atlas'),
    "la mascota remota materializada no es válida" => s.i18n131P6PetInvalid('atlas'),
    "la revisión remota no superó la validación previa a promoción" => s.i18n131P6PetInvalid('atlas'),
    "la rejilla del atlas remoto está fuera de límites" => s.i18n131P6PetOutOfRange('grid / frameCount'),
    "conteo de frames remoto fuera de rango" => s.i18n131P6PetOutOfRange('grid / frameCount'),
    "la taxonomía de filas remota no coincide con el atlas" => s.i18n131P6PetInvalid('rowLayout'),
    "la taxonomía de filas remota es inválida" => s.i18n131P6PetInvalid('rowLayout'),
    "caché de mascotas remotas no disponible" => s.i18n131P6PetUnavailable,
    "el gateway omitió un atlas que no está en caché" => s.i18n131P6PetMissing('atlas'),
    "el manifest no es JSON válido" => s.i18n131P6PetInvalid('manifest (JSON)'),
    "el manifest no tiene el formato esperado" => s.i18n131P6PetInvalid('manifest (JSON)'),
    "el manifest no contiene mascotas válidas" => s.i18n131P6PetNoEntries,
    "origen del ZIP no permitido" => s.i18n131P6PetUrlBlocked,
    "el recurso supera el tamaño máximo" => s.i18n131P6PetTooLarge('bytes'),
    "tiempo de espera agotado" => s.apiErrorTimeout,
    _ => null,
  };
  if (fixed != null) return fixed;
  final quoted = RegExp(r'"([^"\n]*)"').allMatches(message).map((m) => m[1]!).toList();
  if (message.startsWith('ruta no permitida en el ZIP:') && quoted.isNotEmpty) {
    return s.i18n131P6PetArchivePath(quoted.first);
  }
  if (message.startsWith('una mascota base ya usa el slug') && quoted.isNotEmpty) {
    return s.i18n131P6PetSlugUsed(quoted.first);
  }
  if (message.startsWith('slug "') && quoted.length == 2) {
    return s.i18n131P6PetMismatch(quoted[0], quoted[1]);
  }
  if (message.startsWith('el estado "') && quoted.isNotEmpty) {
    return s.i18n131P6PetFieldType('states.${quoted.first}', 'Map');
  }
  if (message.startsWith('estado "') && quoted.length == 2) {
    return s.i18n131P6PetOutOfRange('states.${quoted[0]}.${quoted[1]}');
  }
  if (message.endsWith('debe ser un entero') && quoted.isNotEmpty) {
    return s.i18n131P6PetFieldType(quoted.first, 'int');
  }
  if (message.endsWith('debe ser numérico') && quoted.isNotEmpty) {
    return s.i18n131P6PetFieldType(quoted.first, 'num');
  }
  if (message.startsWith('JSON inválido:')) {
    return s.i18n131P6PetInvalid('pet.json (JSON)');
  }
  if (message.startsWith('fallo al escribir la mascota:')) {
    return s.i18n131P6PetWriteFailed;
  }
  if (message.startsWith('spritesheet con dimensiones inesperadas')) {
    final dimensions = RegExp(r'\d+x\d+').allMatches(message).map((m) => m[0]!).toList();
    if (dimensions.length == 2) {
      return s.i18n131P6PetDimensions(dimensions[0], dimensions[1]);
    }
    return s.i18n131P6PetInvalid('spritesheet');
  }
  if (message.startsWith('URL no permitida:')) {
    return s.i18n131P6PetUrlBlocked;
  }
  final http = RegExp(r'^respuesta HTTP (\d+)$').firstMatch(message);
  if (http != null) return s.i18n131P6PetHttp(http[1]!);
  if (message.startsWith('fallo de red:')) return s.apiErrorNetwork;
  return message;
}
