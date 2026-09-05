// STT en vivo on-device con sherpa-onnx: micrófono → VAD (silero) → reconocedor
// offline (Whisper / Parakeet). Da parciales mientras hablas (frase a frase, al
// estilo Jarvis) y un final al detectar fin de habla por VAD. 100% en el
// dispositivo, sin nube: a diferencia del reconocedor del sistema, NO necesita
// servicios de Google, así que funciona en GrapheneOS y móviles desgooglizados.
//
// No hay modelo de STT *streaming* (token a token) en español on-device; el
// truco para la sensación "en vivo" es: VAD que trocea el audio en frases +
// reconocedor offline que transcribe cada frase en cuanto haces una pausa.
//
// Los modelos se descargan bajo demanda (ver SherpaSttModelManager); cada uno se
// puede elegir en Ajustes › Voz.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'model_download.dart';
import 'sherpa_stt_worker.dart';
import 'stt_engine.dart';
import 'voice_latency_trace.dart';
import 'voice_response_policy.dart';

/// Qué modelo de reconocimiento usar. Los tres son en español (Whisper es
/// multilingüe; Parakeet v3 incluye español).
enum SherpaModelKind {
  whisperBase('whisper-base'),
  whisperSmall('whisper-small'),
  parakeetV3('parakeet-v3');

  const SherpaModelKind(this.id);
  final String id;

  static SherpaModelKind from(String? v) => values.firstWhere(
    (e) => e.id == v,
    orElse: () => SherpaModelKind.whisperBase,
  );
}

/// Un modelo de STT descargable para sherpa-onnx. Whisper trae encoder+decoder;
/// Parakeet es un transductor (encoder+decoder+joiner). Todos comparten el VAD
/// silero (un .onnx pequeño aparte).
class SherpaSttModel {
  final SherpaModelKind kind;
  final String displayName;
  final String quality; // copy corto para la UI
  final int sizeMb; // tamaño aproximado de la descarga
  final int ramMb; // RAM aproximada en uso (para avisar de OOM)
  final String url; // .tar.bz2 en el release asr-models
  final String dirName; // carpeta raíz dentro del tar
  final bool isTransducer; // true = Parakeet (encoder/decoder/joiner)
  final String tokens;
  final String encoder;
  final String decoder;
  final String joiner; // '' para Whisper

  const SherpaSttModel({
    required this.kind,
    required this.displayName,
    required this.quality,
    required this.sizeMb,
    required this.ramMb,
    required this.url,
    required this.dirName,
    required this.isTransducer,
    required this.tokens,
    required this.encoder,
    required this.decoder,
    this.joiner = '',
  });

  String get id => kind.id;

  /// ¿Conviene avisar del consumo de memoria? (Parakeet ronda 1 GB y puede
  /// quedarse sin RAM en móviles modestos.)
  bool get heavyRam => ramMb >= 1000;
}

const String _asrRelease =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';

/// VAD silero (compartido por todos los modelos): un único .onnx ligero.
const String _sileroUrl = '$_asrRelease/silero_vad.onnx';

const List<SherpaSttModel> kSherpaSttModels = [
  SherpaSttModel(
    kind: SherpaModelKind.whisperBase,
    displayName: 'Whisper base',
    quality: 'Balanced · low RAM · recommended',
    sizeMb: 210,
    ramMb: 450,
    url: '$_asrRelease/sherpa-onnx-whisper-base.tar.bz2',
    dirName: 'sherpa-onnx-whisper-base',
    isTransducer: false,
    tokens: 'base-tokens.txt',
    encoder: 'base-encoder.int8.onnx',
    decoder: 'base-decoder.int8.onnx',
  ),
  SherpaSttModel(
    kind: SherpaModelKind.whisperSmall,
    displayName: 'Whisper small',
    quality: 'More accurate · medium RAM',
    sizeMb: 640,
    ramMb: 750,
    url: '$_asrRelease/sherpa-onnx-whisper-small.tar.bz2',
    dirName: 'sherpa-onnx-whisper-small',
    isTransducer: false,
    tokens: 'small-tokens.txt',
    encoder: 'small-encoder.int8.onnx',
    decoder: 'small-decoder.int8.onnx',
  ),
  SherpaSttModel(
    kind: SherpaModelKind.parakeetV3,
    displayName: 'Parakeet v3',
    quality: 'Highest accuracy · ~1.2 GB RAM',
    sizeMb: 490,
    ramMb: 1200,
    url: '$_asrRelease/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2',
    dirName: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8',
    isTransducer: true,
    tokens: 'tokens.txt',
    encoder: 'encoder.int8.onnx',
    decoder: 'decoder.int8.onnx',
    joiner: 'joiner.int8.onnx',
  ),
];

SherpaSttModel sherpaModelByKind(SherpaModelKind kind) =>
    kSherpaSttModels.firstWhere((m) => m.kind == kind);

/// Fase de preparación del modelo (mismo contrato que el gestor de TTS).
enum SherpaPrepPhase { downloading, extracting, done }

class SherpaPrepProgress {
  final SherpaPrepPhase phase;

  /// 0..1 durante la descarga; -1 (indeterminado) durante la extracción.
  final double value;
  const SherpaPrepProgress(this.phase, this.value);
}

/// Descarga y gestiona los modelos de STT y el VAD silero en almacenamiento
/// privado de la app. La extracción del .tar.bz2 corre en un isolate.
class SherpaSttModelManager {
  final Map<String, http.Client> _activeDownloads = {};
  final Set<String> _cancelledDownloads = {};

  void cancelDownload(SherpaSttModel m) {
    _cancelledDownloads.add(m.id);
    _activeDownloads[m.id]?.close();
  }

  Future<Directory> _baseDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/stt_sherpa_models');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<String> sileroPath() async =>
      '${(await _baseDir()).path}/silero_vad.onnx';

  Future<bool> sileroReady() async => File(await sileroPath()).existsSync();

  Future<Directory> modelDir(SherpaSttModel m) async =>
      Directory('${(await _baseDir()).path}/${m.dirName}');

  Future<String> tokensPath(SherpaSttModel m) async =>
      '${(await modelDir(m)).path}/${m.tokens}';
  Future<String> encoderPath(SherpaSttModel m) async =>
      '${(await modelDir(m)).path}/${m.encoder}';
  Future<String> decoderPath(SherpaSttModel m) async =>
      '${(await modelDir(m)).path}/${m.decoder}';
  Future<String> joinerPath(SherpaSttModel m) async =>
      '${(await modelDir(m)).path}/${m.joiner}';

