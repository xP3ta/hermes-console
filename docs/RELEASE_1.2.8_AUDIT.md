# Auditoría de publicación 1.2.8

Estado: **en integración — no publicar todavía**.

Base pública comprobada: `v1.2.7` (Google Play y GitHub/Obtainium).
La candidata final debe incluir únicamente cambios reconciliados, revisados y
probados sobre el mismo commit para todos los canales.

## 1. Cambios desde 1.2.7

### Chat, sesiones y recuperación

- [x] Recuperación durable de turnos tras pérdida de red, background y reapertura.
- [x] Protección frente a reenvíos y duplicados durante la recuperación.
- [x] Cancelación offline y tombstones durables.
- [x] Edición/rewind con límites atómicos y reconciliación de ACK perdido.
- [x] Aislamiento correcto por instancia, perfil, sesión y propietario del turno.
- [x] Orden de conversaciones por actividad canónica y tiempos relativos.
- [x] Ocultación de snapshots internos de tareas compactadas.
- [ ] Reconciliar el trabajo local posterior de outbox/recuperación con la candidata.

### Interacción y composición

- [x] Compositor multilínea con envío explícito.
- [x] Controles de chat alineados con Hermes Desktop.
- [x] Comandos `/` reconocidos con accent y preservación de borradores/foco.
- [x] Dictado aislado por perfil y protegido durante comandos y recuperación.
- [x] `clarify` simple y por lotes conforme al contrato de Hermes Desktop.
- [ ] Integrar y verificar la reconciliación posterior de ACK ambiguo de `clarify`.

### Bots, Kanban, voz y configuración

- [x] Jerarquía y claridad móvil de Bots/Kanban y tareas activas.
- [x] Mejoras de ciclo de vida, interrupción y waveform en voz/dictado.
- [x] Reconciliación de selección de modelo por sesión.
- [x] Emparejado deduplicado sin perder intents de arranque.
- [x] Onboarding Windows endurecido.
- [x] Proveedores externos y fallback de autenticación corregidos sin rotar credenciales.
- [x] Diagnóstico por capacidades autenticadas, read-only y same-origin.

### Notificaciones

- [ ] Reconciliar e integrar el ledger durable, deduplicación entre isolates,
      navegación exacta, jerarquía de canales y contratos Cron/Kanban/aprobaciones.
- [ ] Verificar privacidad, reintentos, process death y comportamiento real de Android.

## 2. Falta terminar o corregir

- [ ] Resolver todas las ramas/worktrees exclusivos y eliminar duplicados obsoletos.
- [ ] Dejar una única implementación canónica de recuperación y notificaciones.
- [ ] Resolver cualquier fallo de análisis, tests o revisión independiente.
- [ ] Elegir un `versionCode` final superior al QA instalado en el Pixel.
- [ ] Sincronizar versión en changelog, ficha Play, instalación, checklist y SBOM.
- [ ] Reconciliar manifest final, privacidad, Data Safety y declaraciones FGS.
- [ ] Revisar licencias de nuevas dependencias y todos los `NOASSERTION` del SBOM.

## 3. Falta probar en el Pixel físico

La matriz se ejecutará sobre la APK QA exacta construida desde el commit final,
sin desinstalar ni borrar datos:

- [ ] Actualización `adb install -r`, firma idéntica, versionCode mayor y datos conservados.
- [ ] Arranque, navegación atrás, cambio de instancia/perfil y reconexión.
- [ ] Chat normal, streaming, Markdown, código y adjuntos.
- [ ] Background/foreground, pérdida y recuperación de red, reapertura y process death.
- [ ] Cancelación offline, edición/rewind y ausencia de duplicados.
- [ ] Comandos `/`, teclado, foco, dictado y compositor multilínea.
- [ ] `clarify` simple, selección única/múltiple, texto libre, lotes, reintento y ACK perdido.
- [ ] Orden/tiempos de conversaciones y limpieza correcta de `EN CURSO`.
- [ ] Bots, salas/perfiles y Kanban/tareas activas.
- [ ] QR/enlace de pairing sin duplicados ni pérdida de intents.
- [ ] Voz, dictado, lectura, interrupción, audio privado y background opt-in.
- [ ] Proveedores externos, autenticación existente y diagnóstico de capacidades.
- [ ] Notificaciones de run, cron, Kanban y aprobaciones; taps exactos, agrupación,
      deduplicación, preferencias, reinicio de app y privacidad.
- [ ] Permisos, App Lock, modo solo lectura y limpieza de temporales.

## 4. Falta preparar o subir

### Común

- [ ] Árbol final limpio y commit exacto revisado independientemente.
- [ ] `flutter analyze --fatal-infos`, suite completa y pruebas específicas verdes.
- [ ] Gitleaks/TruffleHog, REUSE, SBOM y licencias verdes.
- [ ] Rama publicada y CI verde.

### Google Play (`play` AAB)

- [ ] Construir AAB `playRelease` firmado desde clon limpio.
- [ ] Verificar package, versión, certificado, manifest y SHA-256.
- [ ] Confirmar política pública, Data Safety, FGS/vídeos, listing y capturas.
- [ ] Obtener autorización explícita del propietario para subir ese AAB exacto.
- [ ] Subir a Play Console y completar la revisión solo tras autorización.

### GitHub Releases / Obtainium (`full` APK)

- [ ] Construir APKs `fullRelease` firmadas y split por ABI desde clon limpio.
- [ ] Verificar package, versión, certificado y SHA-256 de cada APK.
- [ ] Generar evidencia, inventarios, SBOMs y `SHA256SUMS` finales.
- [ ] Obtener autorización explícita del propietario para tag/release y artefactos exactos.
- [ ] Publicar release GitHub/Obtainium solo tras autorización.

### Prohibido publicar

- APK `qa`, debug o profile.
- AAB de Play en GitHub/Obtainium.
- Keystores, credenciales, mappings o diagnósticos privados.
