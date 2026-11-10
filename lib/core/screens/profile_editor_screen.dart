import 'dart:async';
import '../../l10n/app_localizations.dart';
import '../services/bot_profile_client.dart';
import 'bot_profile_settings_screen.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:image_picker/image_picker.dart';

import '../characters/bot_character.dart';
import '../characters/bot_character_store.dart';
import '../characters/character_face.dart';
import '../models/agent_profile.dart';
import '../models/bot_visual_identity.dart';
import '../models/profile_identity.dart';
import '../models/profile_pet.dart';
import '../services/connection_manager.dart';
import '../services/bot_identity_mutation_service.dart';
import '../services/profile_pet_service.dart';
import '../services/profile_pet_visual_adapter.dart';
import '../services/profile_image_normalizer.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../theme/hermes_tokens.dart';
import '../theme/lines.dart';
import '../theme/theme_contrast.dart';
import '../bots/ui/profile/bot_profile_screen.dart' show reasoningLabel;
import '../bots/ui/profile/profile_model_picker.dart';
import '../companion/data/petdex_remote_service.dart';
import '../companion/models/companion_animation_state.dart';
import '../companion/render/spritesheet_renderer.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_bot_face.dart';
import '../widgets/bot_face_options.dart';
import '../widgets/hermes_reasoning_pill.dart';
import '../widgets/hermes_ui.dart';
import 'characters/character_studio_screen.dart';
import 'companion/petdex_gallery_screen.dart';
import 'mission_control_copy.dart';
import '../widgets/console_loader.dart';
import '../design/hermes_design.dart'
    show
        HermesDialogAction,
        HermesDialogActionStyle,
        HermesFadedEnd,
        HermesListGroup,
        HermesListRow,
        HermesSurfaceHeader,
        showHermesDialog,
        showHermesSurface;
import '../feedback/feedback_policy.dart';

typedef ProfileEditorImagePicker = Future<XFile?> Function();
typedef ProfileEditorImageNormalizer =
    Future<AgentProfileAvatar> Function(Uint8List bytes);

enum _IdentityMode { pet, image, face }

/// The tab of the identity sheet. [character] is a face drawn by the
/// Studio: it is the `face` mode of the server identity plus a device-local
/// character on top, so it has its own tab but no mode of its own.
enum _IdentityPanel { pet, image, character, face }

final class _ProfileEditorSaveFailure implements Exception {
  final bool uncertain;

  /// The description write is what the server refused.
  final bool description;

  const _ProfileEditorSaveFailure({
    required this.uncertain,
    this.description = false,
  });
}

/// Editor de identidad de Bot Mode.
///
/// La UI mantiene exactamente una variante activa: mascota animada, imagen
/// raster o cara controlada. Los SVG remotos nunca se interpretan; las caras
/// se regeneran con [HermesBotFace] desde allowlists Desktop.
class ProfileEditorScreen extends StatefulWidget {
  final SavedConnection connection;
  final AgentProfile profile;

  @visibleForTesting
  final HermesDesktopProfileAssetsGateway? gateway;
  @visibleForTesting
  final ProfilePetService? petService;
  @visibleForTesting
  final ProfileEditorImagePicker? imagePicker;
  @visibleForTesting
  final ProfileEditorImageNormalizer? imageNormalizer;
  @visibleForTesting
  final ProfilePetVisualMaterializer? petVisualMaterializer;
  @visibleForTesting
  final PetdexRemoteService? petdexService;

  /// Abre la pantalla de skills de este bot desde la fila "Skills" de
  /// "Personalizar". `null` la deja como fila informativa sin navegación
  /// (p. ej. en tests que no ejercitan esta ruta).
  final VoidCallback? onOpenSkills;

  /// Hermes aceptó un cambio hecho aquí fuera de «Guardar» (el modelo).
  final VoidCallback? onChanged;
  @visibleForTesting
  final ProfileModelCatalogs? modelCatalogs;

  const ProfileEditorScreen({
    required this.connection,
    required this.profile,
    this.gateway,
    this.petService,
    this.imagePicker,
    this.imageNormalizer,
    this.petVisualMaterializer,
    this.petdexService,
    this.onOpenSkills,
    this.onChanged,
    this.modelCatalogs,
    super.key,
  });

  @override
  State<ProfileEditorScreen> createState() => _ProfileEditorScreenState();
}

class _ProfileEditorScreenState extends State<ProfileEditorScreen> {
  static const int _maxVisiblePets = 48;

  late final HermesDesktopProfileAssetsGateway _gateway;
  late final ProfilePetService _petService;
  late final ProfilePetVisualMaterializer _petVisualMaterializer;
  late final BotIdentityMutationService _identityMutation;
  DashboardClient? _ownedDashboard;
  TuiGatewayClient? _ownedGateway;

  late final TextEditingController _titleCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _searchCtrl;
  late final String _initialTitle;

  /// The description the server has (what the field started with, or what
  /// the last successful save wrote).
  late String _savedDescription;

