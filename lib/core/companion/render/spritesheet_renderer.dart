import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/companion.dart';
import '../models/companion_animation_state.dart';
import '../models/companion_display_settings.dart';

/// Renderiza y anima una mascota a partir de su spritesheet (grid de frames).
///
/// - Estados con `loop=true` (idle/run/waiting) ciclan; el resto (wave/failed…)
///   se reproducen una vez y se quedan en el último frame.
/// - Respeta `MediaQuery.disableAnimations` (reduce-motion): muestra un frame
///   estático sin animación de bucle (FR-008).
/// - Avanza en pasos discretos al FPS declarado por la mascota. Un
///   `AnimationController.repeat()` notifica en cada vsync (120 Hz en el Pixel)
///   aunque el manifest diga 8 FPS; multiplicado por cada mensaje visible era
///   una fuente importante de raster/GC durante el scroll.
/// - Se detiene fuera de [TickerMode], en background, con reduce-motion o si la
///   superficie solicita un frame estático.
/// - Cada paso del reloj solo repinta la capa del sprite: no reconstruye
///   widgets. Dentro de la pista del paseo de Inicio (con su
///   `LayoutBuilder`), un `setState` por frame repintaba también el contenido
///   del Home que queda debajo.
class SpritesheetRenderer extends StatefulWidget {
  final Companion companion;
  final CompanionAnimationState state;
  final double size;

  /// Fila a reproducir forzada (para el probador de animaciones extra). Si es
  /// `null` se usa la fila del [state].
  final RowSpec? overrideRow;

  /// Contador para **reiniciar** la animación actual desde el frame 0 aunque el
  /// [state] no cambie (p. ej. tocar repetidamente la mascota para que vuelva a
  /// saludar). Cuando este valor cambia, el renderer reconfigura la animación.
  final int replayToken;

  /// Si es `false`, pinta el primer frame sin programar trabajo periódico.
  /// Las presencias históricas y los previews usan esta ruta; Home y estados
  /// vivos conservan la animación fluida a los FPS del manifest.
  final bool animate;

  /// Multiplicador persistido por mascota. 0.5× permite calmar sprites con un
  /// atlas demasiado rápido; 1× respeta el FPS declarado en pet.json.
  final double speedMultiplier;

  /// Sonda únicamente para tests de cadencia/lifecycle. Nunca recibe píxeles ni
  /// contenido sensible; solo el índice entero del frame que acaba de cambiar.
  @visibleForTesting
  final ValueChanged<int>? onFrameChanged;

  /// Fuente en memoria para tests. En producción siempre se resuelve el asset
  /// o fichero declarado por [companion].
  @visibleForTesting
  final ImageProvider? imageProvider;

  const SpritesheetRenderer({
    super.key,
    required this.companion,
    required this.state,
    this.size = 96,
    this.overrideRow,
    this.replayToken = 0,
    this.animate = true,
    this.speedMultiplier = CompanionDisplaySettings.defaultAnimationSpeed,
    this.onFrameChanged,
    this.imageProvider,
  });

  @override
  State<SpritesheetRenderer> createState() => _SpritesheetRendererState();
}

