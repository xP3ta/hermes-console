# Entrada durante un turno ocupado

Console consulta `GET /api/config` al abrir o volver al chat y al recargar su
perfil, con `?profile=<propietario>` para perfiles nombrados; el cliente REST
existente omite el parámetro para `default`. Es la fuente que usa Hermes Desktop
(`getHermesConfig` / `use-hermes-config.ts`). La caché en memoria guarda solo
`display.busy_input_mode`, por conexión y perfil; no guarda el resto del config.
Una respuesta válida normaliza valores desconocidos o ausentes a `interrupt`.
Una lectura fallida vuelve a `queue` sin aviso; una respuesta obsoleta no pisa
una lectura posterior. Una sesión conserva siempre su perfil propietario.
Los cambios emiten un evento exclusivo del compositor: no reconcilian el
historial ni actúan como evidencia de un cambio del runtime.

- `interrupt`: escribe primero la outbox y llama a `session.redirect` mediante
  `ActiveChat.steer(interrupt: true)`, como Desktop. Retiene el drenaje local
  mientras espera el ACK; el redirect aceptado cierra su registro durable.
  Solo un rechazo seguro o método ausente permite el fallback a
  `sendQueuedNow` → Stop → ACK → envío con el mismo `clientTurnId`.
  Un fallo o timeout de Stop muestra «No se pudo interrumpir; el mensaje sigue
  en cola» y reanuda la cola. Un redirect ambiguo nunca dispara ese fallback.
- `steer`: usa `ActiveChat.steer(interrupt: false)` → `session.steer`, para
  inyectar en el turno actual sin llamar a `session.redirect` ni interrumpir.
- `queue`: conserva la cola y su recuperación actuales.

Con adjuntos, herramientas bloqueadas, compactación o actividad de otro dueño,
el mensaje espera en cola, como los envíos que Desktop no puede redirigir.
Sin un turno ocupado se conserva el envío normal. Los RPC ausentes (`-32601`)
degradan a la ruta compatible o a cola; un rechazo explícito de steer se
encola, mientras que un fallo ambiguo conserva el borrador para evitar
repetir una instrucción que el servidor pudiera haber aceptado.

La pulsación larga del botón ya existente sigue encolando **solo ese mensaje**,
sin escribir ajustes del servidor. Su indicación de accesibilidad lo explica;
el hint, Tooltip y etiqueta del botón anuncian el modo efectivo. El hint usa
puntos suspensivos; la acción accesible no los incluye.

Como Desktop, enviar en modo `interrupt` no abre una confirmación: es una acción
explícita que corta el turno y puede descartar trabajo en curso. Los mensajes en
cola siguen teniendo sus acciones manuales de enviar ahora y guiar.

Pruebas: `chat_busy_input_test.dart` usa un gateway falso desde el chat real
(modos × ocupado/libre, ACK, envío único, cola explícita, RPC ausente, perfil y
hint/Tooltip); los turnos del harness se disponen antes de que Flutter
compruebe sus temporizadores. `busy_input_mode_test.dart` prueba normalización,
aislamiento, fallos de lectura y carreras entre snapshots. No sustituye una prueba en móvil.
