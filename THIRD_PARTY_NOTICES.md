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

## Artwork propio y companions CC0

La procedencia, licencia y SHA-256 de la identidad visual propia y de los tres
spritesheets locales se documentan en [`ASSET_PROVENANCE.md`](ASSET_PROVENANCE.md).
El texto legal completo CC0-1.0 aplicable a los companions está en
[`assets/companions/CC0-1.0.txt`](assets/companions/CC0-1.0.txt).

## Componentes Android transitivos relevantes

- **ZXing Core 3.5.2** — Apache License 2.0; decodifica los QR íntegramente en
  el dispositivo.
- **ZXing Android Embedded 4.3.0** — Apache License 2.0; visor de cámara usado
  por `qr_code_scanner_plus`. La dependencia se integra sin sus transitivas y
  usa ZXing Core explícitamente.
- **AndroidX** — Apache License 2.0; componentes de compatibilidad, ciclo de
  vida, cámara y UI incluidos transitivamente por los plugins Android.

El escáner QR es local: no envía fotogramas, contenido, resultados ni métricas
del escáner a XPeta Lab o a otro servicio.

## Tipografías empaquetadas

Inter, JetBrains Mono, Montserrat y Nunito se distribuyen bajo la SIL Open Font
License 1.1 y se empaquetan localmente. No se usa ninguna API ni CDN de fuentes
en runtime. El catálogo y los perfiles antiguos migran las familias retiradas a
una de estas cuatro alternativas redistribuibles.

El texto completo y los avisos de copyright están en
`assets/fonts/OFL.txt`; también aparecen dentro de la app en **Ajustes → Acerca
de → Licencias open source**.

Dependencias de desarrollo (no se distribuyen en el APK): flutter_test,
flutter_lints, build_runner, json_serializable.
