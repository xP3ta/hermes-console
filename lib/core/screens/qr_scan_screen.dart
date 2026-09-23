import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

import '../../l10n/app_localizations.dart';
import '../services/pairing_link.dart';
import '../widgets/hermes_notice.dart';
import '../widgets/platform_setup_commands.dart';

/// Escanea el QR de emparejado (`hermes://pair?...`) que imprime el servidor y
/// devuelve el [PairingLink] vía `Navigator.pop`. La cámara solo vive aquí.
/// Incluye una alternativa sin cámara: pegar el enlace desde el portapapeles.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final GlobalKey _qrViewKey = GlobalKey(debugLabel: 'hermesQrScanner');
  QRViewController? _controller;
  StreamSubscription<Barcode>? _scanSubscription;
  bool _handled = false;
  bool _cameraUnavailable = false;

  @override
  void dispose() {
    unawaited(_scanSubscription?.cancel());
    super.dispose();
  }

  void _onQrViewCreated(QRViewController controller) {
    _controller = controller;
    unawaited(_scanSubscription?.cancel());
    _scanSubscription = controller.scannedDataStream.listen(
      _onDetect,
      onError: (_) {
        if (mounted) setState(() => _cameraUnavailable = true);
      },
    );
  }

  void _onPermissionSet(QRViewController _, bool granted) {
    if (!granted && mounted) {
      setState(() => _cameraUnavailable = true);
    }
  }

  void _onDetect(Barcode barcode) {
    if (_handled) return;
    final raw = barcode.code;
    if (raw == null) return;
    final link = PairingLink.tryParse(raw);
    if (link != null) _accept(link);
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller?.toggleFlash();
    } catch (_) {
      if (mounted) setState(() => _cameraUnavailable = true);
    }
  }

  void _accept(PairingLink link) {
    if (_handled) return;
    _handled = true;
    Navigator.of(context).pop(link);
  }

  Future<void> _pasteLink() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    final link = PairingLink.tryParse(raw);
    if (!mounted) return;
    if (link != null) {
      _accept(link);
    } else {
      HermesNotice.of(context).showSnackBar(
        SnackBar(content: Text(Strings.of(context).qrClipboardInvalid)),
        kind: HermesNoticeKind.warning,
      );
    }
  }

  void _showServerCommand() {
    // Los comandos cortos reimprimen el mismo QR/enlace, pero el usuario debe
    // elegir el sistema del equipo que ejecuta Hermes (no el del teléfono).
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(Strings.of(context).qrGenTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(Strings.of(context).qrGenBody),
              const SizedBox(height: 12),
              const PlatformSetupCommands(pairing: true),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(Strings.of(context).commonClose),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(Strings.of(context).qrScanTitle),
        actions: [
          IconButton(
            tooltip: Strings.of(context).qrTorch,
            icon: const Icon(Icons.flash_on),
            onPressed: _cameraUnavailable ? null : _toggleTorch,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _cameraUnavailable
                ? _CameraError(onPaste: _pasteLink)
                : QRView(
                    key: _qrViewKey,
                    onQRViewCreated: _onQrViewCreated,
                    onPermissionSet: _onPermissionSet,
                    formatsAllowed: const [BarcodeFormat.qrcode],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  Strings.of(context).qrAimHint,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.content_paste),
                  label: Text(Strings.of(context).qrPasteInstead),
                  onPressed: _pasteLink,
                ),
                TextButton(
                  onPressed: _showServerCommand,
                  child: Text(Strings.of(context).qrHowTo),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.onPaste});

  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, size: 48),
            const SizedBox(height: 12),
            Text(
              Strings.of(context).qrCameraError,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.content_paste),
              label: Text(Strings.of(context).qrPasteLink),
              onPressed: onPaste,
            ),
          ],
        ),
      ),
    );
  }
}
