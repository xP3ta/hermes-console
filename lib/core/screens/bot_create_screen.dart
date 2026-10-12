// Creación de bots con paridad al `CreateAgentDialog` del plugin hermes-bots
// de Hermes Desktop (Fase 1 del rediseño de Mission Control):
//
// - Una sola escritura autoritativa `profiles.create` con clonación, SOUL,
//   modelo y compartición de auth (nada de asistentes por pasos ni mutaciones
//   legacy sobre el gateway en marcha).
// - Skills del profile origen vía `profiles.describe` (capacidad opcional:
//   un gateway sin el RPC oculta la sección) aplicadas con
//   `profiles.configure disabled_skills` como paso best-effort posterior.
// - La identidad visible (título + sello `created`) se publica en el
//   namespace `hermes-bots` de `ui_meta`, como `saveBotMeta` de Desktop.
import 'dart:async';
import '../../l10n/app_localizations.dart';
import '../services/bot_profile_client.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../companion/data/petdex_remote_service.dart';
import '../models/agent_profile.dart';
import '../models/bot_visual_identity.dart';
import '../models/profile_pet.dart';
import '../services/bot_identity_mutation_service.dart';
import '../services/connection_manager.dart';
import '../services/profile_pet_service.dart';
import '../services/profile_pet_visual_adapter.dart';
import '../services/profile_image_normalizer.dart';
import '../services/tui_gateway_client.dart';
import '../design/modal.dart'
    show HermesModelChoice, HermesModelGroup, showHermesModelPicker;
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/bot_settings_group.dart';
import '../widgets/bot_capabilities.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_bot_face.dart';
import '../widgets/bot_face_options.dart';
import '../widgets/hermes_ui.dart';
import 'companion/petdex_gallery_screen.dart';
import 'mission_control_copy.dart';
import '../widgets/console_loader.dart';
import '../design/hermes_design.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesFadedEnd,
        HermesOption,
        HermesSelectField,
        HermesSpace,
        HermesType,
        showHermesDialog;
import '../feedback/feedback_policy.dart';

typedef BotCreateImagePicker = Future<XFile?> Function();
typedef BotCreateImageNormalizer =
    Future<AgentProfileAvatar> Function(Uint8List bytes);

enum _CreateIdentityMode { pet, image, face }

final class _BotCreateIdentityFailure implements Exception {
  final bool uncertain;

  const _BotCreateIdentityFailure({required this.uncertain});
}

/// Slug de profile con la misma normalización que `slugify` de Desktop.
String slugifyBotName(String value) {
  final lowered = value.toLowerCase().replaceAll(RegExp('[^a-z0-9_-]+'), '-');
  final trimmed = lowered
      .replaceAll(RegExp('^-+'), '')
      .replaceAll(RegExp(r'-+$'), '');
  return trimmed.length > 64 ? trimmed.substring(0, 64) : trimmed;
}

/// SOUL inicial con la plantilla de `composeSoul` de Desktop. La sección
/// "Messaging other agents" se omite a propósito: el protocolo
/// agente-a-agente lo inyecta server-side el gateway moderno
/// (`bot_mode_protocol`) y las Rooms móviles no usan ese comando.
String composeBotSoul({
  required String slug,
  required String title,
  required String description,
  required String customSoul,
}) {
  final custom = customSoul.trim();
  if (custom.isNotEmpty) return custom;
  final display = title.trim().isEmpty ? slug : title.trim();
  return [
    '# $display',
    '',
    if (title.trim().isNotEmpty) '**Role:** ${title.trim()}',
    if (description.trim().isNotEmpty) '**Mission:** ${description.trim()}',
    '',
    'You are $display, a persistent named agent (profile `$slug`) on this machine.',
    'You keep your own memory, skills, and conversation history across sessions.',
  ].join('\n');
}

class BotCreateScreen extends StatefulWidget {
  final SavedConnection connection;

  /// Nombres de profile ya existentes: validación de colisiones y opciones
  /// de clonación (el roster local, como en Desktop).
  final Set<String> existing;

  /// Dobles inyectables en tests; en producción se construyen desde
  /// [connection] y se cierran al salir de la pantalla.
  @visibleForTesting
  final HermesDesktopBotCreationGateway? gateway;
  @visibleForTesting
  final Future<List<ModelProvider>> Function(String profile)?
  modelOptionsLoader;
  @visibleForTesting
  final HermesDesktopProfileAssetsGateway? assetsGateway;
  @visibleForTesting
  final ProfilePetService? petService;
  @visibleForTesting
  final ProfilePetVisualMaterializer? petVisualMaterializer;
  @visibleForTesting
  final BotCreateImagePicker? imagePicker;
  @visibleForTesting
  final BotCreateImageNormalizer? imageNormalizer;
  @visibleForTesting
  final PetdexRemoteService? petdexService;

  /// Dashboard used when the Gateway has no `profiles.create` (tests).
  @visibleForTesting
  final DashboardClient? dashboardForTesting;

  const BotCreateScreen({
    required this.connection,
    required this.existing,
    this.gateway,
    this.modelOptionsLoader,
    this.assetsGateway,
    this.petService,
    this.petVisualMaterializer,
    this.imagePicker,
    this.imageNormalizer,
    this.petdexService,
    this.dashboardForTesting,
    super.key,
  });

  @override
  State<BotCreateScreen> createState() => _BotCreateScreenState();
}

class _BotCreateScreenState extends State<BotCreateScreen> {
  static final _nameRe = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  /// Centinela de "profile nuevo" (el `__none__` de Desktop).
  static const _freshClone = '__none__';

  late final HermesDesktopBotCreationGateway _gateway;
  HermesDesktopProfileAssetsGateway? _assetsGateway;
  ProfilePetService? _petService;
  late final ProfilePetVisualMaterializer _petVisualMaterializer;
  BotIdentityMutationService? _identityMutation;
  late final Future<List<ModelProvider>> Function(String profile) _modelLoader;
  DashboardClient? _ownedDashboard;
  TuiGatewayClient? _ownedGateway;

  final _nameCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _soulCtrl = TextEditingController();

