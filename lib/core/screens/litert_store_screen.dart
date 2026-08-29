// Tienda de modelos `.litertlm` para el motor local por GPU (OlliteRT).
//
// Honestidad de diseño: la DESCARGA física la hace la app OlliteRT (su tienda
// integrada baja de "LiteRT Community" en HuggingFace); su API remota no permite
// dispararla. Por eso esta pantalla es un CATÁLOGO CURADO que: muestra los
// modelos compatibles con tamaños/RAM, avisa si caben en el móvil, enlaza a la
// descarga (página de HF), y refleja el estado real cruzando con `/v1/models`
// de OlliteRT (lista pasada por el padre). La SELECCIÓN del modelo activo de
// Hermes sí la hacemos: «Usar» devuelve el id al padre, que apunta la config.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../data/litert_catalog.dart';
import '../services/connection_manager.dart';
import '../services/litert_engine.dart';
import '../services/platform/android_apps.dart';
import '../theme/app_theme.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_pill.dart';
import '../widgets/hermes_ui.dart';

/// Encaje del modelo en la RAM del dispositivo.
enum _Fit { fits, tight, tooBig, unknown }

class LitertStoreScreen extends StatelessWidget {
  const LitertStoreScreen({
    required this.connection,
    required this.deviceInfo,
    required this.served,
    this.activeModelId,
    super.key,
  });

  final SavedConnection connection;
  final DeviceInfo deviceInfo;

  /// Modelos que OlliteRT reporta servidos (`/v1/models`), para marcar
  /// «descargado/en marcha» y habilitar «Usar».
  final List<OlliteRtServedModel> served;

  /// Id del modelo activo en config (si el motor GPU está activo), para el
  /// badge «en uso».
  final String? activeModelId;

  _Fit _fitFor(LitertModel m) {
    final ram = deviceInfo.totalRamGb;
    if (ram <= 0) return _Fit.unknown;
    if (ram >= m.minRamGb + 2) return _Fit.fits;
    if (ram >= m.minRamGb) return _Fit.tight;
    return _Fit.tooBig;
  }

  /// ¿OlliteRT sirve este modelo del catálogo? (cruce tolerante por id).
  OlliteRtServedModel? _servedFor(LitertModel m) {
    for (final s in served) {
      if (m.matchesServedId(s.id)) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(title: Text(s.litertStoreTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          HermesInfoBanner(s.litertStoreIntro, icon: Icons.storefront_outlined),
          const SizedBox(height: 16),
          for (final m in kLitertCatalog) ...[
            _modelCard(context, colors, m),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  Widget _modelCard(
    BuildContext context,
    HermesThemeColors colors,
    LitertModel m,
  ) {
    final s = Strings.of(context);
    final fit = _fitFor(m);
    final servedModel = _servedFor(m);
    final isServed = servedModel != null;
    final inUse = isServed && activeModelId == servedModel.id;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: inUse ? colors.accent : colors.divider,
          width: inUse ? 1.2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  m.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (m.recommended) ...[
                HermesPill(
                  label: s.litertStoreRecommended,
                  color: colors.accent,
                ),
                const SizedBox(width: 6),
              ],
              if (inUse)
                HermesPill(
                  label: s.litertStoreInUseLower,
                  color: colors.success,
                )
              else if (isServed)
                HermesPill(
                  label: s.litertStoreDownloaded,
                  color: colors.success,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              _meta(colors, Icons.sd_storage_outlined, '${m.sizeGb} GB'),
              _meta(colors, Icons.memory, 'RAM ${m.minRamGb} GB'),
              _meta(colors, Icons.short_text, '${m.contextLabel} ctx'),
              _fitChip(colors, fit, s),
            ],
          ),
          if (m.note != null) ...[
            const SizedBox(height: 6),
            Text(
              _note(s, m.note!),
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: Text(s.litertStoreDownload),
                  onPressed: () => _openDownload(context, m),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  icon: Icon(inUse ? Icons.check : Icons.play_arrow, size: 16),
                  label: Text(inUse ? s.litertStoreInUse : s.litertStoreUse),
                  onPressed: (!isServed || inUse)
                      ? null
                      : () => Navigator.of(context).pop(servedModel.id),
                ),
              ),
            ],
          ),
          if (!isServed) ...[
            const SizedBox(height: 6),
            Text(
              s.litertStoreStartHint,
              style: TextStyle(fontSize: 11, color: colors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _meta(HermesThemeColors colors, IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: colors.textSecondary),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
        ),
      ],
    );
  }

  Widget _fitChip(HermesThemeColors colors, _Fit fit, Strings s) {
    final (String label, Color color) = switch (fit) {
      _Fit.fits => (s.litertStoreFits, colors.success),
      _Fit.tight => (s.litertStoreTight, colors.warning),
      _Fit.tooBig => (s.litertStoreTooBig, colors.error),
      _Fit.unknown => ('RAM ?', colors.textSecondary),
    };
    return HermesPill(label: label, color: color);
  }

  String _note(Strings s, LitertModelNote note) => switch (note) {
    LitertModelNote.recommended => s.litertNoteRecommended,
    LitertModelNote.highEnd => s.litertNoteHighEnd,
    LitertModelNote.lightweight => s.litertNoteLightweight,
    LitertModelNote.distilledReasoner => s.litertNoteDistilledReasoner,
  };

  /// Abre la página de HuggingFace del modelo (la descarga real la gestiona
  /// OlliteRT desde su propia tienda; el enlace es la fuente oficial).
  Future<void> _openDownload(BuildContext context, LitertModel m) async {
    try {
      await launchUrl(Uri.parse(m.hfUrl), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint(
        '[litert-store] excepción silenciada (se avisa al usuario y se sigue): $e',
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).litertStoreOpenError(m.hfUrl)),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }
}
