# Hermes Console 1.2.11 — notas de publicación

Build candidata: `1.2.11+9009` (2026-09-19). Validación física pendiente en Pixel 9 Pro
antes de cualquier publicación; nada se sube sin ese visto bueno del propietario.

## Lo más importante frente a 1.2.10

- **Modo Bot completo.** Secciones de bots (crear, renombrar, borrar, mover, deshacer),
  crear bots desde un clon, un perfil nuevo o uno vacío (habilidades, herramientas,
  MCP, modelo y SOUL), crear en otra conexión guardada, editor avanzado, duplicado
  completo, caras geométricas y blob, avatares generados con IA, roster entre
  conexiones con caché acotada y salas nativas entre máquinas (RoomLink).
  Lo que Desktop guarda solo en almacenamiento local del plugin (orden de secciones
  vacías, orden/fijado de salas, mensajes por mensajero, backends calientes) no tiene
  equivalente en el servidor y no se simula.
- **@menciones entre bots** con paleta de autocompletado (nombres y alias), destinatarios
  de sala, presencia por miembro y píldora de resumen de sala.
- **El historial de los chats de bots ya no da el error 401.** Se carga por el mismo
  WebSocket autenticado que usa Desktop (`session.history`) en vez de la clave REST
  por perfil; REST queda como respaldo.
- **Salas compartidas:** el envío vuelve a estar habilitado, se reintenta la
  comprobación del driver mientras arranca el worker del servidor, la sala abierta se
  refresca sola y `@all`/`@everyone` salen en el autocompletado.
- **Un corte de socket ya no esconde una respuesta terminada** (#38 y #40).
- Dock v2 ampliado a Cron/Tareas/Herramientas, drawer en tres zonas, Tareas en Lista o
  Tablero, superficies planas y flotantes, Bot Chat editable, silencio de notificaciones
  por elemento y áreas táctiles de 44 dp.
- Unos 50 textos que estaban fijos en un solo idioma pasan a los recursos en español e
  inglés, y las transiciones entre pantallas pierden el fundido de página completa.

## Fuera de esta versión

- Borrador del composer que se pierde al salir del chat (#37) y la voz poco fiable tras
  la primera grabación (#39): registrados, pendientes de la siguiente versión.

## Agradecimientos

Gracias a @josephsellers por #38 y #40, a @Akuyumu por el reporte #37 y a @jphccfc por
el reporte #39.

## Puertas de publicación

- Firma y compilación de los artefactos `full` (APK) y `play` (AAB) con el procedimiento
  privado del propietario (`tool/release/double_build.sh`); nada sensible entra en el repo.
- `gitleaks` y revisión de rutas/IPs/tokens sobre el commit exacto antes de publicar.