  String _cloneFrom = 'default';
  bool _shareAuth = true;
  bool _noSkills = false;
  bool _advanced = false;
  bool _busy = false;
  bool _profileCreated = false;
  bool _identityApplied = false;
  String? _createdProfileSlug;
  int? _createdAtMs;
  bool _uncertain = false;
  bool _allowPop = false;
  bool _discardDialogOpen = false;
  String? _error;

  _CreateIdentityMode _identityMode = _CreateIdentityMode.face;
  ClassicFaceIdentity? _classic;
  BlobatarShapeWire _blobatar = BlobatarShapeWire.parse('blobatar');
  String _dormantColorHex = '#8b5cf6';
  bool _useShapeColor = false;
  String? _selectedPetSlug;
  AgentProfileAvatar? _pickedAvatar;
  bool _pickingImage = false;
  ProfilePetGallery? _gallery;
  Future<ProfilePetGallery?>? _galleryFuture;

  /// `pet.gallery` no respondió (distinto de un Hermes sin `pet.*`).
  bool _galleryFailed = false;

  /// Mascota elegida en la galería Petdex que la lista del perfil no trae:
  /// Hermes la instala en el perfil al crearlo.
  ProfilePetGalleryEntry? _petdexPick;
  final Map<String, Future<String?>> _thumbFutures = {};

  /// Catálogo de modelos del profile origen; `null` mientras carga y
  /// [_modelFailed] cuando el gateway no lo publica (el perfil hereda el
  /// modelo y la fila vuelve a pedir el catálogo; nunca se escribe a mano).
  List<ModelProvider>? _modelCatalog;
  bool _modelFailed = false;
  ({String provider, String model})? _model;

  /// Skills del profile origen; `null` hasta cargar y [_skillsUnsupported]
  /// cuando `profiles.describe` no existe en este gateway.
  List<DesktopProfileSkill>? _skills;
  bool _skillsLoading = false;
  int _skillsEpoch = 0;
  bool _skillsUnsupported = false;
  bool _skillsTouched = false;
  Map<String, dynamic>? _capabilities;
  final Map<String, List<String>> _capabilityChanges = {};
  int _capabilityEpoch = 0;

  Future<void> _loadCapabilities() async {
    final gateway = _gateway;
    if (gateway is! BotProfileGateway) return;
    final epoch = ++_capabilityEpoch;
    final source = _catalogSource;
    try {
      final result = await (gateway as BotProfileGateway).describeBotProfile(
        source,
      );
      if (mounted && epoch == _capabilityEpoch && source == _catalogSource) {
        setState(() => _capabilities = result);
      }
    } catch (_) {}
  }

  Widget _capabilityOptions(String field, String wire, String title) {
    final s = Strings.of(context);
    final entries = (_capabilities?[field] as List? ?? const [])
        .whereType<Map>()
        .where((e) => e['name'] is String)
        .toList();
    final selected = _capabilityChanges[wire];
    final options = [
      for (final entry in entries)
        BotCapabilityEntry.fromMap(
          entry,
          enabled:
              selected?.contains(entry['name']) ?? entry['enabled'] != false,
        ),
    ];
    final inherited =
        field == 'toolsets' &&
        (selected != null
            ? selected.isEmpty
            : _capabilities?['toolsets_pinned'] == false);
    return BotCapabilitiesRow(
      key: ValueKey('bot-create-$field-row'),
      title: title,
      summary: botCapabilitySummary(context, options, inherited: inherited),
      keyPrefix: 'bot-create-$field',
      entries: options,
      emptyText: field == 'mcp_servers' ? s.botMcpEmpty : s.botToolsEmpty,
      inheritedHint: field == 'toolsets' ? s.botToolsetsInherit : null,
      enabled: !_busy,
      onChanged: (name, value) => setState(() {
        final values =
            _capabilityChanges[wire]?.toSet() ??
            entries
                .where((e) => e['enabled'] != false)
                .map((e) => e['name'] as String)
                .toSet();
        if (value) {
          values.add(name);
        } else {
          values.remove(name);
        }
        _capabilityChanges[wire] = values.toList()..sort();
      }),
    );
  }

  String get _slug => slugifyBotName(_nameCtrl.text);
  String get _targetSlug => _createdProfileSlug ?? _slug;
  bool get _valid => _nameRe.hasMatch(_targetSlug);
  bool get _taken => !_profileCreated && widget.existing.contains(_targetSlug);
  bool get _identityLocked => _profileCreated && _identityApplied;
  bool get _dirty =>
      _profileCreated ||
      _nameCtrl.text.isNotEmpty ||
      _titleCtrl.text.isNotEmpty ||
      _descCtrl.text.isNotEmpty ||
      _soulCtrl.text.isNotEmpty ||
      _model != null ||
      _cloneFrom != 'default' ||
      !_shareAuth ||
      _noSkills ||
      _skillsTouched ||
      _capabilityChanges.isNotEmpty ||
      _identityMode != _CreateIdentityMode.face ||
      _classic != null ||
      _useShapeColor ||
      _blobatar.wire != 'blobatar';

  bool get _spanish =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'es';
  String _text(String es, String en) => _spanish ? es : en;

  /// Origen del catálogo (skills y modelos): el profile clonado, o el
  /// principal cuando se crea vacío — igual que `capSource` en Desktop.
  String get _catalogSource =>
      _cloneFrom == _freshClone ? 'default' : _cloneFrom;