  /// ¿Listo para usar? Modelo (todos sus archivos) + VAD silero presentes.
  Future<bool> isReady(SherpaSttModel m) async {
    if (!File(await encoderPath(m)).existsSync()) return false;
    if (!File(await decoderPath(m)).existsSync()) return false;
    if (!File(await tokensPath(m)).existsSync()) return false;
    if (m.isTransducer && !File(await joinerPath(m)).existsSync()) return false;
    return sileroReady();
  }

  Future<void> delete(SherpaSttModel m) async {
    final dir = await modelDir(m);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    // El silero se queda: lo comparten todos los modelos.
  }

  /// Descarga el VAD silero si falta (es pequeño, ~2 MB). Sin progreso visible.
  Future<void> _ensureSilero(http.Client client) async {
    final path = await sileroPath();
    if (File(path).existsSync()) return;
    final res = await client.get(Uri.parse(_sileroUrl));
    if (res.statusCode != 200) {
      throw Exception('VAD download failed (HTTP ${res.statusCode}).');
    }
    await File(path).writeAsBytes(res.bodyBytes, flush: true);
  }

  /// Descarga (con progreso, a disco) y extrae el modelo, y asegura el VAD.
  /// Idempotente: si ya está listo, no hace nada.
  Future<void> download(
    SherpaSttModel m, {
    void Function(SherpaPrepProgress)? onProgress,
  }) async {
    if (await isReady(m)) {
      onProgress?.call(const SherpaPrepProgress(SherpaPrepPhase.done, 1));
      return;
    }
    final base = await _baseDir();
    final client = http.Client();
    _activeDownloads[m.id] = client;

    try {
      // VAD primero (rápido); así un fallo de red se ve antes de bajar cientos
      // de MB y también queda cubierto por Cancelar.
      await _ensureSilero(client);
      if (_cancelledDownloads.contains(m.id)) {
        throw const ModelDownloadCancelled();
      }

      // ¿Hace falta bajar el modelo, o solo faltaba el VAD?
      final modelPresent =
          File(await encoderPath(m)).existsSync() &&
          File(await decoderPath(m)).existsSync() &&
          File(await tokensPath(m)).existsSync() &&
          (!m.isTransducer || File(await joinerPath(m)).existsSync());
      if (!modelPresent) {
        final tmp = File('${base.path}/${m.dirName}.tar.bz2.part');
        try {
          final req = http.Request('GET', Uri.parse(m.url));
          final res = await client.send(req);
          if (res.statusCode != 200) {
            throw Exception('Model download failed (HTTP ${res.statusCode}).');
          }
          final total = res.contentLength ?? (m.sizeMb * 1024 * 1024);
          var received = 0;
          final sink = tmp.openWrite();
          try {
            await for (final chunk in res.stream) {
              sink.add(chunk);
              received += chunk.length;
              onProgress?.call(
                SherpaPrepProgress(
                  SherpaPrepPhase.downloading,
                  total > 0 ? received / total : 0,
                ),
              );
            }
          } finally {
            await sink.close();
          }

          if (_cancelledDownloads.contains(m.id)) {
            throw const ModelDownloadCancelled();
          }
          onProgress?.call(
            const SherpaPrepProgress(SherpaPrepPhase.extracting, -1),
          );
          final requiredFiles = <String>[
            m.tokens,
            m.encoder,
            m.decoder,
            if (m.isTransducer) m.joiner,
          ];
          await Isolate.run(
            () => extractSherpaModelArchive(
              tmp.path,
              base.path,
              dirName: m.dirName,
              requiredFiles: requiredFiles,
            ),
          );
        } finally {
          if (tmp.existsSync()) tmp.deleteSync();
        }
      }
    } catch (e) {
      if (_cancelledDownloads.contains(m.id)) {
        throw const ModelDownloadCancelled();
      }
      rethrow;
    } finally {
      client.close();
      _activeDownloads.remove(m.id);
      _cancelledDownloads.remove(m.id);
    }

    if (!await isReady(m)) {
      throw Exception(
        'Model downloaded but files are missing after extraction.',
      );
    }
    onProgress?.call(const SherpaPrepProgress(SherpaPrepPhase.done, 1));
  }
}

/// Extrae únicamente los artefactos int8 que usa la app, sin materializar en
/// RAM el archivo comprimido ni el tar completo. Whisper Small expande a más de
/// 1,3 GB porque el release también contiene los modelos float32; el extractor
/// anterior mantenía a la vez esos bytes y los ~640 MB comprimidos y Android
/// podía matar el proceso sin entregar una excepción a Flutter.
///
/// Top-level para [Isolate.run]. También lo reutilizan modelos Sherpa pequeños
/// que comparten este contrato de extracción mediante allowlist.
void extractSherpaModelArchive(
  String tarBz2Path,
  String destRoot, {
  required String dirName,
  required List<String> requiredFiles,
}) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(dirName) ||
      requiredFiles.isEmpty ||
      requiredFiles.toSet().length != requiredFiles.length ||
      requiredFiles.any(
        (name) => !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name),
      )) {
    throw const FormatException('Invalid local STT model catalog.');
  }

  final root = Directory(destRoot);
  root.createSync(recursive: true);
  final stage = Directory('${root.path}/$dirName.extracting');
  final target = Directory('${root.path}/$dirName');
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);

  final allowed = <String, String>{
    for (final name in requiredFiles) '$dirName/$name': name,
  };
  final input = InputFileStream(tarBz2Path);
  final output = _SelectedModelTarSink(stage, allowed);
  var installed = false;
  try {
    final decoded = BZip2Decoder().decodeStream(input, output, verify: true);
    if (!decoded) {
      throw const FormatException('The model BZip2 file is corrupt.');
    }
    output.complete();
    if (target.existsSync()) target.deleteSync(recursive: true);
    stage.renameSync(target.path);
    installed = true;
  } finally {
    input.closeSync();
    output.closeSync();
    if (!installed && stage.existsSync()) stage.deleteSync(recursive: true);
  }
}

