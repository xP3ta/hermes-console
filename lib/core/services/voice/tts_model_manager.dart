// Descarga y gestión de modelos de voz neuronal on-device (Piper/VITS para
// sherpa-onnx). El modelo viaja como un único `.tar.bz2` (onnx + tokens.txt +
// espeak-ng-data/) que se descarga con progreso y se extrae en un isolate para
// no congelar la UI. Todo queda en el almacenamiento privado de la app; no hay
// nube ni clave: la síntesis es 100% en el dispositivo.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'model_download.dart';

/// Una voz neuronal descargable. [dirName] es la carpeta raíz dentro del tar y
/// [onnxFile] el nombre del modelo ONNX dentro de ella.
class NeuralVoice {
  final String id;
  final String displayName;
  final String locale; // p.ej. "es-ES", "es-MX"
  final String quality; // "ligera" | "media" | "alta"
  final int sizeMb;
  final String url;
  final int archiveBytes;
  final String archiveSha256;
  final String dirName;
  final String onnxFile;

  const NeuralVoice({
    required this.id,
    required this.displayName,
    required this.locale,
    required this.quality,
    required this.sizeMb,
    required this.url,
    required this.archiveBytes,
    required this.archiveSha256,
    required this.dirName,
    required this.onnxFile,
  });
}

/// Catálogo de voces en español e inglés empaquetadas para sherpa-onnx
/// (origen Piper, de HuggingFace/rhasspy; las distribuye el proyecto
/// sherpa-onnx en un único archivo con todo lo necesario). Añadir una
/// voz = una entrada más aquí.
const String _ttsRelease =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';

// Tamaño y digest proceden de los metadatos de los assets del release oficial.
// Son parte del catálogo para rechazar cortes y reemplazos del archivo remoto.
const List<NeuralVoice> kNeuralVoices = [
  NeuralVoice(
    id: 'es_ES-carlfm-x_low',
    displayName: 'Carlos (Spain)',
    locale: 'es-ES',
    quality: 'ligera',
    sizeMb: 25,
    url: '$_ttsRelease/vits-piper-es_ES-carlfm-x_low.tar.bz2',
    archiveBytes: 26520563,
    archiveSha256:
        '15585c5add2ab1915ce69e8c966c7c9fb0b6afb21f9b92f18110fda5a4787f99',
    dirName: 'vits-piper-es_ES-carlfm-x_low',
    onnxFile: 'es_ES-carlfm-x_low.onnx',
  ),
  NeuralVoice(
    id: 'es_ES-davefx-medium',
    displayName: 'David (Spain)',
    locale: 'es-ES',
    quality: 'media',
    sizeMb: 64,
    url: '$_ttsRelease/vits-piper-es_ES-davefx-medium.tar.bz2',
    archiveBytes: 67184952,
    archiveSha256:
        'a3f6beb54a9cb893279f72978a22f807a4d9fc9c7848157b524d5cc7b7f58b22',
    dirName: 'vits-piper-es_ES-davefx-medium',
    onnxFile: 'es_ES-davefx-medium.onnx',
  ),
  NeuralVoice(
    id: 'es_ES-sharvard-medium',
    displayName: 'Sara (Spain)',
    locale: 'es-ES',
    quality: 'media',
    sizeMb: 77,
    url: '$_ttsRelease/vits-piper-es_ES-sharvard-medium.tar.bz2',
    archiveBytes: 80318184,
    archiveSha256:
        'b30a7a83df0518f0ee1c7039506648cade99f1f9b498fc49ed2ced2e2536bb5a',
    dirName: 'vits-piper-es_ES-sharvard-medium',
    onnxFile: 'es_ES-sharvard-medium.onnx',
  ),
  NeuralVoice(
    id: 'es_MX-claude-high',
    displayName: 'Claudia (Mexico)',
    locale: 'es-MX',
    quality: 'alta',
    sizeMb: 64,
    url: '$_ttsRelease/vits-piper-es_MX-claude-high.tar.bz2',
    archiveBytes: 67207890,
    archiveSha256:
        'ec33fb689c248fe64810aab564cba97babf0f506672cfd404928d46e751a4721',
    dirName: 'vits-piper-es_MX-claude-high',
    onnxFile: 'es_MX-claude-high.onnx',
  ),
  NeuralVoice(
    id: 'en_US-amy-medium',
    displayName: 'Amy (United States)',
    locale: 'en-US',
    quality: 'media',
    sizeMb: 64,
    url: '$_ttsRelease/vits-piper-en_US-amy-medium.tar.bz2',
    archiveBytes: 67223746,
    archiveSha256:
        '9a5d1fc497f85e8022b785bff5f8105203b1e33099ee6265203efc70b0cb0264',
    dirName: 'vits-piper-en_US-amy-medium',
    onnxFile: 'en_US-amy-medium.onnx',
  ),
  NeuralVoice(
    id: 'en_GB-alan-medium',
    displayName: 'Alan (United Kingdom)',
    locale: 'en-GB',
    quality: 'media',
    sizeMb: 64,
    url: '$_ttsRelease/vits-piper-en_GB-alan-medium.tar.bz2',
    archiveBytes: 67220121,
    archiveSha256:
        'a48d4017da0f77668b27bed63fe6e04dd64c6397e1fadad4f460efb0ef7c9012',
    dirName: 'vits-piper-en_GB-alan-medium',
    onnxFile: 'en_GB-alan-medium.onnx',
  ),
];

