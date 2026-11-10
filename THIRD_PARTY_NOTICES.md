# Third-Party Notices

Este proyecto es un fork con modificaciones sustanciales. Este documento recoge
las atribuciones obligatorias del código del que deriva, de sus assets y de las
bibliotecas que utiliza. **No eliminar estas atribuciones.**

---

## Proyecto base (upstream)

Partes de este proyecto derivan de:

- **Proyecto**: hermes-android
- **Autor**: rusty4444
- **Repositorio**: https://github.com/rusty4444/hermes-android
- **Licencia declarada**: MIT (declarada en la sección "License" del README del
  upstream; verificada tanto en el commit base como en `main` a fecha
  2026-07-11; el repositorio upstream no incluye archivo `LICENSE` independiente)
- **Commit base del fork**: `5f9baafe349f960817041a44ce8d80b87fbb9f2d`
  (2026-06-08, v1.0.4 — "Add release signing config with stable keystore")

Texto de la licencia MIT aplicable al código del upstream:

```
MIT License

Copyright (c) rusty4444 and hermes-android contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

> Nota: el upstream no publica el texto completo de la licencia ni el nombre
> exacto del titular del copyright; se reproduce el texto MIT estándar con la
> atribución al autor del repositorio. Si el upstream añade un `LICENSE`
> formal, actualizar esta sección con su texto literal.

## Estado de la licencia de este fork

El código original escrito para Hermes Console se publica bajo
**GNU GPL versión 3.0 solamente** (`GPL-3.0-only`). Las partes derivadas del
upstream siguen sujetas también a la licencia MIT y a su atribución. El archivo
`LICENSE` contiene el texto completo de GPLv3. La GPL no relicencia dependencias,
fuentes, modelos, marcas ni assets de terceros, que conservan sus propios
términos.

## Marcas y proyectos relacionados

- **Hermes Agent** es un proyecto independiente; esta aplicación es un cliente
  no oficial que se comunica con su API self-hosted. No está afiliada,
  patrocinada ni mantenida por Nous Research ni por los autores de Hermes
  Agent.

## Dependencias directas (pub.dev)

Bibliotecas de terceros usadas por la app, con sus licencias publicadas en
pub.dev. Los textos completos se muestran en la app en
**Ajustes → Acerca de → Licencias open source** (generado por Flutter a partir
de los paquetes empaquetados).

| Paquete | Licencia |
|---|---|
| flutter (SDK) | BSD-3-Clause |
| flutter_localizations | BSD-3-Clause |
| intl | BSD-3-Clause |
| cupertino_icons | MIT |
| flutter_markdown | BSD-3-Clause |
| markdown | BSD-3-Clause |
| flutter_animate | BSD-3-Clause |
| flutter_staggered_animations | MIT |
| go_router | BSD-3-Clause |
| http | BSD-3-Clause |
| web_socket_channel | BSD-3-Clause |
| shared_preferences | BSD-3-Clause |
| home_widget | BSD-3-Clause |
| path_provider | BSD-3-Clause |
| json_annotation | BSD-3-Clause |
| uuid | MIT |
| url_launcher | BSD-3-Clause |
| package_info_plus | BSD-3-Clause |
| app_links | Apache-2.0 |
| share_plus | BSD-3-Clause |
| gal | BSD-3-Clause |
| highlight | MIT |
| flutter_secure_storage | BSD-3-Clause |
| image_picker | Apache-2.0 / BSD-3-Clause |
| image_picker_android | BSD-3-Clause |
| image_picker_platform_interface | BSD-3-Clause |
| file_picker | MIT |
| local_auth | BSD-3-Clause |
| crypto | BSD-3-Clause |
| speech_to_text | BSD-3-Clause |
| flutter_tts | MIT |
| audioplayers | MIT |
| video_player | BSD-3-Clause |
| record | BSD-3-Clause |
| whisper_ggml_plus | MIT |
| sherpa_onnx | Apache-2.0 |
| qr_code_scanner_plus | BSD-2-Clause |
| archive | BSD-3-Clause / MIT (componentes; ver licencia del paquete) |
| flutter_local_notifications | BSD-3-Clause |
| flutter_foreground_task | MIT |
| dartssh2 | MIT |
| xterm | MIT |
| webview_flutter | BSD-3-Clause |
| webview_flutter_android | BSD-3-Clause |
| flutter_webrtc | MIT |
| dart_webrtc | MIT |
| webrtc_interface | MIT |
| logger | MIT |

## Indicador de carga "three-body" (Uiverse, MIT)

El indicador de carga `HermesLoader`
([`lib/core/widgets/hermes_loader.dart`](lib/core/widgets/hermes_loader.dart))
reimplementa en Flutter (`CustomPainter` y un único `AnimationController`) la
geometría y los tiempos del loader "three-body" (`tidy-walrus-92`):

- **Autor**: Gabriel (GitHub: dovatgabriel)
- **Fuente**: Uiverse.io, https://uiverse.io/dovatgabriel/tidy-walrus-92
- **Licencia**: MIT (licencia de los elementos de Uiverse.io)

No se incluye código CSS del original; solo se replican su geometría y sus
tiempos de animación.

## Artwork propio y companions CC0

La procedencia, licencia y SHA-256 de la identidad visual propia y de los tres
spritesheets locales se documentan en [`ASSET_PROVENANCE.md`](ASSET_PROVENANCE.md).
El texto legal completo CC0-1.0 aplicable a los companions está en
[`assets/companions/CC0-1.0.txt`](assets/companions/CC0-1.0.txt).

## Logos de proveedores (Simple Icons, CC0; LobeHub Icons, MIT)

Las marcas monocromas de proveedores del selector de modelos y de Modelos usan
los trazados vectoriales de Simple Icons 16.1.0 (`CC0-1.0`), sin sus colores.
Las marcas que Simple Icons no incluye (OpenAI, DeepSeek, xAI, Nous Research,
Moonshot AI, Z.ai, Microsoft, LM Studio) usan los trazados monocromos de
LobeHub Icons, npm `@lobehub/icons-static-svg@1.95.1` (commit
`49a2130df7bfa5eb1b088261bff20a37e2967789`), con licencia MIT, también sin colores.
Detalle por proveedor en [`ASSET_PROVENANCE.md`](ASSET_PROVENANCE.md). Las
marcas pertenecen a sus titulares y solo identifican al proveedor del modelo.

Aviso de LobeHub Icons (https://github.com/lobehub/lobe-icons):

```text
MIT License

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Marcas de sitios en Artefactos (Simple Icons, CC0)

