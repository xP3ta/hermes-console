import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../widgets/hermes_app_bar.dart';

class ImageViewerScreen extends StatelessWidget {
  final String imageUrl;
  final Uint8List? imageBytes;
  final Object? heroTag;

  const ImageViewerScreen({
    super.key,
    required this.imageUrl,
    this.imageBytes,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: HermesAppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        // Solo brillo de iconos: con edge-to-edge forzado (Android 15+ /
        // targetSdk 35+) los colores de barra son parámetros deprecated e
        // ignorados; pasarlos dispara el aviso de compatibilidad de Play.
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        leading: Semantics(
          label: Strings.of(context).commonClose,
          button: true,
          onTap: () => Navigator.pop(context),
          excludeSemantics: true,
          child: IconButton(
            icon: const Icon(Icons.close),
            tooltip: Strings.of(context).commonClose,
            onPressed: () => Navigator.pop(context),
          ),
        ),
      ),
      body: Center(
        child: Hero(
          tag: heroTag ?? imageUrl,
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: imageBytes != null
                ? Image.memory(imageBytes!, fit: BoxFit.contain)
                : Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white38,
                      size: 64,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