  @override
  void initState() {
    super.initState();
    final injectedGateway = widget.gateway;
    final injectedLoader = widget.modelOptionsLoader;
    if (injectedGateway != null && injectedLoader != null) {
      _gateway = injectedGateway;
      _modelLoader = injectedLoader;
    } else {
      final dashboard = DashboardClient.lazy(widget.connection);
      _ownedDashboard = dashboard;
      if (injectedGateway != null) {
        _gateway = injectedGateway;
      } else {
        final gateway = TuiGatewayClient(
          widget.connection,
          dashboard: dashboard,
        );
        _ownedGateway = gateway;
        _gateway = gateway;
      }
      _modelLoader =
          injectedLoader ??
          (source) => dashboard.getModelOptions(profile: source);
    }
    if (widget.assetsGateway != null) {
      _assetsGateway = widget.assetsGateway;
    } else if (injectedGateway
        case final HermesDesktopProfileAssetsGateway assetsGateway) {
      _assetsGateway = assetsGateway;
    } else {
      _assetsGateway = _ownedGateway;
    }
    final injectedPetService = widget.petService;
    if (injectedPetService != null) {
      _petService = injectedPetService;
    } else {
      if (injectedGateway case final HermesDesktopPetGateway petGateway) {
        _petService = ProfilePetService(petGateway);
      } else if (_ownedGateway != null) {
        _petService = ProfilePetService(_ownedGateway!);
      }
    }
    _petVisualMaterializer =
        widget.petVisualMaterializer ?? ProfilePetVisualAdapter();
    final assets = _assetsGateway;
    final pets = _petService;
    if (assets != null && pets != null) {
      _identityMutation = BotIdentityMutationService(
        assets: assets,
        readPet: (profile) async =>
            await pets.activePet(profile: profile) ??
            (throw StateError('pet.info unavailable')),
        selectPet: (profile, slug) =>
            pets.selectPet(profile: profile, slug: slug),
        disablePet: (profile) => pets.disablePet(profile: profile),
        materializeSelectedPet: (profile, info) =>
            _petVisualMaterializer.materialize(
              info,
              connectionId: widget.connection.id,
              profileId: profile,
            ),
      );
    }
    for (final controller in [_titleCtrl, _descCtrl, _soulCtrl]) {
      controller.addListener(_onFormChanged);
    }
    unawaited(_loadModels());
    unawaited(_loadCapabilities());
    _galleryFuture = _loadGallery();
  }

