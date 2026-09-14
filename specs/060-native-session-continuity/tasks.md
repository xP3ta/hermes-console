# Tareas — Spec 060

## S0 — Especificación

- [x] Definir experiencia nativa, contratos e invariantes.
- [x] Documentar límite de backends aislados.
- [x] Establecer aceptación física Desktop→Console→Desktop.

## S1 — Adhesión al abrir (P0)

- [x] RED: cold-open visible intenta adjuntar el mismo durable.
- [x] GREEN: implementar adhesión mínima sin submit/interrupt.
- [x] Verificar que `resume` devuelve el runtime compartido sin crear ni enviar.
- [x] Mantener `active-list`/`activate` para reactivación del binding existente.
- [x] RED: respuesta o alias contradictorio no vincula otra sesión/lineage.
- [x] GREEN: cercas de load epoch, perfil e identidad durable explícita.

## S2 — Historial y eventos (P0)

- [x] RED: REST tardío no borra streaming/eventos nuevos.
- [x] GREEN: reconciliación tail durable + proyección viva.
- [x] RED: metadatos terminales de delegación sobreviven a cold-open.
- [x] GREEN: preservar `display_metadata` en la fuente primaria.

## S3 — Continuación y reconexión (P0)

- [x] RED: una reconexión ambigua no drena outbox antes de status.
- [x] GREEN: reconcile-before-drain.
- [x] RED: active-list tardío no revive actividad cerrada.
- [x] GREEN: orden por observación/epoch.
- [x] RED: cierre de una superficie no invalida la sesión durable local.
- [x] GREEN: reattach sin duplicados.
- [x] RED: socket idle y fallo transitorio de cold-open quedan sin adhesión.
- [x] GREEN: single-flight con backoff y `resumeExisting` no creador.
- [x] RED: polling/invalidate REST cancelan una recuperación lenta.
- [x] GREEN: separar frescura de lectura de autoridad de adhesión.
- [x] Caracterizar dispose y repin durable como cercas reales.
- [x] RED: historial vacío, fallo REST y expected-count omitían reattach.
- [x] GREEN: finalización ortogonal transcript/adhesión antes de todo exit.
- [x] RED: timeout/cierre se perdían en capability y RPC pendiente.
- [x] GREEN: causas tipadas body-free preservadas solo para lifecycle viewer.
- [x] RED: auth/protocolo/errores desconocidos entraban en retry incorrecto.
- [x] GREEN: política cerrada de viewer separada de toda mutación.
- [x] RED/GREEN: cierre terminal cancela vuelos previos y callbacks tardíos.
- [x] RED/GREEN: upgrades 401/403/404 paran; 408/429/5xx reintentan.
- [x] RED/GREEN: envelopes/eventos map-shaped malformados retiran el canal.
- [x] RED/GREEN: fence durable impide reabrir recuperación cerrada.

## S4 — Degradación honesta (P1)

- [x] Owner/lease ajeno no crea runtime competidor ni reenvía el prompt.
- [x] El historial permanece legible mientras la adhesión no está disponible.
- [x] Retry controlado y cercado retoma el mismo durable cuando queda accesible.
- [x] Backend realmente separado permanece en degradación histórica sin fingir live.

## S5 — Verificación

- [x] Tests nominales RED→GREEN registrados.
- [ ] Suites de chat, continuidad, paginación, reconexión y subagentes.
- [x] `flutter analyze --no-pub` limpio sobre la candidata.
- [ ] Revisión independiente del diff exacto.
- [ ] Build QA exacta.
- [ ] Con autorización: instalación in-place y matriz E2E física.
- [x] No commit, push, publicación, reinicio ni cambio upstream sin permiso.

## S6 — Frontera auditada post-v8

- [x] RED verticales sobre WebSocket real para 18 slices de parser, ready,
  replay, recovery y errores sensibles.
- [x] Decoder JSON duplicate-aware y enteros seguros interoperables.
- [x] Gramática disjunta y parser de eventos global/session raw-exacto.
- [x] Proof/coordinator replay atómico sin sort y con `latest_seq`/count/held.
- [x] Recovery tipado por identidad, generaciones y cobertura de dominios.
- [x] Factory cerrada para fallos de `sudo.respond` y `secret.respond`.
- [x] Documentar el límite upstream: replay no libera live tras reconnect.

## S7 — Reencauce nominal-live post-v11

- [x] Ratificar contrato A–F y matriz total antes de editar producción.
- [x] RED/GREEN: `RecoveryProof` y coordinador exigen identidad de canal no nula.
- [x] RED/GREEN: adopción posterior a `delivery.markRunning()` revalida toda la autoridad.
- [x] RED/GREEN: overflow abandona held events sin corromper el contador global.
- [x] RED/GREEN: `rotateEpoch`/`retireTransport` no causan poison permanente.
- [x] Verificación integrada: Desktop-origin partial/tool/subagent llega antes de terminal.
- [x] RED/GREEN integrado: Console-origin es visible para un segundo cliente.
- [x] Verificación integrada: idle resume conserva durable y `created:false`.
- [x] Verificación integrada: cerrar un viewer no detiene al otro.
- [x] Verificación integrada: REST/live invertidos convergen sin duplicados.
- [x] Verificación integrada: gateway distinto degrada y corte no autoritativo conserva transcript.
- [x] Verificación integrada: adquisición automática nunca create/submit/interrupt/activate arbitrario.
- [x] Suites focales y analyzer con clasificación explícita de todo rojo/timeout.
- [x] Gate: write-set exclusivo del árbol Console; upstream y sistemas reales
  sin cambios, y sin URLs/perfiles/rutas/IDs/topología xPeta hardcodeados.
