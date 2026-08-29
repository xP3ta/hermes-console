/// Catálogo curado de modelos `.litertlm` compatibles con OlliteRT (el motor
/// local por GPU/NPU vía LiteRT-LM de Google).
///
/// OlliteRT corre estos modelos en la GPU/NPU del móvil y los sirve por un
/// endpoint OpenAI-compatible en `127.0.0.1:8000`, que es lo que el agente
/// Hermes consume. La DESCARGA física la hace la propia app OlliteRT (su tienda
/// integrada baja de "LiteRT Community" en HuggingFace); aquí solo curamos qué
/// modelos existen, sus requisitos y el enlace de descarga, y reflejamos el
/// estado real cruzando con `GET /v1/models` de OlliteRT.
///
/// Fuente: README de OlliteRT + `huggingface.co/litert-community`.
library;

enum LitertModelNote { recommended, highEnd, lightweight, distilledReasoner }

/// Un modelo `.litertlm` del catálogo.
class LitertModel {
  const LitertModel({
    required this.id,
    required this.name,
    required this.family,
    required this.sizeGb,
    required this.minRamGb,
    required this.contextLabel,
    required this.hfRepo,
    this.recommended = false,
    this.note,
  });

  /// Slug estable para casar con el id que reporta OlliteRT en `/v1/models`.
  final String id;

  /// Nombre visible.
  final String name;

  /// Familia (Gemma, Qwen, DeepSeek…), para agrupar.
  final String family;

  /// Tamaño de descarga aproximado en GB.
  final double sizeGb;

  /// RAM mínima recomendada por OlliteRT en GB.
  final int minRamGb;

  /// Ventana de contexto (etiqueta, p. ej. "32K").
  final String contextLabel;

  /// Repo de HuggingFace, p. ej. `litert-community/gemma-4-E2B-it-litert-lm`.
  final String hfRepo;

  /// Recomendado por OlliteRT para la mayoría de dispositivos.
  final bool recommended;

  /// Nota corta opcional.
  final LitertModelNote? note;

  /// Página de descarga en HuggingFace.
  String get hfUrl => 'https://huggingface.co/$hfRepo';

  /// Tokens normalizados del nombre/repo para casar con `/v1/models`.
  List<String> get _matchTokens {
    final raw = '$id $name $hfRepo'.toLowerCase();
    return raw
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .split(' ')
        .where((t) => t.length > 1)
        .toList(growable: false);
  }

  /// ¿Este id reportado por OlliteRT corresponde a este modelo del catálogo?
  /// Casado tolerante: OlliteRT puede exponer el id como nombre de fichero
  /// (`gemma-4-E2B-it.litertlm`), repo o variante; comparamos por solapamiento
  /// de tokens significativos (familia + tamaño/variante).
  bool matchesServedId(String servedId) {
    final s = servedId.toLowerCase();
    final norm = s.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    // Señales fuertes: variante tipo "e2b"/"e4b"/"1b"/"1.5b"/"0.6b".
    final mine = _matchTokens.toSet();
    final variants = mine.where(
      (t) => RegExp(r'^(e\d+b|\d+b|\d+\.\d+b)$').hasMatch(t),
    );
    final familyHit = norm.contains(family.toLowerCase());
    final variantHit =
        variants.isNotEmpty && variants.every((v) => norm.contains(v));
    if (familyHit && variantHit) return true;
    // Fallback: el repo (sin el prefijo de comunidad) aparece tal cual.
    final repoTail = hfRepo.split('/').last.toLowerCase();
    return s.contains(repoTail) || repoTail.contains(s.replaceAll(' ', ''));
  }
}

/// Catálogo curado (orden: recomendados primero, luego por tamaño).
const List<LitertModel> kLitertCatalog = [
  LitertModel(
    id: 'gemma-4-e2b',
    name: 'Gemma 4 E2B',
    family: 'gemma',
    sizeGb: 2.4,
    minRamGb: 8,
    contextLabel: '32K',
    hfRepo: 'litert-community/gemma-4-E2B-it-litert-lm',
    recommended: true,
    note: LitertModelNote.recommended,
  ),
  LitertModel(
    id: 'gemma-4-e4b',
    name: 'Gemma 4 E4B',
    family: 'gemma',
    sizeGb: 3.4,
    minRamGb: 12,
    contextLabel: '32K',
    hfRepo: 'litert-community/gemma-4-E4B-it-litert-lm',
    recommended: true,
    note: LitertModelNote.highEnd,
  ),
  LitertModel(
    id: 'gemma-3n-e2b',
    name: 'Gemma 3n E2B',
    family: 'gemma',
    sizeGb: 3.4,
    minRamGb: 8,
    contextLabel: '4K',
    hfRepo: 'litert-community/gemma-3n-E2B-it-litert-lm',
  ),
  LitertModel(
    id: 'gemma-3n-e4b',
    name: 'Gemma 3n E4B',
    family: 'gemma',
    sizeGb: 4.6,
    minRamGb: 12,
    contextLabel: '4K',
    hfRepo: 'litert-community/gemma-3n-E4B-it-litert-lm',
  ),
  LitertModel(
    id: 'qwen3-0.6b',
    name: 'Qwen 3 0.6B',
    family: 'qwen',
    sizeGb: 0.5,
    minRamGb: 6,
    contextLabel: '4K',
    hfRepo: 'litert-community/Qwen3-0.6B',
    note: LitertModelNote.lightweight,
  ),
  LitertModel(
    id: 'qwen2.5-1.5b',
    name: 'Qwen 2.5 1.5B',
    family: 'qwen',
    sizeGb: 1.5,
    minRamGb: 6,
    contextLabel: '4K',
    hfRepo: 'litert-community/Qwen2.5-1.5B-Instruct',
  ),
  LitertModel(
    id: 'gemma-3-1b',
    name: 'Gemma 3 1B',
    family: 'gemma',
    sizeGb: 0.5,
    minRamGb: 6,
    contextLabel: '1K',
    hfRepo: 'litert-community/Gemma3-1B-IT',
  ),
  LitertModel(
    id: 'deepseek-r1-1.5b',
    name: 'DeepSeek-R1 1.5B',
    family: 'deepseek',
    sizeGb: 1.7,
    minRamGb: 6,
    contextLabel: '4K',
    hfRepo: 'litert-community/DeepSeek-R1-Distill-Qwen-1.5B',
    note: LitertModelNote.distilledReasoner,
  ),
];

/// Busca en el catálogo el modelo que corresponde a un id servido por OlliteRT.
LitertModel? litertModelForServedId(String servedId) {
  for (final m in kLitertCatalog) {
    if (m.matchesServedId(servedId)) return m;
  }
  return null;
}