  void _onFormChanged() {
    if (mounted) {
      setState(() {
        _uncertain = false;
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final controller in [_titleCtrl, _descCtrl, _soulCtrl]) {
      controller
        ..removeListener(_onFormChanged)
        ..dispose();
    }
    if (_ownedGateway != null) unawaited(_ownedGateway!.close());
    _ownedDashboard?.close();
    super.dispose();
  }

  String? get _nameError {
    if (_nameCtrl.text.trim().isEmpty) return null;
    final copy = MissionControlCopy.of(context);
    if (!_valid) return copy.agentNameInvalid;
    if (_taken) return copy.agentNameTaken;
    return null;
  }

  void _retryModels() {
    setState(() {
      _modelCatalog = null;
      _modelFailed = false;
    });
    unawaited(_loadModels());
  }

  Future<void> _loadModels() async {
    final source = _catalogSource;
    try {
      final catalog = await _modelLoader(source);
      if (!mounted || source != _catalogSource) return;
      setState(() {
        _modelCatalog = catalog;
        _modelFailed = catalog.isEmpty;
      });
    } catch (_) {
      if (!mounted || source != _catalogSource) return;
      setState(() {
        _modelCatalog = null;
        _modelFailed = true;
      });
    }
  }

  Future<ProfilePetGallery?> _loadGallery() async {
    final service = _petService;
    if (service == null) return null;
    final source = _catalogSource;
    final ProfilePetGallery? gallery;
    try {
      gallery = await service.gallery(profile: source);
    } catch (_) {
      if (mounted && source == _catalogSource) {
        setState(() => _galleryFailed = true);
      }
      return null;
    }
    if (!mounted || source != _catalogSource) return null;
    setState(() {
      _galleryFailed = false;
      _gallery = gallery;
      if (_selectedPetSlug == null && gallery?.pets.isNotEmpty == true) {
        _selectedPetSlug = gallery!.pets.first.slug;
      }
    });
    return gallery;
  }

  Future<String?> _petThumb(ProfilePetGalleryEntry entry) {
    final service = _petService;
    if (service == null) return Future<String?>.value();
    final key = '$_catalogSource:${entry.slug}';
    return _thumbFutures[key] ??= service.thumbnail(
      profile: _catalogSource,
      slug: entry.slug,
      url: entry.spritesheetUrl,
    );
  }

  /// La entrada de [slug]: de la lista del perfil o la elegida en Petdex.
  ProfilePetGalleryEntry? _petEntry(String? slug) {
    if (slug == null) return null;
    final listed = _gallery?.pets.where((pet) => pet.slug == slug).firstOrNull;
    return listed ?? (_petdexPick?.slug == slug ? _petdexPick : null);
  }

  void _retryGallery() => setState(() {
    _galleryFailed = false;
    _galleryFuture = _loadGallery();
  });

  /// La galería Petdex, con su buscador: la mascota elegida vuelve aquí como
  /// identidad del perfil nuevo.
  Future<void> _pickFromPetdex() async {
    final pet = await Navigator.of(context).push<PetdexRemotePet>(
      MaterialPageRoute<PetdexRemotePet>(
        builder: (_) =>
            PetdexGalleryScreen.picker(service: widget.petdexService),
      ),
    );
    if (pet == null || !mounted) return;
    _changeIdentity(() {
      _identityMode = _CreateIdentityMode.pet;
      _selectedPetSlug = pet.slug;
      _petdexPick = ProfilePetGalleryEntry(
        slug: pet.slug,
        displayName: pet.displayName,
        spritesheetUrl: pet.spritesheetUrl.toString(),
      );
    });
  }

  void _changeIdentity(VoidCallback mutation) {
    if (_identityLocked) return;
    setState(() {
      mutation();
      _uncertain = false;
      _error = null;
    });
  }

  void _selectIdentityMode(_CreateIdentityMode mode) {
    if (mode == _CreateIdentityMode.pet && _selectedPetSlug == null) {
      _selectedPetSlug = _gallery?.pets.firstOrNull?.slug;
    }
    _changeIdentity(() => _identityMode = mode);
  }

  Future<void> _pickImage() async {
    if (_pickingImage || _busy || _identityLocked) return;
    setState(() => _pickingImage = true);
    final messenger = AppFeedback.of(context);
    try {
      final file =
          await (widget.imagePicker?.call() ??
              ImagePicker().pickImage(source: ImageSource.gallery));
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final avatar =
          await (widget.imageNormalizer?.call(bytes) ??
              ProfileImageNormalizer.normalize(bytes));
      if (!mounted) return;
      setState(() {
        _pickedAvatar = avatar;
        _identityMode = _CreateIdentityMode.image;
        _uncertain = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      messenger.notify(
        FeedbackKind.error,
        _text(
          'Usa una imagen PNG, JPEG, WebP o GIF de hasta 15 MB.',
          'Use a PNG, JPEG, WebP, or GIF image up to 15 MB.',
        ),
        warning: true,
      );
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  BotVisualIdentity _faceIdentity() =>
      _classic ??
      ProceduralFaceIdentity(
        shapeWire: _blobatar.wire,
        dormantColorHex: _dormantColorHex,
        useShapeColor: _useShapeColor,
      );

  Future<BotVisualIdentity> _selectedIdentity() async {
    return switch (_identityMode) {
      _CreateIdentityMode.face => _faceIdentity(),
      _CreateIdentityMode.image => switch (_pickedAvatar) {
        final AgentProfileAvatar avatar => ProfileImageIdentity(
          avatar: avatar,
          legacy: false,
        ),
        null => throw const FormatException('Profile image unavailable'),
      },
      _CreateIdentityMode.pet => _selectedPetIdentity(),
    };
  }

  BotVisualIdentity _selectedPetIdentity() {
    final slug = _selectedPetSlug;
    if (slug == null) throw const FormatException('No pet selected');
    if (_petEntry(slug) == null) throw const FormatException('Pet unavailable');
    return PetSpriteIdentity(slug: slug);
  }

  Future<void> _loadSkills() async {
    if (_skillsLoading) return;
    final source = _catalogSource;
    final epoch = ++_skillsEpoch;
    setState(() {
      _skillsLoading = true;
      _skillsUnsupported = false;
    });
    try {
      final skills = await _gateway.describeProfileSkills(source);
      if (!mounted || epoch != _skillsEpoch || source != _catalogSource) return;
      setState(() {
        _skillsLoading = false;
        if (skills == null) {
          _skills = null;
          _skillsUnsupported = true;
        } else {
          _skills = skills;
        }
      });
    } catch (_) {
      if (!mounted || epoch != _skillsEpoch || source != _catalogSource) return;
      setState(() {
        _skillsLoading = false;
        _skills = null;
        _skillsUnsupported = true;
      });
    }
  }

  void _selectCloneSource(String value) {
    if (value == _cloneFrom) return;
    setState(() {
      _cloneFrom = value;
      if (value != _freshClone) _noSkills = false;
      _capabilities = null;
      _capabilityChanges.clear();
      _model = null;
      _modelCatalog = null;
      _modelFailed = false;
      _skills = null;
      _skillsLoading = false;
      _skillsEpoch++;
      _skillsTouched = false;
      _gallery = null;
      _galleryFailed = false;
      // La elegida en Petdex no depende del perfil de origen.
      if (_selectedPetSlug != _petdexPick?.slug) _selectedPetSlug = null;
      _thumbFutures.clear();
    });
    unawaited(_loadModels());
    unawaited(_loadCapabilities());
    _galleryFuture = _loadGallery();
  }

  void _toggleSkill(String name, bool enabled) {
    final skills = _skills;
    if (skills == null) return;
    setState(() {
      _skillsTouched = true;
      _skills = [
        for (final skill in skills)
          skill.name == name ? skill.withEnabled(enabled) : skill,
      ];
    });
  }

  Future<void> _pickModel() async {
    final catalog = _modelCatalog;
    if (catalog == null || catalog.isEmpty) return;
    final copy = MissionControlCopy.of(context);
    final current = _model;
    final choice = await showHermesModelPicker(
      context: context,
      surfaceKey: const ValueKey('bot-create-model-picker'),
      keyPrefix: 'bot-create-model',
      defaultLabel: copy.modelInherited,
      current: current == null
          ? const HermesModelChoice.defaultModel()
          : HermesModelChoice(current.provider, current.model),
      groups: [
        for (final provider in catalog)
          if (provider.models.isNotEmpty)
            HermesModelGroup(
              slug: provider.slug,
              name: provider.name,
              models: provider.models,
            ),
      ],
    );
    // Dismissing keeps the current choice; "inherit" clears it.
    if (choice == null) return;
    final picked = choice.isDefault
        ? null
        : (provider: choice.provider, model: choice.model);
    if (!mounted) return;
    setState(() => _model = picked);
  }

  /// Older Gateways without `profiles.create`: the profile is created through
  /// the Dashboard, as the former Profiles wizard did. Identity, skills and
  /// Bot Mode metadata need the newer RPCs and stay as inherited; a chosen
  /// model is not applied because legacy `model/set` moves the running
  /// default Gateway.
  Future<void> _createLegacy({
    required String slug,
    required String? cloneFrom,
    required String description,
    required String soul,
    required bool wantsModel,
  }) async {
    final str = Strings.of(context);
    final notice = AppFeedback.of(context);
    final owned = widget.dashboardForTesting == null && _ownedDashboard == null;
    final dashboard =
        widget.dashboardForTesting ??
        _ownedDashboard ??
        DashboardClient.lazy(widget.connection);
    try {
      await dashboard.createProfile(
        name: slug,
        cloneFrom: cloneFrom,
        description: description,
      );
      _profileCreated = true;
      if (soul.trim().isNotEmpty) {
        try {
          await dashboard.setProfileSoul(slug, soul);
        } catch (error) {
          notice.notify(
            FeedbackKind.error,
            str.prfSoulWarning(humanizeApiError(error)),
            warning: true,
          );
        }
      }
      if (wantsModel) {
        notice.notify(
          FeedbackKind.error,
          str.prfModelWarning(
            'profiles.create is unavailable on this Hermes Gateway',
          ),
          warning: true,
        );
      }
    } finally {
      if (owned) dashboard.close();
    }
  }

  /// Orden autoritativo: `profiles.create` primero y, solo después, identidad
  /// tipada (pet/asset/ui_meta). Si la identidad no queda confirmada la
  /// pantalla permanece abierta y no navega como si el bot estuviera listo.
  Future<void> _create() async {
    if (!_valid || _taken || _busy) return;
    final copy = MissionControlCopy.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final slug = _targetSlug;
    final title = _titleCtrl.text.trim();
    final description = _descCtrl.text.trim();
    final descriptionText = [
      title,
      description,
    ].where((part) => part.isNotEmpty).join(' — ');
    final model = _model;
    try {
      final mutation = _identityMutation;
      if (mutation == null) {
        throw StateError('Bot identity RPCs unavailable');
      }
      final identityPlan = _identityApplied ? null : await _selectedIdentity();
      if (!_profileCreated) {
        final cloneFrom = _noSkills || _cloneFrom == _freshClone
            ? null
            : _cloneFrom;
        final soul = composeBotSoul(
          slug: slug,
          title: title,
          description: description,
          customSoul: _soulCtrl.text,
        );
        try {
          await _gateway.createProfileNative(
            name: slug,
            cloneFrom: cloneFrom,
            description: descriptionText,
            soul: soul,
            model: model?.model ?? '',
            provider: model?.provider ?? '',
            noSkills: _noSkills,
            shareAuth: _shareAuth,
          );
        } on TuiGatewayRpcError catch (error) {
          // -32601: this Gateway predates `profiles.create`.
          if (error.code != -32601) rethrow;
          await _createLegacy(
            slug: slug,
            cloneFrom: cloneFrom,
            description: descriptionText,
            soul: soul,
            wantsModel: model != null,
          );
          if (!mounted) return;
          _allowPop = true;
          Navigator.of(context).pop(slug);
          return;
        }
        _profileCreated = true;
        _createdProfileSlug = slug;
        _createdAtMs = DateTime.now().millisecondsSinceEpoch;
      }
      final skills = _skills;
      if (_skillsTouched && skills != null && !_noSkills) {
        try {
          await _gateway.setProfileDisabledSkills(
            profile: slug,
            disabledSkills: [
              for (final skill in skills)
                if (!skill.enabled) skill.name,
            ],
          );
        } catch (error) {
          rethrow;
        }
      }
      if (_capabilityChanges.isNotEmpty && _gateway is BotProfileGateway) {
        final result = await (_gateway as BotProfileGateway)
            .configureBotProfile(slug, _capabilityChanges);
        final applied = result['applied'];
        if (applied is! Map ||
            (_capabilityChanges.containsKey('enabled_toolsets') &&
                applied['toolsets'] != true) ||
            (_capabilityChanges.containsKey('enabled_mcp_servers') &&
                applied['mcp_servers'] != true)) {
          throw StateError('Profile capabilities were not saved');
        }
        _capabilityChanges.clear();
      }
      if (!_identityApplied) {
        final profile = AgentProfile.fromJson({
          'name': slug,
          'has_avatar': false,
          'ui_meta': const <String, dynamic>{
            'hermes-bots': <String, dynamic>{},
          },
        });
        final identityResult = await mutation.apply(
          profile: profile,
          target: identityPlan!,
          title: title.isEmpty ? null : title,
          previousPet: ProfilePetInfo.disabled,
          previousAvatar: null,
        );
        switch (identityResult.status) {
          case BotIdentityMutationStatus.applied:
            _identityApplied = true;
          case BotIdentityMutationStatus.rolledBack:
            throw const _BotCreateIdentityFailure(uncertain: false);
          case BotIdentityMutationStatus.uncertain:
            throw const _BotCreateIdentityFailure(uncertain: true);
        }
      }
      await _gateway.saveProfileBotMeta(
        profile: slug,
        createdAtMs: _createdAtMs,
      );
      if (!mounted) return;
      _allowPop = true;
      Navigator.of(context).pop(slug);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _uncertain = switch (error) {
          final _BotCreateIdentityFailure failure => failure.uncertain,
          _ => false,
        };
        _error = switch (error) {
          final _BotCreateIdentityFailure failure when failure.uncertain => _text(
            'El perfil existe, pero no sabemos si su identidad se guardó. Revísala y vuelve a intentarlo.',
            'The profile exists, but its identity is uncertain. Review it and try again.',
          ),
          _BotCreateIdentityFailure() => _text(
            'El perfil existe, pero no se pudo aplicar su identidad. Corrige el problema y vuelve a intentarlo.',
            'The profile exists, but its identity could not be applied. Fix the issue and try again.',
          ),
          FormatException() => _text(
            'Elige una identidad válida antes de crear el perfil.',
            'Choose a valid identity before creating the profile.',
          ),
          _ => copy.createAgentError(humanizeApiError(error)),
        };
      });
    }
  }

  Future<void> _confirmDiscard() async {
    if (_discardDialogOpen || _busy) return;
    _discardDialogOpen = true;
    final discard = await showHermesDialog<bool>(
      context: context,
      surfaceKey: const ValueKey('bot-create-discard-dialog'),
      title: _text('¿Descartar cambios?', 'Discard changes?'),
      message: _profileCreated
          ? _text(
              'El perfil ya existe, pero su configuración visual no terminó. Si sales, no se abrirá su chat automático.',
              'The profile already exists, but its visual setup is incomplete. Leaving will not open its automatic chat.',
            )
          : _text(
              'Perderás la configuración de este perfil.',
              'You will lose this profile setup.',
            ),
      actions: [
        HermesDialogAction(
          key: const ValueKey('bot-create-keep-editing'),
          label: _text('Seguir editando', 'Keep editing'),
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('bot-create-discard'),
          label: _text('Descartar', 'Discard'),
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    _discardDialogOpen = false;
    if (discard == true && mounted) {
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final copy = MissionControlCopy.of(context);
    return PopScope(
      canPop: _allowPop || (!_dirty && !_busy),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmDiscard());
      },
      child: Scaffold(
        appBar: HermesAppBar(title: Text(copy.newAgent)),
        body: Column(
          children: [
            Expanded(
              child: HermesFadedEnd(
                child: ListView(
                  key: const ValueKey('bot-create-form'),
                  clipBehavior: hermesUnderHeader,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 44),
                  children: [
                    Text(
                      copy.createAgentSubtitle,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(child: _buildIdentityPreview()),
                    const SizedBox(height: 18),
                    IgnorePointer(
                      ignoring: _profileCreated,
                      child: Opacity(
                        opacity: _profileCreated ? 0.62 : 1,
                        child: HermesField(
                          key: const ValueKey('bot-create-name'),
                          controller: _nameCtrl,
                          label: copy.agentNameLabel,
                          hint: copy.agentNameHint,
                          errorText: _nameError,
                          helperText: _valid ? '@$_targetSlug' : null,
                          autofocus: true,
                          onChanged: (_) => setState(() {
                            _uncertain = false;
                            _error = null;
                          }),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(
                          child: Text(
                            _text('Personalizar', 'Customize'),
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w800,
                              fontSize: 14.5,
                            ),
                          ),
                        ),
                        Text(
                          _text('opcional', 'optional'),
                          style: TextStyle(
                            color: colors.textTertiary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    BotSettingsGroup(
                      children: [
                        BotSettingsRow(
                          rowKey: const ValueKey('bot-create-identity-row'),
                          initiallyExpanded: false,
                          label: _text('Identidad visual', 'Visual identity'),
                          summary: switch (_identityMode) {
                            _CreateIdentityMode.pet => _text('Mascota', 'Pet'),
                            _CreateIdentityMode.image => _text(
                              'Imagen',
                              'Image',
                            ),
                            _CreateIdentityMode.face => _text('Cara', 'Face'),
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _identitySelector(colors),
                              const SizedBox(height: 8),
                              switch (_identityMode) {
                                _CreateIdentityMode.pet => _buildPetSection(
                                  copy,
                                  colors,
                                ),
                                _CreateIdentityMode.image => _buildImageSection(
                                  colors,
                                ),
                                _CreateIdentityMode.face => _buildFaceSection(
                                  colors,
                                ),
                              },
                            ],
                          ),
                        ),
                        BotSettingsRow(
                          rowKey: const ValueKey('bot-create-title-desc-row'),
                          initiallyExpanded: false,
                          label: _text(
                            'Título y descripción',
                            'Title and description',
                          ),
                          summary:
                              _titleCtrl.text.trim().isEmpty &&
                                  _descCtrl.text.trim().isEmpty
                              ? _text('Sin rellenar', 'Not filled in')
                              : _titleCtrl.text.trim().isNotEmpty
                              ? _titleCtrl.text.trim()
                              : _descCtrl.text.trim(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              HermesField(
                                key: const ValueKey('bot-create-title'),
                                controller: _titleCtrl,
                                label: copy.agentTitleLabel,
                                hint: copy.agentTitleHint,
                              ),
                              const SizedBox(height: 12),
                              HermesField(
                                key: const ValueKey('bot-create-description'),
                                controller: _descCtrl,
                                label: copy.agentDescriptionLabel,
                                hint: copy.agentDescriptionHint,
                                minLines: 2,
                                maxLines: null,
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            HermesSpace.rowH,
                            HermesSpace.rowV + 4,
                            HermesSpace.rowH,
                            HermesSpace.rowV + 4,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                copy.modelLabel,
                                style: HermesType.body.copyWith(
                                  color: colors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _buildModelSection(copy, colors),
                            ],
                          ),
                        ),
                        BotCapabilitiesRow(
                          key: const ValueKey('bot-create-skills-row'),
                          keyPrefix: 'bot-create-skill',
                          title: copy.skills,
                          summary: _noSkills
                              ? Strings.of(context).botCapabilitiesNone
                              : botCapabilitySummary(
                                  context,
                                  _skillOptions,
                                  inherited: !_skillsTouched,
                                ),
                          entries: _noSkills ? const [] : _skillOptions,
                          emptyText: Strings.of(context).botSkillsEmpty,
                          unavailableText: Strings.of(
                            context,
                          ).botSkillCatalogUnavailable,
                          enabled: !_busy,
                          loadEntries: () async {
                            if (_skills == null && !_skillsUnsupported) {
                              await _loadSkills();
                            }
                            return mounted ? _skillOptions : null;
                          },
                          onChanged: _toggleSkill,
                        ),
                        if (_capabilities?['toolsets'] is List)
                          _capabilityOptions(
                            'toolsets',
                            'enabled_toolsets',
                            Strings.of(context).botTools,
                          ),
                        if (_capabilities?['mcp_servers'] is List)
                          _capabilityOptions(
                            'mcp_servers',
                            'enabled_mcp_servers',
                            Strings.of(context).botMcp,
                          ),
                        BotSettingsRow(
                          rowKey: const ValueKey('bot-create-advanced'),
                          label: copy.advanced,
                          summary: _text(
                            'Soul · Clonar de',
                            'Soul · Clone from',
                          ),
                          expanded: _advanced,
                          onToggle: (value) =>
                              setState(() => _advanced = value),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              HermesSectionHeader(copy.cloneFromLabel),
                              HermesSelectField<String>(
                                key: const ValueKey('bot-create-clone'),
                                value: _cloneFrom,
                                options: [
                                  HermesOption(
                                    value: _freshClone,
                                    label: copy.cloneFresh,
                                  ),
                                  const HermesOption(
                                    value: 'default',
                                    label: 'default',
                                  ),
                                  for (final name in widget.existing)
                                    if (name != 'default')
                                      HermesOption(value: name, label: name),
                                ],
                                onChanged: _busy ? null : _selectCloneSource,
                              ),
                              HermesSectionHeader(copy.soulOptionalLabel),
                              Text(
                                copy.soulOptionalHint,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 8),
                              HermesField(
                                key: const ValueKey('bot-create-soul'),
                                controller: _soulCtrl,
                                label: copy.soul,
                                hint: '# $slugPlaceholder',
                                minLines: 6,
                                maxLines: null,
                              ),
                              HermesSwitchTile(
                                key: const ValueKey('bot-create-share-auth'),
                                contentPadding: EdgeInsets.zero,
                                title: copy.shareAuthLabel,
                                value: _shareAuth,
                                onChanged: _busy
                                    ? null
                                    : (value) =>
                                          setState(() => _shareAuth = value),
                              ),
                              Text(
                                _cloneFrom != _freshClone
                                    ? Strings.of(
                                        context,
                                      ).botCloneCredentialsHint
                                    : copy.shareAuthHint,
                                style: TextStyle(
                                  color: colors.textTertiary,
                                  fontSize: 11.5,
                                ),
                              ),
                              HermesSwitchTile(
                                key: const ValueKey('bot-create-no-skills'),
                                contentPadding: EdgeInsets.zero,
                                title: copy.noSkillsLabel,
                                value: _noSkills,
                                onChanged: _busy
                                    ? null
                                    : (value) => setState(() {
                                        _noSkills = value;
                                        if (value) {
                                          _cloneFrom = _freshClone;
                                          _capabilities = null;
                                          _capabilityChanges.clear();
                                          unawaited(_loadCapabilities());
                                        }
                                      }),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        key: const ValueKey('bot-create-error'),
                        style: TextStyle(
                          color: _uncertain ? colors.warning : colors.error,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            _buildFixedCreate(copy, colors),
          ],
        ),
      ),
    );
  }

  String get slugPlaceholder {
    final slug = _slug;
    return slug.isEmpty ? 'agent' : slug;
  }

  Widget _identitySelector(HermesThemeColors colors) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      _modeTile(
        key: const ValueKey('bot-create-mode-pet'),
        label: _text('Mascota', 'Pet'),
        icon: Icons.pets_outlined,
        selected: _identityMode == _CreateIdentityMode.pet,
        onTap: () => _selectIdentityMode(_CreateIdentityMode.pet),
        colors: colors,
      ),
      _modeTile(
        key: const ValueKey('bot-create-mode-image'),
        label: _text('Imagen', 'Image'),
        icon: Icons.image_outlined,
        selected: _identityMode == _CreateIdentityMode.image,
        onTap: () => _selectIdentityMode(_CreateIdentityMode.image),
        colors: colors,
      ),
      _modeTile(
        key: const ValueKey('bot-create-mode-face'),
        label: _text('Cara', 'Face'),
        icon: Icons.face_outlined,
        selected: _identityMode == _CreateIdentityMode.face,
        onTap: () => _selectIdentityMode(_CreateIdentityMode.face),
        colors: colors,
      ),
    ],
  );

  Widget _modeTile({
    required Key key,
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
    required HermesThemeColors colors,
  }) => Semantics(
    selected: selected,
    button: true,
    child: InkWell(
      key: key,
      borderRadius: BorderRadius.circular(999),
      onTap: _busy || _identityLocked ? null : onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 40, minWidth: 86),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.16)
              : colors.surfaceVariant.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? colors.accent.withValues(alpha: 0.38)
                : colors.divider,
            width: selected ? 1 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 19,
              color: selected ? colors.accent : colors.textSecondary,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: selected ? colors.textPrimary : colors.textSecondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildIdentityPreview() {
    final accent = Theme.of(context).hermes.accent;
    return Container(
      key: const ValueKey('bot-create-preview'),
      width: 120,
      height: 120,
      alignment: Alignment.center,
      decoration: _identityMode == _CreateIdentityMode.face
          ? null
          : BoxDecoration(
              color: Theme.of(
                context,
              ).hermes.surfaceVariant.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.28),
                  blurRadius: 18,
                  spreadRadius: -2,
                ),
              ],
            ),
      child: switch (_identityMode) {
        _CreateIdentityMode.pet => _petPreview(),
        _CreateIdentityMode.image => _imagePreview(),
        _CreateIdentityMode.face => _facePreview(size: 96),
      },
    );
  }

  Widget _petPreview() {
    final entry = _petEntry(_selectedPetSlug);
    if (entry == null) {
      return Icon(
        Icons.pets_outlined,
        size: 42,
        color: Theme.of(context).hermes.textDisabled,
      );
    }
    return FutureBuilder<String?>(
      future: _petThumb(entry),
      builder: (context, snapshot) {
        final avatar = _decodeAvatar(snapshot.data);
        if (avatar == null) {
          return Icon(
            Icons.pets_outlined,
            size: 42,
            color: Theme.of(context).hermes.textDisabled,
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Image.memory(
            avatar.bytes,
            width: 96,
            height: 96,
            cacheWidth: 288,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }

  Widget _imagePreview() {
    final avatar = _pickedAvatar;
    if (avatar == null) {
      return Icon(
        Icons.add_photo_alternate_outlined,
        size: 42,
        color: Theme.of(context).hermes.textDisabled,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Image.memory(
        avatar.bytes,
        width: 96,
        height: 96,
        cacheWidth: 288,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }

  Widget _facePreview({required double size}) {
    final profileName = slugPlaceholder;
    final visual = _classic != null
        ? HermesClassicFaceVisual.tryParse(
            shape: _classic!.shape,
            colorHex: _classic!.colorHex,
          )!
        : HermesBlobatarFaceVisual.tryParse(
            shapeWire: _blobatar.wire,
            profileName: profileName,
            colorHex: _useShapeColor ? _dormantColorHex : null,
          )!;
    return HermesBotFace(
      visual: visual,
      size: size,
      semanticLabel: _text('Cara del perfil', 'Profile face'),
      animate: true,
    );
  }

  Widget _buildImageSection(HermesThemeColors colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        _text(
          'PNG, JPEG, WebP o GIF. Se recorta al centro y se guarda cuadrada.',
          'PNG, JPEG, WebP, or GIF. Center-cropped and saved square.',
        ),
        style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const ValueKey('bot-create-pick-image'),
        onPressed: _pickingImage || _busy ? null : _pickImage,
        icon: Icon(_pickingImage ? Icons.hourglass_top : Icons.photo_library),
        label: Text(
          _pickedAvatar == null
              ? _text('Elegir imagen', 'Choose image')
              : _text('Cambiar imagen', 'Change image'),
        ),
      ),
    ],
  );

  Widget _buildFaceSection(HermesThemeColors colors) => BotFaceOptions(
    name: slugPlaceholder,
    keyPrefix: 'bot-create',
    blob: _blobatar,
    classic: _classic,
    colorHex: _useShapeColor ? _dormantColorHex : null,
    fallbackColorHex: _dormantColorHex,
    enabled: !_busy,
    onBlob: (value) => _changeIdentity(() {
      _classic = null;
      _blobatar = value;
    }),
    onClassic: (value) => _changeIdentity(() {
      _classic = value;
      _dormantColorHex = value.colorHex;
      _useShapeColor = true;
    }),
    onColor: (color) => _changeIdentity(() {
      _dormantColorHex = color;
      _useShapeColor = true;
      if (_classic != null) {
        _classic = ClassicFaceIdentity(shape: _classic!.shape, colorHex: color);
      }
    }),
  );

  Widget _buildPetSection(MissionControlCopy copy, HermesThemeColors colors) =>
      FutureBuilder<ProfilePetGallery?>(
        key: const ValueKey('bot-create-sprite-gallery'),
        future: _galleryFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: ConsoleLoader.medium(showLabel: true)),
            );
          }
          final gallery = snapshot.data;
          if (gallery == null && !_galleryFailed) {
            return Text(
              copy.botSpriteUnsupported,
              style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
            );
          }
          final listed = gallery?.pets ?? const <ProfilePetGalleryEntry>[];
          final pick = _petdexPick;
          final unlisted =
              pick != null && !listed.any((pet) => pet.slug == pick.slug)
              ? pick
              : null;
          final visible = [?unlisted, ...listed].take(48).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                copy.botSpriteHint,
                style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              if (_galleryFailed)
                _buildPetListNotice(copy.botSpriteLoadFailed, colors)
              else if (listed.isEmpty)
                _buildPetListNotice(copy.botSpriteEmpty, colors),
              if (visible.isNotEmpty)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final scale = MediaQuery.textScalerOf(
                      context,
                    ).scale(1).clamp(1.0, 2.0);
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: visible.length,
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 92,
                        mainAxisExtent: 86 + 14 * (scale - 1),
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                      ),
                      itemBuilder: (context, index) =>
                          _petTile(visible[index], colors),
                    );
                  },
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('bot-create-petdex'),
                onPressed: _busy || _identityLocked ? null : _pickFromPetdex,
                icon: const Icon(Icons.travel_explore_outlined),
                label: Text(Strings.of(context).petdexGalleryTitle),
              ),
            ],
          );
        },
      );

  /// La lista del perfil no está: lo dice en una línea, con el reintento.
  Widget _buildPetListNotice(String line, HermesThemeColors colors) => Row(
    children: [
      Expanded(
        child: Text(
          line,
          style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
        ),
      ),
      TextButton(
        key: const ValueKey('bot-create-pets-retry'),
        onPressed: _busy ? null : _retryGallery,
        child: Text(Strings.of(context).commonRetry),
      ),
    ],
  );

  Widget _petTile(ProfilePetGalleryEntry pet, HermesThemeColors colors) {
    final selected = _selectedPetSlug == pet.slug;
    return Semantics(
      selected: selected,
      button: true,
      label: pet.displayName,
      child: InkWell(
        key: ValueKey('bot-create-sprite-${pet.slug}'),
        borderRadius: BorderRadius.circular(12),
        onTap: _busy
            ? null
            : () => _changeIdentity(() {
                _identityMode = _CreateIdentityMode.pet;
                _selectedPetSlug = pet.slug;
              }),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? colors.accent : colors.divider,
                  width: selected ? 1.8 : 1,
                ),
              ),
              child: FutureBuilder<String?>(
                future: _petThumb(pet),
                builder: (context, snapshot) {
                  final avatar = _decodeAvatar(snapshot.data);
                  if (avatar == null) {
                    return Icon(
                      Icons.pets,
                      size: 22,
                      color: colors.textDisabled,
                    );
                  }
                  return Image.memory(
                    avatar.bytes,
                    cacheWidth: 168,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            Text(
              pet.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }

  AgentProfileAvatar? _decodeAvatar(String? dataUri) {
    if (dataUri == null) return null;
    try {
      return AgentProfileAvatar.fromDataUri(dataUri);
    } on FormatException {
      return null;
    }
  }

  Widget _buildFixedCreate(MissionControlCopy copy, HermesThemeColors colors) =>
      Material(
        key: const ValueKey('bot-create-fixed-submit'),
        color: colors.background,
        child: SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 9, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_uncertain ||
                    _profileCreated ||
                    _nameCtrl.text.trim().isEmpty) ...[
                  Text(
                    _uncertain
                        ? _text(
                            'Estado incierto: revisa y vuelve a intentar.',
                            'Uncertain state: review and try again.',
                          )
                        : _profileCreated
                        ? _text(
                            'Perfil creado · falta confirmar la identidad',
                            'Profile created · identity confirmation pending',
                          )
                        : Strings.of(context).botCreateNameRequired,
                    key: ValueKey(
                      _uncertain ? 'bot-create-uncertain' : 'bot-create-clean',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _uncertain ? colors.warning : colors.textSecondary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 7),
                ],
                HermesPrimaryButton(
                  key: const ValueKey('bot-create-submit'),
                  label: _busy
                      ? _text('Creando…', 'Creating…')
                      : _profileCreated
                      ? _text('Reintentar identidad', 'Retry identity')
                      : copy.createAgentSubmit,
                  icon: _busy ? Icons.sync : Icons.smart_toy_outlined,
                  onTap: _valid && !_taken && !_busy ? _create : null,
                ),
              ],
            ),
          ),
        ),
      );

  /// The model is chosen from the catalog, never typed. Without a catalog
  /// the profile inherits its model, and the tile reads the catalog again.
  Widget _buildModelSection(MissionControlCopy copy, HermesThemeColors colors) {
    final selected = _model;
    final loading = _modelCatalog == null && !_modelFailed;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('bot-create-model-tile'),
        borderRadius: BorderRadius.circular(12),
        onTap: loading || _busy
            ? null
            : _modelFailed
            ? _retryModels
            : _pickModel,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.divider),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  loading
                      ? Strings.of(context).commonLoading
                      : selected == null
                      ? copy.modelInherited
                      : '${selected.model} · ${selected.provider}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textPrimary, fontSize: 13.5),
                ),
              ),
              if (loading)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  _modelFailed
                      ? Icons.refresh_rounded
                      : Icons.chevron_right_rounded,
                  size: 20,
                  color: colors.textSecondary,
                  semanticLabel: _modelFailed
                      ? Strings.of(context).commonRetry
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<BotCapabilityEntry>? get _skillOptions => _skills == null
      ? null
      : [
          for (final skill in _skills!)
            BotCapabilityEntry(
              name: skill.name,
              label: skill.label,
              description: skill.description,
              group: skill.group,
              enabled: skill.enabled,
            ),
        ];
}