class _SpritesheetRendererState extends State<SpritesheetRenderer>
    with WidgetsBindingObserver {
  Timer? _frameTimer;

  /// Frame visible. El painter escucha este notifier: avanzar la animación
  /// marca solo su `RepaintBoundary`, sin reconstruir ningún elemento.
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  int get _frameIndex => _frame.value;
  bool _tickerModeEnabled = true;
  bool _reduceMotion = false;
  bool _appActive = true;
  ui.Image? _image;
  List<ui.Image> _preparedFrames = const [];
  ui.Image? _preparedSource;
  int? _preparedRow;
  int? _preparedFrameCount;
  int? _preparedCols;
  int? _preparedRows;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _resolvedDecodeSize;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // La imagen se resuelve en didChangeDependencies, cuando ya conocemos el
    // pixel ratio real. Decodificar el atlas completo aquí podía reservar
    // cientos de MB con mascotas importadas de alta resolución.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerMode = TickerMode.valuesOf(context).enabled;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final decodeSize = _decodeSizeFor(devicePixelRatio);
    if (_stream == null || _resolvedDecodeSize != decodeSize) {
      _resolveImage(devicePixelRatio);
    }
    if (_tickerModeEnabled != tickerMode || _reduceMotion != reduceMotion) {
      _tickerModeEnabled = tickerMode;
      _reduceMotion = reduceMotion;
      _syncFrameClock();
    }
  }

  @override
  void didUpdateWidget(covariant SpritesheetRenderer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final companionChanged = oldWidget.companion != widget.companion;
    final sourceChanged =
        oldWidget.companion.spritesheetAsset !=
            widget.companion.spritesheetAsset ||
        oldWidget.imageProvider != widget.imageProvider;
    final devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final decodeSizeChanged =
        _resolvedDecodeSize != _decodeSizeFor(devicePixelRatio);
    if (sourceChanged || decodeSizeChanged) {
      _frameTimer?.cancel();
      _frameTimer = null;
      _disposePreparedFrames();
      _image = null;
      _resolvedDecodeSize = null;
      _resolveImage(devicePixelRatio);
      return;
    }
    if ((companionChanged ||
            oldWidget.state != widget.state ||
            oldWidget.overrideRow != widget.overrideRow ||
            oldWidget.replayToken != widget.replayToken) &&
        _image != null) {
      _configureForState();
      return;
    }
    if (oldWidget.animate != widget.animate) {
      if (!widget.animate) _setFrame(0);
      _syncFrameClock();
    } else if (oldWidget.speedMultiplier != widget.speedMultiplier) {
      _syncFrameClock();
    }
  }

  RowSpec get _row =>
      widget.overrideRow ??
      widget.companion.rowFor(widget.state) ??
      widget.companion.states[CompanionAnimationState.idle]!;

  void _configureForState() {
    _frameTimer?.cancel();
    _frameTimer = null;
    _prepareFramesForRow();
    _setFrame(0, notifyWidget: true);
    _syncFrameClock();
  }

  /// Materializa una sola vez las celdas de la fila activa como texturas
  /// pequeñas. El reloj cambia después entre esas texturas ya preparadas, en
  /// vez de volver a recortar y filtrar el atlas completo en cada frame.
  ///
  /// En el Pixel, un atlas Petdex de 1536x1872 mantenía un coste visible incluso
  /// a 8 fps. Las celdas del Home, después del decode acotado, ocupan solo unos
  /// cientos de KiB en total y se liberan al cambiar de fila o de mascota.
  void _prepareFramesForRow() {
    final image = _image;
    if (image == null) {
      _disposePreparedFrames();
      return;
    }
    final row = _row;
    if (identical(_preparedSource, image) &&
        _preparedRow == row.row &&
        _preparedFrameCount == row.frameCount &&
        _preparedCols == widget.companion.cols &&
        _preparedRows == widget.companion.rows) {
      return;
    }

    _disposePreparedFrames();
    final frameWidth = image.width ~/ widget.companion.cols;
    final frameHeight = image.height ~/ widget.companion.rows;
    if (frameWidth <= 0 || frameHeight <= 0) return;

    final prepared = <ui.Image>[];
    try {
      for (var col = 0; col < row.frameCount; col++) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(
            (col * frameWidth).toDouble(),
            (row.row * frameHeight).toDouble(),
            frameWidth.toDouble(),
            frameHeight.toDouble(),
          ),
          Rect.fromLTWH(0, 0, frameWidth.toDouble(), frameHeight.toDouble()),
          Paint(),
        );
        final picture = recorder.endRecording();
        try {
          prepared.add(picture.toImageSync(frameWidth, frameHeight));
        } finally {
          picture.dispose();
        }
      }
    } catch (_) {
      for (final frame in prepared) {
        frame.dispose();
      }
      // Algunos backends de test o dispositivos sin contexto gráfico pueden no
      // soportar toImageSync. Conservamos el painter anterior como fallback.
      return;
    }

    _preparedFrames = prepared;
    _preparedSource = image;
    _preparedRow = row.row;
    _preparedFrameCount = row.frameCount;
    _preparedCols = widget.companion.cols;
    _preparedRows = widget.companion.rows;
  }

  void _disposePreparedFrames() {
    for (final frame in _preparedFrames) {
      frame.dispose();
    }
    _preparedFrames = const [];
    _preparedSource = null;
    _preparedRow = null;
    _preparedFrameCount = null;
    _preparedCols = null;
    _preparedRows = null;
  }

  @visibleForTesting
  static Duration intervalForFps(double fps) {
    // Decorative atlases do not benefit from display-rate rebuilds. A hard
    // 30 fps ceiling preserves every existing low-fps manifest while bounding
    // CPU/raster work on 60/120 Hz panels and aggressive speed multipliers.
    final safeFps = fps.clamp(1, 30);
    return Duration(
      microseconds: (Duration.microsecondsPerSecond / safeFps).round(),
    );
  }

  bool get _shouldAnimate =>
      mounted &&
      _image != null &&
      widget.animate &&
      _appActive &&
      _tickerModeEnabled &&
      !_reduceMotion &&
      _row.frameCount > 1;

  void _syncFrameClock() {
    _frameTimer?.cancel();
    _frameTimer = null;
    if (!_shouldAnimate) return;
    _frameTimer = Timer.periodic(
      intervalForFps(
        widget.companion.fps *
            CompanionDisplaySettings.clampAnimationSpeed(
              widget.speedMultiplier,
            ),
      ),
      (_) => _advanceFrame(),
    );
  }

  void _advanceFrame() {
    if (!_shouldAnimate) {
      _syncFrameClock();
      return;
    }
    final row = _row;
    final next = _frameIndex + 1;
    if (next >= row.frameCount) {
      if (!row.loop) {
        _frameTimer?.cancel();
        _frameTimer = null;
        _setFrame(row.frameCount - 1);
        return;
      }
      _setFrame(0);
      return;
    }
    _setFrame(next);
  }

  void _setFrame(int value, {bool notifyWidget = false}) {
    final safe = value.clamp(0, _row.frameCount - 1).toInt();
    if (_frameIndex == safe && !notifyWidget) return;
    _frame.value = safe;
    // Solo un cambio de fila o de atlas altera la estructura del painter.
    if (notifyWidget && mounted) setState(() {});
    widget.onFrameChanged?.call(safe);
  }

  Size _decodeSizeFor(double devicePixelRatio) {
    // Para un spritesheet importa el tamaño de cada celda, no el del atlas
    // completo. Limitamos el DPR efectivo y usamos tres buckets compartibles:
    // evita crear una imagen distinta por cada paso del slider de tamaño.
    final effectiveDpr = devicePixelRatio.clamp(1.0, 2.0);
    final requiredFrameExtent = widget.size * effectiveDpr;
    final frameExtent = requiredFrameExtent <= 128
        ? 128
        : requiredFrameExtent <= 256
        ? 256
        : 384;
    final nativeMaxSide =
        widget.companion.frameWidth > widget.companion.frameHeight
        ? widget.companion.frameWidth
        : widget.companion.frameHeight;
    final frameWidth =
        (frameExtent * widget.companion.frameWidth / nativeMaxSide)
            .round()
            .clamp(1, 384);
    final frameHeight =
        (frameExtent * widget.companion.frameHeight / nativeMaxSide)
            .round()
            .clamp(1, 384);
    return Size(
      (frameWidth * widget.companion.cols).toDouble(),
      (frameHeight * widget.companion.rows).toDouble(),
    );
  }

  void _resolveImage(double devicePixelRatio) {
    _disposeStream();
    // Base → asset empaquetado; importada/generada → fichero del sandbox.
    final ImageProvider source =
        widget.imageProvider ??
        (widget.companion.isFileBacked
            ? FileImage(File(widget.companion.spritesheetAsset))
            : AssetImage(widget.companion.spritesheetAsset));
    final decodeSize = _decodeSizeFor(devicePixelRatio);
    _resolvedDecodeSize = decodeSize;
    final provider = ResizeImage.resizeIfNeeded(
      decodeSize.width.round(),
      decodeSize.height.round(),
      source,
    );
    final stream = provider.resolve(
      ImageConfiguration(devicePixelRatio: devicePixelRatio),
    );
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() => _image = info.image);
        _configureForState();
      },
      onError: (_, _) {
        // Si la imagen no carga, el widget queda en blanco; el fallback a
        // HermesSparkMascot lo decide CompanionView a partir de la validez.
      },
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  void _disposeStream() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) return;
    _appActive = active;
    _syncFrameClock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frameTimer?.cancel();
    _frameTimer = null;
    _disposePreparedFrames();
    _disposeStream();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return SizedBox(width: widget.size, height: widget.size);
    }

    return RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.size, widget.size),
        painter: SpriteFramePainter(
          image: image,
          preparedFrames: _preparedFrames,
          frameWidth: image.width ~/ widget.companion.cols,
          frameHeight: image.height ~/ widget.companion.rows,
          row: _row.row,
          frame: _frame,
          staticFrame: _reduceMotion || !widget.animate,
        ),
      ),
    );
  }
}

