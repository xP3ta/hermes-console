## Console 1.4.2

A corrective release: signing in again, rooms, attachments and viewers, chat
behaviours brought in line with Hermes Desktop, and less memory and
background data. Console still talks only to the Hermes Dashboard.

**Fixed**

- **«Could not load» after signing in again.** If the Dashboard session had
  expired and you signed in again, Rooms and Cron on Home kept saying «Could
  not load» and Bots stayed empty until the app was restarted. Every
  connection now reconnects as soon as the sign-in is saved, including the
  background service and a sign-in with another password or method.
- **«The turn could not be saved».** A chat that failed its first read of the
  phone's secure storage refused to send until you left and came back.
- **One slow room no longer hides every room.** The room list is the server's
  own list, as in Hermes Desktop, re-read every 10 s while Bots is on screen.
  A room's conversation is read while the room is open; a room not opened yet
  says it is loading, and nothing in it counts as seen before it is on screen.
- **Files posted in a room** can be opened, saved and shared.
- **An image attached through Files is an image**, with its thumbnail, and
  the model sees it. Images up to 25 MB.
- **Your message no longer shows what Hermes adds for the model** (the
  «Attached Context» block, the «Image attached at …» lines with server
  paths).
- **A generated image is drawn once**, not with an empty box above it.
- **3D models**: compressed models (Draco, Meshopt, KTX2), the usual «light»
  web exports, stayed grey for ever; they now draw, with decoders packed in
  the app.
- **A viewer never stays blank**: what cannot be shown says why and keeps
  Open with, Share and Save.
- **Parallel approvals** wait in a queue instead of replacing each other.
- **A slow start of a turn** is no longer reported as failed after two
  minutes while Hermes keeps running it.
- **Deleting a running chat** stops its turn first.
- **Cron**: «Run now» no longer errors on a slow job; a run in flight shows
  as running and can be stopped; missed-run policy in the editor.
- **The glow of the send and stop buttons** is no longer cut to a square.

**New**

- Slash commands complete their arguments; terminal-only commands leave the
  palette.
- A running MCP tool shows its progress.
- Agent notices, live chat titles, the review summary and live context
  figures, as on Desktop.
- A provider that is not set up leads to the Models screen.
- Settings › Security › Messaging access: approve or revoke messaging users.
- Settings › System: the server's doctor and security audit.

**Lighter**

- The chats kept for a fast start moved out of the phone's secure storage
  into encrypted files, and several screens no longer decrypt everything
  stored. This is aimed at the out-of-memory closes reported on some phones.
- The background service follows Kanban events instead of downloading the
  board every cycle.

If rooms still do not load for you on 1.4.2, please open an issue and include
the short line shown under the notice in Bots (for example
`groups.list · timeout`).

---

## Console 1.4.2 (español)

Versión correctiva: volver a iniciar sesión, salas, adjuntos y visores,
comportamientos del chat igualados a Hermes Desktop, y menos memoria y datos
en segundo plano.

**Corregido**

- **«No se pudo cargar» tras volver a iniciar sesión.** Si la sesión del
  Dashboard caducaba y volvías a iniciarla, Salas y Cron de Inicio seguían
  diciendo «No se pudo cargar» y Bots salía vacío hasta reiniciar la app.
  Ahora todas las conexiones se rehacen al guardar el inicio de sesión,
  también la del servicio en segundo plano y con otra contraseña o método.
- **«No se pudo guardar el turno».** Un chat cuya primera lectura del
  almacenamiento seguro fallaba se negaba a enviar hasta salir y volver.
- **Una sala lenta ya no esconde todas.** La lista de salas es el listado del
  servidor, como en Hermes Desktop, y se relee cada 10 s mientras se ve Bots.
  La conversación de una sala se lee mientras está abierta; una sala sin
  abrir dice que está cargando y nada cuenta como visto antes de verse.
- **Los ficheros publicados en una sala** se pueden abrir, guardar y
  compartir.
- **Una imagen adjuntada desde Archivos es una imagen**, con su miniatura, y
  el modelo la ve. Imágenes de hasta 25 MB.
- **Tu mensaje ya no muestra lo que Hermes añade para el modelo** (el bloque
  «Attached Context», las líneas «Image attached at …» con rutas del
  servidor).
- **Una imagen generada se dibuja una vez**, sin el hueco vacío encima.
- **Modelos 3D**: los modelos comprimidos (Draco, Meshopt, KTX2), las
  exportaciones «ligeras» habituales, se quedaban en gris; ahora se dibujan,
  con los decodificadores dentro de la app.
- **Un visor nunca se queda en blanco**: lo que no se puede mostrar dice por
  qué y conserva Abrir con, Compartir y Guardar.
- **Las aprobaciones en paralelo** esperan en cola en vez de pisarse.
- **Un turno que tarda en arrancar** ya no se da por fallido a los dos
  minutos mientras Hermes lo sigue ejecutando.
- **Borrar un chat en curso** para antes su turno.
- **Cron**: «Ejecutar ahora» ya no da error con un trabajo lento; una
  ejecución en curso se ve y se puede parar; política de ejecuciones perdidas
  en el editor.
- **El resplandor de los botones de enviar y parar** ya no se recorta en
  cuadrado.

**Nuevo**

- Los comandos de barra completan sus argumentos; los que solo sirven en una
  terminal salen de la paleta.
- Una herramienta MCP en curso muestra su progreso.
- Avisos del agente, títulos de chat en vivo, resumen de revisión y cifras de
  contexto en vivo, como en Desktop.
- Un proveedor sin configurar lleva a la pantalla de Modelos.
- Ajustes › Seguridad › Acceso de mensajería: aprobar o revocar usuarios.
- Ajustes › Sistema: doctor y auditoría de seguridad del servidor.

**Más ligero**

- Los chats guardados para arrancar rápido salen del almacenamiento seguro
  del teléfono a ficheros cifrados, y varias pantallas ya no descifran todo lo
  guardado. Va dirigido a los cierres por falta de memoria vistos en algunos
  teléfonos.
- El servicio en segundo plano sigue los eventos de Kanban en vez de
  descargar el tablero en cada ciclo.
