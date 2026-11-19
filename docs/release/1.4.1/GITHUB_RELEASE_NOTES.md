## Console 1.4.1

A corrective release on top of 1.4.0, with a lighter chat look and a new Usage
screen. Console still talks only to the Hermes Dashboard.

**New look and Usage**

- Lighter icons across the app; the reply sits in a soft bubble and, when a
  turn ends, a line at its foot says how long it worked and how many tools it
  used. The composer is more compact.
- Chat settings › Usage shows the session's context, model and tokens. **See
  all usage** opens cost, tokens and plan limits by day, provider and model
  (24 h, 7, 30 or 90 days).
- Permissions moved from the composer to Chat settings. In the model sheet,
  Think and Fast are small switches and the plan limits moved to Usage.
- A face made in Studio for a profile is saved with the profile and shows on
  your other devices with Console.

**Files, diagrams and 3D in the chat**

- A file the agent delivers previews itself in the reply: web pages and SVG
  drawn, Markdown formatted, PDFs with their first page.
- A `mermaid` code block is drawn as a diagram, and `.mmd` files and
  `.glb`/`.gltf` 3D models (up to 24 MB) show in the chat and open in the
  viewer. They are drawn on the device, with no network access.
- A cited PDF opens inside Console, page by page.
- Markdown links to files on the server open the file; cited `.html` and
  `.svg` files open rendered instead of as source text.

**Chat recovery**

- After returning to the app or a network cut, paragraphs and tool steps
  already shown no longer disappear, and the reply is not duplicated when the
  stored turn arrives.
- A turn that ended while the app was away closes by itself; a turn started
  from another device shows up live.
- With Hermes 0.23.1 or later, a reply chunk the server sends twice is shown
  once.

**Sending and queue**

- A message whose delivery was not confirmed is not resent automatically; it
  is shown as «delivery unknown».
- The queue waits while the session is busy elsewhere and drains when the
  server reports it idle.

**Sub-agents**

- Sub-agents and background processes keep showing as running when you
  return; they are no longer shown as «Stopped» while they work.

**Rooms**

- One room the app cannot read no longer empties the list or hides
  **New ▸ room**; a notice says how many could not be loaded, with **Retry**.
- A room that fails for a moment keeps its last copy, marked as not updated.
- Messages with files sent from Hermes Desktop show the file names (open them
  in Desktop; Console does not download them).
- Rooms in round 3 or later, members without an explicit target and member
  rows with extra fields are read; Bot Mode and room alerts skip only the room
  that fails.

**Projects**

- Every project request carries the selected profile; a project opened in one
  profile keeps acting, and opening chats, in that profile.
- Hiding an automatic folder hides it only in the current profile.
- A folder whose chats Hermes counts but does not list (automated runs,
  sub-agent or empty sessions) says so instead of "No chats yet".

**Connection**

- Home re-checks by itself after a failed check (1, 2, 4, 8 s, then every
  15 s), right away when the chat connection comes up, and goes offline as
  soon as Android reports the network lost. With the VPN off it no longer
  stays «online» on a sign-in it could not renew. With a password-protected
  Dashboard, the chat list can take up to a minute longer to refresh after
  an outage.

**HTML preview**

- A page whose script declares its own `open` function no longer stays blank
  in the viewer; pop-ups stay blocked.

**Voice**