/// Pinta el frame actual de [frame] sin pasar por `build`.
///
/// Usa la celda ya preparada (equivalente a `RawImage` con `BoxFit.contain`)
/// o, si el backend no pudo prepararlas, recorta la celda del atlas.
@visibleForTesting
class SpriteFramePainter extends CustomPainter {
  final ui.Image image;
  final List<ui.Image> preparedFrames;
  final int frameWidth;
  final int frameHeight;
  final int row;
  final ValueListenable<int> frame;
  final bool staticFrame;

  SpriteFramePainter({
    required this.image,
    required this.preparedFrames,
    required this.frameWidth,
    required this.frameHeight,
    required this.row,
    required this.frame,
    required this.staticFrame,
  }) : super(repaint: frame);

  int get _index => staticFrame ? 0 : frame.value;

  /// Celda preparada que se pintaría ahora; `null` en la ruta de fallback.
  @visibleForTesting
  ui.Image? get currentFrameImage {
    final index = _index;
    return index < preparedFrames.length ? preparedFrames[index] : null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final prepared = currentFrameImage;
    if (prepared != null) {
      paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: prepared,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
      return;
    }
    final col = _index;
    final src = Rect.fromLTWH(
      (col * frameWidth).toDouble(),
      (row * frameHeight).toDouble(),
      frameWidth.toDouble(),
      frameHeight.toDouble(),
    );
    // Escala "contain" preservando la relación de aspecto del frame.
    final scale = (size.width / frameWidth) < (size.height / frameHeight)
        ? size.width / frameWidth
        : size.height / frameHeight;
    final dstW = frameWidth * scale;
    final dstH = frameHeight * scale;
    final dst = Rect.fromLTWH(
      (size.width - dstW) / 2,
      (size.height - dstH) / 2,
      dstW,
      dstH,
    );
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant SpriteFramePainter old) =>
      old.image != image ||
      !identical(old.preparedFrames, preparedFrames) ||
      old.frameWidth != frameWidth ||
      old.frameHeight != frameHeight ||
      old.row != row ||
      old.frame != frame ||
      old.staticFrame != staticFrame;
}
