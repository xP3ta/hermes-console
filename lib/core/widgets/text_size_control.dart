import 'package:hermes_android/core/design/hicons.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../services/font_size_service.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'hermes_ui.dart';

/// The one text size control (Ajustes → Aspecto → Look & Feel): a live
/// sample, smaller/larger steps around a slider, the value in percent and a
/// reset to the default. Applies at once to the whole app and persists.
class TextSizeControl extends StatelessWidget {
  final FontSizeService service;

  const TextSizeControl({super.key, required this.service});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final factor = service.factor;
    final percent = (factor * 100).round();
    final atMin = factor <= FontSizeService.minFactor;
    final atMax = factor >= FontSizeService.maxFactor;
    void stepBy(int steps) => service.setFactor(
      factor + steps * FontSizeService.step,
    );
    return HermesGroup(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HermesSpace.x4,
            HermesSpace.x3,
            HermesSpace.x3,
            HermesSpace.x2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      s.setTextSize,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    s.lflTextSizePercent(percent),
                    key: const ValueKey('text-size-value'),
                    style: TextStyle(color: colors.textSecondary),
                  ),
                ],
              ),
              const SizedBox(height: HermesSpace.x2),
              // The sample is the app's own text: it changes with the value.
              Text(
                s.setTextSizePreview,
                key: const ValueKey('text-size-sample'),
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: HermesType.textSize,
                  height: 1.35,
                ),
              ),
              Row(
                children: [
                  IconButton(
                    key: const ValueKey('text-size-smaller'),
                    tooltip: s.setTextSizeSmaller,
                    onPressed: atMin ? null : () => stepBy(-1),
                    icon: const Icon(HIcons.text_decrease_rounded),
                  ),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('text-size-slider'),
                      min: FontSizeService.minFactor,
                      max: FontSizeService.maxFactor,
                      divisions: FontSizeService.divisions,
                      value: factor,
                      label: s.lflTextSizePercent(percent),
                      semanticFormatterCallback: (value) =>
                          s.lflTextSizePercent((value * 100).round()),
                      onChanged: service.setFactor,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('text-size-larger'),
                    tooltip: s.setTextSizeLarger,
                    onPressed: atMax ? null : () => stepBy(1),
                    icon: const Icon(HIcons.text_increase_rounded),
                  ),
                ],
              ),
              Text(
                s.lflTextSizeSystemNote,
                style: TextStyle(
                  fontSize: HermesType.captionSize,
                  color: colors.textSecondary,
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  key: const ValueKey('text-size-reset'),
                  onPressed: service.isDefault ? null : service.reset,
                  child: Text(s.lflTextSizeReset),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
