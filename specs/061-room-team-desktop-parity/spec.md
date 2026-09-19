# Spec 061 — Una sola sala, sin invenciones de Console

## Decisión de producto

Hermes Console debe sentirse como Hermes Desktop en el móvil: nativo, no un
cliente aparte con sus propios conceptos de producto. Hoy Console tiene DOS
tipos de "sala" que aparentan ser la misma cosa y no lo son. Esta spec elimina
esa duplicidad: queda **una sola sala**, con el mismo modelo de interacción de
equipo (plano, sin coordinador, sin tablero de tareas) verificado tanto contra
el backend real de Hermes Agent como contra la propia Desktop.

Esta spec sustituye el trabajo hecho en la sesión anterior que añadió una
sección "Equipo" a las dos salas por igual — ese trabajo fue correcto para la
sala compartida y debe revertirse para la sala local, que se elimina.

## Hallazgo de investigación (por qué esto no es solo "copiar Desktop")

Se investigaron tres fuentes, no dos, antes de decidir el comportamiento
objetivo:

1. **El protocolo real del backend** (`tui_gateway/methods_groups.py` en
   Hermes Agent) — una familia de RPC `groups.*` genuina: `capabilities`,
   `list`, `create`, `state`, `send`, `rename`, `log`, `disband`, `replicate`,
   `replica_state`, `promote`, `demote`, `stop`, `retry`, `approve`,
   `peer.invite/revoke/register`. Es real, está implementada, y soporta
   réplica multi-gateway y autoridad fenced. `groups.promote`/`groups.demote`
   son sobre qué **gateway** es la autoridad de la sala tras un fallo, nunca
   sobre el rol de un **miembro**. No existe ningún campo de rol/coordinador
   en `create_room` ni en el modelo de miembro del backend.
2. **Hermes Desktop** (`apps/desktop/src/plugins/hermes-bots/group-chat.ts`)
   — sorprendentemente, Desktop NO usa el protocolo `groups.*` de arriba. Su
   "group chat" es un mecanismo propio, más antiguo: cada bot mantiene su
   propia sesión, Desktop orquesta el turno de palabra client-side
   (`group-rounds.ts`/`group-turns.ts`) y sincroniza el estado como un blob
   JSON dentro de `ui_meta` del perfil `default` (vía `profiles.list`), no
   como una entidad de servidor con autoridad propia. Tampoco tiene ningún
   campo de rol de coordinador — es un conjunto plano de miembros.
3. **Console hoy** — `HostedGroupRoom` (`lib/core/models/hosted_groups.dart`)
   ya habla el protocolo real del punto 1, probablemente por delante de lo
   que la propia Desktop ha adoptado todavía. `MissionRoom`
   (`lib/core/models/mission_room.dart`) es una invención exclusiva de
   Console sin sesión de servidor propia: "hablar con el coordinador" abre un
   `ChatScreen` de un solo bot corriente; el "equipo" es solo una lista
   recordada de colaboradores habituales de ESE bot, nunca una conversación
   compartida real.

**Conclusión:** la sala compartida de Console no imita mal a Desktop — usa
infraestructura de servidor real y más moderna. Lo único que hay que corregir
es (a) eliminar la sala local por ser una ficción sin ninguna de las tres
fuentes reales detrás, y (b) alinear la UX de equipo con lo único en lo que
las tres fuentes coinciden: **ningún rol de coordinador de miembro, ningún
tablero de tareas dentro de la sala**.

## Contrato

A. **Una sola sala.** Toda entidad "sala" en Console es un
   `HostedGroupRoom` respaldado por `groups.*`. No existe ninguna otra
   entidad de producto llamada sala.
B. **Sin rol de miembro.** Ninguna sala expone un coordinador, manager o
   cualquier jerarquía entre miembros. Todos los miembros se presentan al
   mismo nivel.
C. **Sin tablero de tareas dentro de la sala.** La vista de una sala no
   proyecta ni enlaza tareas de Kanban. Kanban sigue existiendo como función
   independiente del resto de la app; solo desaparece su enlace DESDE la
   sala.
D. **Creación fail-closed.** Crear una sala requiere la capacidad
   `groups.create` disponible en la conexión activa. Sin esa capacidad, la
   acción de crear se deshabilita con una explicación — nunca se sustituye
   por un simulacro local.
E. **Nomenclatura.** El texto visible dice "sala"/"salas", nunca "sala
   compartida"/"salas compartidas" — ya no hay una segunda sala de la que
   distinguirse.
F. **Datos existentes, no destructivos.** Los datos de salas locales que ya
   existan en el dispositivo de un usuario no se borran activamente; el
   código simplemente deja de leerlos/mostrarlos. No hay migración
   automática a sala compartida (ver Preguntas abiertas).

## Historias de usuario

### US1 — Ver quién está en una sala (P0)

Como usuario, al abrir una sala quiero ver a todos sus miembros con foto,
nombre y estado en vivo, sin jerarquía ni etiqueta de "coordinador".

**Aceptación**
- Cada miembro se presenta con el mismo peso visual; ninguno lleva un badge
  de rol.
- Un miembro resuelto a un perfil local muestra avatar real y estado
  derivado (`MissionAgent`); un miembro federado sin perfil local muestra
  avatar neutro y no es tocable.
- Tocar un miembro local abre su ficha de agente (Chat/Editar/Rutinas/
  Tareas/Memoria/Skills) — igual que en Bots.

### US2 — Crear una sala (P0)

Como usuario, quiero crear una sala real de equipo, nunca un simulacro.

**Aceptación**
- El botón de crear sala llama a `groups.create` cuando la capacidad está
  disponible.
- Sin esa capacidad, el botón se deshabilita con un mensaje que explica por
  qué (no crea nada localmente).

### US3 — La sala no muestra tareas (P0)

Como usuario, al entrar en una sala no quiero ver un tablero de tareas
vinculado — eso no existe en el resto del ecosistema Hermes.

**Aceptación**
- La vista de sala no contiene ninguna sección de tareas/Kanban.
- Kanban/Tareas como pantalla independiente de la app permanece intacta.

## Preguntas abiertas (llevadas al maintainer, no adivinadas)

1. ¿Qué botones/entradas de creación existentes deben quedar simplemente
   deshabilitados cuando `groups.create` no está disponible, y cuáles deben
   directamente ocultarse en vez de mostrarse grises? (Afecta a UX, no a
   arquitectura — decisión de gusto.)
2. ~~Las salas locales que ya tenga un usuario...~~ **Resuelto por el
   maintainer:** no hay que preservar nada. Se puede eliminar el store local
   de salas por completo; cualquier dato de sala local existente en un
   dispositivo simplemente deja de ser accesible.
3. `MissionRoomWorkProjection`/`MissionRoomWorkProjector` — antes de
   borrarlos, confirmar por grep que ningún otro punto de la app (fuera de
   las pantallas de sala) los usa. Si algo más los usa, esta spec no cubre
   ese caso y debe volver a revisarse.