NeuralVoice? neuralVoiceById(String id) {
  for (final v in kNeuralVoices) {
    if (v.id == id) return v;
  }
  return null;
}

/// Fase de la preparación del modelo, para el copy de la UI.
enum TtsPrepPhase { downloading, extracting, done }

class TtsPrepProgress {
  final TtsPrepPhase phase;

  /// 0..1 durante la descarga; -1 (indeterminado) durante la extracción.
  final double value;
  const TtsPrepProgress(this.phase, this.value);
}

class TtsModelManager {
  final Map<String, http.Client> _activeDownloads = {};
  final Set<String> _cancelledDownloads = {};

  static const int _minimumOnnxBytes = 1024 * 1024;
  static const int _minimumTokensBytes = 16;

  /// Cancela la transferencia activa. El `.part` se limpia desde [download]
  /// una vez se haya cerrado el stream y el sink de forma segura.
  void cancelDownload(NeuralVoice v) {
    _cancelledDownloads.add(v.id);
    _activeDownloads[v.id]?.close();
  }

  /// Carpeta base de modelos TTS (almacenamiento privado de la app).
  Future<Directory> _baseDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/tts_models');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> voiceDir(NeuralVoice v) async =>
      Directory('${(await _baseDir()).path}/${v.dirName}');

  Future<String> modelPath(NeuralVoice v) async =>
      '${(await voiceDir(v)).path}/${v.onnxFile}';
  Future<String> tokensPath(NeuralVoice v) async =>
      '${(await voiceDir(v)).path}/tokens.txt';
  Future<String> dataDirPath(NeuralVoice v) async =>
      '${(await voiceDir(v)).path}/espeak-ng-data';

  /// ¿Está la voz lista para usarse? (onnx + tokens + datos de espeak presentes).
  Future<bool> isReady(NeuralVoice v) async {
    final dir = await voiceDir(v);
    final data = '${dir.path}/espeak-ng-data';
    final checks = await Future.wait([
      _fileHasAtLeast('${dir.path}/${v.onnxFile}', _minimumOnnxBytes),
      _fileHasAtLeast('${dir.path}/tokens.txt', _minimumTokensBytes),
      _fileHasAtLeast('$data/phontab', 1),
      _fileHasAtLeast('$data/phondata', 1),
      _fileHasAtLeast('$data/phonindex', 1),
      _fileHasAtLeast('$data/${_dictionaryName(v.locale)}', 1),
    ]);
    return checks.every((ready) => ready);
  }

  /// Voz ya descargada cuyo id coincide, o null.
  Future<NeuralVoice?> firstReady() async {
    for (final v in kNeuralVoices) {
      if (await isReady(v)) return v;
    }
    return null;
  }

  Future<void> delete(NeuralVoice v) async {
    final dir = await voiceDir(v);
    if (await dir.exists()) await dir.delete(recursive: true);
    final stage = Directory('${dir.path}.extracting');
    if (await stage.exists()) await stage.delete(recursive: true);
    final previous = Directory('${dir.path}.previous');
    if (await previous.exists()) await previous.delete(recursive: true);
    final partial = File('${dir.path}.tar.bz2.part');
    if (await partial.exists()) await partial.delete();
  }

