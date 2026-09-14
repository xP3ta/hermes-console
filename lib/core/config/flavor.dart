// Bandera de variante de build (flavor) en tiempo de compilación.
//
// Hay dos salidas del mismo código (ver docs/RELEASE_DISTRIBUTION.md):
//  · full → app completa con instancia local en Termux (descarga directa).
//  · play → solo-remoto, sin la función de instancia local (Google Play).
//
// El valor se inyecta en el build con `--dart-define=HERMES_FLAVOR=play|full`.
// Por defecto es `full` para conservar la variante de desarrollo; la integración
// local de Termux exige además `HERMES_LOCAL_AGENT=true`.
const String kHermesFlavor = String.fromEnvironment(
  'HERMES_FLAVOR',
  defaultValue: 'full',
);

/// ¿Está habilitada la función de instancia local en Termux en este build?
///
/// Permanece `false` por defecto y en `play` no puede activarse nunca. El build
/// público `full` la habilita explícitamente para incluir la integración Termux;
/// los builds que omitan ese define conservan la experiencia solo-remota.
///
/// Reactivación para desarrollo/APK completo:
///   flutter build apk --debug --dart-define=HERMES_LOCAL_AGENT=true
const bool kLocalAgentEnabled =
    bool.fromEnvironment('HERMES_LOCAL_AGENT', defaultValue: false) &&
    kHermesFlavor != 'play';

/// ¿Está habilitado el modo conversación por voz (VoiceStage/sesión continua)?
///
/// Forma parte del producto en todas las variantes. El define negativo permite
/// construir rápidamente una candidata de rollback sin mantener dos ramas ni
/// ocultar el dictado o la lectura puntual de respuestas:
///   --dart-define=HERMES_DISABLE_VOICE_MODE=true
const bool kVoiceModeEnabled = !bool.fromEnvironment(
  'HERMES_DISABLE_VOICE_MODE',
  defaultValue: false,
);

/// Harness de audio reproducible para QA: fuerza Sherpa + ONNX y desactiva las
/// optimizaciones experimentales, pero ya no gobierna la disponibilidad del
/// producto ni su notificación.
bool voiceQaHarnessAllowed({required String flavor, required bool requested}) =>
    flavor == 'qa' && requested;

const bool kVoiceQaHarnessEnabled =
    kHermesFlavor == 'qa' &&
    bool.fromEnvironment('HERMES_VOICE_FGS_SPIKE', defaultValue: false);

/// Gate efectivo. QA puede conservar el arnés aunque se pruebe expresamente un
/// build de rollback; Play/full obedecen el kill-switch anterior.
const bool kVoiceRuntimeEnabled = kVoiceModeEnabled || kVoiceQaHarnessEnabled;

/// Solo una sesión activa cuyo usuario eligió expresamente continuidad con la
/// pantalla bloqueada necesita sostener el foreground service de micrófono.
bool voiceRuntimeNeedsForeground({
  required bool active,
  required bool continueWhenLocked,
}) => active && continueWhenLocked;