/// Consume el tar según el BZip2 lo produce. Solo escribe las rutas exactas del
/// catálogo; el resto (incluidos los ONNX float32) se descarta en streaming.
class _SelectedModelTarSink extends OutputStream {
  _SelectedModelTarSink(this._stage, this._allowed)
    : _required = _allowed.keys.toSet(),
      super(byteOrder: ByteOrder.littleEndian);

  static const int _tarBlockSize = 512;
  static const int _bufferSize = 64 * 1024;
  static const int _maxExpandedTarBytes = 6 * 1024 * 1024 * 1024;
  static const int _maxGnuLongNameBytes = 4096;

  final Directory _stage;
  final Map<String, String> _allowed;
  final Set<String> _required;
  final Set<String> _extracted = {};
  final Uint8List _buffer = Uint8List(_bufferSize);
  final Uint8List _header = Uint8List(_tarBlockSize);

  RandomAccessFile? _file;
  BytesBuilder? _gnuLongNamePayload;
  String? _pendingGnuLongName;
  int _bufferLength = 0;
  int _headerLength = 0;
  int _entryRemaining = 0;
  int _paddingRemaining = 0;
  int _length = 0;
  bool _sawEnd = false;
  bool _closed = false;

  @override
  int get length => _length;

  @override
  bool get isOpen => !_closed;

  @override
  void writeByte(int value) {
    _ensureWritable(1);
    _buffer[_bufferLength++] = value & 0xff;
    if (_bufferLength == _buffer.length) _drainBuffer();
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw RangeError.range(count, 0, bytes.length, 'length');
    }
    _ensureWritable(count);
    var offset = 0;
    while (offset < count) {
      final amount = math.min(_buffer.length - _bufferLength, count - offset);
      _buffer.setRange(_bufferLength, _bufferLength + amount, bytes, offset);
      _bufferLength += amount;
      offset += amount;
      if (_bufferLength == _buffer.length) _drainBuffer();
    }
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final amount = math.min(_bufferSize, stream.length);
      if (amount <= 0) break;
      writeBytes(stream.readBytes(amount).toUint8List());
    }
  }

  void _ensureWritable(int additional) {
    if (_closed) throw StateError('The STT extractor is already closed.');
    if (additional < 0 ||
        _length + _bufferLength + additional > _maxExpandedTarBytes) {
      throw const FormatException('The expanded STT model exceeds the limit.');
    }
  }

  void _drainBuffer() {
    if (_bufferLength == 0) return;
    _consume(_buffer, 0, _bufferLength);
    _length += _bufferLength;
    _bufferLength = 0;
  }

  void _consume(List<int> bytes, int start, int end) {
    var offset = start;
    while (offset < end) {
      if (_sawEnd) return;

      if (_entryRemaining > 0) {
        final amount = math.min(_entryRemaining, end - offset);
        final longNamePayload = _gnuLongNamePayload;
        if (longNamePayload != null) {
          longNamePayload.add(bytes.sublist(offset, offset + amount));
        } else {
          _file?.writeFromSync(bytes, offset, offset + amount);
        }
        _entryRemaining -= amount;
        offset += amount;
        if (_entryRemaining == 0) _finishEntry();
        continue;
      }

      if (_paddingRemaining > 0) {
        final amount = math.min(_paddingRemaining, end - offset);
        _paddingRemaining -= amount;
        offset += amount;
        continue;
      }

      final amount = math.min(_tarBlockSize - _headerLength, end - offset);
      _header.setRange(_headerLength, _headerLength + amount, bytes, offset);
      _headerLength += amount;
      offset += amount;
      if (_headerLength == _tarBlockSize) _startEntry();
    }
  }

  void _startEntry() {
    _headerLength = 0;
    if (_header.every((byte) => byte == 0)) {
      _sawEnd = true;
      return;
    }

    final expectedChecksum = _parseTarNumber(_header, 148, 8, 'checksum');
    var actualChecksum = 0;
    for (var i = 0; i < _header.length; i++) {
      actualChecksum += i >= 148 && i < 156 ? 0x20 : _header[i];
    }
    if (actualChecksum != expectedChecksum) {
      throw const FormatException('Invalid STT tar checksum.');
    }

    final headerName = _normaliseTarName(
      _readTarText(_header, 0, 100),
      _readTarText(_header, 345, 155),
    );
    final size = _parseTarNumber(_header, 124, 12, 'size');
    final type = _header[156];
    final regularFile = type == 0 || type == 0x30;
    final gnuLongName = type == 0x4c;
    if (gnuLongName) {
      if (_pendingGnuLongName != null ||
          headerName != '@LongLink' ||
          size <= 0 ||
          size > _maxGnuLongNameBytes) {
        throw const FormatException(
          'Invalid STT model long-name metadata.',
        );
      }
      _gnuLongNamePayload = BytesBuilder(copy: false);
    }

    final pendingLongName = _pendingGnuLongName;
    if (!gnuLongName) _pendingGnuLongName = null;
    if (pendingLongName != null && !regularFile) {
      throw const FormatException(
        'The STT model long name does not precede a file.',
      );
    }
    final name = pendingLongName ?? headerName;
    final outputName = _allowed[name];
    if (outputName != null) {
      if (!regularFile || !_extracted.add(name)) {
        throw const FormatException(
          'Invalid required STT model entry.',
        );
      }
      _file = File('${_stage.path}/$outputName').openSync(mode: FileMode.write);
    }

    _entryRemaining = size;
    _paddingRemaining =
        (_tarBlockSize - (size % _tarBlockSize)) % _tarBlockSize;
    if (_entryRemaining == 0) _finishEntry();
  }

  void _finishEntry() {
    _file?.flushSync();
    _file?.closeSync();
    _file = null;
    final longNamePayload = _gnuLongNamePayload;
    if (longNamePayload != null) {
      _gnuLongNamePayload = null;
      final raw = longNamePayload.takeBytes();
      final zero = raw.indexOf(0);
      if (zero >= 0 && raw.skip(zero + 1).any((byte) => byte != 0)) {
        throw const FormatException(
          'Invalid STT model long-name metadata.',
        );
      }
      final encodedName = zero < 0 ? raw : raw.sublist(0, zero);
      if (encodedName.isEmpty) {
        throw const FormatException(
          'Empty STT model long-name metadata.',
        );
      }
      _pendingGnuLongName = _normaliseTarName(
        utf8.decode(encodedName, allowMalformed: false),
        '',
      );
    }
  }

  static int _parseTarNumber(
    Uint8List header,
    int offset,
    int fieldLength,
    String field,
  ) {
    final raw = header.sublist(offset, offset + fieldLength);
    if (raw.isNotEmpty && (raw.first & 0x80) != 0) {
      throw FormatException('Campo tar $field no soportado.');
    }
    final zero = raw.indexOf(0);
    final text = ascii
        .decode(zero < 0 ? raw : raw.sublist(0, zero), allowInvalid: false)
        .trim();
    if (text.isEmpty) return 0;
    if (!RegExp(r'^[0-7]+$').hasMatch(text)) {
      throw FormatException('Invalid tar field $field.');
    }
    return int.parse(text, radix: 8);
  }

  static String _readTarText(Uint8List header, int offset, int fieldLength) {
    final raw = header.sublist(offset, offset + fieldLength);
    final zero = raw.indexOf(0);
    return utf8.decode(
      zero < 0 ? raw : raw.sublist(0, zero),
      allowMalformed: false,
    );
  }

  static String _normaliseTarName(String name, String prefix) {
    var value = prefix.isEmpty ? name : '$prefix/$name';
    while (value.startsWith('./')) {
      value = value.substring(2);
    }
    final parts = value.split('/');
    if (value.isEmpty ||
        value.startsWith('/') ||
        value.contains(r'\') ||
        parts.any((part) => part == '..')) {
      throw const FormatException('Ruta insegura en el modelo STT.');
    }
    return value;
  }

  void complete() {
    flush();
    if (!_sawEnd ||
        _entryRemaining != 0 ||
        _file != null ||
        _gnuLongNamePayload != null ||
        _pendingGnuLongName != null) {
      throw const FormatException('The STT model tar is truncated.');
    }
    final missing = _required.difference(_extracted);
    if (missing.isNotEmpty) {
      throw FormatException(
        'Faltan ${missing.length} archivos requeridos del modelo STT.',
      );
    }
  }

  @override
  void flush() {
    _drainBuffer();
    _file?.flushSync();
  }

  @override
  void clear() => throw UnsupportedError('clear');

  @override
  Uint8List subset(int start, [int? end]) => throw UnsupportedError('subset');

  @override
  Future<void> close() async => closeSync();

  @override
  void closeSync() {
    if (_closed) return;
    try {
      flush();
    } finally {
      _file?.closeSync();
      _file = null;
      _closed = true;
    }
  }
}

