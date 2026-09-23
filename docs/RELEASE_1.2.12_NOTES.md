# Hermes Console 1.2.12 — notas de publicación

Build de publicación: `1.2.12+9320` (2026-09-23), probada físicamente en Pixel 9 Pro contra la
instancia real de Hermes (build de QA `+9310`, mismo código salvo cabecera del bloque del asistente,
dos tests deterministas, documentación y SBOM). Pruebas hechas: suite completa
(6393 pasan, 0 fallos, dos pasadas), `flutter analyze` limpio, gitleaks y grep manual de
rutas/IPs/tokens sobre todo el diff limpios, emulador Android 35 y Pixel 9 Pro conectados a la
instancia real de Hermes (con el plugin de enrutado Laya activo), incluidos cortes de red reales
por `adb` y cierres forzados de la app a mitad de `/compress`. Esta build añade sobre la `+9010`:
el rediseño de la píldora de actividad/panel/compactación/editor inline, las correcciones de una
auditoría de seguridad y una revisión de código independientes, y el rediseño de la compactación
«abierta por defecto» descrito más abajo.

## Lo más importante frente a 1.2.11

- **Stop como en Desktop.** Llega siempre al servidor (ya no lo bloquea una comprobación local
  de propiedad ni un fallo al escribir en disco), se confirma con la señal real del gateway y
  escala con un límite de 8 s en vez de quedarse en «Deteniendo…». Está disponible mientras
  haya trabajo, sea cual sea (turno, proceso en segundo plano, subagente, bucle o sesión
  arrancada en otro sitio), desde el chat y desde las filas de Inicio y la lista; también
  detiene los procesos en segundo plano; un turno interrumpido dice «Detenido»; y una sesión
  colgada por auto-continuar muestra un banner «Detener esta sesión».
- **Editar, cola y forzar como en Desktop.** La fila se resuelve por contenido, las ediciones
  consecutivas funcionan, un fallo restaura el historial sin burbujas huérfanas, y un «forzar»
  que el backend declina porque el turno acababa de terminar ya no se anuncia como fallo: el
  mensaje sigue en cola.
- **Pérdida de red.** El chat se recupera solo: reintentos con jitter hasta 15 s, aviso
  inmediato cuando Android detecta la red o la app vuelve a primer plano, ticket nuevo en cada
  intento, y si el turno terminó mientras estabas sin conexión se adopta la respuesta final del
  historial. Mientras dura, el chat lo dice con calma y avisa con «Reconectado».
- **Aprobaciones y preguntas del agente (#42), voz desde la segunda grabación (#39) y borrador
  (#37, con pruebas de regresión).**
- **Una burbuja por turno,** con la cabecera del avatar sin aro de carga y en el color de acento,
  y una línea atenuada debajo del nombre redactada como Desktop («Pensó durante 40s» en vivo,
  «Pensó un momento», «Pensó» al reabrir); **una sola píldora de actividad** que se
  expande en el sitio a un panel compacto con scroll (tareas con check animado, ahora, hecho con
  duraciones, segundo plano/subagentes/bucles); **compactación real** (manual y automática) con
  una píldora flotante con anillo, hechos reales del backend y cronómetro real, que al terminar
  pasa a «Compactado · 38 → 34 mensajes» o «Nada que compactar», nunca un porcentaje inventado;
  si se cierra la app a mitad de compactación no se bloquea nada: al reabrir se muestra la píldora
  solo si el servidor sigue comprimiendo y luego un único resultado; **el estado de cada chat en
  las listas** con su propio color (verde trabajando, ámbar necesita atención, rojo fallo); **editar en la
  propia burbuja**, sin ventana modal, con más espacio para escribir; **aviso de Stop discreto**
  que se desvanece solo; **archivos con visor propio** (imagen, vídeo, PDF, texto, audio);
  **trabajo en segundo plano visible** en el chat, Inicio y la lista, incluido Stop de
  subagentes; avisos flotantes arriba; flechas de subir/bajar solo cuando sirven.
- Sondeos del chat y de las listas guiados por eventos con respaldo lento; backoff estable;
  historial largo accesible tras compactar; nueva autorización normal `ACCESS_NETWORK_STATE`.
- **Seguridad**: denylist de rutas sensibles para `MEDIA:` mucho más amplia (claves SSH,
  `.ssh`/`.aws`/`.kube`/`.docker`/etc., `/proc`, `/sys`, `/dev`) con una segunda comprobación
  antes de mostrar texto en línea; instaladores/ejecutables ya no se auto-abren; las descargas
  autenticadas ya no siguen redirecciones con la credencial de sesión puesta; un intent de
  compartir externo solo se acepta desde `content://`; una ruta personal ya no puede filtrarse en
  el paquete público de evidencias del release.
- **Correcciones de una revisión de código independiente**: Stop de un proceso en segundo plano
  ya no puede afectar a otra sesión en un cliente compartido; una ráfaga de reintentos de sesión
  ya no puede recursar sin límite; el panel de actividad ya no recalcula en cada pulsación de
  tecla; una edición interrumpida a mitad de camino ya no puede reportar éxito falso.

## Límites conocidos

- Las notificaciones de trabajo que termina en otro dispositivo (p. ej. la tablet) no están.
- Sin certeza de «exactamente una vez» si la conexión cae justo al enviar un mensaje (el
  backend actual ignora `client_turn_id`); un turno sin actividad durante 10 min separado del
  cliente puede ser interrumpido por el servidor.
- Console y Desktop siguen sin poder continuar el mismo turno en vivo entre clientes.

## Ya validado (2026-09-22)

Turno largo con herramientas y cierre forzado; corte de red real (modo avión 90 s) con el turno
en marcha; Stop con proceso en segundo plano, con subagentes (confirmado con `ps` en el
servidor) y desde Inicio; editar en la burbuja y cola con «forzar»; cabecera y flechas; archivos
(TXT, PDF, imagen, audio); tareas del agente y su panel; aprobaciones (`clarify`); compactación
manual y automática; voz con dos grabaciones seguidas contra un STT del servidor.

## Validado en el Pixel 9 Pro (2026-09-23, build de QA `+9310`)

`/compress` en vivo (píldora con hechos y cronómetro reales, composer bloqueado solo durante la
compactación, «Compactado · N s» al terminar); `/compress` sin cambios («Nada que compactar · N
mensajes» al instante); cierre forzado de la app a mitad de compactación y reapertura, con un chat
creado en la misma sesión y con uno ya guardado (píldora con el tiempo real sin bloquear el
composer, un único «Compactado» al terminar, sin avisos falsos); menú de comandos que ya no queda
sobre el drawer; Stop desde el chat y desde la fila de la lista (el servidor confirma la
interrupción); edición en la propia burbuja (una sola burbuja, una sola fila en el servidor);
colores de estado en la lista.

## Pendiente

Modo voz/Realtime queda fuera de alcance de esta versión (auditoría aparte). La cabecera
«Pensó…» y los colores en tema claro se validaron con tests, no a ojo en el Pixel.
