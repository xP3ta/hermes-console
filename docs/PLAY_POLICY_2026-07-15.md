# Impacto del anuncio de políticas de Google Play — 15-07-2026

Fuente oficial:
<https://support.google.com/googleplay/android-developer/answer/17134731>

Revisado el 01-09-2026 para el candidato fuente `1.2.9`. La inspección del AAB
firmado final continúa pendiente; este documento no la da por realizada.

| Cambio anunciado | ¿Afecta? | Acción para Hermes Console |
|---|---:|---|
| Chat anónimo/aleatorio y seguridad infantil | No directamente | La app conversa con el agente privado del usuario; no empareja personas ni ofrece chat anónimo entre usuarios. Mantener «no dirigida a menores» y clasificación de contenido precisa |
| `READ_CALL_LOG` para verificación telefónica | No | El manifest no declara SMS, llamadas ni `READ_CALL_LOG` |
| Registro/verificación de apps del desarrollador | Sí, administrativo | Revisar la portada de Play Console y confirmar que `dev.xpetalab.hermesconsole` figure registrada antes del plazo. No requiere código si Google la registró automáticamente |
| Integraciones de IA de terceros sujetas a uso limitado, divulgación y consentimiento | Sí | Actualizados aviso de primer uso, Política ES/EN, Data Safety y textos de Play para explicar Hermes, proveedores de modelo/herramienta y motores de voz |
| Clasificación de contenido obligatoria | Sí, administrativo | Completar/revisar el cuestionario IARC; no dejar la app «sin clasificar» |
| Target API más reciente antes del 31-08-2026 | Cumplido en código | La candidata usa target/compile SDK 36; verificarlo otra vez en el AAB final |

## Gates antes de enviar

- [ ] Confirmar registro de la aplicación en la portada de Play Console.
- [ ] Publicar Política de Privacidad v3 ES/EN y comprobar ambas URLs sin login.
- [ ] Actualizar Data Safety para mensajes, audio, adjuntos y terceros; el
  escáner ZXing no añade recopilación ni compartición de datos.
- [ ] Revisar IARC/Content rating y Target audience (la app no se dirige a niños).
- [ ] Declarar FGS `dataSync`, `remoteMessaging`, `microphone` y
  `mediaPlayback`, cada uno con texto, impacto y vídeo.
- [ ] Verificar en el AAB firmado final que no existan permisos de llamadas/SMS
  ni `USE_FULL_SCREEN_INTENT` (los manifests fuente actuales no los declaran).

## Conclusión

El anuncio no bloquea el modo conversación ni exige instalar nada en el
servidor. Sí obliga a que la ruta de datos hacia Hermes/IA y la captura de voz
sean transparentes y coherentes entre la app, la política pública y Play
Console. La implementación usa consentimiento afirmativo, continuidad bloqueada
desactivada por defecto y control visible del micrófono.
