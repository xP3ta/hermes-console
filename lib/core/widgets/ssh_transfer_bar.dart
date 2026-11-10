import 'package:flutter/material.dart';

import '../services/sftp_transfer_service.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart' show HermesChrome;
import '../theme/text_scale.dart';
import '../../l10n/app_localizations.dart';

/// Barra in-app que muestra las transferencias SFTP (en curso y recién
/// terminadas), con su barra de progreso. Observa el servicio, así que sigue
/// reflejando el avance aunque cambies de pantalla y vuelvas.
///
/// the owner (Fold horizontal, APK 9708): «email-nous.txt · listo ×» ocupaba un
/// bloque grande al pie de Archivos. Ahora es una pastilla fina con una
/// fila de 48 dp por transferencia, sin banda de fondo.
class SshTransferBar extends StatelessWidget {
  final SftpTransferService service;

  /// A finished download's «Ver»: what can be done with the document
  /// written (Abrir, Compartir, Guardar otra copia…). Without it, the row
  /// only says it is done.
  final void Function(SftpTransfer transfer)? onShowDownload;

  /// A failed download's «Reintentar».
  final void Function(SftpTransfer transfer)? onRetry;

  const SshTransferBar({
    required this.service,
    this.onShowDownload,
    this.onRetry,
    super.key,
  });

  /// One transfer's row: a 48 dp touch target and nothing more.
  static const double rowHeight = 48;

  /// The pill's corners (mock 136 v2-A's row radius).
  static const double rowRadius = 16;

  static final ButtonStyle _rowButton = TextButton.styleFrom(
    minimumSize: const Size(rowHeight, rowHeight),
    padding: const EdgeInsets.symmetric(horizontal: 10),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return ValueListenableBuilder<List<SftpTransfer>>(
      valueListenable: service.transfers,
      builder: (context, list, _) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: DecoratedBox(
            key: const ValueKey('sftp-transfer-bar'),
            decoration: ShapeDecoration(
              color: colors.surfaceVariant,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(rowRadius),
              ),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 12, end: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final t in list) _row(context, colors, t),
                ],
              ),
            ),
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
    return ConstrainedBox(
      key: ValueKey('sftp-transfer-row-${t.id}'),
      constraints: const BoxConstraints(minHeight: rowHeight),
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
                        // Ola 8: two lines once the text is enlarged.
                        maxLines: labelMaxLines(context),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5, color: colors.textPrimary),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      err
                          ? Strings.of(context).m1215TransferError
                          : ok
                              ? Strings.of(context).m1215TransferDone
                              : (pct == null ? '…' : '$pct%'),
                      style: TextStyle(fontSize: 11, color: tone),
                    ),
                  ],
                ),
                // Why it failed (no room, a file that is gone…), in words.
                if (err && (t.error ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    t.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ],
                if (t.isRunning) ...[
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: t.fraction,
                      minHeight: 3,
                      // The pill is surfaceVariant: a track of the same
                      // colour could not be seen (audit §2.8).
                      backgroundColor: HermesChrome.of(colors).line,
                      color: colors.accent,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (ok && t.saved != null && onShowDownload != null)
            TextButton(
              key: ValueKey('sftp-transfer-show-${t.id}'),
              style: _rowButton,
              onPressed: () => onShowDownload!(t),
              child: Text(Strings.of(context).sftpDlShow),
            ),
          if (err &&
              t.direction == TransferDirection.download &&
              t.remotePath.isNotEmpty &&
              onRetry != null)
            TextButton(
              key: ValueKey('sftp-transfer-retry-${t.id}'),
              style: _rowButton,
              onPressed: () => onRetry!(t),
              child: Text(Strings.of(context).commonRetry),
            ),
          if (!t.isRunning)
            IconButton(
              icon: Icon(Icons.close, size: 15, color: colors.textDisabled),
              // Objetivo táctil real de 48dp aunque el icono visible sea de
              // 15dp: `BoxConstraints()` vacío colapsaba el hit-test al
              // tamaño del icono.
              constraints: const BoxConstraints(
                minWidth: rowHeight,
                minHeight: rowHeight,
              ),
              // «Dismiss» this row, as its tooltip says; the others stay.
              tooltip: Strings.of(context).inAppDismiss,
              onPressed: () => service.dismiss(t),
            ),
        ],
      ),
    );
  }
}
