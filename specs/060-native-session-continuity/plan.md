# Plan técnico — Spec 060

## Contratos upstream utilizados

Hermes Desktop y Hermes Agent son upstream oficial read-only. La implementación
se limita al árbol de Hermes Console y no requiere forks, reinicios,
configuración local ni capacidades no publicadas. Todos los destinos se derivan
de la conexión/perfil elegidos por el usuario; no se hardcodea infraestructura.

- Dashboard REST `/api/sessions` y páginas de mensajes con perfil e `include_compacted`.
- Gateway WebSocket `/api/ws`.
- `session.active_list` para descubrir runtimes del mismo gateway.
- `session.activate` para adjuntar el transporte a un runtime conocido.
- `session.resume` para adjuntar o reconstruir la sesión durable.
- `session.status` para reconciliar turnos ambiguos.
- Exclusión oficial por sesión para `prompt.submit`.

## Arquitectura

### Orden de autoridad

El camino nominal es deliberadamente corto: suscribir WS, capturar la tupla de
autoridad, ejecutar `session.resume` exacto no creador, validar toda la respuesta
y adoptar. REST corre ortogonalmente. `active_list → activate` solo acelera un
binding ya conocido y su resultado debe confirmarse de nuevo; nunca decide la
identidad. El coordinador de replay queda confinado al corte anormal y no puede
bloquear, poner en cuarentena ni envenenar un attach nominal sano.

La matriz total de `spec.md` es la definición ejecutable de las transiciones.
Cada operación asíncrona captura antes de su primer `await` la identidad completa
y la revalida después de cada espera. No se conserva maquinaria de recovery que
no contribuya a `reconnecting → liveAttached|degraded/historyPending`.

### Identidad

Crear un vínculo explícito:

```text
SessionBinding {
  connectionId,
  profile,
  storedSessionId,
  runtimeSessionId?,
  bindEpoch,
  sessionEpoch,
  turnEpoch,
  recoveryGeneration,
}
```

Solo `connectionId + profile + storedSessionId` identifica el destino durable.
Runtime y epochs locales cercan callbacks y ACK tardíos; el contrato estable no
expone una generación remota.

### Adhesión visible

Al abrir una conversación persistida con gateway Dashboard:

1. Suscribirse al stream antes de iniciar la adhesión.
2. Publicar en paralelo el historial durable disponible.
3. Ejecutar `resumeExisting(storedSessionId, deferHistory: true)`: el gateway
   reutiliza y adjunta el runtime vivo del mismo durable de forma atómica.
4. Usar `active_list`/`activate` solo al reactivar un runtime ya vinculado.
5. Vincular el runtime únicamente si la ruta, perfil y epochs siguen vigentes.
6. Reconciliar el snapshot/runtime y la cola durable.

`loadMessages(passiveOnly: true)` queda reservado a fallback, pantallas no visibles y backends legacy; deja de ser la ruta inicial de una conversación visible moderna.

### Lectura y eventos

REST y WebSocket corren en paralelo. El reconciliador injerta el tail durable sobre la proyección viva por `message_id`, identidades sintéticas y fences terminales. La respuesta REST no puede borrar deltas vivos más nuevos ni revivir actividad cerrada.

La finalización del cold-open reduce dos resultados independientes:

```text
TranscriptOutcome = empty | published | preserved | recoveryNeeded | failed
AttachmentOutcome = attached | transient | missing | terminal | ambiguous | stale
```

Una única finalización procesa primero la autoridad de adhesión y después el
resultado del transcript. Así, `empty`, error REST o expected-count inválido no
pueden omitir una recuperación viva transitoria; `4007` marca ausencia durable
con cualquier forma de historial y nunca crea una sesión.

### Reconexión acotada y honesta

Ante cierre de socket:

1. Invalidar el bind epoch del transporte.
2. Conservar `storedSessionId`, mensajes y outbox.
3. Reconectar al mismo backend/perfil.
4. Ejecutar de nuevo `resumeExisting` no creador sobre el durable exacto;
   `active-list`/`activate` solo reactivan un binding local ya conocido.
5. Consultar status antes de reenviar cualquier mensaje ambiguo.
6. Rellenar huecos desde REST.

La recuperación automática es single-flight y conserva la autoridad al pasar a
segundo plano o durante polling REST. Se invalida únicamente por cambio de
identidad/turno/runtime o destrucción real de la instancia. Toda adopción
revalida gateway, conexión, perfil, lineage, durable, epochs y snapshot después
de cada `await`; nunca crea, activa ni envía.

Estados efectivos: `detached → attaching → backoff → attached`, con salidas
cerradas `terminal/ambiguous`, delegación separada a turn recovery y `disposed`.
Los productores normalizan timeout JSON-RPC, cierre de socket y fallo de ticket
WebSocket en causas tipadas sin body. La política de viewer reintenta solo el
conjunto transitorio cerrado; las políticas de mutación permanecen intactas.
El cierre terminal incrementa la generación, se comprueba después de cada
`await` y absorbe vuelos previos. No se limpia durante una carga bloqueada por
un fence durable de compresión. Los envelopes/eventos estructuralmente
malformados retiran el socket y todos los pendientes reciben un error saneado.