- Downloading the on-device dictation model works again (#227).

**Text size and menu**

- New text size control in Settings › Appearance › Look & Feel (85–150 %),
  combined with Android's text size.
- The menu opens from its button. Opening it by swiping from the left edge
  is now a switch in Look & Feel, off by default (also after the update), so
  the edge is left to Android's Back gesture and to wide tables.
- Confirmation dialogs, the chat composer and the empty Home fit large text.
  At the largest text size the menu shows «Console» whole, and Projects
  scrolls its loading message and empty pane on short landscape windows.

Known limits: the Home recovery was checked with an emulator network cut, not
with the Tailscale Android app; room files cannot be downloaded from Console;
Studio faces are shown by Console only; the line at the foot of a turn loses
the duration when the chat is reloaded; 3D models only as glTF.

---

## Console 1.4.1 (español)

Versión correctiva sobre la 1.4.0, con un aspecto más ligero del chat y una
pantalla nueva de Uso. Console sigue hablando solo con el Dashboard de Hermes.

**Nuevo aspecto y Uso**

- Iconos más ligeros en toda la app; la respuesta va en una burbuja suave y,
  al terminar un turno, una línea al pie dice cuánto trabajó y cuántas
  herramientas usó. La caja de texto es más compacta.
- Ajustes del chat › Uso muestra el contexto, el modelo y los tokens de la
  sesión. **Ver todo el uso** abre coste, tokens y límites del plan por día,
  proveedor y modelo (24 h, 7, 30 o 90 días).
- Los permisos pasan de la caja de texto a los ajustes del chat. En la hoja
  de modelo, Razonar y Rápido son interruptores pequeños y los límites del
  plan pasan a Uso.
- La cara creada en Studio para un perfil se guarda con el perfil y aparece
  en tus otros dispositivos con Console.

**Archivos, diagramas y 3D en el chat**

- Un archivo que entrega el agente se previsualiza en la respuesta: páginas
  web y SVG dibujados, Markdown con formato, PDF con su primera página.
- Un bloque de código `mermaid` se dibuja como diagrama, y los archivos
  `.mmd` y los modelos 3D `.glb`/`.gltf` (hasta 24 MB) se ven en el chat y se
  abren en el visor. Se dibujan en el teléfono, sin acceso a la red.
- Un PDF citado se abre dentro de Console, página a página.
- Los enlaces Markdown a archivos del servidor abren el archivo; los `.html`
  y `.svg` citados se abren dibujados en vez de como texto.

**Recuperación del chat**

- Al volver a la app o tras un corte de red ya no desaparecen párrafos ni
  pasos ya mostrados, y la respuesta no se duplica cuando llega el turno
  guardado.
- Un turno que terminó con la app fuera se cierra solo; un turno empezado
  desde otro dispositivo aparece en vivo.
- Con Hermes 0.23.1 o posterior, un fragmento que el servidor envía dos veces
  se muestra una vez.

**Envío y cola**

- Un mensaje cuyo envío quedó sin confirmar no se reenvía solo; se muestra
  como «entrega desconocida».
- La cola espera mientras la sesión está ocupada en otro sitio y sale cuando
  el servidor la da por libre.

**Subagentes**

- Los subagentes y procesos en segundo plano siguen mostrándose en marcha al
  volver; ya no aparecen como «Detenido» mientras trabajan.

**Salas**

- Una sala que la app no puede leer ya no vacía la lista ni esconde
  **Nuevo ▸ sala**; un aviso dice cuántas no se cargaron, con **Reintentar**.
- Una sala que falla un momento conserva su última copia.
- Los mensajes con archivos enviados desde Hermes Desktop muestran sus
  nombres (se abren en Desktop; Console no los descarga).
- Se leen las salas de ronda 3 o posterior, los miembros sin destino
  explícito y las filas con campos extra.

**Proyectos**

- Proyectos sigue el perfil elegido; un proyecto abierto en un perfil sigue
  actuando en él.
- Una carpeta cuyos chats Hermes cuenta pero no lista lo dice, en vez de
  «Aún no hay chats».

**Conexión**

- Inicio se recomprueba solo tras un fallo y pasa a sin conexión en cuanto
  Android avisa de que no hay red.

**Vista previa de HTML**

- Una página cuyo script declara su propia función `open` ya no se queda en
  blanco en el visor; las ventanas emergentes siguen bloqueadas.

**Voz**

- Vuelve a funcionar la descarga del modelo de dictado en el teléfono (#227).

**Tamaño de texto y menú**

- Nuevo control de tamaño de texto en Ajustes › Apariencia › Look & Feel
  (85–150 %), combinado con el de Android.
- Abrir el menú deslizando desde el borde izquierdo pasa a ser un
  interruptor, apagado por defecto.
- Los diálogos de confirmación y la caja de texto caben con letra grande.

Límites conocidos: la recuperación de Inicio se comprobó con un corte de red
en emulador, no con la app de Tailscale; los archivos de las salas no se
pueden descargar desde Console; las caras de Studio solo las muestra Console;
la línea al pie de un turno pierde la duración al recargar el chat; modelos
3D solo en glTF.
