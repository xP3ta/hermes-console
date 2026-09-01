# Hermes Console 1.2.9 — notas de publicación

## Cambios frente a 1.2.8

- Los chats conservan el historial visible durante refreshes solapados,
  reconexiones, paginación y recuperación desde Desktop.
- Al volver a la app después de ejecutar herramientas como búsqueda web, el
  turno se reengancha y la respuesta final se recupera automáticamente.
- `Parar` conserva de forma durable la cancelación sin resucitar respuestas
  canceladas ni ocultar respuestas legítimas.
- La conexión WebSocket tolera mejor la suspensión y reanudación de Android.
- La escucha opcional en segundo plano permanece activa hasta que el usuario la
  desactiva y puede avisar de respuestas, runs, Cron y Kanban.
- Las notificaciones son más resistentes a reinicios, actualizaciones y muerte
  del proceso, manteniendo deduplicación y privacidad.
- Voz, lectura en voz alta, SSH y SFTP conservan sus flujos y servicios
  independientes.

## Mensaje público

Queremos pediros disculpas por los problemas introducidos en Hermes Console
1.2.8. Esa versión no alcanzó el nivel de estabilidad que esperábamos,
especialmente al recuperar chats, reconectar con Gateway y mantener las
notificaciones en segundo plano.

En 1.2.9 hemos trabajado sobre las causas: protegimos el historial frente a
refreshes y reconexiones simultáneos, reforzamos la continuidad de los turnos
entre Desktop y Console, corregimos la recuperación tras usar herramientas o
Parar y rehicimos el comportamiento de las notificaciones persistentes. También
ampliamos las pruebas automáticas y la validación en un dispositivo físico.

Gracias por avisarnos con ejemplos concretos y por vuestra paciencia. Sabemos
que una app de acceso remoto tiene que ser fiable; seguiremos vigilando esta
versión y atendiendo cualquier incidencia con prioridad.

## Google Play — Novedades (español)

Los chats conservan mejor su historial al refrescar, reconectar o continuar
desde Desktop, incluso tras usar herramientas o Parar. La escucha opcional en
segundo plano permanece activa hasta que la desactivas y puede avisarte de
respuestas, runs, Cron y Kanban. También reforzamos WebSocket, Voz, lectura,
SSH y SFTP.

## Google Play — What's new (English)

Chats preserve history across refreshes, reconnects, Desktop handoffs, tools,
and Stop. Optional background listening stays active until you disable it and
can notify you about replies, runs, Cron, and Kanban. WebSocket recovery,
Voice, read-aloud, SSH, and SFTP are also hardened.
