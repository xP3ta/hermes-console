# Spec 060 — Continuidad nativa de sesiones

## Decisión de producto

Hermes Console es otra superficie de la misma sesión Hermes, no un lector móvil ni un cliente que copie conversaciones. Al abrir en Console una sesión iniciada en Desktop, Console debe adjuntarse automáticamente al runtime oficial cuando sea alcanzable, mostrar su trabajo en vivo y permitir continuar sin crear otra sesión. No se modifica Hermes Agent ni Desktop.

Esta especificación sustituye la regla anterior «abrir/leer no adquiere runtime» para sesiones persistidas del Dashboard: abrir una conversación visible autoriza una adhesión no destructiva como viewer mediante el contrato oficial. No autoriza enviar, interrumpir ni tomar control sin una acción explícita del usuario.

## Contrato de autoridad ratificado

A. **Cold open visible en gateway compartido.** Console instala primero la
   suscripción WebSocket y después ejecuta un `session.resume` exacto, no
   creador, sobre el ID durable. La hidratación REST se ejecuta en paralelo y no
   autoriza, retrasa ni sustituye la adhesión viva.
B. **Respuesta válida.** Solo se adopta una respuesta con `created:false`,
   runtime raw no vacío, aliases durable/runtime explícitos y coherentes, y la
   misma conexión, perfil y generaciones capturadas antes del primer `await`.
C. **Attach atómico.** `session.resume` es la autoridad preferida.
   `active_list → activate` es una optimización revocable y nunca la autoridad
   final para adoptar un runtime después de una carrera.
D. **Publicación y reconciliación.** Los eventos del runtime adjunto se publican
   en vivo. REST y live convergen por IDs durables, IDs de evento, epochs y
   límites de turno; ni texto ni tiempo por sí solos deduplican.
E. **Corte anormal.** Se conserva el transcript y se muestra `reconnecting`.
   La recuperación exacta nunca crea, envía, interrumpe ni activa un runtime
   arbitrario. Si upstream no prueba un corte completo, el estado termina en
   `degraded/history-pending`; esa limitación no bloquea el attach nominal sano.
F. **Submit.** Cada envío respeta la exclusión e idempotencia oficial. Ninguna
   adquisición automática reenvía prompts, incluidos los prompts ambiguos que
   estaban en vuelo durante una desconexión.

## Matriz total de estados

| Estado | Evidencia de entrada | Acción automática permitida | Salida |
|---|---|---|---|
| `durableIdle` | Durable exacto, sin turno vivo conocido | subscribe WS → `session.resume` exacto | `liveAttached` si la respuesta B es válida; si el runtime ya terminó, misma sesión durable reanudada sin crear otra |
| `liveAttaching` | Suscripción instalada y resume pendiente | REST ortogonal; ninguna mutación | `liveAttached`, `reconnecting`, `degraded` o `historyOnly` |
| `liveAttached` | Respuesta B válida en gateway compartido | publicar live; reconciliar REST | permanece vivo hasta terminal, retarget o corte |
| `reconnecting` | Corte anormal del transporte actual | connect + subscribe + resume exacto | `liveAttached` solo con nueva autoridad completa; en otro caso `degraded/historyPending` |
| `historyPending` | Transcript conservado, corte upstream incompleto | REST no destructivo; attach exacto acotado | `liveAttached` con prueba completa o `degraded` |
| `degraded` | Gateway distinto, aliases ambiguos o corte no demostrable | conservar historial y diagnóstico | nueva evaluación explícita; nunca continuidad viva falsa |
| `historyOnly` | Durable existe y no hay runtime vivo ni turno activo | resume exacto no creador al abrir/continuar | misma identidad durable; nunca sesión competidora |
| `terminal` | Evento terminal autoritativo del turno | cerrar solo ese turno; conservar sesión | `durableIdle` |
| `retargeted/disposed` | cambió conexión/perfil/durable o murió el dueño | rechazar todo callback previo | sin transición por callbacks stale |

Para cada fila, cualquier callback posterior a un `await` debe volver a validar
socket/canal, conexión, perfil, durable, runtime y generaciones. Un fallo de
recovery nunca envenena una futura adhesión nominal de un transporte sano.

## Historias de usuario

### US1 — Abrir en Console una sesión que trabaja en Desktop (P0)

Como usuario, al abrir en Console una sesión activa en Desktop quiero ver el mismo turno, streaming, herramientas y actividad pública sin recargar ni generar otro runtime.

