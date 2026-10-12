import 'package:flutter/material.dart';

import '../../companion/render/companion_view.dart';
import '../../companion/state/companion_controller.dart';
import '../../companion/models/companion_mood.dart';

/// Playground del Companion (006 FASE 2): muestra la mascota **equipada a gran
/// tamaño** y permite disparar cada animación para lucirlas. Reutiliza
/// [CompanionView] (que mapea cada [CompanionMood] a su estado de animación),
/// así que funciona igual con la cara del perfil o con un spritesheet
/// importado. No toca voz, runtime ni red.
class CompanionPlaygroundScreen extends StatefulWidget {
  final CompanionController controller;
  const CompanionPlaygroundScreen({required this.controller, super.key});

  @override
  State<CompanionPlaygroundScreen> createState() =>
      _CompanionPlaygroundScreenState();
}

class _CompanionPlaygroundScreenState
    extends State<CompanionPlaygroundScreen> {
  // Animaciones mostrables (etiqueta visible → mood que las dispara).
  static const List<({String label, CompanionMood mood})> _moves = [
    (label: 'Reposo', mood: CompanionMood.idle),
    (label: 'Correr', mood: CompanionMood.thinking),
    (label: 'Esperar', mood: CompanionMood.waiting),
    (label: 'Saludar', mood: CompanionMood.success),
    (label: 'Saltar', mood: CompanionMood.jump),
    (label: 'Fallo', mood: CompanionMood.error),
  ];

  CompanionMood _mood = CompanionMood.idle;

  /// Cambia con cada pulsación para re-disparar animaciones one-shot
  /// (saludar/saltar/fallo) aunque se repita el mismo estado.
  int _replay = 0;

  void _play(CompanionMood mood) {
    setState(() {
      _mood = mood;
      _replay++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Animaciones')),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          return Column(
            children: [
              Expanded(
                child: Center(
                  child: CompanionView(
                    mood: _mood,
                    size: 200,
                    controller: widget.controller,
                    replayToken: _replay,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final m in _moves)
                      ChoiceChip(
                        label: Text(m.label),
                        selected: _mood == m.mood,
                        onSelected: (_) => _play(m.mood),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
