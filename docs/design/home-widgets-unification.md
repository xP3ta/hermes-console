# Inicio: el lenguaje del lanzador en widgets vivos

## Diferencias comprobadas

Comparado el tablero con `launcher_widget_{palette,text,geometry,words,identity}`
y las maquetas aprobadas de app móvil/Fold (Console claro/oscuro y Medianoche):

- Inicio calculaba otra paleta (`SoftPalette`), con tintas y estados
  desaturados y rotación del acento según el tipo. El lanzador usa la tinta,
  el estado y un único acento del tema.
- Las tarjetas heredaban el radio variable de `HermesCard`, con padding
  14×12; fuera hay un radio de 28 y margen interior de 16 dp.
- Cabeceras, filas, títulos y cifras tenían estilos casi iguales pero
  duplicados: fila de 14 frente a 15 sp; cifra de 34 frente a 44 sp;
  alturas y tracking distintos. La nota de cabecera heredaba otra familia.
- Cron imponía HH:mm con cero inicial y redondeaba horas: «en 5 h»
  donde fuera dice «en 4 h 56 min». No respetaba la selección 12/24 h.
- Tareas pequeña con trabajo en marcha carecía de la cifra principal;
  predominaba el título de la primera tarea. El estado pendiente sí tenía cifra.
- Las cifras podían desvanecerse por la derecha. Ahora se miden y usan
  un tamaño compartido menor; la unidad puede bajar de línea o ceder espacio.
- Caras: ya se usaba `LivingBotFace`, que llama a `ProfileIdentityResolver`.
  No era necesario sustituirlo por imágenes. Los nombres se componían aparte.
- `home_board_tiles_classic.dart` está activo: Bot, Chat fijado, Límites,
  Servidor y Hoy. No existe selector de tablero clásico; los temas Classic
  siguen disponibles en Ajustes. No se elimina código activo.

## Implementación por tile

- Todos: adaptador `HomePalette` sobre `LauncherWidgetPalette`, roles `LwType`,
  geometría `LwGrid`, tipografía del tema y líneas medidas con `TextScaler`.
  Se conserva el material Cristal Completo nativo y la página propia de cada
  tema. Las hojas usan la superficie compuesta **opaca**.
- Ahora: petición destacada, detalle secundario y cara de tamaño compartido;
  variante compacta para conservar aprobación/rechazo en filas bajas.
- Chats / Chat fijado: filas de 15 sp, secundarios de 13, tiempos tabulares
  de 12; cara de lista compartida y navegación existente.
- Bots / Bot fijado: misma tinta de estado/acento y tamaños compartidos en
  el bot fijado; identidad viva y selección de perfil conservadas.
- Cron: cifra de 44 sp, tamaños menores completos si no cabe y calendario
  `LwWords` (12/24 h y minutos exactos).
- Tareas: cifra y unidad «en curso», título que abre la tarea exacta,
  pendientes y barra; listas grandes conservan su contenido y destinos.
- Salas: misma jerarquía de filas, caras vivas, contadores y estado.
- Hoy: cifra de 44 sp y unidad adaptativa; datos reales y destino conservados.
- Servidor: título del rol compartido y estados del tema; conserva prioridad
  del socket frente al resultado REST.
- Límites: nueva paleta y roles comunes; porcentajes y proveedores conservados.

`LwType.style` genera también el estilo del raster sin cambiar sus propiedades:
fuente, fallback, peso, altura, tracking, cifras y escalado son equivalentes.
`lwProfileName` acepta el perfil ya leído por Inicio sin consultar otra conexión.
No se añaden dependencias, claves ARB, lecturas de red ni temporizadores.

## Validación y límites

Las pruebas nuevas comparan paleta/roles/geometría con el lanzador, comprueban
cifras completas a 1.0/1.3/2.0 en 320/360/412/600/840 dp y temas
Console/Medianoche claros/oscuros, calendario 12/24 h y aprobación en fila baja.
La matriz existente cubre además todas las clases de tile, estados, idiomas,
anchos de Fold/tablet y datos hostiles; se ejecuta sola al final.

No se regeneran goldens. Cambia la apariencia de las capturas de Inicio
(tarjetas, textos, cifras y distribución del contenido); el raster del
lanzador debe conservar sus goldens. Los títulos de datos largos mantienen
elipsis; datos secundarios completos se omiten cuando no caben.
Pendiente verificación en dispositivo físico, launchers OEM y TalkBack real.

Resultado de validación local (2026-11-03):

- `flutter pub get --offline`: correcto; sin cambios de dependencias.
- `dart analyze --fatal-infos lib test`: limpio.
- Suite `test/home/*` (matriz separada), identidad, legibilidad y trinquetes:
  ejecutada; los fallos iniciales se corrigieron y se repitieron los archivos
  afectados. Última repetición de tiles + contrato compartido: **81/81**.
- Repetición Home/pantalla y lanzador (layout, raster, identidad, goldens):
  **272/272**. Los goldens del lanzador pasan sin regeneración.
- Ninguna clave de `/tmp/nous-obs/deadkeys.json` añadida; ningún ARB modificado.
- Se revisaron capturas Flutter de Ahora, Tareas y del tablero completo.
- La matriz conserva toda su cobertura: ahora reutiliza los cuatro temas
  inmutables y registra la limpieza de la vista una vez por prueba, evitando
  reconstruir el mismo tema y acumular miles de limpiezas por caso.

Los casos de 12 h revelaron columnas HH:mm demasiado estrechas: ahora miden
AM/PM completo. La matriz japonesa/china detectó el alto de la cápsula de no
leídos; su tipografía y la reserva de la fila se comparten explícitamente.
No se redujeron comprobaciones ni se subieron umbrales para admitir recortes.

Matriz final: **36/36**, completa, sola y última tanda de `flutter test -j 1`,
con `timeout 900`; terminó en 3 min 1 s, sin recortes ni desbordes detectados.
