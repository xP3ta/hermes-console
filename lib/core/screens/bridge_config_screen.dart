import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_ui.dart';
import '../widgets/hermes_app_bar.dart';

/// Resultado de [BridgeConfigScreen]: URL efectiva y token introducidos.
typedef BridgeConfigResult = ({String url, String token});

/// Configuración del Mobile Bridge (URL + token), presentada como RUTA.
///
/// Se presenta con `Navigator.push` (no `showDialog`): un diálogo con un
/// `TextField` enfocado dispara el assert `_dependents.isEmpty` al cerrarse,
/// porque el `EditableText` sigue dependiendo del Overlay del diálogo que se
/// desmonta. Como ruta usa el Overlay estable del Navigator y, además, suelta
/// el foco antes de hacer pop. Devuelve [BridgeConfigResult] o null si cancela.
///
/// Compartida por todos los editores con bridge (memoria, SOUL, cron…).
class BridgeConfigScreen extends StatefulWidget {
  final String initialUrl;
  final String initialToken;
  final String derivedUrl;

  const BridgeConfigScreen({
    required this.initialUrl,
    this.initialToken = '',
    this.derivedUrl = '',
    super.key,
  });

  @override
  State<BridgeConfigScreen> createState() => _BridgeConfigScreenState();
}

class _BridgeConfigScreenState extends State<BridgeConfigScreen> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.initialUrl);
    _tokenCtrl = TextEditingController(text: widget.initialToken);
  }

  void _releaseFocus() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus.hasFocus) focus.unfocus();
  }

  void _save() {
    _releaseFocus();
    Navigator.of(context).pop((
      url: _urlCtrl.text.trim(),
      token: _tokenCtrl.text.trim(),
    ));
  }

  void _cancel() {
    _releaseFocus();
    Navigator.of(context).pop();
  }

  @override
  void deactivate() {
    // Red de seguridad: suelta el foco antes de desmontar pase lo que pase.
    _releaseFocus();
    super.deactivate();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Scaffold(
      appBar: HermesAppBar(
        title: Text(Strings.of(context).bridgeCfgTitle),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: Strings.of(context).commonClose,
          onPressed: _cancel,
        ),
        actions: [
          TextButton(onPressed: _save, child: Text(Strings.of(context).commonSave)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          HermesInfoBanner(
            widget.derivedUrl.isNotEmpty
                ? Strings.of(context).bridgeAutoUrl(widget.derivedUrl)
                : Strings.of(context).bridgeOptionalService,
            icon: Icons.cloud_outlined,
          ),
          const SizedBox(height: 16),
          HermesField(
            controller: _tokenCtrl,
            autofocus: true,
            obscure: true,
            autocorrect: false,
            enableSuggestions: false,
            label: Strings.of(context).bridgeToken,
            hint: Strings.of(context).bridgeTokenHint,
          ),
          const SizedBox(height: 14),
          HermesField(
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            label: Strings.of(context).bridgeUrlAdvanced,
            hint: 'http://100.x.x.x:9131',
            helperText: widget.derivedUrl.isNotEmpty
                ? Strings.of(context).bridgeUrlHint
                : null,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: Text(Strings.of(context).bridgeSaveConnect),
          ),
          const SizedBox(height: 8),
          Text(
            Strings.of(context).bridgeTokenNote,
            style: TextStyle(fontSize: 11, color: colors.textDisabled),
          ),
        ],
      ),
    );
  }
}
