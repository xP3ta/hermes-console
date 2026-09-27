import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../hermes_notice.dart';
import '../message_avatar_header.dart';
import 'chat_message_selection_area.dart';

/// Marco compartido de un mensaje del chat (spec 070, T103): cabecera con
/// cara/avatar + nombre + acciones, cuerpo libre y hora al pie. El cuerpo vive
/// dentro de una [ChatMessageSelectionArea] (selección parcial estable, nunca
/// `SelectableText`), así que el llamador pasa el contenido sin selección
/// propia, p. ej. `ChatMarkdownBody(selectable: false, ...)`.
///
/// Lo usan el chat principal y, a partir de la fase 3, las salas.
class ChatMessageFrame extends StatelessWidget {
  const ChatMessageFrame({
    super.key,
    required this.children,
    this.header,
    this.time,
    this.selectable = true,
    this.selectionIdentity,
    this.padding = const EdgeInsets.only(
      left: 12,
      right: 16,
      top: 11,
      bottom: 3,
    ),
    this.headerSpacing = 4,
  });

  /// Cabecera (normalmente un [ChatMessageHeader]); `null` la omite, p. ej. en
  /// las porciones intermedias de una respuesta larga virtualizada.
  final Widget? header;

  /// Contenido del mensaje, en orden.
  final List<Widget> children;

  /// Hora ya formateada (ver [formatChatMessageTime]); `null` omite el pie.
  final String? time;

  /// Habilita la selección parcial (se deshabilita durante el streaming).
  final bool selectable;

  /// Identidad del mensaje; al cambiar se limpia la selección previa.
  final Object? selectionIdentity;

  final EdgeInsetsGeometry padding;

  /// Separación entre la cabecera y el cuerpo.
  final double headerSpacing;

  @override
  Widget build(BuildContext context) {
    final header = this.header;
    final time = this.time;
    return ChatMessageSelectionArea(
      enabled: selectable,
      selectionIdentity: selectionIdentity,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (header != null)
              Padding(
                padding: EdgeInsets.only(bottom: headerSpacing),
                child: header,
              ),
            ...children,
            if (time != null) ChatMessageTimestamp(time),
          ],
        ),
      ),
    );
  }
}

/// Cabecera de un mensaje: cara/avatar (44 dp, o la inicial en acento si es
/// `null`), nombre, segunda línea opcional y acciones a la derecha.
class ChatMessageHeader extends StatelessWidget {
  const ChatMessageHeader({
    super.key,
    required this.name,
    this.avatar,
    this.subtitle,
    this.nameColor,
    this.actions = const [],
  });

  final String name;
  final Widget? avatar;
  final Widget? subtitle;

  /// Color del nombre; por defecto el acento del tema.
  final Color? nameColor;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => MessageAvatarHeader(
    name: name,
    mascot: avatar,
    subtitle: subtitle,
    nameColor: nameColor,
    actions: actions,
  );
}

/// Hora al pie de un mensaje (mono 10, `textSecondary`).
class ChatMessageTimestamp extends StatelessWidget {
  const ChatMessageTimestamp(this.value, {super.key});

  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
      child: Text(
        value,
        // A-202 (spec 028): timestamps en mono (§8/§3); A-112: textSecondary
        // para que el texto informativo llegue a 4.5:1.
        style: TextStyle(
          fontSize: 10,
          fontFamily: 'monospace',
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

/// Acción de icono de la cabecera (48×48, tooltip y etiqueta accesible).
class ChatMessageActionButton extends StatelessWidget {
  const ChatMessageActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconSize = 18,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Icon(icon, size: iconSize, color: colors.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

/// «Copiar mensaje»: copia [text] (ya en texto plano) y confirma con un aviso.
class ChatCopyMessageButton extends StatelessWidget {
  const ChatCopyMessageButton({super.key, required this.text});

  /// Texto a copiar; se evalúa al pulsar.
  final String Function() text;

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return ChatMessageActionButton(
      icon: Icons.copy_rounded,
      iconSize: 16,
      label: strings.chaCopyMessage,
      onPressed: () {
        Clipboard.setData(ClipboardData(text: text()));
        HermesNotice.of(context).showSnackBar(
          SnackBar(
            content: Text(Strings.of(context).chaCopied),
            duration: const Duration(seconds: 1),
          ),
          kind: HermesNoticeKind.success,
        );
      },
    );
  }
}

/// Formatea la hora `HH:mm` de un sello Unix (segundos o milisegundos, número
/// o cadena). Devuelve `null` si no es válido.
String? formatChatMessageTime(Object? raw) {
  if (raw == null) return null;
  final double? value;
  if (raw is num) {
    value = raw.toDouble();
  } else if (raw is String) {
    value = double.tryParse(raw);
  } else {
    value = null;
  }
  if (value == null || value <= 0) return null;

  // The Gateway sends Unix timestamps in seconds (float), like
  // Session.started_at. Values >= 1e12 can only be milliseconds, so
  // accept both defensively.
  final milliseconds = value < 1e12 ? (value * 1000).round() : value.round();
  final dt = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}
