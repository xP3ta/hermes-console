# Avisos cron: política local mínima

La app usa Automático por defecto: todos los fallos y como máximo un éxito
por conexión/perfil/job cada 60 minutos, desde la primera reserva de éxito.
Todos elimina ese límite; Solo fallos y Apagado restringen la entrega. Los
silenciamientos previos y las políticas por job siguen vigentes: `all` hereda
el modo global. Un opt-out antiguo explícito se lee como Apagado; la ausencia
de preferencias empieza en Automático. La migración es de lectura y no borra
ni reescribe los ajustes antiguos.

`cronFinished` reserva en una base SQLite (esquema 3). Una transacción
registra el mensaje y, solo para éxitos en Automático, la ventana y su
contador. Sobrevive a reinicios y serializa motores Flutter distintos. Los
fallos no gastan ese cupo y solo se deduplican por mensaje; cada fallo lleva
una clave de bandeja distinta, separada de los éxitos. `recent` se conserva
únicamente para las demás familias. Los identificadores de estas dos tablas se
guardan como hashes; los mensajes tienen retención de 30 días.

Limitaciones deliberadas de esta versión:

- Una reserva cuenta como intento. Un cierre entre reserva y presentación
  puede perder el aviso, pero nunca abrir una segunda plaza de éxito. El
  sistema operativo puede impedir la presentación por permisos o canales.
- Con la app cerrada los avisos cron solo llegan si el usuario activó la
  escucha en segundo plano (opt-in de 1.3.1). No se ha añadido «Importante».


## Respuestas a turnos internos

El mismo selector controla también los éxitos `turn_done` iniciados por una
fila de usuario editorial `async_delegation_complete`, `auto_continue` o
`process_complete`: solo Todos permite esos avisos rutinarios. No se añade un
interruptor ni se alteran los avisos de respuestas a usuarios reales. El texto
bajo el selector explica esta extensión. Fallos y peticiones de atención
mantienen la entrega habitual, sujeta al ajuste general, permisos y ajustes de
respuestas; aprobación y pregunta conservan sus tipos de aviso independientes.

Se reutiliza el export HTTP ya leído (sin otra consulta), vinculando la última
respuesta al usuario inmediatamente anterior. `effectiveUserDisplayKind`
reconoce también carriers canónicos legacy. El origen desconocido, el export
comprimido, la lectura fallida o un contexto antiguo sin esa evidencia mantienen
el comportamiento anterior: avisar. La clasificación se queda en memoria.

Una pregunta en el texto público de la respuesta conserva el aviso, incluso al
final de un informe largo; se reconoce por `?` o `？`, excluyendo bloques de
código y razonamiento privado. Peticiones implícitas sin esos signos dependen
del aviso específico de aprobación/pregunta. Fallos estructurados del turno o
`end_reason` de error conservan el aviso de fallo.


Validación local: tanda cron de 196 tests y tanda de ampliación de 126 tests,
ambas con `timeout 900 flutter test --no-pub -j 1`; incluyen regresiones y
trinquetes, sin elevarlos. `dart analyze --fatal-infos lib test` limpio y
`:app:compileFullDebugKotlin` correcto.