**Aceptación**
- Console resuelve la identidad por conexión, perfil y `stored_session_id`.
- Console usa `session.resume` con la sesión durable exacta; Hermes adjunta el
  transporte al runtime existente cuando ya está vivo en ese mismo gateway.
- `session.active_list`/`session.activate` se reservan para reactivación de un
  runtime ya vinculado y no son una condición previa susceptible a carreras.
- La adhesión devuelve y conserva `runtime_session_id`; un `bindEpoch` local
  cerca respuestas tardías porque el contrato estable no expone generación.
- Abrir no ejecuta `prompt.submit`, `interrupt` ni crea una conversación alternativa.
- Desktop permanece operativo al conectar o desconectar Console.

### US2 — Continuar desde cualquiera de las superficies (P0)

Como usuario, quiero enviar el siguiente mensaje desde Console o Desktop sin duplicados ni pérdida de identidad.

**Aceptación**
- Un runtime ocupado no se trata como libre por una lectura tardía.
- Antes de drenar una cola tras reconectar se reconcilia `getTurnStatus`.
- Un rechazo busy/ownership conserva texto y adjuntos.
- El siguiente envío aceptado continúa el mismo `stored_session_id`.

### US3 — Observar y dirigir subagentes (P0)

Como usuario, quiero ver que los subagentes siguen trabajando y poder continuar el turno padre aunque uno falle.

**Aceptación**
- Los eventos vivos llegan por WebSocket del runtime adjunto.
- El historial REST conserva `display_metadata` y resultados públicos.
- Un subagente sin resultado persistido termina como `interrupted` o `result_not_received`, nunca eternamente `working` ni genéricamente `unknown` si la interrupción es demostrable.
- El compositor sigue disponible para seguimiento, reintento o continuación.

### US4 — Reconectar desde Android (P1)

Como usuario, quiero volver de segundo plano o de una pérdida de red y recuperar la misma sesión.

**Aceptación**
- Console revalida conexión, perfil, identidad durable, runtime y `bindEpoch`.
- Reutiliza el runtime si sigue vivo y reanuda el durable si terminó.
- REST rellena huecos durables; los eventos tardíos no duplican mensajes.
- Un envío ambiguo no se repite sin reconciliación autoritativa.
- `session.events.since` es evidencia auxiliar local, no una condición del
  happy path ni autoridad suficiente para liberar una proyección tras corte.
- Una prueba completa puede reconciliar transcript, turno, overlay vivo,
  herramientas, subagentes y prompts interactivos. Los dominios no demostrados
  permanecen `history-pending`; nunca se inventa continuidad con un attach
  `omit_messages:true` ni con una identidad de runtime aislada.
- **Límite upstream actual:** Hermes Agent/Desktop no expone cobertura por dominio
  ni un cursor de corte que conecte atómicamente el snapshot con el tail vivo.
  Por tanto, después de un corte ambiguo Console conserva el historial como
  `history-pending/degraded`; no exige reconstrucción perfecta de eventos
  efímeros. Cold-open, transporte ininterrumpido y una adhesión nominal sana no
  dependen de esa maquinaria.
- Un corte de socket en reposo o un fallo transitorio al abrir inicia una única
  recuperación con backoff sobre el durable exacto, sin acción manual.
- Polling REST, ocultar la ruta, segundo plano y cancelar una lectura tardía no
  revocan esa recuperación mientras el mismo `ActiveChat` siga retenido.
- Un historial durable vacío, un fallo de REST o una violación del recuento no
  cancelan la demanda viva: historial y adhesión se resuelven como ejes
  independientes.
- Timeout JSON-RPC, pérdida del socket y transporte del ticket WebSocket se
  tipan sin texto privado y reintentan únicamente la adhesión no mutante.

### Matriz de autoridad de adhesión

Una respuesta de recuperación solo puede vincularse si siguen vigentes: misma
instancia no destruida, gateway, conexión, perfil, lineage, durable exacto,
generación de recuperación, `turnEpoch`, `bindEpoch`, `sessionEpoch` y ausencia
de otro runtime ya adoptado. El snapshot debe ser no creador, identificar
explícitamente el durable solicitado, tener aliases coherentes, runtime no vacío
y lineage compatible.

Invalidan la recuperación: destrucción real del `ActiveChat`, cambio de
gateway/conexión/perfil/durable/lineage, transición de turno, adopción o relevo
de runtime, generación posterior y respuesta terminal o de identidad inválida.
Un cierre terminal incrementa además la generación y cerca cualquier vuelo ya
iniciado. Una carga visible solo puede reabrir la evaluación después de que no
quede ningún fence durable de compresión pendiente.
No la invalidan: lectura REST, `passiveOnly`, visibilidad, segundo plano,
desmontaje de pantalla con servicio retenido ni actualización del transcript.
Ninguna recuperación automática puede crear, activar, enviar, reenviar,
interrumpir ni iniciar un run REST.

