# Hermes Console 1.2.10 — notas de publicación

Build publicado: `1.2.10+9008` (2026-09-14). Validado en Pixel 9 Pro contra
Hermes Agent `main` (contrato v7): clarify/aprobaciones de extremo a extremo,
espera de más de dos minutos sin falso `firstTokenTimeout`, y recuperación de un
turno con la terminal tras un cambio de red a mitad de ejecución.

## Cambios frente a 1.2.9

- Console habla el contrato v7 de Hermes Agent: aprobaciones, clarify, sudo,
  secretos y lecturas de terminal llegan como peticiones JSON-RPC
  servidor→cliente y se responden por el mismo socket; los lotes de clarify
  bloquean respuesta a respuesta (`clarify.lock`), `request.cancel` retira la
  tarjeta y `open_requests` reentrega las preguntas pendientes tras reconectar.
  Un backend que aún emite los eventos `*.request` heredados sigue funcionando.
- Un corte de socket a mitad de turno contra un gateway sin
  `turn_idempotency_v1` (el oficial) reanuda la sesión viva y adopta el turno en
  vuelo en vez de fallar de inmediato.
- Desaparece el falso «Modelo sin respuesta» mientras el agente espera una
  respuesta humana: los eventos de vida del servidor ya no rearman el vigilante
  de 90 s bajo una tarjeta pendiente.
- «Reintentar» sobre un turno fallido siempre actúa: reconcilia con el
  transcript durable y, si el servidor no tiene el turno, lo reenvía.
- La tarjeta de clarify/sudo/secreto sube como hoja compacta sobre el chat, con
  opciones en filas anchas, etiqueta «Recomendado» y campo «Otro» integrado.

- La lista de sesiones muestra una proyección global y acotada de actividad
  iniciada en Desktop u otra Console. Reconcilia el roster activo, la lista
  autoritativa de procesos y los prompts bloqueantes sin tomar control de la
  sesión ni guardar payloads libres del Gateway.
- Los turnos consecutivos dentro del mismo runtime vuelven a aparecer después
  de completar o pulsar Stop; una respuesta de roster realmente anterior no
  puede revivir el estado detenido. Eventos de runtimes desconocidos,
  `sessions.changed` y el gesto de refresco relanzan la reconciliación.
- Una caída del canal de eventos reintenta con backoff y techo acotados. Mientras
  no existe autoridad nueva, el último estado se muestra con color neutral y
  deja de afirmar actividad viva al superar su ventana; un replay incompleto se
  etiqueta como estado desconocido.
- Borrar una sesión o el historial local de un perfil purga también el journal
  público cifrado; pause/detach espera su vaciado. La píldora no desborda a 200%
  de escala en español y TalkBack recibe una sola etiqueta combinada.
- Límites honestos: `process.list` sigue siendo la única autoridad de trabajo en
  background. La proyección no crea eventos de proceso, no convierte una cola
  FIFO o una edición en trabajo ya iniciado y no añade rutas de redirect/steer.
- Las aprobaciones respetan exactamente los scopes anunciados por Desktop; ni la
  tarjeta ni la política automática ofrecen o envían `session`/`always` cuando
  `choices`, `allow_session` o `allow_permanent` los prohíben.
- Las solicitudes de Vault que requieren secretos no se descartan ni se copian:
  Console muestra «Continúa esta solicitud en Hermes Desktop» y no persiste
  origen, código, contraseña ni payload.
- Una edición rechazada restaura el transcript previo. Los turnos encolados desde
  el composer se cifran antes de vaciarlo, restauran FIFO y conservan una cabeza
  rechazada con reintento acotado y acción manual.
- `session.reclaimed` invalida sólo el binding que coincide en conexión, perfil,
  runtime, sesión durable y época, seguido de reattach frío. Steering automático,
  `background.complete` y `missing_servers` quedan explícitamente para 1.2.11.

- El historial retenido por compactación se carga mediante la API pasiva ya
  publicada por Hermes (`include_compacted=true`). Console acepta la respuesta
  actual `messages` y la heredada `data` sin mezclarlas; si un servidor antiguo
  o un linaje rotado no demuestra cobertura completa, mantiene el aviso parcial.
- El historial confirmado permanece visible al refrescar, reconectar o reabrir
  chats, sin duplicar el transcript.
- Una tarjeta de subagente activa no desaparece al insertar un turno humano: la
  finalización tardía actualiza exactamente la misma fila. La tarjeta solo
  muestra estado, modelo, duración y contadores autoritativos; si el historial
  no conserva identidad, objetivo, actividad o resultado individual, lo indica
  sin inventarlos.
- La reconexión WebSocket recupera eventos por secuencia, ordena el replay y
  aparca frames live hasta cerrar el hueco.
- Un replay truncado no proyecta una continuidad no demostrada: aparta tail y
  frames live hasta que el historial autoritativo cierra el hueco.
- Las secuencias malformadas no pueden corromper el watermark de reconexión.
- Las tarjetas de delegación persistidas con datos públicos seguros sobreviven
  al refresco y pueden cambiar con una finalización pública; no indican
  actividad actual entre procesos.
- Un turno durable que termina después de agotar la ventana de recuperación
  offline puede reconciliarse sin reenviar ni duplicar el prompt; el borrador no
  confirmado permanece editable.
- El texto o la voz recibidos mientras hay un turno activo se encolan en orden
  FIFO como turnos siguientes. Chat y Voz no alcanzan `session.redirect` ni
  `session.steer`, y una cola remota no cae al transporte REST.
- Abrir, listar, hidratar o paginar una sesión es pasivo. Un conflicto durante
  una mutación explícita falla cerrado, sin resume, retry ni takeover automático.
- Cron, Kanban y el historial seguro de subagentes aparecen bajo Automatización.
  Los no-op de Cron y Kanban `done` no interrumpen; los bloqueos y fallos de
  entrega siguen visibles.

## Google Play — Novedades (español)

Mejoramos la continuidad entre Desktop y Console: recuperación segura de chats
compactados, reconexión WebSocket ordenada y protección ante huecos de replay.
También aclaramos Cron, Kanban y el historial persistido de subagentes para que
los avisos sean accionables sin atribuir actividad no demostrada.

## Google Play — What's new (English)

Improved Desktop-to-Console continuity using Hermes' existing public APIs:
retained compacted history is loaded passively, current and legacy Dashboard
response shapes remain compatible, and incomplete coverage stays clearly
labelled. Active subagent cards now remain stable across new human turns and
show only authoritative status and metadata. WebSocket replay remains ordered
and fail-closed when continuity cannot be proven.
