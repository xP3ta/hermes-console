# Hermes Console 1.2.13 — notas de publicación

Build de publicación: `1.2.13+9345` (2026-09-25). Base pública de comparación:
`v1.2.12`. El mismo código se probó físicamente en Pixel 9 Pro (Android 17)
como build de QA `+9345`, instalada encima de la anterior sin borrar datos,
contra una instancia real de Hermes. Tres revisiones independientes (9342,
9343, 9344) encontraron fallos que quedaron corregidos con su regresión antes
de esta build.

## Chat, historial y turnos

- **Texto previo a herramientas:** se conservan los segmentos `message.interim`
  al recibir herramientas, razonamiento, nuevos deltas y el resultado final.
- **Dos respuestas idénticas durante streaming:** una fila terminal retenida
  para preservar la posición de lectura podía compartir el notifier de texto con
  el siguiente turno externo. La transición terminal → streaming reinicia la
  identidad visual aunque no llegue el evento local `started`. No se eliminan
  mensajes comparando su texto; la respuesta histórica permanece independiente.
- **Correcciones en vuelo:** `display_kind='steer'` se normaliza como corrección,
  no como un turno de usuario adicional. Se preservan los ordinales usados por
  edición, rewind y reconciliación de historial.
- **Envío normal durante un turno activo:** botón y teclado guardan el siguiente
  turno en la cola FIFO durable, sin redirigir ni interrumpir al agente o sus
  hijos. El compositor se limpia después de persistir. La acción explícita
  «Steer now» y editar/rewind conservan sus contratos propios.
- **Drenaje de texto plano:** el terminal autoritativo también rearma el lease de
  colas sin adjuntos. Un ACK de Stop, un evento intermedio o una lectura obsoleta
  no se convierten por ello en permiso para enviar el siguiente turno.
- **Edición con subagentes:** el turno interrumpido sella sus actividades como
  canceladas; no quedan tareas antiguas aparentemente vivas ni se etiqueta una
  cancelación como fallo por el mero contenido de un campo de error.

## Sesiones largas y compositor

- Se reducen proyecciones repetidas y trabajo de Markdown en sesiones largas,
  con regresiones de equivalencia del renderizado y presupuesto por frame.
- Abrir el teclado no invalida innecesariamente todo el transcript. El
  compositor sigue siendo editable mientras se refresca el historial; el envío
  conserva la barrera de autoridad hasta publicar ese refresh.
- Las lecturas idénticas simultáneas de apertura comparten el transporte REST.
  El scrollback y la recuperación mantienen lecturas independientes, y cada
  consumidor valida su propia cobertura y autoridad antes de aplicar datos.

## Envío, reintento y subagentes (paridad con Desktop)

- **Primer turno sin duplicar:** en un chat nuevo, el paso del id provisional a
  la sesión durable ya no muestra dos veces el mensaje del usuario ni la
  respuesta. La identidad se decide por fila durable, no comparando texto.
- **Reintento seguro:** «No se pudo enviar · reintentar» reenvía solo si el
  historial durable demuestra que el turno no llegó. Si el estado es ambiguo
  se conserva el error y se permite descartar, sin riesgo de doble envío. La
  sesión creada se persiste antes del envío, por lo que el criterio se
  mantiene aunque Android cierre la app entre el fallo y el reintento.
- **Tarjeta de subagentes en vivo:** una delegación con solo identificadores
  (sin conteos) se trata como incompleta y se hidrata desde el historial; la
  tarjeta pasa sola a «N completado · N fallaron · duración» también en el
  primer turno de un chat nuevo. El historial muestra una única línea
  compacta en lugar de listas repetidas.
- **Actividad en la lista:** los procesos que el Gateway ya reporta como
  `exited` no cuentan como trabajo en segundo plano (mismo criterio que
  Desktop), y tras un corte de red no quedan filas «trabajando» fantasma.
- **Lecturas de historial acotadas:** solo un error transitorio (conexión o
  timeout) permite repetir la hidratación; un error permanente del servidor no
  genera lecturas por cada refresco.
- **Compactación:** una sesión en compactación no invalida el historial
  durable, igual que Desktop. Las cachés de proyección tienen presupuesto en
  bytes y se invalidan al cambiar de perfil o conexión.
- **Borrador de Inicio:** sobrevive a segundo plano y cierre forzado, y se
  borra con los datos del perfil.

## Adjuntos y previews

- `::preview{file="..."}` se interpreta mediante la ruta de medios autenticada
  (#49). Las imágenes tienen miniatura; HTML se ofrece como archivo descargable,
  **no** como un widget ejecutable o iframe de Desktop. Las directivas
  desconocidas permanecen visibles como texto.
- Las miniaturas mantienen identidad y proporción al reconstruir el historial.
  Los adjuntos del compositor se alinean al inicio y no muestran un estado
  «Pendiente» que no corresponda al estado real de entrega.

## Recuperación y navegación

- Se corrige la recuperación idle cuando el servidor ha retirado el runtime:
  su ausencia en el roster no deja indefinidamente «Reconnecting…» (#46).
  Es un mecanismo concreto; no implica que estén resueltos todos los posibles
  cierres del proceso Android, problemas de red o fallos de Bot Mode.
- Logs de Kanban y paneles de texto largo aceptan el arrastre vertical (#48).
- Se puede elegir Inicio o Bots como pantalla inicial (#47), respetando
  notificaciones y enlaces profundos.
- Se añaden regresiones de borradores al navegar y en Bot Chat (#37), y del
  reciclaje del motor de dictado entre grabaciones (#39). La cobertura añadida
  no se presenta como un arreglo nuevo cuando la conducta ya funcionaba.

## Límites de esta candidata

- No modifica Hermes Agent/Desktop ni requiere un patch privado del servidor.
- No cambia permisos, dependencias, canales de distribución ni consentimiento
  de servicios en primer plano.
- Docker (#44) queda fuera del alcance.
- Las pruebas de widgets no sustituyen aceptación en Android físico. La
  reproducción de las dos filas demuestra una causa suficiente del cliente,
  no reconstruye por sí sola la secuencia exacta de un teléfono concreto.

## Validación

- `flutter analyze --fatal-infos` limpio y suite completa verde (6.506 tests).
- QA física en Pixel 9 Pro sobre la build `9345`: primer turno sin duplicados,
  reintento sin red con un único envío (confirmado en SQLite y tras cierre
  forzado), tarjeta de subagente en vivo en chat nuevo, cola y Stop, borrador
  de Inicio, lista sin actividad fantasma tras corte de red y con proceso
  `exited`, apertura de sesiones largas sin frames lentos, #47 y #49; sin
  crashes ni ANR de la app.
- Límites conocidos: sin red, el aviso «No se pudo enviar» tarda unos 20 s; si
  Android cierra la app tras un fallo del primer mensaje de un chat nuevo, ese
  mensaje solo puede descartarse (por diseño, para no arriesgar un doble
  envío). #48 está cubierto por test, sin prueba física con un log real.