/// Frontera inyectable con el grabador y la preparación nativa de Sherpa.
abstract class SherpaSttRuntime {
  Future<bool> hasPermission();

  Future<bool> modelReady();

  Future<void> prepare();

  Future<Stream<Uint8List>> startStream();

  Future<void> stop();

  Future<void> dispose();
}

/// Captura PCM usada por el dictado Sherpa/Parakeet en Android.
///
/// `VOICE_RECOGNITION` selecciona el preset del sistema orientado a habla y los
/// efectos best-effort igualan la petición de captura de Hermes Desktop. No se
/// modifica el PCM, el VAD ni el modelo: únicamente cómo Android adquiere el
/// audio antes de entregarlo al worker local.
@visibleForTesting
const kSherpaSttRecordConfig = RecordConfig(
  encoder: AudioEncoder.pcm16bits,
  sampleRate: 16000,
  numChannels: 1,
  echoCancel: true,
  noiseSuppress: true,
  androidConfig: AndroidRecordConfig(
    audioSource: AndroidAudioSource.voiceRecognition,
  ),
);

class _PluginSherpaSttRuntime implements SherpaSttRuntime {
  _PluginSherpaSttRuntime(this._modelReady, this._prepare);

  final AudioRecorder _recorder = AudioRecorder();
  final Future<bool> Function() _modelReady;
  final Future<void> Function() _prepare;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<bool> modelReady() => _modelReady();

  @override
  Future<void> prepare() => _prepare();

  @override
  Future<Stream<Uint8List>> startStream() =>
      _recorder.startStream(kSherpaSttRecordConfig);

  @override
  Future<void> stop() => _recorder.stop();

  @override
  Future<void> dispose() => _recorder.dispose();
}

class _SherpaListenOperation {
  _SherpaListenOperation(this.generation, this.controller, this.latencyTurn);

  final int generation;
  final StreamController<SttResult> controller;
  final VoiceLatencyTurn? latencyTurn;
  final List<Uint8List> pendingAudio = [];
  final List<String> committed = [];
  int pendingAudioBytes = 0;
  bool queueAudioUntilWorkerCommand = true;
  bool acousticSpeechEvidence = false;
  double peakLevel = 0;
  bool cancelled = false;
  bool started = false;
  String? workerError;
}

Uint8List? _pcm16Mono16kFromWav(Uint8List wavBytes) {
  bool tagEquals(int offset, String value) {
    if (offset < 0 || offset + value.length > wavBytes.length) return false;
    for (var index = 0; index < value.length; index++) {
      if (wavBytes[offset + index] != value.codeUnitAt(index)) return false;
    }
    return true;
  }

  if (wavBytes.length < 44 || !tagEquals(0, 'RIFF') || !tagEquals(8, 'WAVE')) {
    return null;
  }
  final data = ByteData.sublistView(wavBytes);
  final riffEnd = 8 + data.getUint32(4, Endian.little);
  if (riffEnd < 12 || riffEnd > wavBytes.length) return null;

  var validFormat = false;
  int? pcmOffset;
  int? pcmLength;
  var chunkOffset = 12;
  while (chunkOffset + 8 <= riffEnd) {
    final chunkSize = data.getUint32(chunkOffset + 4, Endian.little);
    final payloadOffset = chunkOffset + 8;
    if (chunkSize > riffEnd - payloadOffset) return null;
    final payloadEnd = payloadOffset + chunkSize;
    if (tagEquals(chunkOffset, 'fmt ')) {
      if (chunkSize < 16) return null;
      validFormat =
          data.getUint16(payloadOffset, Endian.little) == 1 &&
          data.getUint16(payloadOffset + 2, Endian.little) == 1 &&
          data.getUint32(payloadOffset + 4, Endian.little) == 16000 &&
          data.getUint16(payloadOffset + 12, Endian.little) == 2 &&
          data.getUint16(payloadOffset + 14, Endian.little) == 16;
    } else if (tagEquals(chunkOffset, 'data') && pcmOffset == null) {
      pcmOffset = payloadOffset;
      pcmLength = chunkSize;
    }
    final paddedEnd = payloadEnd + (chunkSize.isOdd ? 1 : 0);
    if (paddedEnd > riffEnd) return null;
    chunkOffset = paddedEnd;
  }

  final offset = pcmOffset;
  final length = pcmLength;
  if (!validFormat ||
      offset == null ||
      length == null ||
      length < 2 ||
      length.isOdd) {
    return null;
  }
  return Uint8List.fromList(
    Uint8List.sublistView(wavBytes, offset, offset + length),
  );
}

