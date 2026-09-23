import 'dart:async';
import '../../l10n/app_localizations.dart';
import '../services/bot_profile_client.dart';
import '../widgets/hermes_notice.dart';
import 'bot_profile_settings_screen.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/agent_profile.dart';
import '../models/bot_visual_identity.dart';
import '../models/profile_pet.dart';
import '../services/connection_manager.dart';
import '../services/bot_identity_mutation_service.dart';
import '../services/profile_pet_service.dart';
import '../services/profile_pet_visual_adapter.dart';
import '../services/profile_image_normalizer.dart';
import '../services/tui_gateway_client.dart';
import '../theme/app_theme.dart';
import '../companion/models/companion_animation_state.dart';
import '../companion/render/spritesheet_renderer.dart';
import '../widgets/bot_settings_group.dart';
import '../widgets/hermes_app_bar.dart';
import '../widgets/hermes_bot_face.dart';
import '../widgets/bot_face_options.dart';
import '../widgets/bot_avatar_generate_button.dart';
import '../widgets/hermes_ui.dart';
import 'mission_control_copy.dart';

typedef ProfileEditorImagePicker = Future<XFile?> Function();
typedef ProfileEditorImageNormalizer =
    Future<AgentProfileAvatar> Function(Uint8List bytes);

enum _IdentityMode { pet, image, face }

final class _ProfileEditorSaveFailure implements Exception {
  final bool uncertain;

  const _ProfileEditorSaveFailure({required this.uncertain});
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

  /// Abre la pantalla de skills de este bot desde la fila "Skills" de
  /// "Personalizar". `null` la deja como fila informativa sin navegación
  /// (p. ej. en tests que no ejercitan esta ruta).
  final VoidCallback? onOpenSkills;

  const ProfileEditorScreen({
    required this.connection,
    required this.profile,
    this.gateway,
    this.petService,
    this.imagePicker,
    this.imageNormalizer,
    this.petVisualMaterializer,
    this.onOpenSkills,
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
  late final TextEditingController _searchCtrl;
  late final String _initialTitle;

  late _IdentityMode _mode;
  late String _dormantColorHex;
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
      _IdentityMode.face => _classic == null ? 'face:${_blobatar.wire}' : 'classic:${_classic!.shape}:${_classic!.colorHex}',
    };
  }

  late String _baselineIdentitySignature;

  bool get _identityDirty =>
      _identityTouched && _identitySignature != _baselineIdentitySignature;
  bool get _dirty => _titleDirty || _identityDirty;

  bool get _spanish =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'es';
  String _text(String es, String en) => _spanish ? es : en;

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
    _searchCtrl = TextEditingController();

    final blobatar = BlobatarShapeWire.tryParse(widget.profile.botShape);
    _blobatar = blobatar ?? BlobatarShapeWire.parse('blobatar');
    if (ClassicFaceIdentity.shapes.contains(widget.profile.botShape) &&
        ClassicFaceIdentity.colors.contains(widget.profile.botColorHex)) {
      _classic = ClassicFaceIdentity(shape: widget.profile.botShape!, colorHex: widget.profile.botColorHex!);
    }
    _needsLegacyFaceMigration = blobatar == null && _classic == null;
    _dormantColorHex =
        ClassicFaceIdentity.colors.contains(widget.profile.botColorHex)
        ? widget.profile.botColorHex!
        : '#8b5cf6';

    final startsAsImage =
        widget.profile.hasAvatar && widget.profile.botImageKind != 'shape';
    _mode = startsAsImage ? _IdentityMode.image : _IdentityMode.face;
    _baselineIdentitySignature =
        _needsLegacyFaceMigration && _mode == _IdentityMode.face
        ? 'face:legacy'
        : _identitySignature;

