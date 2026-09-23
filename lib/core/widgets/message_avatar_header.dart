import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Tamaño de la mascota en la cabecera (el de siempre).
const double kAvatarMascotSize = 44;

/// Ancho reservado a la mascota, más un respiro hasta el título.
const double kAvatarSlotWidth = 50;

/// «HERMES CONSOLE» / «hermes» se muestra en «Hermes Console»; un nombre con
/// mayúsculas mezcladas se respeta tal cual.
String displayAgentName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return 'Hermes';
  if (name != name.toLowerCase() && name != name.toUpperCase()) return name;
  return name
      .split(RegExp(r'\s+'))
      .map(
        (word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}',
      )
      .join(' ');
}

/// Cabecera de un mensaje del asistente: la mascota (sin marco ni anillo), el
/// título en color de acento y, justo debajo, la segunda línea —el desplegable
/// del turno, en tono apagado—. Las acciones quedan a la derecha.
///
/// Sin presencia (mascota apagada) el hueco lo ocupa la inicial del nombre, en
/// acento y sin círculo, para que la geometría sea idéntica.
class MessageAvatarHeader extends StatelessWidget {
  const MessageAvatarHeader({
    required this.name,
    this.mascot,
    this.subtitle,
    this.actions = const [],
    super.key,
  });

  final String name;

  /// La mascota ya construida (44 dp), o `null` con la presencia apagada.
  final Widget? mascot;

  /// Segunda línea bajo el título (desplegable del turno o «Trabajando…»).
  final Widget? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final title = displayAgentName(name);
    final initial = title.substring(0, 1).toUpperCase();
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kAvatarMascotSize),
      child: Row(
        children: [
          SizedBox(
            key: const ValueKey('assistant-avatar-slot'),
            width: kAvatarSlotWidth,
            height: kAvatarMascotSize,
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: kAvatarMascotSize,
                height: kAvatarMascotSize,
                child:
                    mascot ??
                    Center(
                      child: Text(
                        initial,
                        key: const ValueKey('assistant-avatar-initial'),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: colors.accent,
                        ),
                      ),
                    ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  key: const ValueKey('assistant-header-name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: colors.accent,
                    letterSpacing: 0.3,
                  ),
                ),
                ?subtitle,
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}