En «Artefactos», cada enlace lleva la marca monocroma de su sitio, como en
Hermes Desktop: la misma tabla de dominios de Desktop
(`apps/desktop/src/lib/brand-icon.ts` de
https://github.com/NousResearch/hermes-agent, licencia **MIT**, Copyright (c)
2025 Nous Research) y los trazados de Simple Icons 16.8.0 (`CC0-1.0`), tal como
los empaqueta `@icons-pack/react-simple-icons@13.11.1`, sin colores. Detalle en [`ASSET_PROVENANCE.md`](ASSET_PROVENANCE.md). Las
marcas pertenecen a sus titulares y solo indican qué sitio abre el enlace.

## Componentes Android transitivos relevantes

- **ZXing Core 3.5.2** — Apache License 2.0; decodifica los QR íntegramente en
  el dispositivo.
- **ZXing Android Embedded 4.3.0** — Apache License 2.0; visor de cámara usado
  por `qr_code_scanner_plus`. La dependencia se integra sin sus transitivas y
  usa ZXing Core explícitamente.
- **AndroidX** — Apache License 2.0; componentes de compatibilidad, ciclo de
  vida, cámara y UI incluidos transitivamente por los plugins Android.
- **AndroidX WebKit 1.15.0** — Apache License 2.0; capa de compatibilidad de
  `webview_flutter_android` sobre el WebView del sistema. El visor de
  artefactos no empaqueta motor web propio.