/// Motor de STT en vivo on-device. Abre el micro en streaming PCM, alimenta el
/// VAD silero y, por cada frase que el VAD cierra (al hacer una pausa), la
/// transcribe con el reconocedor offline y emite un parcial acumulado. Al
/// detectar fin de habla sostenido (o al parar manualmente) vacía el VAD,
/// transcribe lo que reste y emite el resultado final.
class SherpaSttEngine implements SttEngine, CapturedWavSttEngine {
  final SherpaSttModel model;
  final SherpaSttModelManager manager;

  /// Reporta el nivel de micrófono normalizado (0..1) para el orbe.
  final void Function(double level)? onLevel;

  /// Silencio sostenido tras oír voz para cerrar el turno (fin de habla).
  final Duration silenceTimeout;

  /// Tope de seguridad por turno.
  final Duration maxDuration;

  /// Cierra una captura conversacional que nunca llegó a detectar voz.
  final Duration idleSilenceTimeout;

  /// Idioma en el que decodifican los modelos Whisper ('es'|'en', spec 031).
  /// Parakeet (transducer) es multilingüe automático y lo ignora. Inmutable
  /// por instancia: VoiceService recicla el motor si el idioma cambia.
  final String lang;

  SherpaSttEngine({
    required this.model,
    SherpaSttModelManager? manager,
    this.onLevel,
    this.silenceTimeout = kVoiceTurnSilenceTimeout,
    this.maxDuration = kVoiceTurnMaxDuration,
    this.idleSilenceTimeout = kVoiceTurnIdleSilenceTimeout,
    this.lang = 'es',
    SherpaSttRuntime? runtime,
    SherpaSttWorkerFactory? workerFactory,
    VoiceTurnTimerFactory? timerFactory,
  }) : manager = manager ?? SherpaSttModelManager() {
    _timerFactory =
        timerFactory ?? ((duration, callback) => Timer(duration, callback));
    _workerFactory = runtime == null || workerFactory != null
        ? (workerFactory ?? IsolateSherpaSttWorker.start)
        : null;
    _prepareWorkerAfterRuntime = runtime != null && workerFactory != null;
    _runtime =
        runtime ??
        _PluginSherpaSttRuntime(
          () => this.manager.isReady(model),
          _prepareWorker,
        );
  }

  /// Identidad lógica del recognizer: modelo + idioma. El idioma DEBE formar
  /// parte (contrato I3): con solo `model.id`, cambiar la app de idioma podría
  /// reutilizar un worker Whisper aún configurado en el idioma anterior.
  @visibleForTesting
  static String recognizerCacheKey(SherpaSttModel model, String lang) =>
      '${model.id}:$lang';

  /// Hilos para el reconocedor: núcleos disponibles, acotado a [2, 6].
  static int get _threads => Platform.numberOfProcessors.clamp(2, 6);

  late final SherpaSttRuntime _runtime;
  late final SherpaSttWorkerFactory? _workerFactory;
  late final bool _prepareWorkerAfterRuntime;
  late final VoiceTurnTimerFactory _timerFactory;
  SherpaSttWorker? _worker;
  Future<SherpaSttWorker>? _workerStart;
  StreamSubscription<SherpaSttWorkerUpdate>? _workerUpdates;

  StreamSubscription<Uint8List>? _audioSub;
  Timer? _idleSilenceTimer;
  StreamController<SttResult>? _controller;
  void Function()? _onSpeechEnd;

  // Un stop invalida la operación visible de inmediato, pero el worker aún
  // puede tener updates ya decodificados en tránsito antes de responder al
  // flush. Los conservamos por generación hasta construir el resultado final.
  final Map<int, _SherpaListenOperation> _drainingOperations = {};
  bool _heardSpeech = false;
  DateTime? _silenceSince;
  DateTime? _startedAt;
  bool _stopping = false;
  bool _continuous = false;
  int _generation = 0;
  _SherpaListenOperation? _operation;
  Future<void> _startupTail = Future<void>.value();
  Future<void> _stopTail = Future<void>.value();
  Future<void> _capturedTranscriptionTail = Future<void>.value();
  bool _disposed = false;
  Future<void>? _disposeFuture;

  @override
  bool get supportsPartials => true;

  @override
  Future<bool> available() async {
    if (_disposed) return false;
    final hasMic = await _runtime.hasPermission();
    if (_disposed) return false;
    final ready = await _runtime.modelReady();
    return hasMic && ready;
  }