  /// Descarga (a un archivo temporal, con progreso) y extrae el modelo. Es
  /// idempotente: si ya está listo, no hace nada. La extracción corre en un
  /// isolate aparte para no bloquear la UI.
  Future<void> download(
    NeuralVoice v, {
    void Function(TtsPrepProgress)? onProgress,
  }) async {
    // Se limpia una cancelación antigua antes del primer await. Si el usuario
    // cancela mientras se consulta el disco, la nueva marca ya no se pierde.
    _cancelledDownloads.remove(v.id);
    if (await isReady(v)) {
      _cancelledDownloads.remove(v.id);
      onProgress?.call(const TtsPrepProgress(TtsPrepPhase.done, 1));
      return;
    }
    if (_activeDownloads.containsKey(v.id)) {
      throw StateError('This voice is already downloading.');
    }
    final client = http.Client();
    // La reserva se publica antes del siguiente await: dos toques rápidos no
    // pueden escribir a la vez sobre el mismo `.part`, y una cancelación que
    // llegue mientras se consulta el disco ya puede cerrar este cliente.
    _activeDownloads[v.id] = client;
    File? tmp;

    // 1) Descarga con progreso, escribiendo a disco (memoria baja).
    try {
      final base = await _baseDir();
      final partial = File('${base.path}/${v.dirName}.tar.bz2.part');
      tmp = partial;
      if (await partial.exists()) await partial.delete();
      if (_cancelledDownloads.contains(v.id)) {
        throw const ModelDownloadCancelled();
      }
      final req = http.Request('GET', Uri.parse(v.url));
      final res = await client.send(req);
      if (res.statusCode != 200) {
        throw Exception('Model download failed (HTTP ${res.statusCode}).');
      }
      if (res.contentLength != null && res.contentLength != v.archiveBytes) {
        throw const FormatException(
          'The published TTS model size does not match.',
        );
      }
      var received = 0;
      final sink = partial.openWrite();
      final digestOutput = _DigestSink();
      final digestInput = sha256.startChunkedConversion(digestOutput);
      try {
        await for (final chunk in res.stream) {
          if (_cancelledDownloads.contains(v.id)) {
            throw const ModelDownloadCancelled();
          }
          received += chunk.length;
          if (received > v.archiveBytes) {
            throw const FormatException(
              'The TTS model download exceeds the expected size.',
            );
          }
          sink.add(chunk);
          digestInput.add(chunk);
          onProgress?.call(
            TtsPrepProgress(
              TtsPrepPhase.downloading,
              received / v.archiveBytes,
            ),
          );
        }
      } finally {
        digestInput.close();
        await sink.close();
      }

      if (received != v.archiveBytes) {
        throw const FormatException(
          'The TTS model download is truncated.',
        );
      }
      if (digestOutput.value?.toString() != v.archiveSha256) {
        throw const FormatException(
          'The TTS model SHA-256 signature does not match.',
        );
      }

      if (_cancelledDownloads.contains(v.id)) {
        throw const ModelDownloadCancelled();
      }

      // 2) Extracción en un isolate (bzip2 + tar son CPU-intensivos).
      onProgress?.call(const TtsPrepProgress(TtsPrepPhase.extracting, -1));
      await Isolate.run(
        () => extractTtsModelArchive(
          partial.path,
          base.path,
          dirName: v.dirName,
          onnxFile: v.onnxFile,
          languageCode: _languageCode(v.locale),
        ),
      );
      if (_cancelledDownloads.contains(v.id)) {
        await delete(v);
        throw const ModelDownloadCancelled();
      }
    } catch (e) {
      if (_cancelledDownloads.contains(v.id)) {
        throw const ModelDownloadCancelled();
      }
      rethrow;
    } finally {
      client.close();
      _activeDownloads.remove(v.id);
      _cancelledDownloads.remove(v.id);
      final cleanupPartial = tmp;
      if (cleanupPartial != null && await cleanupPartial.exists()) {
        await cleanupPartial.delete();
      }
    }

    if (!await isReady(v)) {
      throw Exception(
        'Model downloaded but files are missing after extraction.',
      );
    }
    onProgress?.call(const TtsPrepProgress(TtsPrepPhase.done, 1));
  }
}