    _avatarFuture = _loadAvatar();
    _galleryFuture = _loadGallery();
  }

  void _onTitleChanged() {
    if (mounted) setState(() => _uncertain = false);
  }

  @override
  void dispose() {
    _titleCtrl
      ..removeListener(_onTitleChanged)
      ..dispose();
    _searchCtrl.dispose();
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
    final gallery = await _petService.gallery(profile: _profileName);
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

  void _changeIdentity(VoidCallback mutation) {
    setState(() {
      mutation();
      _identityTouched = true;
      _uncertain = false;
    });
  }

  void _selectMode(_IdentityMode mode) {
    if (mode == _IdentityMode.pet && _selectedSlug == null) {
      _selectedSlug =
          _baselinePetSlug ?? _resolvedGallery?.pets.firstOrNull?.slug;
    }
    _changeIdentity(() => _mode = mode);
  }

  Future<void> _pickImage() async {
    if (_pickingImage || _saving) return;
    setState(() => _pickingImage = true);
    final messenger = HermesNotice.of(context);
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
        _identityTouched = true;
        _uncertain = false;
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

  BotVisualIdentity _faceIdentity() => _classic ?? ProceduralFaceIdentity(
    shapeWire: _blobatar.wire,
    dormantColorHex: _dormantColorHex,
  );

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    final copy = MissionControlCopy.of(context);
    final messenger = HermesNotice.of(context);
    setState(() {
      _saving = true;
      _uncertain = false;
    });

    try {
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
            break;
          case BotIdentityMutationStatus.rolledBack:
            throw const _ProfileEditorSaveFailure(uncertain: false);
          case BotIdentityMutationStatus.uncertain:
            throw const _ProfileEditorSaveFailure(uncertain: true);
        }
      }

      if (identity == null && title != null) {
        await _gateway.saveProfileBotMeta(profile: _profileName, title: title);
      }
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(copy.botEditorSaved)),
        kind: HermesNoticeKind.success,
      );
      _allowPop = true;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _uncertain = switch (error) {
          final _ProfileEditorSaveFailure failure => failure.uncertain,
          FormatException() || ArgumentError() => false,
          _ => true,
        };
      });
      messenger.showSnackBar(
        SnackBar(content: Text(copy.botEditorSaveFailed)),
        kind: HermesNoticeKind.error,
      );
    }
  }

  ProfilePetGalleryEntry _galleryEntry(String slug) =>
      _resolvedGallery?.pets.firstWhere(
        (entry) => entry.slug == slug,
        orElse: () => ProfilePetGalleryEntry(slug: slug, displayName: slug),
      ) ??
      ProfilePetGalleryEntry(slug: slug, displayName: slug);

  Future<void> _confirmDiscard() async {
    if (_discardDialogOpen || _saving) return;
    _discardDialogOpen = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_text('¿Descartar cambios?', 'Discard changes?')),
        content: Text(
          _text(
            'La identidad del bot todavía no se ha guardado.',
            'The bot identity has not been saved yet.',
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('profile-editor-keep-editing'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_text('Seguir editando', 'Keep editing')),
          ),
          TextButton(
            key: const ValueKey('profile-editor-discard'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_text('Descartar', 'Discard')),
          ),
        ],
      ),
    );
    _discardDialogOpen = false;
    if (discard == true && mounted) {
      setState(() => _allowPop = true);
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final copy = MissionControlCopy.of(context);
    return PopScope(
      canPop: _allowPop || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmDiscard());
      },
      child: Scaffold(
        appBar: HermesAppBar(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(copy.editBotTitle),
              Text(
                '@$_profileName',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          actions: [
            if (_dirty)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: colors.warning.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _text('Sin guardar', 'Unsaved'),
                    style: TextStyle(
                      color: colors.warning,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                key: const ValueKey('profile-editor-scroll'),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                children: [
                  Center(child: _buildPreview()),
                  const SizedBox(height: 18),
                  HermesField(
                    label: copy.botDisplayName,
                    controller: _titleCtrl,
                    hint: copy.botDisplayNameHint,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 4),
                    child: Text(
                      _text(
                        'El identificador @$_profileName no cambia',
                        'The @$_profileName identifier does not change',
                      ),
                      style: TextStyle(
                        color: colors.textDisabled,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    _text('Personalizar', 'Customize'),
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  BotSettingsGroup(
                    children: [
                      BotSettingsRow(
                        rowKey: const ValueKey('profile-editor-identity-row'),
                        label: _text('Identidad visual', 'Visual identity'),
                        summary: switch (_mode) {
                          _IdentityMode.pet => _text('Mascota', 'Pet'),
                          _IdentityMode.image => _text('Imagen', 'Image'),
                          _IdentityMode.face => _text('Cara', 'Face'),
                        },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _identitySelector(colors),
                            const SizedBox(height: 8),
                            switch (_mode) {
                              _IdentityMode.pet => _buildPetSection(
                                copy,
                                colors,
                              ),
                              _IdentityMode.image => _buildImageSection(colors),
                              _IdentityMode.face => _buildFaceSection(colors),
                            },
                          ],
                        ),
                      ),
                      if (_gateway is BotProfileGateway)
                        ListTile(contentPadding: EdgeInsets.zero,
                          title: Text(Strings.of(context).botAdvanced),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _saving ? null : () => Navigator.of(context).push<bool>(
                            MaterialPageRoute(builder: (_) => BotProfileSettingsScreen(
                              profile: _profileName, gateway: _gateway as BotProfileGateway)))),
                      _infoRow(
                        colors,
                        label: _text('Descripción', 'Description'),
                        value: widget.profile.description.trim().isEmpty
                            ? _text('Sin descripción', 'No description')
                            : widget.profile.description,
                      ),
                      _infoRow(
                        colors,
                        label: copy.modelLabel,
                        value: widget.profile.model.trim().isEmpty
                            ? _text('Automático', 'Automatic')
                            : widget.profile.model,
                      ),
                      _navRow(
                        colors,
                        key: const ValueKey('profile-editor-skills-row'),
                        label: copy.skills,
                        value: _text('Ver skills', 'View skills'),
                        onTap: widget.onOpenSkills,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _buildFixedSave(copy, colors),
          ],
        ),
      ),
    );
  }

  /// Fila de solo lectura dentro de "Personalizar": muestra datos del bot
  /// que hoy no se pueden editar desde esta pantalla (no hay escritura de
  /// `description`/`model` en el gateway de perfiles), sin fingir un control
  /// interactivo que no lleva a ningún sitio.
  Widget _infoRow(
    HermesThemeColors colors, {
    required String label,
    required String value,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.textSecondary, fontSize: 13.5),
          ),
        ),
      ],
    ),
  );

  /// Fila de navegación dentro de "Personalizar" hacia una pantalla ya
  /// existente (p. ej. Skills). Sin `onTap` se degrada a informativa: nunca
  /// muestra una flecha que no lleve a ningún sitio.
  Widget _navRow(
    HermesThemeColors colors, {
    required Key key,
    required String label,
    required String value,
    required VoidCallback? onTap,
  }) => Material(
    color: Colors.transparent,
    child: InkWell(
      key: key,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textSecondary, fontSize: 13.5),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colors.textSecondary,
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _identitySelector(HermesThemeColors colors) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      _modeTile(
        key: const ValueKey('profile-editor-mode-pet'),
        label: _text('Mascota', 'Pet'),
        icon: Icons.pets_outlined,
        selected: _mode == _IdentityMode.pet,
        onTap: () => _selectMode(_IdentityMode.pet),
        colors: colors,
      ),
      _modeTile(
        key: const ValueKey('profile-editor-mode-image'),
        label: _text('Imagen', 'Image'),
        icon: Icons.image_outlined,
        selected: _mode == _IdentityMode.image,
        onTap: () => _selectMode(_IdentityMode.image),
        colors: colors,
      ),
      _modeTile(
        key: const ValueKey('profile-editor-mode-face'),
        label: _text('Cara', 'Face'),
        icon: Icons.face_outlined,
        selected: _mode == _IdentityMode.face,
        onTap: () => _selectMode(_IdentityMode.face),
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
      onTap: onTap,
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
            width: 1,
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

  Widget _buildPreview() {
    final accent = Theme.of(context).hermes.accent;
    return Container(
      key: const ValueKey('profile-editor-preview'),
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
      child: switch (_mode) {
        _IdentityMode.pet => _petPreview(),
        _IdentityMode.image => _imagePreview(),
        _IdentityMode.face => _facePreview(size: 96),
      },
    );
  }

  Widget _petPreview() {
    final slug = _selectedSlug;
    if (slug == null) {
      return Icon(
        Icons.pets_outlined,
        size: 42,
        color: Theme.of(context).hermes.textDisabled,
      );
    }
    final entry = _galleryEntry(slug);
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
              size: 96,
            );
          }
          return _petThumbPreview(entry);
        },
      );
    }
    return _petThumbPreview(entry);
  }

  Widget _petThumbPreview(ProfilePetGalleryEntry entry) {
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
          key: const ValueKey('profile-editor-pet-static-preview'),
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
    final picked = _pickedAvatar;
    if (picked != null) return _avatarImage(picked);
    return FutureBuilder<AgentProfileAvatar?>(
      future: _avatarFuture,
      builder: (context, snapshot) {
        final avatar = snapshot.data;
        if (avatar != null) return _avatarImage(avatar);
        return Icon(
          Icons.add_photo_alternate_outlined,
          size: 42,
          color: Theme.of(context).hermes.textDisabled,
        );
      },
    );
  }

  Widget _avatarImage(AgentProfileAvatar avatar) => ClipRRect(
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

  Widget _facePreview({required double size}) {
    final visual = _classic != null ? HermesClassicFaceVisual.tryParse(
      shape: _classic!.shape, colorHex: _classic!.colorHex)! : HermesBlobatarFaceVisual.tryParse(
      shapeWire: _blobatar.wire,
      profileName: _profileName,
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
      if (_gateway is BotAvatarGenerationGateway)
        BotAvatarGenerateButton(gateway: _gateway as BotAvatarGenerationGateway,
          enabled: !_saving, onSelected: (avatar) => _changeIdentity(() {
            _pickedAvatar = avatar;
            _pickedAvatarDataUri = avatar.toDataUri();
          })),
      Text(
        _text(
          'PNG, JPEG, WebP o GIF. Se recorta al centro y se guarda cuadrada.',
          'PNG, JPEG, WebP, or GIF. Center-cropped and saved square.',
        ),
        style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const ValueKey('profile-editor-pick-image'),
        onPressed: _pickingImage || _saving ? null : _pickImage,
        icon: Icon(_pickingImage ? Icons.hourglass_top : Icons.photo_library),
        label: Text(
          _pickedAvatar == null && _remoteAvatar == null
              ? _text('Elegir imagen', 'Choose image')
              : _text('Cambiar imagen', 'Change image'),
        ),
      ),
    ],
  );

  Widget _buildFaceSection(HermesThemeColors colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      BotFaceOptions(name: _profileName, blob: _blobatar,
        classic: _classic, enabled: !_saving,
        onBlob: (value) => _changeIdentity(() { _classic = null; _blobatar = value; }),
        onClassic: (value) => _changeIdentity(() => _classic = value)),
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
      profileName: _profileName,
    )!;
    return Tooltip(
      message: kind ?? _text('Automática', 'Automatic'),
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          key: ValueKey('profile-editor-blobatar-${kind ?? 'auto'}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => _changeIdentity(() {
            _classic = null;
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
        key: const ValueKey('profile-editor-sprite-gallery'),
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
          final query = _query.trim().toLowerCase();
          final filtered =
              gallery.pets.where((pet) {
                if (query.isEmpty) return true;
                return pet.displayName.toLowerCase().contains(query) ||
                    pet.slug.toLowerCase().contains(query);
              }).toList()..sort(
                (a, b) => (b.installed ? 1 : 0).compareTo(a.installed ? 1 : 0),
              );
          final visible = filtered.take(_maxVisiblePets).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                copy.botSpriteHint,
                style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
              ),
              if (_petPhotoConflict) _buildConflictCard(colors),
              const SizedBox(height: 10),
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
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    copy.botSpriteEmpty,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.textSecondary),
                  ),
                )
              else
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
            ],
          );
        },
      );

  Widget _buildConflictCard(HermesThemeColors colors) => Container(
    key: const ValueKey('profile-editor-pet-image-conflict'),
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: colors.warning.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: colors.warning.withValues(alpha: 0.5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _text(
            'También hay una imagen guardada. La mascota tiene prioridad.',
            'A saved image also exists. The pet takes priority.',
          ),
          style: TextStyle(color: colors.textPrimary, fontSize: 12.5),
        ),
        const SizedBox(height: 4),
        TextButton(
          key: const ValueKey('profile-editor-use-image'),
          onPressed: _remoteAvatar == null
              ? null
              : () => _changeIdentity(() => _mode = _IdentityMode.image),
          child: Text(_text('Usar imagen', 'Use image')),
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
        borderRadius: BorderRadius.circular(12),
        onTap: () => _changeIdentity(() {
          _mode = _IdentityMode.pet;
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
                borderRadius: BorderRadius.circular(12),
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

  Widget _buildFixedSave(MissionControlCopy copy, HermesThemeColors colors) =>
      Material(
        key: const ValueKey('profile-editor-fixed-save'),
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
                          'Estado incierto: revisa y vuelve a guardar.',
                          'Uncertain state: review and save again.',
                        )
                      : _dirty
                      ? _text('Cambios sin guardar', 'Unsaved changes')
                      : _text('Sin cambios pendientes', 'No pending changes'),
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
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
                HermesPrimaryButton(
                  key: const ValueKey('profile-editor-save'),
                  label: _saving ? _text('Guardando…', 'Saving…') : copy.save,
                  icon: _saving ? Icons.sync : Icons.check,
                  onTap: _saving || !_dirty ? null : _save,
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