  /// Bumped on every state change so the identity sheet, which lives in its
  /// own route, repaints the live preview with the page.
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);

  /// The character the Studio drew for this profile (device-local), as a
  /// draft: [BotCharacterStore.shared] is only written on «Guardar».
  BotCharacter? _character;
  BotCharacter? _characterBaseline;
  _IdentityPanel? _panelOverride;

  /// The reasoning level of the profile (`agent.reasoning_effort`); applied
  /// as soon as it is picked, like the model.
  String? _reasoning;
  bool _reasoningLoaded = false;
  bool _reasoningBusy = false;

  /// A server refusal, written in the save bar.
  String? _error;

  late _IdentityMode _mode;
  late String _dormantColorHex;
  bool _useShapeColor = false;
  late BlobatarShapeWire _blobatar;
  ClassicFaceIdentity? _classic;
  late bool _needsLegacyFaceMigration;
  String? _selectedSlug;
  String? _baselinePetSlug;
  String _query = '';

  late Future<AgentProfileAvatar?> _avatarFuture;
  late Future<ProfilePetGallery?> _galleryFuture;
  Future<ProfilePetVisual?>? _activePetVisualFuture;
  AgentProfileAvatar? _remoteAvatar;
  AgentProfileAvatar? _pickedAvatar;
  String? _pickedAvatarDataUri;
  ProfilePetGallery? _resolvedGallery;

  /// `pet.gallery` no respondió (distinto de un Hermes sin `pet.*`).
  bool _galleryFailed = false;

  /// Mascota elegida en la galería Petdex que la lista del perfil no trae:
  /// Hermes la instala en el perfil al guardar.
  ProfilePetGalleryEntry? _petdexPick;
  final Map<String, Future<String?>> _thumbFutures = {};

  bool _identityTouched = false;
  bool _pickingImage = false;
  bool _saving = false;
  bool _uncertain = false;
  bool _allowPop = false;
  bool _discardDialogOpen = false;
  bool _petPhotoConflict = false;

  String get _profileName => widget.profile.name;

  bool get _titleDirty => _titleCtrl.text.trim() != _initialTitle;

  String get _identitySignature {
    return switch (_mode) {
      _IdentityMode.pet => 'pet:${_selectedSlug ?? ''}',
      _IdentityMode.image =>
        _pickedAvatarDataUri == null
            ? 'image:remote'
            : 'image:picked:${_pickedAvatarDataUri.hashCode}',
      _IdentityMode.face =>
        _classic == null
            ? 'face:${_blobatar.wire}:${_useShapeColor ? _dormantColorHex : 'auto'}'
            : 'classic:${_classic!.shape}:${_classic!.colorHex}',
    };
  }

  late String _baselineIdentitySignature;

  bool get _identityDirty =>
      _identityTouched && _identitySignature != _baselineIdentitySignature;
  bool get _descriptionWritable => _gateway is BotProfileGateway;
  bool get _descriptionDirty =>
      _descriptionWritable && _descCtrl.text.trim() != _savedDescription;
  bool get _characterDirty => _character != _characterBaseline;
  bool get _dirty =>
      _titleDirty || _identityDirty || _descriptionDirty || _characterDirty;

  /// Whether the fields and the identity can be changed at all: not on a
  /// read-only connection, not while saving.
  bool get _canEdit => !widget.connection.readOnly && !_saving;

  String get _connectionId => widget.connection.id;

  _IdentityPanel get _panel =>
      _panelOverride ??
      switch (_mode) {
        _IdentityMode.pet => _IdentityPanel.pet,
        _IdentityMode.image => _IdentityPanel.image,
        _IdentityMode.face =>
          _character != null ? _IdentityPanel.character : _IdentityPanel.face,
      };

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _tick.value++;
  }

  Strings get _strings => Strings.of(context);

  @override
  void initState() {
    super.initState();
    final injectedGateway = widget.gateway;
    final injectedPets = widget.petService;
    if (injectedGateway != null && injectedPets != null) {
      _gateway = injectedGateway;
      _petService = injectedPets;
    } else {
      final dashboard = DashboardClient.lazy(widget.connection);
      final gateway = TuiGatewayClient(widget.connection, dashboard: dashboard);
      _ownedDashboard = dashboard;
      _ownedGateway = gateway;
      _gateway = gateway;
      _petService = ProfilePetService(gateway);
    }
    _petVisualMaterializer =
        widget.petVisualMaterializer ?? ProfilePetVisualAdapter();
    _identityMutation = BotIdentityMutationService(
      assets: _gateway,
      readPet: (profile) async =>
          await _petService.activePet(profile: profile) ??
          (throw StateError('pet.info unavailable')),
      selectPet: (profile, slug) =>
          _petService.selectPet(profile: profile, slug: slug),
      disablePet: (profile) => _petService.disablePet(profile: profile),
      materializeSelectedPet: (profile, info) =>
          _petVisualMaterializer.materialize(
            info,
            connectionId: widget.connection.id,
            profileId: profile,
          ),
    );

    _initialTitle = widget.profile.botTitle ?? '';
    _titleCtrl = TextEditingController(text: _initialTitle)
      ..addListener(_onTitleChanged);
    _savedDescription = widget.profile.description.trim();
    _descCtrl = TextEditingController(text: _savedDescription)
      ..addListener(_onTitleChanged);
    _searchCtrl = TextEditingController();
    _characterBaseline = BotCharacterStore.shared.characterFor(
      _connectionId,
      _profileName,
    );
    _character = _characterBaseline;

    final blobatar = BlobatarShapeWire.tryParse(widget.profile.botShape);
    _blobatar = blobatar ?? BlobatarShapeWire.parse('blobatar');
    if (ClassicFaceIdentity.shapes.contains(widget.profile.botShape) &&
        ClassicFaceIdentity.colors.contains(widget.profile.botColorHex)) {
      _classic = ClassicFaceIdentity(
        shape: widget.profile.botShape!,
        colorHex: widget.profile.botColorHex!,
      );
    }
    _needsLegacyFaceMigration = blobatar == null && _classic == null;
    _dormantColorHex =
        ClassicFaceIdentity.colors.contains(widget.profile.botColorHex)
        ? widget.profile.botColorHex!
        : '#8b5cf6';
    _useShapeColor = _classic != null || widget.profile.botUsesShapeColor;

    final startsAsImage =
        widget.profile.hasAvatar && widget.profile.botImageKind != 'shape';
    _mode = startsAsImage ? _IdentityMode.image : _IdentityMode.face;
    _baselineIdentitySignature =
        _needsLegacyFaceMigration && _mode == _IdentityMode.face
        ? 'face:legacy'
        : _identitySignature;

    _avatarFuture = _loadAvatar();
    _galleryFuture = _loadGallery();
    unawaited(_loadReasoning());
  }

  void _onTitleChanged() {
    if (mounted) {
      setState(() {
        _uncertain = false;
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    _titleCtrl
      ..removeListener(_onTitleChanged)
      ..dispose();
    _descCtrl
      ..removeListener(_onTitleChanged)
      ..dispose();
    _searchCtrl.dispose();
    _tick.dispose();
    if (_ownedGateway != null) unawaited(_ownedGateway!.close());
    _ownedDashboard?.close();
    super.dispose();
  }

  Future<AgentProfileAvatar?> _loadAvatar() async {
    if (!widget.profile.hasAvatar) return null;
    try {
      final avatar = await _gateway.profileAvatar(_profileName);
      _remoteAvatar = avatar;
      if (mounted) setState(() {});
      return avatar;
    } catch (_) {
      return null;
    }
  }

  Future<ProfilePetGallery?> _loadGallery() async {
    final ProfilePetGallery? gallery;
    try {
      gallery = await _petService.gallery(profile: _profileName);
    } catch (_) {
      _galleryFailed = true;
      if (mounted) setState(() {});
      return null;
    }
    _galleryFailed = false;
    if (gallery == null) return null;
    _resolvedGallery = gallery;
    final active = gallery.enabled && gallery.active.isNotEmpty
        ? gallery.active
        : null;
    _baselinePetSlug = active;
    // `pet.info` and Bot Mode metadata are separate server stores. A stale or
    // separately configured active pet must not silently replace an explicitly
    // persisted Blobatar (`imageKind: shape`) in this profile: doing so made
    // the editor look clean and disabled Save even though the roster still
    // rendered the saved face. Keep the active slug available as the first pet
    // choice, but only rehydrate Pet mode when the stored identity permits it.
    final activeIsPersistedIdentity =
        active != null &&
        widget.profile.hasAvatar &&
        widget.profile.botImageKind == 'photo';
    final mayHavePhotoConflict =
        active != null &&
        widget.profile.hasAvatar &&
        widget.profile.botImageKind == 'photo';
    _petPhotoConflict = false;
    if (!_identityTouched && activeIsPersistedIdentity) {
      _selectedSlug = active;
      _mode = _IdentityMode.pet;
      _baselineIdentitySignature = _identitySignature;
    }
    if (active != null) {
      final visualFuture = _loadActivePetVisual(active);
      _activePetVisualFuture = visualFuture;
      if (mayHavePhotoConflict) {
        unawaited(_resolvePetPhotoConflict(active, visualFuture));
      }
    }
    if (mounted) setState(() {});
    return gallery;
  }

  Future<void> _resolvePetPhotoConflict(
    String expectedSlug,
    Future<ProfilePetVisual?> visualFuture,
  ) async {
    final remoteAvatar = await _avatarFuture;
    final visual = await visualFuture;
    final conflict =
        remoteAvatar != null &&
        (visual == null || !_sameAvatar(remoteAvatar, visual.avatar));
    if (!mounted || _baselinePetSlug != expectedSlug) return;
    setState(() => _petPhotoConflict = conflict);
  }

  Future<ProfilePetVisual?> _loadActivePetVisual(String expectedSlug) async {
    try {
      final info = await _petService.activePet(profile: _profileName);
      if (info == null || !info.hasPet || info.slug != expectedSlug) {
        return null;
      }
      return await _petVisualMaterializer.materialize(
        info,
        connectionId: widget.connection.id,
        profileId: _profileName,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _thumbFuture(ProfilePetGalleryEntry entry) =>
      _thumbFutures[entry.slug] ??= _petService.thumbnail(
        profile: _profileName,
        slug: entry.slug,
        url: entry.spritesheetUrl,
      );

  void _retryGallery() => setState(() {
    _galleryFailed = false;
    _galleryFuture = _loadGallery();
  });

  /// La galería Petdex, con su buscador: la mascota elegida vuelve aquí como
  /// identidad del perfil.
  Future<void> _pickFromPetdex() async {
    final pet = await Navigator.of(context).push<PetdexRemotePet>(
      MaterialPageRoute<PetdexRemotePet>(
        builder: (_) =>
            PetdexGalleryScreen.picker(service: widget.petdexService),
      ),
    );
    if (pet == null || !mounted) return;
    _changeIdentity(() {
      _mode = _IdentityMode.pet;
      _panelOverride = _IdentityPanel.pet;
      _selectedSlug = pet.slug;
      _petdexPick = ProfilePetGalleryEntry(
        slug: pet.slug,
        displayName: pet.displayName,
        spritesheetUrl: pet.spritesheetUrl.toString(),
      );
    });
  }

  void _changeIdentity(VoidCallback mutation) {
    setState(() {
      mutation();
      _identityTouched = true;
      _uncertain = false;
      _error = null;
    });
  }

  void _selectMode(_IdentityMode mode) {
    if (mode == _IdentityMode.pet && _selectedSlug == null) {
      _selectedSlug =
          _baselinePetSlug ?? _resolvedGallery?.pets.firstOrNull?.slug;
    }
    _changeIdentity(() {
      _mode = mode;
      // «Cara» is the other way round from «Personaje»: picking it asks for a
      // plain face, so the character stops covering it.
      if (mode == _IdentityMode.face) _character = null;
      _panelOverride = switch (mode) {
        _IdentityMode.pet => _IdentityPanel.pet,
        _IdentityMode.image => _IdentityPanel.image,
        _IdentityMode.face => _IdentityPanel.face,
      };
    });
  }

  /// The Studio, on a draft store seeded with this profile's character: what
  /// is chosen there comes back as the draft and only reaches the saved
  /// characters on «Guardar».
  Future<void> _openStudio() async {
    if (!_canEdit) return;
    final store = BotCharacterStore.detached();
    final current = _character;
    if (current != null) {
      await store.save(_connectionId, _profileName, current);
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CharacterStudioScreen(
          profileName: _profileName,
          connectionId: _connectionId,
          store: store,
        ),
      ),
    );
    final picked = store.characterFor(_connectionId, _profileName);
    store.dispose();
    if (!mounted) return;
    // A character only shows over a face: a photo or a pet would hide it.
    if (picked != _character ||
        (picked != null && _mode != _IdentityMode.face)) {
      _changeIdentity(() {
        _character = picked;
        if (picked != null) _mode = _IdentityMode.face;
        _panelOverride = _IdentityPanel.character;
      });
    }
  }

  /// Back to the plain seeded face: no photo, no pet, no character, no colour.
  void _resetIdentity() => _changeIdentity(() {
    _mode = _IdentityMode.face;
    _character = null;
    _classic = null;
    _blobatar = BlobatarShapeWire.parse('blobatar');
    _useShapeColor = false;
    _panelOverride = _IdentityPanel.face;
  });

  bool get _isDefaultIdentity =>
      _mode == _IdentityMode.face &&
      _character == null &&
      _classic == null &&
      !_useShapeColor &&
      _blobatar.wire == BlobatarShapeWire.parse('blobatar').wire;

  Future<void> _loadReasoning() async {
    final gateway = _gateway;
    if (gateway is! BotModelGateway) return;
    try {
      final value = await (gateway as BotModelGateway).botReasoning(
        _profileName,
      );
      if (!mounted) return;
      setState(() {
        _reasoning = value;
        _reasoningLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _reasoningLoaded = true);
    }
  }

  /// Unknown counts as supported: only a catalog that says «no reasoning»
  /// for the profile's model hides the row.
  bool get _reasoningSupported {
    final catalogs = widget.modelCatalogs ?? ProfileModelCatalogs.shared;
    final option = catalogs
        .peek(_connectionId, _profileName)
        ?.optionFor(widget.profile.provider, widget.profile.model);
    return option?.capabilities.reasoning != false;
  }

  Future<void> _pickReasoning() async {
    final gateway = _gateway;
    if (gateway is! BotModelGateway || !_canEdit || _reasoningBusy) return;
    final s = _strings;
    final picked = await showHermesReasoningPicker(
      context: context,
      surfaceKey: const ValueKey('profile-editor-reasoning-picker'),
      title: s.pexReasoning,
      selected: _reasoning,
      defaultLabel: s.botProfileReasoningDefault,
      levels: [
        for (final effort in BotProfileClient.reasoningEfforts)
          HermesReasoningLevel(effort, reasoningLabel(s, effort)),
      ],
    );
    if (picked == null || !mounted || picked == _reasoning) return;
    setState(() {
      _reasoningBusy = true;
      _error = null;
    });
    try {
      await (gateway as BotModelGateway).setBotReasoning(_profileName, picked);
      if (!mounted) return;
      setState(() => _reasoning = picked);
      widget.onChanged?.call();
    } catch (_) {
      if (mounted) setState(() => _error = s.pexReasoningFailed);
    } finally {
      if (mounted) setState(() => _reasoningBusy = false);
    }
  }

  Future<void> _pickImage() async {
    if (_pickingImage || _saving) return;
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
      final dataUri = avatar.toDataUri();
      if (!mounted) return;
      setState(() {
        _pickedAvatar = avatar;
        _pickedAvatarDataUri = dataUri;
        _mode = _IdentityMode.image;
        _panelOverride = _IdentityPanel.image;
        _identityTouched = true;
        _uncertain = false;
      });
    } catch (_) {
      if (!mounted) return;
      messenger.notify(
        FeedbackKind.error,
        _strings.i18n131ProfileUseAPngJpegWebpOrGif,
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

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    final copy = MissionControlCopy.of(context);
    final messenger = AppFeedback.of(context);
    setState(() {
      _saving = true;
      _uncertain = false;
      _error = null;
    });

    try {
      // The description goes first: it is one plain write, so when it fails
      // nothing else has changed yet.
      if (_descriptionDirty) {
        final text = _descCtrl.text.trim();
        final result = await (_gateway as BotProfileGateway)
            .configureBotProfile(_profileName, {'description': text});
        final applied = result['applied'];
        if (applied is! Map || applied['description'] != true) {
          throw const _ProfileEditorSaveFailure(
            uncertain: false,
            description: true,
          );
        }
        _savedDescription = text;
        widget.onChanged?.call();
      }
      final newTitle = _titleCtrl.text.trim();
      final title = _titleDirty ? newTitle : null;
      BotVisualIdentity? identity;

      if (_identityDirty ||
          (_needsLegacyFaceMigration && _mode == _IdentityMode.face)) {
        switch (_mode) {
          case _IdentityMode.pet:
            final slug = _selectedSlug;
            if (slug == null) {
              throw const FormatException('No pet selected');
            }
            identity = PetSpriteIdentity(slug: slug);
          case _IdentityMode.image:
            final avatar = _pickedAvatar ?? _remoteAvatar;
            if (avatar == null) {
              throw const FormatException('Profile image unavailable');
            }
            identity = ProfileImageIdentity(avatar: avatar, legacy: false);
          case _IdentityMode.face:
            identity = _faceIdentity();
        }
      }

      if (identity != null) {
        final previousPet =
            await _petService.activePet(profile: _profileName) ??
            (_baselinePetSlug == null
                ? ProfilePetInfo.disabled
                : ProfilePetInfo(enabled: true, slug: _baselinePetSlug!));
        final previousAvatar = await _avatarFuture;
        final result = await _identityMutation.apply(
          profile: widget.profile,
          target: identity,
          title: title,
          previousPet: previousPet,
          previousAvatar: previousAvatar,
        );
        switch (result.status) {
          case BotIdentityMutationStatus.applied:
            // The pet chosen here is this profile's identity everywhere.
            ProfileIdentities.instance.refresh(widget.connection.id);
          case BotIdentityMutationStatus.rolledBack:
            throw const _ProfileEditorSaveFailure(uncertain: false);
          case BotIdentityMutationStatus.uncertain:
            throw const _ProfileEditorSaveFailure(uncertain: true);
        }
      }

      if (identity == null && title != null) {
        await _gateway.saveProfileBotMeta(profile: _profileName, title: title);
      }
      // The character lives on this device: it is written once the server
      // has taken the rest, so a refusal never leaves it half applied.
      if (_characterDirty) {
        await BotCharacterStore.shared.save(
          _connectionId,
          _profileName,
          _character ?? BotCharacter.standard,
        );
      }
      if (!mounted) return;
      messenger.notify(FeedbackKind.routine, copy.botEditorSaved);
      _allowPop = true;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      final uncertain = switch (error) {
        final _ProfileEditorSaveFailure failure => failure.uncertain,
        FormatException() || ArgumentError() => false,
        _ => true,
      };
      setState(() {
        _saving = false;
        _uncertain = uncertain;
        // The «uncertain» line already says it; a refusal is written once.
        _error = uncertain
            ? null
            : error is _ProfileEditorSaveFailure && error.description
            ? _strings.pexDescriptionFailed
            : _strings.pexSaveFailed;
      });
      messenger.notify(FeedbackKind.error, copy.botEditorSaveFailed);
    }
  }

  ProfilePetGalleryEntry _galleryEntry(String slug) =>
      _resolvedGallery?.pets.firstWhere(
        (entry) => entry.slug == slug,
        orElse: () => _unlistedEntry(slug),
      ) ??
      _unlistedEntry(slug);

  ProfilePetGalleryEntry _unlistedEntry(String slug) =>
      _petdexPick?.slug == slug
      ? _petdexPick!
      : ProfilePetGalleryEntry(slug: slug, displayName: slug);

  Future<void> _confirmDiscard() async {
    if (_discardDialogOpen || _saving) return;
    _discardDialogOpen = true;
    final discard = await showHermesDialog<bool>(
      context: context,
      title: _strings.i18n131ProfileDiscardChanges,
      message: _strings.i18n131ProfileTheProfileIdentityHasNotBeenSaved,
      actions: [
        HermesDialogAction(
          key: const ValueKey('profile-editor-keep-editing'),
          label: _strings.i18n131ProfileKeepEditing,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('profile-editor-discard'),
          label: _strings.i18n131ProfileDiscard,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    _discardDialogOpen = false;
    if (discard == true && mounted) {
      setState(() => _allowPop = true);
      Navigator.of(context).pop(false);
    }
  }

  Future<void> _openIdentitySheet() async {
    if (!_canEdit) return;
    await showHermesSurface<void>(
      context: context,
      surfaceKey: const ValueKey('profile-editor-identity-sheet'),
      maxHeightFactor: 0.92,
      builder: (sheet) => ValueListenableBuilder<int>(
        valueListenable: _tick,
        builder: (context, tick, child) => _identitySheet(sheet),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final copy = MissionControlCopy.of(context);
    final s = _strings;
    final model = _gateway;
    return PopScope(
      canPop: _allowPop || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmDiscard());
      },
      child: Scaffold(
        appBar: HermesAppBar(title: Text(copy.editBotTitle)),
        body: Column(
          children: [
            Expanded(
              child: HermesFadedEnd(
                child: ListView(
                  key: const ValueKey('profile-editor-scroll'),
                  // Hard edge: what scrolls up stops at the header instead of
                  // passing under its title, where the avatar used to show
                  // cut in half.
                  clipBehavior: Clip.hardEdge,
                  padding: const EdgeInsets.fromLTRB(
                    HermesSpace.x5,
                    HermesSpace.x2,
                    HermesSpace.x5,
                    HermesSpace.x6,
                  ),
                  children: [
                    _buildAvatarHero(colors),
                    const SizedBox(height: HermesSpace.x4),
                    HermesField(
                      label: copy.botDisplayName,
                      controller: _titleCtrl,
                      hint: copy.botDisplayNameHint,
                      enabled: _canEdit,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(
                        left: HermesSpace.x1,
                        top: HermesSpace.x1,
                      ),
                      child: Text(
                        s.i18n131ProfileTheProfilenameIdentifierDoesNotChange(
                          _profileName,
                        ),
                        style: TextStyle(
                          color: colors.textTertiary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: HermesSpace.x4),
                    HermesField(
                      label: s.pexDescription,
                      controller: _descCtrl,
                      hint: s.pexDescriptionHint,
                      fieldKey: const ValueKey('profile-editor-description'),
                      enabled: _canEdit && _descriptionWritable,
                      minLines: 2,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      inputFormatters: [LengthLimitingTextInputFormatter(2048)],
                    ),
                    const SizedBox(height: HermesSpace.x4),
                    HermesListGroup(
                      children: [
                        // El modelo se elige de lo que el perfil puede usar.
                        ProfileModelPicker(
                          profile: _profileName,
                          scope: widget.connection.id,
                          provider: widget.profile.provider,
                          model: widget.profile.model,
                          catalogGateway: model is BotModelGateway
                              ? model as BotModelGateway
                              : null,
                          writer: model is BotProfileGateway
                              ? model as BotProfileGateway
                              : null,
                          readOnly: widget.connection.readOnly,
                          keyPrefix: 'profile-editor-model',
                          catalogs: widget.modelCatalogs,
                          onChanged: widget.onChanged,
                          builder: (context, row) => _navRow(
                            key: const ValueKey('profile-editor-model-row'),
                            label: copy.modelLabel,
                            value: row.model.trim().isEmpty
                                ? s.i18n131ProfileAutomatic
                                : row.model,
                            onTap: row.onTap,
                            busy: row.busy,
                          ),
                        ),
                        if (model is BotModelGateway && _reasoningSupported)
                          _navRow(
                            key: const ValueKey('profile-editor-reasoning-row'),
                            label: s.pexReasoning,
                            value: !_reasoningLoaded
                                ? '…'
                                : _reasoning == null
                                ? s.botProfileReasoningDefault
                                : reasoningLabel(s, _reasoning!),
                            onTap: _canEdit && _reasoningLoaded
                                ? _pickReasoning
                                : null,
                            busy: _reasoningBusy,
                          ),
                        _navRow(
                          key: const ValueKey('profile-editor-skills-row'),
                          label: copy.skills,
                          value: s.i18n131ProfileViewSkills,
                          onTap: widget.onOpenSkills,
                        ),
                        if (model is BotProfileGateway)
                          _navRow(
                            key: const ValueKey('profile-editor-advanced-row'),
                            label: s.botAdvanced,
                            value: '',
                            onTap: _saving
                                ? null
                                : () => Navigator.of(context).push<bool>(
                                    MaterialPageRoute(
                                      builder: (_) => BotProfileSettingsScreen(
                                        profile: _profileName,
                                        gateway: model as BotProfileGateway,
                                      ),
                                    ),
                                  ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            _buildFixedSave(copy, colors),
          ],
        ),
      ),
    );
  }

  /// Fila de navegación hacia una pantalla ya existente (p. ej. Skills): la
  /// misma fila que el resto de la app. Sin `onTap` se degrada a
  /// informativa: nunca muestra una flecha que no lleve a ningún sitio.
  Widget _navRow({
    required Key key,
    required String label,
    required String value,
    required VoidCallback? onTap,
    bool busy = false,
  }) => HermesListRow(
    key: key,
    title: label,
    value: value,
    onTap: onTap,
    trailing: busy ? const ConsoleLoader.small() : null,
  );

  /// The big avatar at the top, the same faces the Bots list paints, and the
  /// one way into the identity sheet: the avatar itself or «Cambiar».
  Widget _buildAvatarHero(HermesThemeColors colors) {
    final open = _canEdit ? _openIdentitySheet : null;
    return Column(
      children: [
        Semantics(
          button: true,
          enabled: open != null,
          label: _strings.pexAvatarLabel(
            widget.profile.botTitle ?? _profileName,
          ),
          excludeSemantics: true,
          onTap: open,
          child: InkResponse(
            key: const ValueKey('profile-editor-avatar'),
            onTap: open,
            radius: 84,
            child: SizedBox(
              width: 156,
              height: 156,
              child: Center(child: _buildPreview()),
            ),
          ),
        ),
        TextButton(
          key: const ValueKey('profile-editor-change'),
          style: TextButton.styleFrom(minimumSize: const Size(96, 48)),
          onPressed: open,
          child: Text(_strings.pexChange),
        ),
      ],
    );
  }

  /// Everything about the profile's look, in one place: the live preview, the
  /// four kinds of identity as tabs and, under them, the options of the one
  /// chosen. Every change shows at once, on the sheet and on the page behind.
  Widget _identitySheet(BuildContext sheet) {
    final colors = Theme.of(sheet).hermes;
    final s = _strings;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HermesSurfaceHeader(title: s.i18n131ProfileVisualIdentity),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.x4,
              HermesSpace.x1,
              HermesSpace.x4,
              HermesSpace.x4,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: SizedBox(
                    key: const ValueKey('profile-editor-sheet-preview'),
                    width: 112,
                    height: 112,
                    child: Center(
                      child: _identityVisual(size: 96, still: true),
                    ),
                  ),
                ),
                const SizedBox(height: HermesSpace.x3),
                _identitySelector(colors),
                const SizedBox(height: HermesSpace.x3),
                switch (_panel) {
                  _IdentityPanel.pet => _buildPetSection(
                    MissionControlCopy.of(context),
                    colors,
                  ),
                  _IdentityPanel.image => _buildImageSection(colors),
                  _IdentityPanel.character => _buildCharacterSection(colors),
                  _IdentityPanel.face => _buildFaceSection(colors),
                },
                const SizedBox(height: HermesSpace.x4),
                HermesPrimaryButton(
                  key: const ValueKey('profile-editor-sheet-done'),
                  label: s.pexDone,
                  onTap: () => Navigator.of(sheet).pop(),
                ),
                const SizedBox(height: HermesSpace.x1),
                Center(
                  child: TextButton(
                    key: const ValueKey('profile-editor-reset'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(96, 48),
                    ),
                    onPressed: _isDefaultIdentity || !_canEdit
                        ? null
                        : _resetIdentity,
                    child: Text(s.pexReset),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCharacterSection(HermesThemeColors colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        _strings.pexCharacterNote,
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: HermesType.supportSize,
        ),
      ),
      const SizedBox(height: HermesSpace.x3),
      OutlinedButton(
        key: const ValueKey('profile-editor-open-studio'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _canEdit ? _openStudio : null,
        child: Text(_strings.pexCharacterOpen),
      ),
    ],
  );

  Widget _identitySelector(HermesThemeColors colors) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      _modeTile(
        key: const ValueKey('profile-editor-mode-image'),
        label: _strings.pexPhoto,
        selected: _panel == _IdentityPanel.image,
        onTap: () => _selectMode(_IdentityMode.image),
        colors: colors,
      ),
      _modeTile(
        key: const ValueKey('profile-editor-mode-character'),
        label: _strings.pexCharacter,
        selected: _panel == _IdentityPanel.character,
        // The Studio opens at once: choosing «Personaje» is choosing one.
        onTap: () {
          setState(() => _panelOverride = _IdentityPanel.character);
          unawaited(_openStudio());
        },
        colors: colors,
      ),
      _modeTile(
        key: const ValueKey('profile-editor-mode-pet'),
        label: _strings.i18n131ProfilePet,
        selected: _panel == _IdentityPanel.pet,
        onTap: () => _selectMode(_IdentityMode.pet),
        colors: colors,
      ),
      _modeTile(
        key: const ValueKey('profile-editor-mode-face'),
        label: _strings.i18n131ProfileFace,
        selected: _panel == _IdentityPanel.face,
        onTap: () => _selectMode(_IdentityMode.face),
        colors: colors,
      ),
    ],
  );

  Widget _modeTile({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required HermesThemeColors colors,
  }) => Semantics(
    selected: selected,
    button: true,
    enabled: _canEdit,
    child: InkWell(
      key: key,
      borderRadius: BorderRadius.circular(HermesRadius.tag),
      onTap: _canEdit ? onTap : null,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 86),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.16)
              : colors.surfaceVariant.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(HermesRadius.tag),
          border: Border.all(
            color: selected
                ? colors.accent.withValues(alpha: 0.38)
                : colors.divider,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? colors.textPrimary : colors.textSecondary,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            fontSize: HermesType.valueSize,
          ),
        ),
      ),
    ),
  );

  /// The profile's identity as it stands in this draft. The same faces the
  /// Bots list paints: a pet, the photo, a Studio character over the face, or
  /// the face itself. [still] paints it without motion (the sheet's copy).
  Widget _identityVisual({required double size, bool still = false}) =>
      switch (_mode) {
        _IdentityMode.pet => _petPreview(size, still: still),
        _IdentityMode.image => _imagePreview(size),
        _IdentityMode.face =>
          _character != null
              ? CharacterFace(
                  profileName: _profileName,
                  character: _character!,
                  size: size,
                  animate: !still,
                  semanticLabel: _strings.i18n131ProfileProfileFace,
                )
              : _facePreview(size: size, animate: !still),
      };

  Widget _buildPreview() {
    final colors = Theme.of(context).hermes;
    final accent = colors.accent;
    final withBackdrop = _mode != _IdentityMode.face || _character != null;
    // The frame is always drawn, a contour on the page: the place to tap
    // stays visible while an avatar loads or when a face paints nothing
    // (on the device «Cambiar» floated over an empty space).
    final frame = HermesLines.of(colors).contourOn(
      withBackdrop
          ? ThemeContrast.composite(
              colors.surfaceVariant.withValues(alpha: 0.28),
              colors.background,
            )
          : colors.background,
    );
    return Container(
      key: const ValueKey('profile-editor-preview'),
      width: 140,
      height: 140,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: withBackdrop
            ? colors.surfaceVariant.withValues(alpha: 0.28)
            : null,
        borderRadius: BorderRadius.circular(HermesRadius.pane),
        border: Border.all(color: frame),
        boxShadow: !withBackdrop
            ? null
            : [
                BoxShadow(
                  color: accent.withValues(alpha: 0.28),
                  blurRadius: 18,
                  spreadRadius: -2,
                ),
              ],
      ),
      child: _identityVisual(size: 120),
    );
  }

  Widget _petPreview(double size, {bool still = false}) {
    final slug = _selectedSlug;
    if (slug == null) {
      return Icon(
        Icons.pets_outlined,
        size: size * 0.45,
        color: Theme.of(context).hermes.textDisabled,
      );
    }
    final entry = _galleryEntry(slug);
    // The sheet's copy is a still thumbnail: the page behind already runs the
    // pet's animation, and two sprite tickers would only cost.
    if (still) {
      return _petThumbPreview(
        entry,
        size,
        key: const ValueKey('profile-editor-sheet-pet-preview'),
      );
    }
    final activeVisual = slug == _baselinePetSlug
        ? _activePetVisualFuture
        : null;
    if (activeVisual != null) {
      return FutureBuilder<ProfilePetVisual?>(
        future: activeVisual,
        builder: (context, snapshot) {
          final visual = snapshot.data;
          if (visual != null) {
            return SpritesheetRenderer(
              key: const ValueKey('profile-editor-pet-animated-preview'),
              companion: visual.companion,
              state: CompanionAnimationState.idle,
              size: size,
            );
          }
          return _petThumbPreview(entry, size);
        },
      );
    }
    return _petThumbPreview(entry, size);
  }

  Widget _petThumbPreview(
    ProfilePetGalleryEntry entry,
    double size, {
    Key key = const ValueKey('profile-editor-pet-static-preview'),
  }) {
    return FutureBuilder<String?>(
      future: _thumbFuture(entry),
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
          key: key,
          borderRadius: BorderRadius.circular(HermesRadius.card),
          child: Image.memory(
            avatar.bytes,
            width: size,
            height: size,
            cacheWidth: 288,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }

  Widget _imagePreview(double size) {
    final picked = _pickedAvatar;
    if (picked != null) return _avatarImage(picked, size);
    return FutureBuilder<AgentProfileAvatar?>(
      future: _avatarFuture,
      builder: (context, snapshot) {
        final avatar = snapshot.data;
        if (avatar != null) return _avatarImage(avatar, size);
        return Icon(
          Icons.add_photo_alternate_outlined,
          size: 42,
          color: Theme.of(context).hermes.textDisabled,
        );
      },
    );
  }

  Widget _avatarImage(AgentProfileAvatar avatar, double size) => ClipRRect(
    borderRadius: BorderRadius.circular(HermesRadius.card),
    child: Image.memory(
      avatar.bytes,
      width: size,
      height: size,
      cacheWidth: 288,
      fit: BoxFit.cover,
      gaplessPlayback: true,
    ),
  );

  Widget _facePreview({required double size, bool animate = true}) {
    final visual = _classic != null
        ? HermesClassicFaceVisual.tryParse(
            shape: _classic!.shape,
            colorHex: _classic!.colorHex,
          )!
        : HermesBlobatarFaceVisual.tryParse(
            shapeWire: _blobatar.wire,
            profileName: _profileName,
            colorHex: _useShapeColor ? _dormantColorHex : null,
          )!;
    return HermesBotFace(
      visual: visual,
      size: size,
      semanticLabel: _strings.i18n131ProfileProfileFace,
      animate: animate,
    );
  }

  Widget _buildImageSection(HermesThemeColors colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        _strings.i18n131ProfilePngJpegWebpOrGifCenterCropped,
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: HermesType.supportSize,
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const ValueKey('profile-editor-pick-image'),
        onPressed: _pickingImage || _saving ? null : _pickImage,
        icon: Icon(_pickingImage ? Icons.hourglass_top : Icons.photo_library),
        label: Text(
          _pickedAvatar == null && _remoteAvatar == null
              ? _strings.i18n131ProfileChooseImage
              : _strings.i18n131ProfileChangeImage,
        ),
      ),
    ],
  );

  Widget _buildFaceSection(HermesThemeColors colors) => BotFaceOptions(
    name: _profileName,
    keyPrefix: 'profile-editor',
    blob: _blobatar,
    classic: _classic,
    colorHex: _useShapeColor ? _dormantColorHex : null,
    fallbackColorHex: _dormantColorHex,
    enabled: !_saving,
    // A shape or a colour is a request for a plain face: the character that
    // would cover it goes (it comes back with «Personaje»).
    onBlob: (value) => _changeIdentity(() {
      _character = null;
      _classic = null;
      _blobatar = value;
    }),
    onClassic: (value) => _changeIdentity(() {
      _character = null;
      _classic = value;
      _dormantColorHex = value.colorHex;
      _useShapeColor = true;
    }),
    onColor: (color) => _changeIdentity(() {
      _character = null;
      _dormantColorHex = color;
      _useShapeColor = true;
      if (_classic != null) {
        _classic = ClassicFaceIdentity(shape: _classic!.shape, colorHex: color);
      }
    }),
  );

  Widget _buildPetSection(MissionControlCopy copy, HermesThemeColors colors) =>
      FutureBuilder<ProfilePetGallery?>(
        key: const ValueKey('profile-editor-sprite-gallery'),
        future: _galleryFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: HermesSpace.x6),
              child: Center(child: ConsoleLoader.medium(showLabel: true)),
            );
          }
          final gallery = snapshot.data;
          if (gallery == null && !_galleryFailed) {
            return Text(
              copy.botSpriteUnsupported,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: HermesType.supportSize,
              ),
            );
          }
          final listed = gallery?.pets ?? const <ProfilePetGalleryEntry>[];
          final pick = _petdexPick;
          final unlisted =
              pick != null && !listed.any((pet) => pet.slug == pick.slug)
              ? pick
              : null;
          final query = _query.trim().toLowerCase();
          int rank(ProfilePetGalleryEntry pet) =>
              identical(pet, unlisted) ? 0 : (pet.installed ? 1 : 2);
          final filtered = [?unlisted, ...listed].where((pet) {
            if (query.isEmpty) return true;
            return pet.displayName.toLowerCase().contains(query) ||
                pet.slug.toLowerCase().contains(query);
          }).toList()..sort((a, b) => rank(a).compareTo(rank(b)));
          final visible = filtered.take(_maxVisiblePets).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                copy.botSpriteHint,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: HermesType.supportSize,
                ),
              ),
              if (_petPhotoConflict) _buildConflictCard(colors),
              const SizedBox(height: 10),
              if (_galleryFailed)
                _buildPetListNotice(copy.botSpriteLoadFailed, colors)
              else if (listed.isEmpty)
                _buildPetListNotice(copy.botSpriteEmpty, colors),
              if (listed.isNotEmpty) ...[
                TextField(
                  controller: _searchCtrl,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    hintText: copy.botSpriteSearchHint,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    filled: true,
                    fillColor: colors.surfaceVariant.withValues(alpha: 0.3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(HermesRadii.field),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (visible.isEmpty && listed.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: HermesSpace.x4),
                  child: Text(
                    copy.botSpriteEmpty,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.textSecondary),
                  ),
                )
              else if (visible.isNotEmpty)
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
                          _spriteTile(visible[index], colors),
                    );
                  },
                ),
              const SizedBox(height: 12),
              OutlinedButton(
                key: const ValueKey('profile-editor-petdex'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                ),
                onPressed: _canEdit ? _pickFromPetdex : null,
                child: Text(
                  Strings.of(context).petdexGalleryTitle,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          );
        },
      );

  /// La lista del perfil no está: lo dice en una línea, con el reintento.
  Widget _buildPetListNotice(String line, HermesThemeColors colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        line,
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: HermesType.supportSize,
        ),
      ),
      TextButton(
        key: const ValueKey('profile-editor-pets-retry'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _retryGallery,
        child: Text(Strings.of(context).commonRetry),
      ),
    ],
  );

  Widget _buildConflictCard(HermesThemeColors colors) => Container(
    key: const ValueKey('profile-editor-pet-image-conflict'),
    margin: const EdgeInsets.only(top: HermesSpace.x3),
    padding: const EdgeInsets.all(HermesSpace.x3),
    decoration: BoxDecoration(
      color: colors.warning.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(HermesRadius.control),
      border: Border.all(color: colors.warning.withValues(alpha: 0.5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _strings.i18n131ProfileASavedImageAlsoExistsThePet,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: HermesType.supportSize,
          ),
        ),
        const SizedBox(height: 4),
        TextButton(
          key: const ValueKey('profile-editor-use-image'),
          onPressed: _remoteAvatar == null
              ? null
              : () => _changeIdentity(() {
                  _mode = _IdentityMode.image;
                  _panelOverride = _IdentityPanel.image;
                }),
          child: Text(_strings.i18n131ProfileUseImage),
        ),
      ],
    ),
  );

  Widget _spriteTile(ProfilePetGalleryEntry pet, HermesThemeColors colors) {
    final selected = _selectedSlug == pet.slug;
    return Semantics(
      selected: selected,
      button: true,
      label: pet.displayName,
      child: InkWell(
        key: ValueKey('profile-editor-sprite-${pet.slug}'),
        borderRadius: BorderRadius.circular(HermesRadius.control),
        onTap: () => _changeIdentity(() {
          _mode = _IdentityMode.pet;
          _panelOverride = _IdentityPanel.pet;
          _selectedSlug = pet.slug;
        }),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(HermesRadius.control),
                border: Border.all(
                  color: selected ? colors.accent : colors.divider,
                  width: selected ? 1.8 : 1,
                ),
              ),
              child: FutureBuilder<String?>(
                future: _thumbFuture(pet),
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

  Widget _buildFixedSave(MissionControlCopy copy, HermesThemeColors colors) =>
      Material(
        key: const ValueKey('profile-editor-fixed-save'),
        color: colors.background,
        child: SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(
              HermesSpace.x5,
              9,
              HermesSpace.x5,
              HermesSpace.x3,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _uncertain
                      ? _strings.i18n131ProfileUncertainStateReviewAndSaveAgain
                      : _dirty
                      ? _strings.i18n131ProfileUnsavedChanges
                      : _strings.i18n131ProfileNoPendingChanges,
                  key: ValueKey(
                    _uncertain
                        ? 'profile-editor-uncertain'
                        : _dirty
                        ? 'profile-editor-dirty'
                        : 'profile-editor-clean',
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _uncertain
                        ? colors.warning
                        : _dirty
                        ? colors.accent
                        : colors.textSecondary,
                    fontSize: HermesType.captionSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: HermesSpace.x1),
                    child: Text(
                      _error!,
                      key: const ValueKey('profile-editor-error'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.error,
                        fontSize: HermesType.captionSize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const SizedBox(height: 7),
                HermesPrimaryButton(
                  key: const ValueKey('profile-editor-save'),
                  label: _saving ? _strings.i18n131ProfileSaving : copy.save,
                  icon: _saving ? Icons.sync : Icons.check,
                  onTap: !_canEdit || !_dirty ? null : _save,
                ),
              ],
            ),
          ),
        ),
      );
}

bool _sameAvatar(AgentProfileAvatar left, AgentProfileAvatar right) {
  if (left.mimeType != right.mimeType ||
      left.bytes.length != right.bytes.length) {
    return false;
  }
  for (var index = 0; index < left.bytes.length; index++) {
    if (left.bytes[index] != right.bytes[index]) return false;
  }
  return true;
}
