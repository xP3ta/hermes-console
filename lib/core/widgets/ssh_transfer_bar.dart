import 'package:flutter/material.dart';

import '../services/sftp_transfer_service.dart';
import '../theme/app_theme.dart';
import '../../l10n/app_localizations.dart';

/// Barra in-app que muestra las transferencias SFTP (en curso y recién
/// terminadas), con su barra de progreso. Observa el servicio, así que sigue
/// reflejando el avance aunque cambies de pantalla y vuelvas.
class SshTransferBar extends StatelessWidget {
  final SftpTransferService service;
  const SshTransferBar({required this.service, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ValueListenableBuilder<List<SftpTransfer>>(
      valueListenable: service.transfers,
      builder: (context, list, _) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Container(
          color: colors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in list) _row(context, colors, t),
            ],
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, HermesThemeColors colors, SftpTransfer t) {
    final ok = t.status == TransferStatus.done;
    final err = t.status == TransferStatus.error;
    final icon = t.direction == TransferDirection.download
        ? Icons.download_rounded
        : Icons.upload_rounded;
    final tone = err
        ? colors.error
        : ok
            ? colors.success
            : colors.accent;
    final pct = t.fraction == null ? null : (t.fraction! * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            err
                ? Icons.error_outline
                : ok
                    ? Icons.check_circle_outline
                    : icon,
            size: 16,
            color: tone,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5, color: colors.textPrimary),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      err
                          ? 'error'
                          : ok
                              ? 'listo'
                              : (pct == null ? '…' : '$pct%'),
                      style: TextStyle(fontSize: 11, color: tone),
                    ),
                  ],
                ),
                if (t.isRunning) ...[
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: t.fraction,
                      minHeight: 3,
                      backgroundColor: colors.surfaceVariant,
                      color: colors.accent,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!t.isRunning)
            IconButton(
              icon: Icon(Icons.close, size: 15, color: colors.textDisabled),
              // Objetivo táctil real de 44dp aunque el icono visible sea de
              // 15dp: `BoxConstraints()` vacío colapsaba el hit-test al
              // tamaño del icono.
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              tooltip: Strings.of(context).inAppDismiss,
              onPressed: service.clearFinished,
            ),
        ],
      ),
    );
  }
}