Future<bool> _fileHasAtLeast(String path, int minimumBytes) async {
  try {
    final file = File(path);
    return await file.exists() && await file.length() >= minimumBytes;
  } on FileSystemException {
    return false;
  }
}

String _languageCode(String locale) =>
    locale.split(RegExp('[-_]')).first.trim().toLowerCase();

String _dictionaryName(String locale) => '${_languageCode(locale)}_dict';

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    if (value != null) throw StateError('Se recibieron varios hashes TTS.');
    value = data;
  }

  @override
  void close() {}
}

/// Extrae únicamente los artefactos que usa Piper, sin cargar en RAM el BZip2
/// ni el tar completo. La carpeta final solo cambia después de validar todos
/// los archivos imprescindibles; una descarga cortada conserva la instalación
/// anterior y nunca queda marcada como lista.
@visibleForTesting
void extractTtsModelArchive(
  String tarBz2Path,
  String destRoot, {
  required String dirName,
  required String onnxFile,
  required String languageCode,
}) {
  final safeName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
  if (!safeName.hasMatch(dirName) ||
      !safeName.hasMatch(onnxFile) ||
      !onnxFile.endsWith('.onnx') ||
      !RegExp(r'^[a-z]{2,3}$').hasMatch(languageCode)) {
    throw const FormatException('Catálogo local del modelo TTS inválido.');
  }

  final root = Directory(destRoot)..createSync(recursive: true);
  final stage = Directory('${root.path}/$dirName.extracting');
  final target = Directory('${root.path}/$dirName');
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);

  final input = InputFileStream(tarBz2Path);
  final output = _TtsModelTarSink(
    stage,
    rootName: dirName,
    onnxFile: onnxFile,
    languageCode: languageCode,
  );
  var installed = false;
  try {
    final decoded = BZip2Decoder().decodeStream(input, output, verify: true);
    if (!decoded) {
      throw const FormatException(
        'El archivo BZip2 del modelo TTS está dañado.',
      );
    }
    output.complete();
    _replaceTtsDirectory(stage, target);
    installed = true;
  } finally {
    // Un error de formato puede reaparecer al vaciar el último bloque. Cada
    // cierre se aísla para que nunca impida retirar el staging incompleto.
    try {
      input.closeSync();
    } catch (_) {}
    try {
      output.closeSync();
    } catch (_) {}
    if (!installed && stage.existsSync()) {
      try {
        stage.deleteSync(recursive: true);
      } on FileSystemException {
        // El error original describe mejor el fallo; el próximo intento vuelve
        // a limpiar este mismo staging antes de extraer.
      }
    }
  }
}

void _replaceTtsDirectory(Directory stage, Directory target) {
  final previous = Directory('${target.path}.previous');
  if (previous.existsSync()) previous.deleteSync(recursive: true);
  if (!target.existsSync()) {
    stage.renameSync(target.path);
    return;
  }

  target.renameSync(previous.path);
  try {
    stage.renameSync(target.path);
  } catch (_) {
    if (!target.existsSync() && previous.existsSync()) {
      previous.renameSync(target.path);
    }
    rethrow;
  }
  try {
    previous.deleteSync(recursive: true);
  } on FileSystemException {
    // La voz nueva ya está activa. El backup huérfano se limpia en el próximo
    // reemplazo sin invalidar una instalación que sí terminó correctamente.
  }
}

class _TtsModelTarSink extends OutputStream {
  _TtsModelTarSink(
    this._stage, {
    required this._rootName,
    required String onnxFile,
    required String languageCode,
  }) : _onnxFile = onnxFile,
       _required = {
         onnxFile,
         'tokens.txt',
         'espeak-ng-data/phontab',
         'espeak-ng-data/phondata',
         'espeak-ng-data/phonindex',
         'espeak-ng-data/${languageCode}_dict',
       },
       super(byteOrder: ByteOrder.littleEndian);

  static const int _tarBlockSize = 512;
  static const int _bufferSize = 64 * 1024;
  static const int _maxExpandedTarBytes = 512 * 1024 * 1024;
  static const int _minimumOnnxBytes = 1024 * 1024;
  static const int _minimumTokensBytes = 16;

  final Directory _stage;
  final String _rootName;
  final String _onnxFile;
  final Set<String> _required;
  final Set<String> _extracted = {};
  final Map<String, int> _sizes = {};
  final Uint8List _buffer = Uint8List(_bufferSize);
  final Uint8List _header = Uint8List(_tarBlockSize);