  @override
  Future<String> transcribeCapturedWav(Uint8List wavBytes) {
    final pcm = _pcm16Mono16kFromWav(wavBytes);
    if (pcm == null || pcm.isEmpty) {
      return Future<String>.error(
        const FormatException('Expected mono PCM16 WAV at 16 kHz.'),
      );
    }

    final previous = _capturedTranscriptionTail;
    final startupBeforeRequest = _startupTail;
    final stopBeforeRequest = _stopTail;
    final result = () async {
      await previous;
      await stopBeforeRequest;
      await startupBeforeRequest;
      if (_disposed) throw StateError('Sherpa STT is already disposed.');
      if (_operation != null || _drainingOperations.isNotEmpty) {
        throw StateError('Sherpa STT is still finishing another capture.');
      }
      if (!await _runtime.modelReady()) {
        throw StateError('Sherpa STT model is not ready.');
      }

      final perf = Stopwatch()..start();
      final worker = await _ensureWorker();
      await worker.prepare();
      if (_disposed) throw StateError('Sherpa STT was disposed.');
      final generation = ++_generation;
      final acceptedBeforeFlush = <String>[];
      Object? updateError;
      final capturedUpdates = worker.updates
          .where((update) => update.generation == generation)
          .listen((update) {
            final error = update.error;
            if (error != null) {
              updateError ??= SherpaSttWorkerException(error);
              return;
            }
            acceptedBeforeFlush.addAll(_acceptedSegments(update.segments));
          });
      try {
        worker.accept(pcm, generation: generation);
        final flushed = _acceptedSegments(
          await worker.flush(generation: generation),
        );
        final error = updateError;
        if (error != null) throw error;
        final segments = [...acceptedBeforeFlush, ...flushed];
        debugPrint(
          '[VOICE-PERF] sherpa.captured_wav.transcribed_ms='
          '${perf.elapsedMilliseconds} segments=${segments.length}',
        );
        return segments.join(' ').trim();
      } finally {
        await capturedUpdates.cancel();
      }
    }();
    _capturedTranscriptionTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  bool _isCurrent(_SherpaListenOperation operation) =>
      !_disposed &&
      !operation.cancelled &&
      identical(_operation, operation) &&
      operation.generation == _generation;

  void _cancelIdleSilenceTimer() {
    _idleSilenceTimer?.cancel();
    _idleSilenceTimer = null;
  }

  void _armIdleSilenceTimer(_SherpaListenOperation operation) {
    _cancelIdleSilenceTimer();
    if (!_isCurrent(operation) || _continuous || _heardSpeech) return;
    _idleSilenceTimer = _timerFactory(idleSilenceTimeout, () {
      _idleSilenceTimer = null;
      if (!_isCurrent(operation) || _continuous || _heardSpeech) return;
      _autoStop(notifySpeechEnd: false);
    });
  }

  Future<void> _prepareWorker() async {
    final operation = _operation;
    final worker = await _ensureWorker();
    final preparing = worker.prepare();
    if (operation != null) {
      _releasePendingAudio(operation, worker);
    }
    await preparing;
  }

  void _releasePendingAudio(
    _SherpaListenOperation operation,
    SherpaSttWorker worker,
  ) {
    if (!operation.queueAudioUntilWorkerCommand) return;
    operation.queueAudioUntilWorkerCommand = false;
    final queuedBytes = operation.pendingAudioBytes;
    for (final bytes in operation.pendingAudio) {
      worker.accept(bytes, generation: operation.generation);
    }
    operation.pendingAudio.clear();
    operation.pendingAudioBytes = 0;
    if (queuedBytes > 0) {
      final queuedMs = (queuedBytes * 1000) ~/ (16000 * 2);
      debugPrint(
        '[VOICE-PERF] sherpa.queued_audio_ms=$queuedMs '
        'generation=${operation.generation}',
      );
    }
  }

  Future<SherpaSttWorker> _ensureWorker() {
    final current = _worker;
    if (current != null) return Future<SherpaSttWorker>.value(current);
    final starting = _workerStart;
    if (starting != null) return starting;
    final factory = _workerFactory;
    if (factory == null) {
      return Future<SherpaSttWorker>.error(
        StateError('Sherpa worker is disabled for this runtime.'),
      );
    }

    late final Future<SherpaSttWorker> start;
    start = _createWorker(factory).whenComplete(() {
      if (identical(_workerStart, start)) _workerStart = null;
    });
    _workerStart = start;
    return start;
  }

  Future<SherpaSttWorker> _createWorker(SherpaSttWorkerFactory factory) async {
    final config = SherpaSttWorkerConfig(
      tokensPath: await manager.tokensPath(model),
      encoderPath: await manager.encoderPath(model),
      decoderPath: await manager.decoderPath(model),
      joinerPath: model.isTransducer ? await manager.joinerPath(model) : '',
      sileroPath: await manager.sileroPath(),
      language: lang,
      transducer: model.isTransducer,
      numThreads: _threads,
    );
    if (_disposed) {
      throw StateError('Sherpa engine was disposed during worker startup.');
    }
    final created = await factory(config);
    if (_disposed) {
      await created.dispose();
      throw StateError('Sherpa engine was disposed during worker startup.');
    }
    _worker = created;
    _workerUpdates = created.updates.listen(
      _onWorkerUpdate,
      onError: (Object error, StackTrace stack) {
        final operation = _operation;
        if (operation != null && _isCurrent(operation)) {
          operation.workerError = error.toString();
          _autoStop();
          return;
        }
        for (final draining in _drainingOperations.values) {
          draining.workerError = error.toString();
        }
      },
    );
    return created;
  }

  void _onWorkerUpdate(SherpaSttWorkerUpdate update) {
    final current = _operation;
    final operation = current != null && update.generation == current.generation
        ? current
        : _drainingOperations[update.generation];
    if (operation == null ||
        (!_isCurrent(operation) && !_isDraining(operation)) ||
        operation.controller.isClosed) {
      return;
    }
    final error = update.error;
    if (error != null) {
      operation.workerError = error;
      if (_isCurrent(operation)) _autoStop();
      return;
    }
    _applyRecognitionUpdate(
      operation,
      level: update.level,
      speechDetected: update.speechDetected,
      acousticSpeechEvidence: update.acousticSpeechEvidence,
      segments: update.segments,
    );
  }

  @override
  Stream<SttResult> listen({
    String localeId = 'es_ES',
    void Function()? onSpeechEnd,
    void Function()? onCaptureReady,
    bool continuous = false,
  }) {
    _cancelIdleSilenceTimer();
    final previous = _operation;
    if (previous != null) {
      previous.cancelled = true;
      if (!previous.controller.isClosed) unawaited(previous.controller.close());
    }
    final controller = StreamController<SttResult>();
    final operation = _SherpaListenOperation(
      ++_generation,
      controller,
      VoiceLatencyTrace.current.currentTurn,
    );
    debugPrint(
      '[VOICE-PERF] sherpa.listen.request generation=${operation.generation}',
    );
    _operation = operation;
    _controller = controller;
    _onSpeechEnd = onSpeechEnd;
    _continuous = continuous;
    _heardSpeech = false;
    _silenceSince = null;
    _stopping = false;
    final stopBeforeStart = _stopTail;
    final capturedBeforeStart = _capturedTranscriptionTail;
    _startupTail = _startupTail.then(
      (_) async {
        await stopBeforeStart;
        await capturedBeforeStart;
        await _startOperation(operation, onCaptureReady);
      },
      onError: (_) async {
        await stopBeforeStart;
        await capturedBeforeStart;
        await _startOperation(operation, onCaptureReady);
      },
    );
    return controller.stream;
  }

  Future<void> _startOperation(
    _SherpaListenOperation operation,
    void Function()? onCaptureReady,
  ) async {
    final controller = operation.controller;
    final perf = Stopwatch()..start();
    try {
      if (!_isCurrent(operation)) {
        if (!controller.isClosed) await controller.close();
        return;
      }
      if (!await _runtime.hasPermission()) {
        if (_isCurrent(operation)) {
          controller.addError(Exception('No microphone permission.'));
          await controller.close();
        }
        return;
      }
      if (!_isCurrent(operation)) return;
      if (!await _runtime.modelReady()) {
        if (_isCurrent(operation)) {
          controller.addError(
            Exception('Download the live STT model in Settings › Voice.'),
          );
          await controller.close();
        }
        return;
      }
      if (!_isCurrent(operation)) return;
      final stream = await _runtime.startStream();
      if (!_isCurrent(operation)) {
        try {
          await _runtime.stop();
        } catch (_) {}
        return;
      }
      operation.started = true;
      onCaptureReady?.call();
      _startedAt = DateTime.now();
      _armIdleSilenceTimer(operation);
      debugPrint(
        '[VOICE-PERF] sherpa.mic.ready_ms=${perf.elapsedMilliseconds} '
        'generation=${operation.generation}',
      );
      _audioSub = stream.listen(
        (bytes) {
          if (_isCurrent(operation)) _onAudio(operation, bytes);
        },
        onError: (Object e) {
          if (_isCurrent(operation) && !controller.isClosed) {
            controller.addError(Exception('Microphone error: $e'));
          }
        },
      );
      await _runtime.prepare();
      if (_prepareWorkerAfterRuntime) await _prepareWorker();
      debugPrint(
        '[VOICE-PERF] sherpa.worker.ready_ms=${perf.elapsedMilliseconds} '
        'generation=${operation.generation}',
      );
    } catch (e) {
      debugPrint(
        '[VOICE-PERF] sherpa.listen.failed_ms=${perf.elapsedMilliseconds} '
        'generation=${operation.generation} error=${e.runtimeType}',
      );
      if (_isCurrent(operation) && !controller.isClosed) {
        await _audioSub?.cancel();
        _audioSub = null;
        try {
          await _runtime.stop();
        } catch (_) {}
        operation.started = false;
        controller.addError(Exception('Could not start live STT: $e'));
        await controller.close();
      }
    } finally {
      if (!_isCurrent(operation) &&
          !_isDraining(operation) &&
          !controller.isClosed) {
        await controller.close();
      }
    }
  }

  void _onAudio(_SherpaListenOperation operation, Uint8List bytes) {
    if (!_isCurrent(operation) || operation.controller.isClosed || _stopping) {
      return;
    }
    final now = DateTime.now();
    if (_startedAt != null && now.difference(_startedAt!) >= maxDuration) {
      _autoStop();
      return;
    }

    if (operation.queueAudioUntilWorkerCommand) {
      // El turno ya está acotado por [maxDuration] (60 s por defecto), así que
      // conservar todo el PCM pendiente cuesta como máximo ~1,9 MB. El límite
      // anterior de 15 s descartaba el resto sin avisar si Android tardaba en
      // crear el isolate o resolver las rutas del modelo.
      final copy = Uint8List.fromList(bytes);
      operation.pendingAudio.add(copy);
      operation.pendingAudioBytes += copy.length;
      return;
    }

    final worker = _worker;
    if (worker != null) {
      worker.accept(bytes, generation: operation.generation);
    }
  }

  void _applyRecognitionUpdate(
    _SherpaListenOperation operation, {
    required double level,
    required bool speechDetected,
    required bool acousticSpeechEvidence,
    required List<String> segments,
    DateTime? now,
  }) {
    final current = _isCurrent(operation);
    final draining = _isDraining(operation);
    if ((!current && !draining) || operation.controller.isClosed) {
      return;
    }

    if (level > operation.peakLevel) operation.peakLevel = level;
    final aboveDesktopThreshold =
        speechDetected && level >= SherpaDesktopSpeechGate.levelThreshold;
    if (acousticSpeechEvidence) {
      operation.acousticSpeechEvidence = true;
    }

    final accepted = _acceptedOperationSegments(operation, segments);
    if (accepted.isNotEmpty) {
      operation.committed.addAll(accepted);
      if (current && !_stopping) {
        operation.controller.add(
          SttResult(operation.committed.join(' '), false),
        );
      }
    }
    // Durante el flush solo drenamos texto: no reactivamos el orbe ni el VAD.
    if (!current || _stopping) return;

    onLevel?.call(level);

    // Fin de habla: tras oír voz, si el VAD ya no detecta nada durante
    // [silenceTimeout], cerramos el turno.
    if (speechDetected && operation.acousticSpeechEvidence) {
      _cancelIdleSilenceTimer();
      _heardSpeech = true;
      _silenceSince = null;
      if (aboveDesktopThreshold) {
        operation.latencyTurn?.observeSpeechAboveThreshold();
      }
    } else if (!_continuous && _heardSpeech) {
      // Dictado continuo: las pausas NO cierran el turno (manda el usuario con
      // el botón parar, o el tope maxDuration). En modo voz sí auto-cerramos
      // por silencio para encadenar turnos rápido.
      final timestamp = now ?? DateTime.now();
      _silenceSince ??= timestamp;
      if (timestamp.difference(_silenceSince!) >= silenceTimeout) {
        _autoStop();
      }
    }
  }

  bool _isDraining(_SherpaListenOperation operation) =>
      identical(_drainingOperations[operation.generation], operation);

  List<String> _acceptedSegments(List<String> segments) {
    if (segments.isEmpty) return const [];
    final accepted = <String>[];
    var filtered = 0;
    for (final segment in segments) {
      final text = segment.trim();
      if (text.isEmpty) continue;
      if (VoiceResponsePolicy.isLikelySttHallucination(text)) {
        filtered++;
        continue;
      }
      accepted.add(text);
    }
    if (filtered > 0) {
      // Métrica de diagnóstico sin registrar contenido dictado.
      debugPrint('[stt-sherpa] filtered_noise_segments=$filtered');
    }
    return accepted;
  }

  List<String> _acceptedOperationSegments(
    _SherpaListenOperation operation,
    List<String> segments,
  ) {
    final accepted = _acceptedSegments(segments);
    if (accepted.isEmpty || operation.acousticSpeechEvidence) return accepted;
    // Métrica sin contenido: permite distinguir alucinación de Whisper y voz
    // real sin persistir ni imprimir el transcript del usuario.
    debugPrint(
      '[stt-sherpa] filtered_low_energy_segments=${accepted.length} '
      'peak_level=${operation.peakLevel.toStringAsFixed(3)} '
      'threshold=${SherpaDesktopSpeechGate.levelThreshold.toStringAsFixed(3)} '
      'gate=desktop_majority',
    );
    return const [];
  }

  void _autoStop({bool notifySpeechEnd = true}) {
    if (_stopping) return;
    _cancelIdleSilenceTimer();
    _stopping = true;
    if (notifySpeechEnd) {
      _operation?.latencyTurn?.mark(VoiceLatencyPoint.speechEndpoint);
      _operation?.latencyTurn?.mark(VoiceLatencyPoint.sttStarted);
      _onSpeechEnd?.call();
    }
    unawaited(stop());
  }

  @override
  Future<void> stop() {
    _cancelIdleSilenceTimer();
    final operation = _operation;
    final controller = operation?.controller ?? _controller;
    final wasStarted = operation?.started ?? false;
    final startupAtStop = _startupTail;
    if (operation != null) {
      if (wasStarted) {
        operation.latencyTurn?.mark(VoiceLatencyPoint.speechEndpoint);
        operation.latencyTurn?.mark(VoiceLatencyPoint.sttStarted);
      }
      operation.cancelled = true;
      _drainingOperations[operation.generation] = operation;
    }
    _operation = null;
    _generation++;
    _controller = null;
    _stopping = true;
    final previousStop = _stopTail;
    final result = () async {
      await previousStop;
      try {
        await _stopOperation(
          operation,
          controller,
          wasStarted: wasStarted,
          startupAtStop: startupAtStop,
        );
      } finally {
        if (operation != null &&
            identical(_drainingOperations[operation.generation], operation)) {
          _drainingOperations.remove(operation.generation);
        }
      }
    }();
    _stopTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _stopOperation(
    _SherpaListenOperation? operation,
    StreamController<SttResult>? controller, {
    required bool wasStarted,
    required Future<void> startupAtStop,
  }) async {
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _runtime.stop();
    } catch (e) {
      debugPrint('[stt-sherpa] no se pudo detener el grabador: $e');
    }
    onLevel?.call(0);
    if (controller == null || controller.isClosed) {
      operation?.pendingAudio.clear();
      operation?.pendingAudioBytes = 0;
      return;
    }
    if (!wasStarted) {
      operation?.pendingAudio.clear();
      operation?.pendingAudioBytes = 0;
      await controller.close();
      return;
    }
    final startupWait = Stopwatch()..start();
    try {
      // El micro empieza antes que el isolate para conservar el inicio de la
      // frase. Si se pulsa parar durante ese arranque en frío, esperamos a que
      // el worker reciba el PCM en cola antes de pedirle el resultado final.
      await startupAtStop;
      debugPrint(
        '[VOICE-PERF] sherpa.stop.worker_ready_ms='
        '${startupWait.elapsedMilliseconds} '
        'generation=${operation?.generation}',
      );
    } catch (error) {
      debugPrint(
        '[VOICE-PERF] sherpa.stop.worker_failed_ms='
        '${startupWait.elapsedMilliseconds} '
        'generation=${operation?.generation} '
        'error=${error.runtimeType}',
      );
    }
    try {
      final workerError = operation?.workerError;
      if (workerError != null) {
        throw SherpaSttWorkerException(workerError);
      }
      final worker = _worker;
      if (worker != null && operation != null) {
        operation.committed.addAll(
          _acceptedOperationSegments(
            operation,
            await worker.flush(generation: operation.generation),
          ),
        );
        final lateWorkerError = operation.workerError;
        if (lateWorkerError != null) {
          throw SherpaSttWorkerException(lateWorkerError);
        }
      }
      operation?.pendingAudio.clear();
      operation?.pendingAudioBytes = 0;
      debugPrint(
        '[VOICE-PERF] sherpa.stop.final_segments='
        '${operation?.committed.length ?? 0} '
        'generation=${operation?.generation} '
        'acoustic_gate=${operation?.acousticSpeechEvidence ?? false} '
        'peak_level=${operation?.peakLevel.toStringAsFixed(3) ?? '0.000'} '
        'controller_closed=${controller.isClosed}',
      );
      operation?.latencyTurn?.mark(VoiceLatencyPoint.sttFinal);
      controller.add(
        SttResult(operation?.committed.join(' ').trim() ?? '', true),
      );
      await controller.close();
    } catch (e) {
      operation?.pendingAudio.clear();
      operation?.pendingAudioBytes = 0;
      if (!controller.isClosed) {
        controller.addError(Exception('Transcription failed: $e'));
        await controller.close();
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    _cancelIdleSilenceTimer();
    final operation = _operation;
    _operation = null;
    _generation++;
    if (operation != null) {
      operation.cancelled = true;
      operation.pendingAudio.clear();
      operation.pendingAudioBytes = 0;
      if (!operation.controller.isClosed) {
        unawaited(operation.controller.close());
      }
    }
    _disposeFuture = () async {
      await _stopTail;
      await _startupTail;
      await _capturedTranscriptionTail;
      await _audioSub?.cancel();
      _audioSub = null;
      final controller = _controller;
      _controller = null;
      if (controller != null && !controller.isClosed) {
        unawaited(controller.close());
      }
      try {
        await _runtime.dispose();
      } catch (e) {
        debugPrint('[stt-sherpa] no se pudo liberar el grabador: $e');
      }
      final workerUpdates = _workerUpdates;
      _workerUpdates = null;
      await workerUpdates?.cancel();
      _drainingOperations.clear();
      final worker = _worker;
      _worker = null;
      if (worker != null) {
        try {
          await worker.dispose();
        } catch (e) {
          debugPrint('[stt-sherpa] no se pudo liberar el worker: $e');
        }
      }
    }();
    return _disposeFuture!;
  }
}
