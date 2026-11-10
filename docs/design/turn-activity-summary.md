# Resumen de actividad del turno (9809)

El turno activo conserva las tres últimas acciones como filas finas (los
pensamientos comparten ese límite y mantienen su desplegable), con el
verbo, el destino seguro, el estado y un reloj propio por paso. Al terminar,
el mismo contenedor se pliega en una línea descriptiva; tocarla abre todos los
pasos en orden. Se conservan los adjuntos y los desenlaces del turno.

El resumen muestra la duración real recibida del turno, sin sumar herramientas
que pueden solaparse. Ordena los tipos de acción por cantidad, después por tiempo
medido y finalmente por prioridad estable: edición, lectura, comandos/código, búsqueda
en archivos, búsqueda web, páginas, delegación y otras herramientas. Muestra
hasta tres tipos, `+N más` por los tipos restantes y los fallos explícitos. El
texto de Semantics contiene todos los tipos, aunque la línea visible los abrevie.
Los relojes enteros usan `m:ss` / `h:mm:ss`; se omiten las medidas inferiores
a un segundo, negativas, desconocidas o de 24 h o más. El turno que solo piensa
usa su duración total cuando se conoce.

Lecturas y ediciones cuentan nombres de archivo seguros distintos. Si falta
algún objetivo, la categoría se expresa por llamadas («Leyó/Editó N veces»),
sin afirmar cuántos archivos se tocaron. `execute_code` dice «Ejecutó código».

El cliente vuelve a sanear `ActivityStep.detail`, incluso si un snapshot afirma
que ya está proyectado: ejecutable sin argumentos, nombre de archivo o host.
Las consultas/patrones se descartan; URLs firmadas en `file`/`target` también se
reducen al host. Los previews crudos no alimentan las filas ni el resumen.
Las actualizaciones y los relojes viven dentro de los widgets de turno; no se modifican `chat_screen.dart`,
`active_chat_service.dart`, la cola, la cabecera ni la píldora.

## Cuatro salidas reproducibles

Estas salidas se verifican en `test/turn_summary_test.dart`, con casos concretos
de los traces de prueba ya presentes en el repositorio (no son capturas de una
sesión de producción):

- Cuatro ciclos pensamiento/herramientas, diez llamadas terminal y 95 s de turno
  (`turn_one_line_test.dart`): `Trabajó 1:35 · Ejecutó 10 comandos`.
- Historial reabierto con `date` (0,7 s) y lectura fallida de `config.yaml` (12 s),
  sin duración total conocida (`chat_screen_test.dart`):
  `Trabajó · Leyó 1 archivo · Ejecutó 1 comando · 1 falló`.
- Una llamada `delegate_task` que despacha tres hijos
  (`subagent_transcript_projection_test.dart`): `Trabajó · Delegó 1 tarea`.
- Segmento de razonamiento medido en 8 s (`trace_step_cards_mode_test.dart`):
  `Pensó 0:08`.

La limitación acordada del tercer caso es deliberada: el trace del turno no lleva
el roster y una llamada puede lanzar varios agentes. No se deduce un recuento de
agentes a partir de llamadas. El constructor del resumen admite `agentCount`
cuando el llamador conoce el número real; enlazarlo al chat requiere otro cambio
fuera del alcance aprobado. La prueba del constructor verifica también el sufijo
`2 agentes` con un recuento explícito.

## Verificación

- `flutter pub get --offline`, `flutter gen-l10n`.
- `dart analyze --fatal-infos lib test`.
- Todas las ejecuciones Flutter usan
  `flock /tmp/hermes-console-flutter-test.lock timeout 900 flutter test -j 1 …`.
- Pruebas nuevas: construcción del resumen, plurales de los nueve idiomas,
  prioridad/truncado, fallos, recuento explícito de agentes, privacidad, reloj
  local, tres acciones en vivo, plegado, identidad del contenedor y 320 dp / 2×.
- Regresiones: turno/pasos, activity_pill, chat_replying_1215, chat_screen completo,
  chat_scroll_glitch_regression y todas las pruebas running_work/subagent.
- Se retira `turnLineSteps`; no se resucita ninguna clave de
  `/tmp/nous-obs/deadkeys.json`. ARB modificados por adición al final sin reformateo.
- No existe patrón de golden para estos widgets de turno. No se crean ni
  regeneran PNG; el golden global de chat queda sin actualizar.

### Resultado de la revisión (2026-11-04)

- `dart analyze --fatal-infos lib test`: sin incidencias.
- `chat_screen_test.dart` completo sobre el resultado final: **921/921**.
- Otros **30 archivos, 500/500 pruebas aprobadas** en la batería amplia: todos
  los suites solicitados, incluidos los **17 archivos** running_work/subagent,
  además de las pruebas nuevas de privacidad y resumen.
- La batería amplia ejecutó 1.421 casos: 1.420 pasaron y una aserción antigua
  esperaba todavía «0,7 s». Conserva la comprobación de medición real de 700 ms;
  ahora exige omitir «0,7 s» y «0:00» de la fila. Tras corregir esa expectativa,
  se repitió `chat_screen_test.dart` entero con los 921 casos aprobados.
- MEDIO-1: objetivos repetidos, distintos, ausentes y mixtos; código separado
  de comandos; transporte del objetivo seguro del modelo al resumen.
- MEDIO-2: URLs firmadas en todos los campos de ruta, consultas y patrones,
  flags/--token, rutas absolutas, snapshots crudos y tipos inválidos; también
  ausencia de datos privados en texto y Semantics durante y después del turno.
- BAJO: reloj omitido por debajo de un segundo, incluidos los pasos y el turno.
- Se restauran expansión y taps, alturas tocables **≥44 dp**, igualdad de alturas
  entre resumen y pensamiento, `takeException() == null` después de expandir y
  el estado literal «Fallido». Ninguna tolerancia de rendimiento/scroll sube.
- «Fallido · 1:12» se verifica completo a **320 dp y escala 2×**, sin elipsis,
  con los textos completos contenidos en el ancho disponible.
- Se mantiene `colors.warning`, ajustado por `readableInkOnTint`: contraste
  mínimo medido del texto «1 falló» en todos los presets: **4,964:1**.
- Solo se añaden tres claves al final de cada ARB; no se reescriben los valores
  existentes ni se resucitan claves retiradas. Sin dependencias ni goldens nuevos.

Logs locales: `/tmp/turn-review-regression.log`,
`/tmp/turn-review-chat-screen-final.log`, `/tmp/turn-review-analyze-final.log`.
Commits locales con el trailer solicitado, sin push.