El handshake termina únicamente con `gateway.ready` global y válido. La
frontera `JsonRpcWireDecoder → EventEnvelopeParser → ReplayBatchProof →
ReplayCoordinator` valida duplicados, enteros JSON seguros, identidad exacta,
`latest_seq`, count, truncation y continuidad sin ordenar. Debido a la
expulsión FIFO upstream que puede reiniciar `seq` sin rotar epoch, todo runtime
previamente observado queda retenido después de reconnect aun cuando el replay
sea localmente contiguo. Una prueba completa puede liberar eventos retenidos; si upstream no demuestra
el corte, se conserva transcript y se publica `degraded/history-pending`. Ese
resultado es terminal para el intento ambiguo, no poison global: una conexión y
adhesión nominal posterior empieza limpia.

### Backends separados

Un rechazo de lease/owner después de comprobar que no existe runtime activable en este gateway se clasifica como `differentBackend`. La UI permanece usable en solo lectura y no crea una sesión alternativa. La reanudación se vuelve a intentar cuando la fuente oficial demuestra liberación.

## Cambios implementados

- `active_chat_service.dart`: adhesión no destructiva, finalización ortogonal,
  single-flight, fences, clasificación exclusiva de viewer y apertura de un
  turno externo posterior mediante el `message.start` secuenciado del mismo
  runtime adjunto.
- `recovery_proof.dart` y `replay_coordinator.dart`: autoridad de canal no nula,
  comprobación post-persistencia de la autoridad ya comprometida, contabilidad
  balanceada de held events y retiro de transacciones poisoned al rotar epoch o
  transporte.
- `tui_gateway_client.dart`: causas tipadas para timeout/cierre, preservación
  segura durante la prueba de capacidad de `session.resume` y revalidación de
  canal/socket/epoch después de esperas de persistencia.
- `connection_manager.dart`: causa body-free para transporte/malformed del
  ticket WebSocket.
- pruebas integradas con dos `TuiGatewayClient + ActiveChat`, servidor WS local
  compatible, REST real mockeado, continuidad bidireccional, cierre de viewer,
  degradación, reconnect sin corte probado y reconciliación REST/live.
- `tool/spec060_console_scope_gate.py`: gate universal que rechaza paths del
  write-set fuera de la raíz Console, incluidos escapes por symlink.

## Estrategia TDD

Vertical slices:

1. Cold-open llama `resumeExisting` y conserva identidad durable.
2. Runtime activo se activa sin crear otro.
3. Fallo de adhesión conserva historial y declara degradación.
4. Evento vivo posterior a REST no se pierde.
5. Reconexión conserva el turno ambiguo y no drena cola.
6. Delegación viva/histórica converge a un único estado terminal.
7. Socket idle y cold-open transitorio se readjuntan sin acción manual.
8. Polling, invalidación REST, ocultación y background no cancelan reattach.
9. Dispose, repin, turno o runtime nuevo cercan respuestas tardías.
10. Historial vacío, fallo REST y expected-count no omiten reattach transitorio.
11. Timeout/cierre reales del JSON-RPC sobreviven capability y resume.
12. Auth/protocolo/errores desconocidos paran cerrados sin hot-loop.
13. Ticket WebSocket distingue transporte reintentable de payload malformado.
14. Upgrades WS 401/403/404 paran; 408/429/5xx y socket real reintentan.
15. Un cierre terminal cancela vuelos previos y sobrevive callbacks tardíos.
16. Envelopes y eventos map-shaped malformados retiran transporte y pendientes.
17. Un fence durable impide que una carga visible reabra recuperación cerrada.

Cada slice debe fallar primero por ausencia del comportamiento, pasar con el cambio mínimo y ejecutar después las suites focales.

Slices de reencauce: (a) autoridad exige canal no nulo; (b) una adopción stale
después de persistir `running` se rechaza; (c) el contador global de held events
permanece balanceado al abandonar por overflow; (d) rotación/retiro no deja
poison permanente; (e) matriz integrada bidireccional mediante
`TuiGatewayClient + ActiveChatService`, incluidos partial/tool/subagent antes de
terminal, segundo observador, cierre de un viewer, orden REST/live invertido,
gateway distinto y ausencia total de mutaciones automáticas.

## Riesgos

- Semántica distinta en versiones antiguas de Hermes: feature detection y fallback honesto.
- Varias llamadas concurrentes a resume: single-flight por conexión/perfil/stored ID.
- Runtime obsoleto de `active_list`: fallback a resume y bind epochs.
- Android suspende el proceso: rehidratación durable y posterior FGS para actividad larga.
- Backend aislado: no prometer live attach; degradar sin mutar.
- Deriva accidental de alcance: gate programático de write-set y búsqueda de
  constantes xPeta/específicas antes de la revisión independiente.