- **libwebrtc (`io.github.webrtc-sdk:android` 150.7871.01)** — BSD 3-Clause;
  WebRTC media stack used by `flutter_webrtc` for the opt-in GPT-Live voice.
- **AudioSwitch (`com.github.davidliu:audioswitch`, fork of Twilio
  AudioSwitch)** — Apache License 2.0; audio focus and routing for
  `flutter_webrtc`. It is resolved from the JitPack repository that the plugin
  declares.

El escáner QR es local: no envía fotogramas, contenido, resultados ni métricas
del escáner a XPeta Lab o a otro servicio.

## Pantalla del bot (noVNC)

El visor que asume el control del escritorio del bot incluye el núcleo de
**noVNC** (https://github.com/novnc/noVNC, v1.5.0), licencia **MPL-2.0**.
Los avisos originales de cada archivo se conservan. El texto de la licencia
está en `assets/novnc/LICENSE.txt` y `assets/novnc/docs/LICENSE.MPL-2.0`.
`assets/novnc/bridge.html` es código de este proyecto (GPL-3.0-only) y solo
carga ese núcleo.

`assets/novnc/core/crypto/des.js` no es MPL: conserva la concesión BSD-style
de AT&T Laboratories Cambridge (1999), Widget Workshop (1996) y Jef Poskanzer
(1996). El texto está en el propio archivo y en
`LICENSES/LicenseRef-noVNC-DES.txt`.

**pako** (https://github.com/nodeca/pako, Copyright (C) 2014-2016 Vitaly
Puzrin) se incluye tal como lo vende noVNC, bajo la licencia MIT
(`assets/novnc/vendor/pako/LICENSE`).

## Motor del navegador del agente (Hermes Desktop)

`lib/core/browser/hermes_preview_engine.g.dart` contiene, tal como Hermes
Desktop los convierte en texto, el motor que el agente usa para leer, recorrer
y marcar la página del navegador integrado (`act-in-page.ts`,
`watch-in-page.ts` de `apps/desktop/src/lib/preview-act` en
https://github.com/NousResearch/hermes-agent). Licencia **MIT**,
Copyright (c) 2025 Nous Research. Se regenera con
`tool/browser/generate_preview_engine.sh`, que aplica un único cambio propio
(`tool/browser/render_preview_engine.py`): nunca se informa del valor de un
campo de contraseña, de código de un solo uso o de tarjeta. Las plantillas de
`lib/core/browser/agent_preview_act.dart` copian las de `preview-act.ts` del
mismo proyecto y licencia.

## Tipografías empaquetadas

Inter, JetBrains Mono, Montserrat y Nunito se distribuyen bajo la SIL Open Font
License 1.1 y se empaquetan localmente. No se usa ninguna API ni CDN de fuentes
en runtime. El catálogo y los perfiles antiguos migran las familias retiradas a
una de estas cuatro alternativas redistribuibles.

El texto completo y los avisos de copyright están en
`assets/fonts/OFL.txt`; también aparecen dentro de la app en **Ajustes → Acerca
de → Licencias open source**.

Dependencias de desarrollo (no se distribuyen en el APK): flutter_test,
flutter_lints, build_runner, json_serializable, sqflite_common_ffi,
webview_flutter_platform_interface, url_launcher_platform_interface,
plugin_platform_interface (estas tres últimas también llegan al APK como
transitivas de webview_flutter/url_launcher; aquí solo se declaran para los
dobles de prueba).

## Iconos del chat en vivo

Los diez iconos de la fila viva, la píldora de delegados y el chip de cola
(`assets/chat_icons/*.webp`) derivan de Generative Icons
(https://generativeicons.com, LottieFiles), con licencia MIT declarada por el
catálogo para cada icono. Son tiras de fotogramas pre-renderizadas (blanco
sobre transparente) que la app tiñe con el tema; no hay reproductor Lottie
en la app. Licencia y procedencia: `assets/chat_icons/LICENSE.txt`,
`ASSET_PROVENANCE.md` y `assets/chat_icons/SOURCES.json`. Para regenerarlas
se usó lottie-web 5.13.0 (MIT) solo en tiempo de compilación; no se
distribuye.
