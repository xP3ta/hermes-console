# Plan técnico — Spec 061

## Contratos upstream utilizados

- `groups.create` / `groups.list` / `groups.state` / `groups.send` /
  `groups.rename` / `groups.disband` / `groups.log` — ya implementados en
  `tui_gateway/methods_groups.py` de Hermes Agent, ya consumidos por
  `lib/core/services/mission_control_repository.dart` a través de
  `MissionHostedGroupsDataSource`. No se necesita ningún RPC nuevo para esta
  spec — es una limpieza del lado del cliente.
- No se toca Hermes Agent ni Hermes Desktop.

## Qué se elimina

- `lib/core/models/mission_room.dart` (modelo `MissionRoom` completo) y su
  store local (buscar la clase de store real por grep, no asumir el nombre)
  una vez nada la referencie.
- Toda entrada de creación de sala local: `_editRoom()` en su rol de
  CREACIÓN (si también edita membresía de otra cosa, conservar solo esa
  parte), los call sites de `copy.createLocalRoom`, el fallback del
  create-orbit del dock (ya aplicado en `_botDockCreateOrbits`).
- La sección de lista "Salas locales" en la pestaña Rooms (`mission-local-
  rooms`, `mission-rooms`, `copy.localRoomsExplanation`).
- `_MissionRoomDetailScreen` y su ruta, si nada más la usa tras retirar
  `MissionRoom`.
- La sección "Equipo" que la sesión anterior añadió específicamente a la
  sala local (código muerto tras retirar `MissionRoom`).
- `MissionRoomWorkProjection` / `MissionRoomWorkProjector`
  (`lib/core/models/mission_room_projection.dart`), `_RoomTaskLine`, y toda
  UI de "Tareas de la sala" en AMBOS tipos de sala (la spec aplica también a
  la sala compartida que sobrevive — Desktop tampoco tiene tablero ahí).
- En `chat_screen.dart`: los parámetros `missionRoom` / `missionRoomProfiles`
  / `missionAvatarCache` y `_showMissionRoomMembers` / `_openMemberBotChat`,
  SOLO si un grep confirma que ningún `ChatScreen(...)` los sigue
  construyendo tras retirar `MissionRoom` (las salas compartidas usan su
  propio `_HostedRoomWorkspace`, no `ChatScreen`).

## Qué se conserva intacto

- `HostedGroupRoom`, `_HostedRoomWorkspace`, la sección "Equipo" ya construida
  para salas compartidas esta sesión (con `RoomTeamRow`), el widget
  compartido `room_team_row.dart`, todo el mecanismo de conversación/log/
  disband/rename/stop de la sala compartida.
- Kanban/Tareas como pantalla independiente de la app.

## Renombrado

Quitar el calificador "compartida"/"shared" del texto visible en
`mission_control_copy.dart` y las clases de copy locales de
`mission_control_screen.dart` (`_RoomsAreaCopy` etc.). Verificar `.arb` solo
si alguna de estas cadenas resulta estar generada en vez de ser un getter
inline (la convención de esta noche ha sido getters inline; confirmar antes
de tocar codegen).

## Orden de trabajo

1. Confirmar con grep exhaustivo cada referencia a `MissionRoom`,
   `mission_room.dart`, `_editRoom`, `createLocalRoom`, `roomWork`,
   `linkedTasks`, `_RoomTaskLine`, `MissionRoomWorkProjection`,
   `mission-local-rooms`, `managerProfile`, `roomCoordinatorShort`,
   `missionRoom` (en `chat_screen.dart`) antes de borrar nada.
2. Eliminar en orden: UI que consume → modelo/proyección → tests que
   quedaron huérfanos. Nunca al revés (dejaría errores de compilación a
   medio camino más difíciles de rastrear).
3. Renombrar copy.
4. Verificar con `flutter analyze` (nunca repo-wide) y los tests afectados
   tras cada paso, no solo al final.
