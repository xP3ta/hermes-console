import 'package:flutter/material.dart';

import 'reasoning_panel.dart';

/// Bloque de razonamiento del asistente, claramente separado de la respuesta
/// final. rt1215: es el mismo bloque «Pensamiento» del panel de actividad
/// ([ReasoningPanel]): desde 1.4.0 (maqueta 137 A) una línea fina
/// «Pensamiento · 12 s» que se abre con un toque.
///
/// Recibe el texto de razonamiento ya extraído de `<think>…</think>` por
/// `splitReasoning`. Es solo presentación: no muta contenido ni lo persiste.
class ReasoningBlock extends StatelessWidget {
  /// Texto del razonamiento (sin etiquetas). Puede ir creciendo en streaming.
  final String reasoning;

  /// `true` mientras el modelo sigue razonando (apertura sin cierre).
  final bool inProgress;

  const ReasoningBlock({
    required this.reasoning,
    this.inProgress = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (reasoning.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 8, bottom: 4),
      child: ReasoningPanel(text: reasoning, live: inProgress),
    );
  }
}
