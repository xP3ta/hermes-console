# Tareas — Spec 061

## S0 — Especificación

- [x] Investigar el protocolo real del backend (`methods_groups.py`) — sin
      rol de miembro, `promote`/`demote` son de gateway, no de miembro.
- [x] Investigar el mecanismo real de Desktop (`group-chat.ts`) — client-side,
      sync vía `ui_meta`, sin protocolo `groups.*`, sin rol de miembro.
- [x] Confirmar que ningún `MissionRoom`/sala local tiene respaldo en
      ninguna de las dos fuentes anteriores.
- [x] Confirmar que Desktop no tiene tablero de tareas dentro de la sala
      (`grep -i "kanban\|task.*board"` sin resultados en `group-chat-view.tsx`
      / `group-chat.ts`).

## S1 — Detener creación de salas locales (P0)

- [x] Quitar el fallback de sala local del create-orbit del dock de Bots
      (`_botDockCreateOrbits`).
- [ ] Grep `createLocalRoom` y arreglar cada call site restante (cabecera de
      sección, empty state, cualquier otro) para que apunte solo a
      `_createHostedRoom` gated por capacidad, o desaparezca la acción.
- [ ] Confirmar que ningún botón de creación de sala puede llegar a
      `_editRoom()` en su rol de creación.

## S2 — Eliminar la sala local (P0)

- [ ] Grep exhaustivo de `MissionRoom`/`mission_room.dart` en `lib/` y
      `test/` antes de tocar nada.
- [ ] Eliminar `_MissionRoomDetailScreen` y su ruta si nada más la usa.
- [ ] Eliminar la sección "Salas locales" de la pestaña Rooms.
- [ ] Eliminar `lib/core/models/mission_room.dart` y su store local.
- [ ] Eliminar la sección "Equipo" añadida a la sala local la sesión
      anterior (código huérfano tras lo de arriba).
- [ ] En `chat_screen.dart`: confirmar por grep si `missionRoom`/
      `missionRoomProfiles`/`missionAvatarCache`/`_showMissionRoomMembers`/
      `_openMemberBotChat` quedan sin ningún caller; si es así, eliminarlos.

## S3 — Quitar el tablero de tareas de AMBAS salas (P0)

- [ ] Grep repo-wide de `MissionRoomWorkProjection`/`MissionRoomWorkProjector`
      para confirmar que solo lo usan las pantallas de sala antes de borrar
      el archivo de modelo.
- [ ] Eliminar `_RoomTaskLine` y toda sección "Tareas de la sala" de la vista
      de sala compartida (`_HostedRoomWorkspace`) y de cualquier resumen de
      lista de salas.
- [ ] Eliminar `lib/core/models/mission_room_projection.dart` y su test si
      queda sin otro consumidor.

## S4 — Renombrado "sala compartida" → "sala" (P1)

- [ ] Grep case-insensitive de `compartida`/`shared` en las clases de copy
      de salas; cambiar el texto devuelto, no necesariamente el nombre del
      getter Dart.
- [ ] Confirmar si alguna cadena tocada es generada por `.arb`/codegen antes
      de asumir que es un getter inline.

## S5 — Verificación (P0, no negociable)

- [ ] `flutter analyze` en cada archivo tocado (nunca repo-wide).
- [ ] Arreglar/eliminar cada test huérfano encontrado por los greps de S2/S3
      en vez de dejarlo roto.
- [ ] Ejecutar los archivos de test tocados o afectados y reportar
      pass/fail por archivo.
- [ ] `git status`/`git diff --stat` final para verificación independiente.
