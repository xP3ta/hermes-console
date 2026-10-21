// Bandera de variante de build (flavor) en tiempo de compilación.
//
// Distribution flavors retain their branding and channel boundaries.
// Console connects to existing servers in every flavor.
const String kHermesFlavor = String.fromEnvironment(
  'HERMES_FLAVOR',
  defaultValue: 'full',
);

/// The simple connect («Connect by hand» / Dashboard): part of the product in every variant.
/// The negative define builds a rollback candidate without a second branch:
///   --dart-define=HERMES_DISABLE_SIMPLE_CONNECT=true
/// Tests force either state through the screens' own constructor arguments.
const bool kSimpleConnectEnabled = !bool.fromEnvironment(
  'HERMES_DISABLE_SIMPLE_CONNECT',
  defaultValue: false,
);

/// ¿Está habilitado el modo conversación por voz (VoiceStatusLine/sesión continua)?
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

/// An open GPT-Live session may keep running with the app hidden (screen off,
/// another app in front) only when the user chose continuity with the screen
/// locked AND the microphone foreground service is the one running. That
/// service can only be started with the app in front, so a session it does
/// not cover ends when the app is hidden, opt-in or not. A destroyed view
/// (the app swiped away) is not "hidden": its chat is gone, so it ends too.
bool liveVoiceMayContinueHidden({
  required bool continueWhenLocked,
  required bool microphoneServiceHeld,
  required bool viewAttached,
}) => continueWhenLocked && microphoneServiceHeld && viewAttached;