### Política cerrada de errores

La adhesión clasifica cada fallo como `retryTransient`, `stopTerminal` o
`stopAmbiguous`; no comparte esta política con submit, cancelación, rewind ni
recuperación de turnos. Solo son transitorios los fallos tipados de transporte,
timeout/cierre, HTTP 408/429/5xx, autenticación temporal y razones RPC
documentadas como temporales. Ausencia durable, auth 401/403, protocolo
malformado, snapshot no confiable y errores desconocidos paran cerrados. La
clasificación no inspecciona bodies, credenciales ni mensajes remotos; el único
shim textual es la forma legacy exacta del timeout local de `session.resume` y
queda limitado a esta operación no mutante.
`WebSocketChannelException` se decide por su causa tipada: transporte y
408/429/5xx reintentan; 401/403/404 y otros upgrades deterministas terminan;
una causa desconocida falla cerrada. Respuestas map-shaped con contrato
JSON-RPC inválido y eventos con `params` o `seq` malformados retiran el canal
completo y fallan los RPC pendientes con evidencia saneada.

### US5 — Degradación honesta (P1)

Como usuario, quiero saber cuándo la ejecución está en otro backend inaccesible sin que Console finja continuidad.

**Aceptación**
- Compartir `state.db` no se interpreta como compartir runtime.
- Si el runtime pertenece a un gateway aislado no alcanzable, Console muestra historial y estado `differentBackend/readOnly`.
- Console no crea silenciosamente un runtime competidor.
- Cuando el lease/runtime queda libre puede reanudar el mismo durable.

## Invariantes

1. Identidad: `connection_id + profile + stored_session_id`.
2. `runtime_session_id` y epochs locales son vínculos efímeros, no identidad durable.
3. Dashboard REST es autoridad de historial persistido; WebSocket es autoridad de actividad viva.
4. Abrir una sesión puede adjuntar un viewer, pero nunca equivale a enviar o interrumpir.
5. Un PID, registro local o timestamp no demuestra propiedad ni trabajo.
6. Ningún mensaje privado de herramienta, razonamiento interno, token o credencial se proyecta en UI o fixtures.
7. Sin cambios, forks ni capacidades WIP de Hermes Agent/Desktop.
8. Todo frame WS autoritativo es texto JSON duplicate-aware y pertenece a una
   unión disjunta Response/Event/Notification antes de consultar pending.
9. Identidades, discriminadores y epochs se comparan raw-exactos; no se aplica
   `trim`, coerción ni ordenamiento reparador.
10. `sudo.respond` y `secret.respond` descartan mensaje, data y causa remotos;
    solo exponen copy fijo, código seguro y categorías locales cerradas.

## Fuera de alcance

- Publicar, firmar o instalar una release sin autorización separada.
- Reiniciar Hermes o cambiar su upstream.
- Editar, parchear, configurar o reiniciar Hermes Desktop, Hermes Agent,
  servicios, sesiones o dispositivos reales. El único write-set permitido es
  el repositorio de Hermes Console que contiene este spec (`<console-root>`); las
  rutas se expresan relativas a esa raíz y no dependen del checkout local.
- Depender de cambios locales upstream, URLs, perfiles, rutas, IDs o topologías
  xPeta hardcodeados. La solución debe interoperar con cualquier Hermes oficial
  compatible mediante sus contratos publicados.
- Hacer accesible desde otro dispositivo un backend aislado ligado a loopback.
- Inventar resultados de subagentes o razonamiento no persistido.

## Puerta de aceptación final

Una build QA instalada in-place en el Pixel debe completar Desktop→Console→Desktop con streaming, herramientas y al menos un subagente; debe sobrevivir a desconexión de una superficie y reconexión móvil sin duplicar mensajes. La instalación y cualquier cambio de configuración requieren autorización del propietario.

Antes de declarar candidata se ejecuta un gate de write-set: todos los archivos
creados o modificados por Spec 060 deben residir bajo el árbol mutable de
Console indicado, y el diff funcional no puede contener endpoints, perfiles,
rutas, IDs ni supuestos de topología específicos de xPeta. Fixtures de gateway
compatibles y sandboxes aislados sí están permitidos; no cuentan como evidencia
de haber modificado upstream.