  RandomAccessFile? _file;
  int _bufferLength = 0;
  int _headerLength = 0;
  int _entryRemaining = 0;
  int _paddingRemaining = 0;
  int _length = 0;
  bool _sawEnd = false;
  int _endBlockCount = 0;
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
    if (_closed) throw StateError('The TTS extractor is already closed.');
    if (additional < 0 ||
        _length + _bufferLength + additional > _maxExpandedTarBytes) {
      throw const FormatException('The expanded TTS model exceeds the limit.');
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
        _file?.writeFromSync(bytes, offset, offset + amount);
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
      _endBlockCount++;
      _sawEnd = _endBlockCount >= 2;
      return;
    }
    if (_endBlockCount != 0) {
      throw const FormatException(
        'El tar TTS contiene datos tras un marcador final incompleto.',
      );
    }

    final expectedChecksum = _parseTarNumber(_header, 148, 8, 'checksum');
    var actualChecksum = 0;
    for (var i = 0; i < _header.length; i++) {
      actualChecksum += i >= 148 && i < 156 ? 0x20 : _header[i];
    }
    if (actualChecksum != expectedChecksum) {
      throw const FormatException('Invalid TTS tar checksum.');
    }

    final name = _normaliseTarName(
      _readTarText(_header, 0, 100),
      _readTarText(_header, 345, 155),
    );
    if (name != _rootName &&
        name != '$_rootName/' &&
        !name.startsWith('$_rootName/')) {
      throw const FormatException('Ruta ajena al modelo TTS.');
    }

    final size = _parseTarNumber(_header, 124, 12, 'size');
    final type = _header[156];
    final regularFile = type == 0 || type == 0x30;
    final directory = type == 0x35;
    if (!regularFile && !directory) {
      throw const FormatException('Tipo de entrada TTS no soportado.');
    }

    final relative = regularFile ? _selectedRelativePath(name) : null;
    if (relative != null) {
      if (!_extracted.add(relative)) {
        throw const FormatException('Entrada duplicada en el modelo TTS.');
      }
      _sizes[relative] = size;
      final file = File('${_stage.path}/$relative');
      file.parent.createSync(recursive: true);
      _file = file.openSync(mode: FileMode.write);
    }

    _entryRemaining = size;
    _paddingRemaining =
        (_tarBlockSize - (size % _tarBlockSize)) % _tarBlockSize;
    if (_entryRemaining == 0) _finishEntry();
  }

  String? _selectedRelativePath(String name) {
    if (!name.startsWith('$_rootName/')) return null;
    final relative = name.substring(_rootName.length + 1);
    if (relative == _onnxFile || relative == 'tokens.txt') return relative;
    if (relative.startsWith('espeak-ng-data/') &&
        relative.length > 'espeak-ng-data/'.length) {
      return relative;
    }
    return null;
  }

  void _finishEntry() {
    _file?.flushSync();
    _file?.closeSync();
    _file = null;
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
    final value = zero < 0 ? raw : raw.sublist(0, zero);
    final text = ascii.decode(value, allowInvalid: false).trim();
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
    final comparable = value.endsWith('/')
        ? value.substring(0, value.length - 1)
        : value;
    final parts = comparable.split('/');
    if (value.isEmpty ||
        value.length > 512 ||
        value.startsWith('/') ||
        value.contains(r'\') ||
        parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('Ruta insegura en el modelo TTS.');
    }
    return value;
  }

  void complete() {
    flush();
    if (!_sawEnd || _entryRemaining != 0 || _file != null) {
      throw const FormatException('The TTS model tar is truncated.');
    }
    final missing = _required.difference(_extracted);
    if (missing.isNotEmpty) {
      throw FormatException(
        'Faltan ${missing.length} archivos requeridos del modelo TTS.',
      );
    }
    if ((_sizes[_onnxFile] ?? 0) < _minimumOnnxBytes ||
        (_sizes['tokens.txt'] ?? 0) < _minimumTokensBytes ||
        _required
            .where((path) => path.startsWith('espeak-ng-data/'))
            .any((path) => (_sizes[path] ?? 0) == 0)) {
      throw const FormatException('The TTS model contains empty files.');
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
