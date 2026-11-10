import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import 'session_status_tone.dart';

/// Tamaño de la mascota en la cabecera (el de siempre).
const double kAvatarMascotSize = 44;

/// Ancho reservado a la mascota, más un respiro hasta el título.
const double kAvatarSlotWidth = 50;

/// Width of the slot a face of [size] takes before the title (and so how far
/// the card under the title, and what hangs from it, is indented).
double avatarSlotWidthFor(double size) =>
    size == kAvatarMascotSize ? kAvatarSlotWidth : size + HermesSpace.x2;

/// What hangs under a header that wears a face (the live window and its
/// connector, the steps): it starts where the header's text does, past the
/// face's slot, so the connector hangs from the card's own edge.
class AvatarDetailsIndent extends StatelessWidget {
  const AvatarDetailsIndent({
    required this.mascotSize,
    required this.child,
    super.key,
  });

  final double mascotSize;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsetsDirectional.only(start: avatarSlotWidthFor(mascotSize)),
    child: child,
  );
}

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

/// Cabecera de un mensaje del asistente: el título en color de acento y,
/// justo debajo, la segunda línea —el estado del turno o su resumen plegado,
/// en tono apagado—. Las acciones quedan a la derecha.
///
/// Con [mascot], una cara (sin marco ni anillo) abre la cabecera en su hueco.
/// Sin ella no hay hueco ni inicial: el nombre empieza donde el mensaje. Un
/// chat con un solo interlocutor no la pasa (ct1215: quién habla ya está en
/// la cabecera del chat).
class MessageAvatarHeader extends StatelessWidget {
  const MessageAvatarHeader({
    required this.name,
    this.mascot,
    this.mascotSize = kAvatarMascotSize,
    this.subtitle,
    this.nameColor,
    this.actions = const [],
    super.key,
  });

  final String name;

  /// La cara ya construida (44 dp), o `null` para una cabecera sin cara.
  final Widget? mascot;

  /// The face's size: 44 dp by default (rooms); a chat's answer wears its
  /// face small, 24 dp, beside the name (Q9, the owner: «sprite pequeño +
  /// nombre del bot»).
  final double mascotSize;

  /// Segunda línea bajo el título (estado del turno o su resumen plegado).
  final Widget? subtitle;

  /// Color del título; por defecto el acento del tema.
  final Color? nameColor;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final face = mascot;
    final text = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            displayAgentName(name),
            key: const ValueKey('assistant-header-name'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              // A profile's own colour can be as dark as the page; the
              // theme's accent is used as the theme defines it.
              color: nameColor == null
                  ? colors.accent
                  : readableLabelColor(nameColor!, colors.background),
              letterSpacing: 0.3,
            ),
          ),
          ?subtitle,
        ],
      ),
    );
    // No face, no slot: the name starts where the message does.
    if (face == null) return Row(children: [text, ...actions]);
    final size = mascotSize;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: size),
      child: Row(
        // The face sits at the top, level with the name, however tall the
        // block under the name grows (the live card, its window).
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            key: const ValueKey('assistant-avatar-slot'),
            width: avatarSlotWidthFor(size),
            height: size,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: SizedBox(width: size, height: size, child: face),
            ),
          ),
          text,
          ...actions,
        ],
      ),
    );
  }
}
