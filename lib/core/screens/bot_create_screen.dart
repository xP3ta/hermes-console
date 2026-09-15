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
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/agent_profile.dart';
import '../models/bot_visual_identity.dart';
import '../models/profile_pet.dart';
import '../services/bot_identity_mutation_service.dart';
import '../services/connection_manager.dart';
import '../services/profile_pet_service.dart';
import '../services/profile_pet_visual_adapter.dart';
import '../services/profile_image_normalizer.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../utils/api_error.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_bot_face.dart';
import '../widgets/hermes_premium_ui.dart';
import '../widgets/hermes_ui.dart';
import 'mission_control_copy.dart';

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
  final _providerCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();

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
  BlobatarShapeWire _blobatar = BlobatarShapeWire.parse('blobatar');
  static const String _dormantColorHex = '#8b5cf6';
  String? _selectedPetSlug;
  AgentProfileAvatar? _pickedAvatar;
  bool _pickingImage = false;
  ProfilePetGallery? _gallery;
  Future<ProfilePetGallery?>? _galleryFuture;
  final Map<String, Future<String?>> _thumbFutures = {};

  /// Catálogo de modelos del profile origen; `null` mientras carga y
  /// [_modelFailed] cuando el gateway no lo publica (fallback a texto libre,
  /// como el ModelPicker de Desktop con un inventario vacío).
  List<ModelProvider>? _modelCatalog;
  bool _modelFailed = false;
  ({String provider, String model})? _model;

  /// Skills del profile origen; `null` hasta cargar y [_skillsUnsupported]
  /// cuando `profiles.describe` no existe en este gateway.
  List<DesktopProfileSkill>? _skills;
  bool _skillsLoading = false;
  bool _skillsUnsupported = false;
  bool _skillsTouched = false;

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
      _providerCtrl.text.isNotEmpty ||
      _modelCtrl.text.isNotEmpty ||
      _model != null ||
      _cloneFrom != 'default' ||
      !_shareAuth ||
      _noSkills ||
      _advanced ||
      _identityMode != _CreateIdentityMode.face ||
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
    for (final controller in [
      _titleCtrl,
      _descCtrl,
      _soulCtrl,
      _providerCtrl,
      _modelCtrl,
    ]) {
      controller.addListener(_onFormChanged);
    }
    unawaited(_loadModels());
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
    for (final controller in [
      _titleCtrl,
      _descCtrl,
      _soulCtrl,
      _providerCtrl,
      _modelCtrl,
    ]) {
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
    final gallery = await service.gallery(profile: source);
    if (!mounted || source != _catalogSource) return null;
    setState(() {
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
    final messenger = ScaffoldMessenger.of(context);
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _text(
              'Usa una imagen PNG, JPEG, WebP o GIF de hasta 15 MB.',
              'Use a PNG, JPEG, WebP, or GIF image up to 15 MB.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  BotVisualIdentity _faceIdentity() => ProceduralFaceIdentity(
    shapeWire: _blobatar.wire,
    dormantColorHex: _dormantColorHex,
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
    final gallery = _gallery;
    if (slug == null || gallery == null) {
      throw const FormatException('No pet selected');
    }
    final entry = gallery.pets.where((pet) => pet.slug == slug).firstOrNull;
    if (entry == null) throw const FormatException('Pet unavailable');
    return PetSpriteIdentity(slug: slug);
  }

  Future<void> _loadSkills() async {
    if (_skillsLoading) return;
    final source = _catalogSource;
    setState(() {
      _skillsLoading = true;
      _skillsUnsupported = false;
    });
    try {
      final skills = await _gateway.describeProfileSkills(source);
      if (!mounted || source != _catalogSource) return;
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
      if (!mounted || source != _catalogSource) return;
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
      _model = null;
      _modelCatalog = null;
      _modelFailed = false;
      _skills = null;
      _skillsTouched = false;
      _gallery = null;
      _selectedPetSlug = null;
      _thumbFutures.clear();
    });
    unawaited(_loadModels());
    _galleryFuture = _loadGallery();
    if (_advanced) unawaited(_loadSkills());
  }

  void _toggleSkill(String name, bool enabled) {
    final skills = _skills;
    if (skills == null) return;
    setState(() {
      _skillsTouched = true;
      _skills = [
        for (final skill in skills)
          skill.name == name
              ? DesktopProfileSkill(name: skill.name, enabled: enabled)
              : skill,
      ];
    });
  }

  Future<void> _pickModel() async {
    final catalog = _modelCatalog;
    if (catalog == null || catalog.isEmpty) return;
    final copy = MissionControlCopy.of(context);
    final picked =
        await showHermesFloatingSurface<({String provider, String model})>(
          context: context,
          surfaceKey: const ValueKey('bot-create-model-picker'),
          maxWidth: 560,
          maxHeightFactor: 0.88,
          builder: (sheetContext) => ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            children: [
              ListTile(
                key: const ValueKey('bot-create-model-inherit'),
                dense: true,
                leading: const Icon(Icons.auto_awesome, size: 18),
                title: Text(copy.modelInherited),
                onTap: () => Navigator.pop(sheetContext),
              ),
              for (final provider in catalog)
                if (provider.models.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 2),
                    child: Text(
                      provider.name,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(sheetContext).hermes.accentHover,
                      ),
                    ),
                  ),
                  for (final model in provider.models)
                    ListTile(
                      key: ValueKey('bot-create-model-${provider.slug}-$model'),
                      dense: true,
                      title: Text(model, style: const TextStyle(fontSize: 13)),
                      onTap: () => Navigator.pop(sheetContext, (
                        provider: provider.slug,
                        model: model,
                      )),
                    ),
                ],
            ],
          ),
        );
    if (!mounted) return;
    setState(() => _model = picked);
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
    final fallbackProvider = _providerCtrl.text.trim();
    final fallbackModel = _modelCtrl.text.trim();
    final wantsFallbackModel =
        _modelFailed && fallbackProvider.isNotEmpty && fallbackModel.isNotEmpty;
    try {
      final mutation = _identityMutation;
      if (mutation == null) {
        throw StateError('Bot identity RPCs unavailable');
      }
      final identityPlan = _identityApplied ? null : await _selectedIdentity();
      if (!_profileCreated) {
        await _gateway.createProfileNative(
          name: slug,
          cloneFrom: _cloneFrom == _freshClone ? null : _cloneFrom,
          description: descriptionText,
          soul: composeBotSoul(
            slug: slug,
            title: title,
            description: description,
            customSoul: _soulCtrl.text,
          ),
          model: model?.model ?? (wantsFallbackModel ? fallbackModel : ''),
          provider:
              model?.provider ?? (wantsFallbackModel ? fallbackProvider : ''),
          noSkills: _noSkills,
          shareAuth: _shareAuth,
        );
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
          debugPrint('Bot creation: could not apply skill selection: $error');
        }
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
            'El bot existe, pero su identidad quedó en estado incierto. Revísala y vuelve a intentar.',
            'The bot exists, but its identity is uncertain. Review it and try again.',
          ),
          _BotCreateIdentityFailure() => _text(
            'El bot existe, pero no se pudo aplicar su identidad. Corrige el problema y vuelve a intentar.',
            'The bot exists, but its identity could not be applied. Fix the issue and try again.',
          ),
          FormatException() => _text(
            'Elige una identidad válida antes de crear el bot.',
            'Choose a valid identity before creating the bot.',
          ),
          _ => copy.createAgentError(humanizeApiError(error)),
        };
      });
    }
  }

  Future<void> _confirmDiscard() async {
    if (_discardDialogOpen || _busy) return;
    _discardDialogOpen = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('bot-create-discard-dialog'),
        scrollable: true,
        title: Text(_text('¿Descartar cambios?', 'Discard changes?')),
        content: Text(
          _profileCreated
              ? _text(
                  'El perfil ya existe, pero su configuración visual no terminó. Si sales, no se abrirá su chat automático.',
                  'The profile already exists, but its visual setup is incomplete. Leaving will not open its automatic chat.',
                )
              : _text(
                  'Perderás la configuración de este bot.',
                  'You will lose this bot setup.',
                ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('bot-create-keep-editing'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_text('Seguir editando', 'Keep editing')),
          ),
          TextButton(
            key: const ValueKey('bot-create-discard'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_text('Descartar', 'Discard')),
          ),
        ],
      ),
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
              child: ListView(
                key: const ValueKey('bot-create-form'),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                children: [
                  Text(
                    copy.createAgentSubtitle,
                    style: TextStyle(color: colors.textSecondary, fontSize: 13),
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
                  const SizedBox(height: 12),
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
                    maxLines: 4,
                  ),
                  HermesSectionHeader(
                    _text('Identidad visual', 'Visual identity'),
                  ),
                  _identitySelector(colors),
                  const SizedBox(height: 8),
                  switch (_identityMode) {
                    _CreateIdentityMode.pet => _buildPetSection(copy, colors),
                    _CreateIdentityMode.image => _buildImageSection(colors),
                    _CreateIdentityMode.face => _buildFaceSection(colors),
                  },
                  HermesSectionHeader(copy.modelLabel),
                  _buildModelSection(copy, colors),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const ValueKey('bot-create-advanced'),
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() => _advanced = !_advanced);
                            if (_advanced &&
                                _skills == null &&
                                !_skillsLoading &&
                                !_skillsUnsupported) {
                              unawaited(_loadSkills());
                            }
                          },
                    icon: Icon(
                      _advanced ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                    label: Text(copy.advanced),
                    style: TextButton.styleFrom(
                      alignment: AlignmentDirectional.centerStart,
                    ),
                  ),
                  if (_advanced) ...[
                    HermesSectionHeader(copy.cloneFromLabel),
                    DropdownButtonFormField<String>(
                      key: const ValueKey('bot-create-clone'),
                      initialValue: _cloneFrom,
                      items: [
                        DropdownMenuItem(
                          value: _freshClone,
                          child: Text(copy.cloneFresh),
                        ),
                        DropdownMenuItem(
                          value: 'default',
                          child: Text('default'),
                        ),
                        for (final name in widget.existing)
                          if (name != 'default')
                            DropdownMenuItem(value: name, child: Text(name)),
                      ],
                      onChanged: _busy
                          ? null
                          : (value) {
                              if (value != null) _selectCloneSource(value);
                            },
                    ),
                    if (!_noSkills) ...[
                      HermesSectionHeader(copy.skills),
                      _buildSkillsSection(copy, colors),
                    ],
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
                      minLines: 4,
                      maxLines: 8,
                    ),
                    HermesSwitchTile(
                      key: const ValueKey('bot-create-share-auth'),
                      contentPadding: EdgeInsets.zero,
                      title: copy.shareAuthLabel,
                      value: _shareAuth,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _shareAuth = value),
                    ),
                    Text(
                      copy.shareAuthHint,
                      style: TextStyle(
                        color: colors.textDisabled,
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
                          : (value) => setState(() => _noSkills = value),
                    ),
                  ],
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
      decoration: BoxDecoration(
        color: Theme.of(context).hermes.surfaceVariant.withValues(alpha: 0.28),
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
    final slug = _selectedPetSlug;
    final gallery = _gallery;
    final entry = gallery?.pets.where((pet) => pet.slug == slug).firstOrNull;
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
            cacheHeight: 288,
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
        cacheHeight: 288,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }

  Widget _facePreview({required double size}) {
    final profileName = slugPlaceholder;
    final visual = HermesBlobatarFaceVisual.tryParse(
      shapeWire: _blobatar.wire,
      profileName: profileName,
    )!;
    return HermesBotFace(
      visual: visual,
      size: size,
      semanticLabel: _text('Cara del bot', 'Bot face'),
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

  Widget _buildFaceSection(HermesThemeColors colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      HermesSectionHeader(_text('Silueta', 'Silhouette')),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _blobatarOption(null, colors),
          for (final kind in BlobatarShapeWire.kinds)
            _blobatarOption(kind, colors),
        ],
      ),
    ],
  );

  Widget _blobatarOption(String? kind, HermesThemeColors colors) {
    final selected = _blobatar.kind == kind;
    final wire = _blobatar.withKind(kind).wire;
    final visual = HermesBlobatarFaceVisual.tryParse(
      shapeWire: wire,
      profileName: slugPlaceholder,
    )!;
    return Tooltip(
      message: kind ?? _text('Automática', 'Automatic'),
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          key: ValueKey('bot-create-blobatar-${kind ?? 'auto'}'),
          borderRadius: BorderRadius.circular(12),
          onTap: _busy
              ? null
              : () => _changeIdentity(() {
                  _blobatar = _blobatar.withKind(kind);
                }),
          child: Container(
            width: 52,
            height: 52,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? colors.accent : colors.divider,
                width: selected ? 1.8 : 1,
              ),
            ),
            child: HermesBotFace(visual: visual, size: 42),
          ),
        ),
      ),
    );
  }

  Widget _buildPetSection(MissionControlCopy copy, HermesThemeColors colors) =>
      FutureBuilder<ProfilePetGallery?>(
        key: const ValueKey('bot-create-sprite-gallery'),
        future: _galleryFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final gallery = snapshot.data;
          if (gallery == null) {
            return Text(
              copy.botSpriteUnsupported,
              style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
            );
          }
          final visible = gallery.pets.take(48).toList();
          if (visible.isEmpty) {
            return Text(
              copy.botSpriteEmpty,
              style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                copy.botSpriteHint,
                style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
              ),
              const SizedBox(height: 12),
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
            ],
          );
        },
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
                    cacheHeight: 168,
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
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.divider)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                      : _dirty
                      ? _text('Configuración sin crear', 'Uncreated setup')
                      : _text(
                          'Completa el nombre para empezar',
                          'Enter a name to start',
                        ),
                  key: ValueKey(
                    _uncertain
                        ? 'bot-create-uncertain'
                        : _dirty
                        ? 'bot-create-dirty'
                        : 'bot-create-clean',
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _uncertain
                        ? colors.warning
                        : _dirty
                        ? colors.accent
                        : colors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
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

  Widget _buildModelSection(MissionControlCopy copy, HermesThemeColors colors) {
    if (_modelFailed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            copy.modelCatalogEmpty,
            style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          HermesField(
            key: const ValueKey('bot-create-provider'),
            controller: _providerCtrl,
            label: copy.providerLabel,
            hint: 'openai',
          ),
          const SizedBox(height: 10),
          HermesField(
            key: const ValueKey('bot-create-model'),
            controller: _modelCtrl,
            label: copy.modelLabel,
            hint: 'gpt-5.2',
          ),
        ],
      );
    }
    final selected = _model;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('bot-create-model-tile'),
        borderRadius: BorderRadius.circular(12),
        onTap: _modelCatalog == null || _busy ? null : _pickModel,
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
                  _modelCatalog == null
                      ? copy.skillsLoading
                      : selected == null
                      ? copy.modelInherited
                      : '${selected.model} · ${selected.provider}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textPrimary, fontSize: 13.5),
                ),
              ),
              if (_modelCatalog == null)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colors.textSecondary,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSkillsSection(
    MissionControlCopy copy,
    HermesThemeColors colors,
  ) {
    if (_skillsLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          copy.skillsLoading,
          style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
        ),
      );
    }
    final skills = _skills;
    if (_skillsUnsupported || skills == null) {
      return Text(
        copy.skillsUnavailable,
        style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
      );
    }
    if (skills.isEmpty) {
      return Text(
        copy.botSpriteEmpty,
        style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final skill in skills)
          HermesSwitchTile(
            key: ValueKey('bot-create-skill-${skill.name}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: skill.name,
            value: skill.enabled,
            onChanged: _busy
                ? null
                : (value) => _toggleSkill(skill.name, value),
          ),
        const SizedBox(height: 4),
        Text(
          copy.skillsFromSource(_catalogSource),
          style: TextStyle(color: colors.textDisabled, fontSize: 11.5),
        ),
      ],
    );
  }
}
