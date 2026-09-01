#!/usr/bin/env bash

set -Eeuo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ANDROID_DIR="$ROOT/android"
readonly KEY_PROPERTIES="$ROOT/key.properties"
readonly EXPECTED_PACKAGE="dev.xpetalab.hermesconsole"
readonly AAB_REL="build/app/outputs/bundle/playRelease/app-play-release.aab"

usage() {
  cat <<'USAGE'
Uso: tool/qa/release_rehearsal.sh <acción>

Acciones:
  doctor       Verifica herramientas y configuración de firma sin mostrar valores.
  signing      Valida la firma configurada y el fallo seguro sin upload key.
  manifest     Fusiona e inspecciona el manifest Play sin empaquetar un AAB.
  preflight    Ejecuta doctor + signing + manifest; no genera un AAB.
  build        Ejecuta preflight y construye el AAB Play local.

Este laboratorio no contiene comandos de publicación, subida ni Play Console.
Solo lee configuración local y escribe artefactos dentro de build/.
USAGE
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "falta la herramienta requerida: $1"
}

assert_project() {
  [[ -f "$ROOT/pubspec.yaml" ]] || fail "el script no está dentro del proyecto Flutter"
  [[ -f "$ANDROID_DIR/app/build.gradle.kts" ]] || fail "falta build.gradle.kts"
}

key_has_value() {
  local key="$1"
  awk -F= -v wanted="$key" '
    $1 == wanted {
      sub(/^[^=]*=/, "")
      if (length($0) > 0) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$KEY_PROPERTIES"
}

doctor() {
  assert_project
  require_command git
  require_command flutter
  require_command java
  require_command stat
  require_command unshare
  require_command mount

  [[ -f "$KEY_PROPERTIES" ]] || fail "falta key.properties fuera de Git"
  git -C "$ROOT" check-ignore -q key.properties ||
    fail "key.properties no está ignorado por Git"
  if git -C "$ROOT" ls-files --error-unmatch key.properties >/dev/null 2>&1; then
    fail "key.properties está trackeado por Git"
  fi

  local mode permissions key
  mode="$(stat -c '%a' "$KEY_PROPERTIES")"
  permissions=$((8#$mode))
  (( (permissions & 0077) == 0 )) ||
    fail "key.properties concede permisos a grupo/otros"
  for key in storeFile storePassword keyAlias keyPassword; do
    key_has_value "$key" || fail "falta un campo requerido de firma"
  done

  printf 'Doctor OK: firma presente, privada, ignorada y no trackeada (modo %s).\n' "$mode"
  printf 'No se han mostrado valores, rutas de keystore ni huellas.\n'
}

validate_signing_present() {
  "$ANDROID_DIR/gradlew" -p "$ANDROID_DIR" :app:validateReleaseSigning \
    --console=plain >/dev/null
  printf 'Firma configurada: validación Gradle correcta.\n'
}

validate_signing_absent() {
  local log status
  log="$(mktemp "${TMPDIR:-/tmp}/hermes-release-signing.XXXXXX")"
  chmod 600 "$log"
  trap 'rm -f "$log"' RETURN

  set +e
  unshare -Urm --map-root-user sh -c '
    mount --bind /dev/null "$1" &&
    cd "$2" &&
    HOME="$3" GRADLE_USER_HOME="$3/.gradle" \
      ./gradlew :app:validateReleaseSigning --console=plain --no-daemon
  ' sh "$KEY_PROPERTIES" "$ANDROID_DIR" "$HOME" >"$log" 2>&1
  status=$?
  set -e

  (( status != 0 )) || fail "release aceptó una configuración sin upload key"
  grep -q 'Release signing is not configured' "$log" ||
    fail "el fallo sin upload key no fue el esperado"
  rm -f "$log"
  trap - RETURN
  printf 'Sin upload key: fallo explícito y seguro confirmado en namespace aislado.\n'
}

signing() {
  doctor
  validate_signing_present
  validate_signing_absent
}

manifest() {
  assert_project
  "$ANDROID_DIR/gradlew" -p "$ANDROID_DIR" :app:processPlayReleaseManifest \
    --console=plain >/dev/null

  local merged forbidden_permission
  merged="$ROOT/build/app/intermediates/merged_manifests/playRelease/processPlayReleaseManifest/AndroidManifest.xml"
  [[ -f "$merged" ]] || fail "no se generó el manifest Play fusionado"
  grep -q "package=\"$EXPECTED_PACKAGE\"" "$merged" ||
    fail "applicationId Play inesperado"
  grep -q 'android:minSdkVersion="24"' "$merged" || fail "minSdk inesperado"
  grep -q 'android:targetSdkVersion="36"' "$merged" || fail "targetSdk inesperado"
  grep -q 'android:allowBackup="false"' "$merged" || fail "backup no está bloqueado"
  grep -q 'android:usesCleartextTraffic="false"' "$merged" ||
    fail "el manifest principal permite cleartext global"
  grep -q 'android:networkSecurityConfig="@xml/network_security_config"' "$merged" ||
    fail "falta la política de red release"
  grep -q '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"' "$merged" ||
    fail "falta el permiso FGS de micrófono declarado en Play"
  grep -q '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"' "$merged" ||
    fail "falta el permiso FGS de reproducción declarado en Play"
  grep -q '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_REMOTE_MESSAGING"' "$merged" ||
    fail "falta el permiso FGS de mensajería remota declarado en Play"
  grep -q 'android:foregroundServiceType="dataSync|remoteMessaging|microphone|mediaPlayback"' "$merged" ||
    fail "el servicio Play no declara exactamente dataSync|remoteMessaging|microphone|mediaPlayback"
  for forbidden_permission in \
    android.permission.READ_PHONE_STATE \
    android.permission.READ_EXTERNAL_STORAGE; do
    if grep -q "<uses-permission android:name=\"$forbidden_permission\"" "$merged"; then
      fail "el flavor Play contiene permiso implícito no utilizado: $forbidden_permission"
    fi
  done
  if grep -q '<uses-permission android:name="com.termux.permission.RUN_COMMAND"' "$merged" ||
     grep -q '<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"' "$merged" ||
     grep -q '<package android:name="com.termux"' "$merged"; then
    fail "el flavor Play contiene permisos o queries exclusivos de Termux"
  fi
  grep -Rqs 'TransportPrivacy.requireAllowed' "$ROOT/lib/core" ||
    fail "no se encontró la frontera runtime de transporte"

  printf 'Manifest Play OK: identidad, SDK, backup, red, voz FGS y separación Termux verificadas.\n'
}

preflight() {
  signing
  manifest
  printf 'Preflight release OK; todavía no se ha generado ningún AAB.\n'
}

build_aab() {
  preflight
  (
    cd "$ROOT"
    flutter build appbundle --release --flavor play \
      --dart-define=HERMES_FLAVOR=play
  )
  [[ -f "$ROOT/$AAB_REL" ]] || fail "Flutter no produjo el AAB esperado"
  printf 'AAB local construido: %s\n' "$AAB_REL"
  printf 'No se ha ejecutado ninguna publicación o subida.\n'
}

main() {
  case "${1:-}" in
    doctor) doctor ;;
    signing) signing ;;
    manifest) manifest ;;
    preflight) preflight ;;
    build) build_aab ;;
    -h|--help|help|'') usage ;;
    *) usage; fail "acción desconocida: $1" ;;
  esac
}

main "$@"
