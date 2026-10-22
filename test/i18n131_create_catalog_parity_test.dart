import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const keys = <String>{
    'i18n131CreateUseAPngJpegWebpOrGif',
    'i18n131CreateTheProfileExistsButItsIdentityIs',
    'i18n131CreateTheProfileExistsButItsIdentityCould',
    'i18n131CreateChooseAValidIdentityBeforeCreatingThe',
    'i18n131CreateDiscardChanges',
    'i18n131CreateTheProfileAlreadyExistsButItsVisual',
    'i18n131CreateYouWillLoseThisProfileSetup',
    'i18n131CreateKeepEditing',
    'i18n131CreateDiscard',
    'i18n131CreateCustomize',
    'i18n131CreateOptional',
    'i18n131CreateVisualIdentity',
    'i18n131CreatePet',
    'i18n131CreateImage',
    'i18n131CreateFace',
    'i18n131CreateTitleAndDescription',
    'i18n131CreateNotFilledIn',
    'i18n131CreateSoulCloneFrom',
    'i18n131CreateProfileFace',
    'i18n131CreatePngJpegWebpOrGifCenterCropped',
    'i18n131CreateChooseImage',
    'i18n131CreateChangeImage',
    'i18n131CreateUncertainStateReviewAndTryAgain',
    'i18n131CreateProfileCreatedIdentityConfirmationPending',
    'i18n131CreateCreating',
    'i18n131CreateRetryIdentity'
  };
  Map<String, int> arguments(String value) {
    final result = <String, int>{};
    for (final match in RegExp(r'\{[A-Za-z][A-Za-z0-9_]*\}').allMatches(value)) {
      result.update(match.group(0)!, (n) => n + 1, ifAbsent: () => 1);
    }
    return result;
  }
  final catalogs = <String, Map<String, dynamic>>{
    for (final lang in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh'])
      lang: jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
          as Map<String, dynamic>,
  };
  test('exact class keys and placeholder multiplicity in all nine locales', () {
    for (final catalog in catalogs.values) {
      expect(catalog.keys.where((key) => key.startsWith('i18n131Create')), unorderedEquals(keys));
      for (final key in keys) {
        expect((catalog[key] as String).trim(), isNotEmpty, reason: key);
        expect(arguments(catalog[key] as String), arguments(catalogs['en']![key] as String), reason: key);
      }
    }
  });
  test('generated accessors preserve literal and parameterized copy', () {
    expect(lookupStrings(const Locale('es')).i18n131CreateUseAPngJpegWebpOrGif, "Usa una imagen PNG, JPEG, WebP o GIF de hasta 15 MB.");
    expect(lookupStrings(const Locale('en')).i18n131CreateUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateUseAPngJpegWebpOrGif, "Use uma imagem PNG, JPEG, WebP ou GIF de até 15 MB.");
    expect(lookupStrings(const Locale('de')).i18n131CreateUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('it')).i18n131CreateUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('ko')).i18n131CreateUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('es')).i18n131CreateTheProfileExistsButItsIdentityIs, "El perfil existe, pero no sabemos si su identidad se guardó. Revísala y vuelve a intentarlo.");
    expect(lookupStrings(const Locale('en')).i18n131CreateTheProfileExistsButItsIdentityIs, "The profile exists, but its identity is uncertain. Review it and try again.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateTheProfileExistsButItsIdentityIs, "O perfil existe, mas não sabemos se a identidade foi salva. Revise-a e tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131CreateTheProfileExistsButItsIdentityIs, "The profile exists, but its identity is uncertain. Review it and try again.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateTheProfileExistsButItsIdentityIs, "The profile exists, but its identity is uncertain. Review it and try again.");
    expect(lookupStrings(const Locale('it')).i18n131CreateTheProfileExistsButItsIdentityIs, "The profile exists, but its identity is uncertain. Review it and try again.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateTheProfileExistsButItsIdentityIs, "The profile exists, but its identity is uncertain. Review it and try again.");
    expect(lookupStrings(const Locale('ko')).i18n131CreateTheProfileExistsButItsIdentityIs, "The profile exists, but its identity is uncertain. Review it and try again.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateTheProfileExistsButItsIdentityIs, "The profile exists, but its identity is uncertain. Review it and try again.");
    expect(lookupStrings(const Locale('es')).i18n131CreateTheProfileExistsButItsIdentityCould, "El perfil existe, pero no se pudo aplicar su identidad. Corrige el problema y vuelve a intentarlo.");
    expect(lookupStrings(const Locale('en')).i18n131CreateTheProfileExistsButItsIdentityCould, "The profile exists, but its identity could not be applied. Fix the issue and try again.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateTheProfileExistsButItsIdentityCould, "O perfil existe, mas não foi possível aplicar a identidade. Corrija o problema e tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131CreateTheProfileExistsButItsIdentityCould, "The profile exists, but its identity could not be applied. Fix the issue and try again.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateTheProfileExistsButItsIdentityCould, "The profile exists, but its identity could not be applied. Fix the issue and try again.");
    expect(lookupStrings(const Locale('it')).i18n131CreateTheProfileExistsButItsIdentityCould, "The profile exists, but its identity could not be applied. Fix the issue and try again.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateTheProfileExistsButItsIdentityCould, "The profile exists, but its identity could not be applied. Fix the issue and try again.");
    expect(lookupStrings(const Locale('ko')).i18n131CreateTheProfileExistsButItsIdentityCould, "The profile exists, but its identity could not be applied. Fix the issue and try again.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateTheProfileExistsButItsIdentityCould, "The profile exists, but its identity could not be applied. Fix the issue and try again.");
    expect(lookupStrings(const Locale('es')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Elige una identidad válida antes de crear el perfil.");
    expect(lookupStrings(const Locale('en')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Choose a valid identity before creating the profile.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Escolha uma identidade válida antes de criar o perfil.");
    expect(lookupStrings(const Locale('de')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Choose a valid identity before creating the profile.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Choose a valid identity before creating the profile.");
    expect(lookupStrings(const Locale('it')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Choose a valid identity before creating the profile.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Choose a valid identity before creating the profile.");
    expect(lookupStrings(const Locale('ko')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Choose a valid identity before creating the profile.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Choose a valid identity before creating the profile.");
    expect(lookupStrings(const Locale('es')).i18n131CreateDiscardChanges, "¿Descartar cambios?");
    expect(lookupStrings(const Locale('en')).i18n131CreateDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('pt')).i18n131CreateDiscardChanges, "Descartar alterações?");
    expect(lookupStrings(const Locale('de')).i18n131CreateDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('fr')).i18n131CreateDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('it')).i18n131CreateDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('ja')).i18n131CreateDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('ko')).i18n131CreateDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('zh')).i18n131CreateDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('es')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "El perfil ya existe, pero su configuración visual no terminó. Si sales, no se abrirá su chat automático.");
    expect(lookupStrings(const Locale('en')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "The profile already exists, but its visual setup is incomplete. Leaving will not open its automatic chat.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "O perfil já existe, mas a configuração visual não terminou. Se você sair, o chat automático não será aberto.");
    expect(lookupStrings(const Locale('de')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "The profile already exists, but its visual setup is incomplete. Leaving will not open its automatic chat.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "The profile already exists, but its visual setup is incomplete. Leaving will not open its automatic chat.");
    expect(lookupStrings(const Locale('it')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "The profile already exists, but its visual setup is incomplete. Leaving will not open its automatic chat.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "The profile already exists, but its visual setup is incomplete. Leaving will not open its automatic chat.");
    expect(lookupStrings(const Locale('ko')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "The profile already exists, but its visual setup is incomplete. Leaving will not open its automatic chat.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "The profile already exists, but its visual setup is incomplete. Leaving will not open its automatic chat.");
    expect(lookupStrings(const Locale('es')).i18n131CreateYouWillLoseThisProfileSetup, "Perderás la configuración de este perfil.");
    expect(lookupStrings(const Locale('en')).i18n131CreateYouWillLoseThisProfileSetup, "You will lose this profile setup.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateYouWillLoseThisProfileSetup, "Você perderá a configuração deste perfil.");
    expect(lookupStrings(const Locale('de')).i18n131CreateYouWillLoseThisProfileSetup, "You will lose this profile setup.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateYouWillLoseThisProfileSetup, "You will lose this profile setup.");
    expect(lookupStrings(const Locale('it')).i18n131CreateYouWillLoseThisProfileSetup, "You will lose this profile setup.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateYouWillLoseThisProfileSetup, "You will lose this profile setup.");
    expect(lookupStrings(const Locale('ko')).i18n131CreateYouWillLoseThisProfileSetup, "You will lose this profile setup.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateYouWillLoseThisProfileSetup, "You will lose this profile setup.");
    expect(lookupStrings(const Locale('es')).i18n131CreateKeepEditing, "Seguir editando");
    expect(lookupStrings(const Locale('en')).i18n131CreateKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('pt')).i18n131CreateKeepEditing, "Continuar editando");
    expect(lookupStrings(const Locale('de')).i18n131CreateKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('fr')).i18n131CreateKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('it')).i18n131CreateKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('ja')).i18n131CreateKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('ko')).i18n131CreateKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('zh')).i18n131CreateKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('es')).i18n131CreateDiscard, "Descartar");
    expect(lookupStrings(const Locale('en')).i18n131CreateDiscard, "Discard");
    expect(lookupStrings(const Locale('pt')).i18n131CreateDiscard, "Descartar");
    expect(lookupStrings(const Locale('de')).i18n131CreateDiscard, "Discard");
    expect(lookupStrings(const Locale('fr')).i18n131CreateDiscard, "Discard");
    expect(lookupStrings(const Locale('it')).i18n131CreateDiscard, "Discard");
    expect(lookupStrings(const Locale('ja')).i18n131CreateDiscard, "Discard");
    expect(lookupStrings(const Locale('ko')).i18n131CreateDiscard, "Discard");
    expect(lookupStrings(const Locale('zh')).i18n131CreateDiscard, "Discard");
    expect(lookupStrings(const Locale('es')).i18n131CreateCustomize, "Personalizar");
    expect(lookupStrings(const Locale('en')).i18n131CreateCustomize, "Customize");
    expect(lookupStrings(const Locale('pt')).i18n131CreateCustomize, "Personalizar");
    expect(lookupStrings(const Locale('de')).i18n131CreateCustomize, "Customize");
    expect(lookupStrings(const Locale('fr')).i18n131CreateCustomize, "Customize");
    expect(lookupStrings(const Locale('it')).i18n131CreateCustomize, "Customize");
    expect(lookupStrings(const Locale('ja')).i18n131CreateCustomize, "Customize");
    expect(lookupStrings(const Locale('ko')).i18n131CreateCustomize, "Customize");
    expect(lookupStrings(const Locale('zh')).i18n131CreateCustomize, "Customize");
    expect(lookupStrings(const Locale('es')).i18n131CreateOptional, "opcional");
    expect(lookupStrings(const Locale('en')).i18n131CreateOptional, "optional");
    expect(lookupStrings(const Locale('pt')).i18n131CreateOptional, "opcional");
    expect(lookupStrings(const Locale('de')).i18n131CreateOptional, "optional");
    expect(lookupStrings(const Locale('fr')).i18n131CreateOptional, "optional");
    expect(lookupStrings(const Locale('it')).i18n131CreateOptional, "optional");
    expect(lookupStrings(const Locale('ja')).i18n131CreateOptional, "optional");
    expect(lookupStrings(const Locale('ko')).i18n131CreateOptional, "optional");
    expect(lookupStrings(const Locale('zh')).i18n131CreateOptional, "optional");
    expect(lookupStrings(const Locale('es')).i18n131CreateVisualIdentity, "Identidad visual");
    expect(lookupStrings(const Locale('en')).i18n131CreateVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('pt')).i18n131CreateVisualIdentity, "Identidade visual");
    expect(lookupStrings(const Locale('de')).i18n131CreateVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('fr')).i18n131CreateVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('it')).i18n131CreateVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('ja')).i18n131CreateVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('ko')).i18n131CreateVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('zh')).i18n131CreateVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('es')).i18n131CreatePet, "Mascota");
    expect(lookupStrings(const Locale('en')).i18n131CreatePet, "Pet");
    expect(lookupStrings(const Locale('pt')).i18n131CreatePet, "Mascote");
    expect(lookupStrings(const Locale('de')).i18n131CreatePet, "Pet");
    expect(lookupStrings(const Locale('fr')).i18n131CreatePet, "Pet");
    expect(lookupStrings(const Locale('it')).i18n131CreatePet, "Pet");
    expect(lookupStrings(const Locale('ja')).i18n131CreatePet, "Pet");
    expect(lookupStrings(const Locale('ko')).i18n131CreatePet, "Pet");
    expect(lookupStrings(const Locale('zh')).i18n131CreatePet, "Pet");
    expect(lookupStrings(const Locale('es')).i18n131CreateImage, "Imagen");
    expect(lookupStrings(const Locale('en')).i18n131CreateImage, "Image");
    expect(lookupStrings(const Locale('pt')).i18n131CreateImage, "Imagem");
    expect(lookupStrings(const Locale('de')).i18n131CreateImage, "Image");
    expect(lookupStrings(const Locale('fr')).i18n131CreateImage, "Image");
    expect(lookupStrings(const Locale('it')).i18n131CreateImage, "Image");
    expect(lookupStrings(const Locale('ja')).i18n131CreateImage, "Image");
    expect(lookupStrings(const Locale('ko')).i18n131CreateImage, "Image");
    expect(lookupStrings(const Locale('zh')).i18n131CreateImage, "Image");
    expect(lookupStrings(const Locale('es')).i18n131CreateFace, "Cara");
    expect(lookupStrings(const Locale('en')).i18n131CreateFace, "Face");
    expect(lookupStrings(const Locale('pt')).i18n131CreateFace, "Rosto");
    expect(lookupStrings(const Locale('de')).i18n131CreateFace, "Face");
    expect(lookupStrings(const Locale('fr')).i18n131CreateFace, "Face");
    expect(lookupStrings(const Locale('it')).i18n131CreateFace, "Face");
    expect(lookupStrings(const Locale('ja')).i18n131CreateFace, "Face");
    expect(lookupStrings(const Locale('ko')).i18n131CreateFace, "Face");
    expect(lookupStrings(const Locale('zh')).i18n131CreateFace, "Face");
    expect(lookupStrings(const Locale('es')).i18n131CreateTitleAndDescription, "Título y descripción");
    expect(lookupStrings(const Locale('en')).i18n131CreateTitleAndDescription, "Title and description");
    expect(lookupStrings(const Locale('pt')).i18n131CreateTitleAndDescription, "Título e descrição");
    expect(lookupStrings(const Locale('de')).i18n131CreateTitleAndDescription, "Title and description");
    expect(lookupStrings(const Locale('fr')).i18n131CreateTitleAndDescription, "Title and description");
    expect(lookupStrings(const Locale('it')).i18n131CreateTitleAndDescription, "Title and description");
    expect(lookupStrings(const Locale('ja')).i18n131CreateTitleAndDescription, "Title and description");
    expect(lookupStrings(const Locale('ko')).i18n131CreateTitleAndDescription, "Title and description");
    expect(lookupStrings(const Locale('zh')).i18n131CreateTitleAndDescription, "Title and description");
    expect(lookupStrings(const Locale('es')).i18n131CreateNotFilledIn, "Sin rellenar");
    expect(lookupStrings(const Locale('en')).i18n131CreateNotFilledIn, "Not filled in");
    expect(lookupStrings(const Locale('pt')).i18n131CreateNotFilledIn, "Não preenchido");
    expect(lookupStrings(const Locale('de')).i18n131CreateNotFilledIn, "Not filled in");
    expect(lookupStrings(const Locale('fr')).i18n131CreateNotFilledIn, "Not filled in");
    expect(lookupStrings(const Locale('it')).i18n131CreateNotFilledIn, "Not filled in");
    expect(lookupStrings(const Locale('ja')).i18n131CreateNotFilledIn, "Not filled in");
    expect(lookupStrings(const Locale('ko')).i18n131CreateNotFilledIn, "Not filled in");
    expect(lookupStrings(const Locale('zh')).i18n131CreateNotFilledIn, "Not filled in");
    expect(lookupStrings(const Locale('es')).i18n131CreateSoulCloneFrom, "Soul · Clonar de");
    expect(lookupStrings(const Locale('en')).i18n131CreateSoulCloneFrom, "Soul · Clone from");
    expect(lookupStrings(const Locale('pt')).i18n131CreateSoulCloneFrom, "Soul · Clonar de");
    expect(lookupStrings(const Locale('de')).i18n131CreateSoulCloneFrom, "Soul · Clone from");
    expect(lookupStrings(const Locale('fr')).i18n131CreateSoulCloneFrom, "Soul · Clone from");
    expect(lookupStrings(const Locale('it')).i18n131CreateSoulCloneFrom, "Soul · Clone from");
    expect(lookupStrings(const Locale('ja')).i18n131CreateSoulCloneFrom, "Soul · Clone from");
    expect(lookupStrings(const Locale('ko')).i18n131CreateSoulCloneFrom, "Soul · Clone from");
    expect(lookupStrings(const Locale('zh')).i18n131CreateSoulCloneFrom, "Soul · Clone from");
    expect(lookupStrings(const Locale('es')).i18n131CreateProfileFace, "Cara del perfil");
    expect(lookupStrings(const Locale('en')).i18n131CreateProfileFace, "Profile face");
    expect(lookupStrings(const Locale('pt')).i18n131CreateProfileFace, "Rosto do perfil");
    expect(lookupStrings(const Locale('de')).i18n131CreateProfileFace, "Profile face");
    expect(lookupStrings(const Locale('fr')).i18n131CreateProfileFace, "Profile face");
    expect(lookupStrings(const Locale('it')).i18n131CreateProfileFace, "Profile face");
    expect(lookupStrings(const Locale('ja')).i18n131CreateProfileFace, "Profile face");
    expect(lookupStrings(const Locale('ko')).i18n131CreateProfileFace, "Profile face");
    expect(lookupStrings(const Locale('zh')).i18n131CreateProfileFace, "Profile face");
    expect(lookupStrings(const Locale('es')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP o GIF. Se recorta al centro y se guarda cuadrada.");
    expect(lookupStrings(const Locale('en')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('pt')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP ou GIF. Recortada no centro e salva quadrada.");
    expect(lookupStrings(const Locale('de')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('fr')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('it')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('ja')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('ko')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('zh')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('es')).i18n131CreateChooseImage, "Elegir imagen");
    expect(lookupStrings(const Locale('en')).i18n131CreateChooseImage, "Choose image");
    expect(lookupStrings(const Locale('pt')).i18n131CreateChooseImage, "Escolher imagem");
    expect(lookupStrings(const Locale('de')).i18n131CreateChooseImage, "Choose image");
    expect(lookupStrings(const Locale('fr')).i18n131CreateChooseImage, "Choose image");
    expect(lookupStrings(const Locale('it')).i18n131CreateChooseImage, "Choose image");
    expect(lookupStrings(const Locale('ja')).i18n131CreateChooseImage, "Choose image");
    expect(lookupStrings(const Locale('ko')).i18n131CreateChooseImage, "Choose image");
    expect(lookupStrings(const Locale('zh')).i18n131CreateChooseImage, "Choose image");
    expect(lookupStrings(const Locale('es')).i18n131CreateChangeImage, "Cambiar imagen");
    expect(lookupStrings(const Locale('en')).i18n131CreateChangeImage, "Change image");
    expect(lookupStrings(const Locale('pt')).i18n131CreateChangeImage, "Alterar imagem");
    expect(lookupStrings(const Locale('de')).i18n131CreateChangeImage, "Change image");
    expect(lookupStrings(const Locale('fr')).i18n131CreateChangeImage, "Change image");
    expect(lookupStrings(const Locale('it')).i18n131CreateChangeImage, "Change image");
    expect(lookupStrings(const Locale('ja')).i18n131CreateChangeImage, "Change image");
    expect(lookupStrings(const Locale('ko')).i18n131CreateChangeImage, "Change image");
    expect(lookupStrings(const Locale('zh')).i18n131CreateChangeImage, "Change image");
    expect(lookupStrings(const Locale('es')).i18n131CreateUncertainStateReviewAndTryAgain, "Estado incierto: revisa y vuelve a intentar.");
    expect(lookupStrings(const Locale('en')).i18n131CreateUncertainStateReviewAndTryAgain, "Uncertain state: review and try again.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateUncertainStateReviewAndTryAgain, "Estado incerto: revise e tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131CreateUncertainStateReviewAndTryAgain, "Uncertain state: review and try again.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateUncertainStateReviewAndTryAgain, "Uncertain state: review and try again.");
    expect(lookupStrings(const Locale('it')).i18n131CreateUncertainStateReviewAndTryAgain, "Uncertain state: review and try again.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateUncertainStateReviewAndTryAgain, "Uncertain state: review and try again.");
    expect(lookupStrings(const Locale('ko')).i18n131CreateUncertainStateReviewAndTryAgain, "Uncertain state: review and try again.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateUncertainStateReviewAndTryAgain, "Uncertain state: review and try again.");
    expect(lookupStrings(const Locale('es')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Perfil creado · falta confirmar la identidad");
    expect(lookupStrings(const Locale('en')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Profile created · identity confirmation pending");
    expect(lookupStrings(const Locale('pt')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Perfil criado · falta confirmar a identidade");
    expect(lookupStrings(const Locale('de')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Profile created · identity confirmation pending");
    expect(lookupStrings(const Locale('fr')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Profile created · identity confirmation pending");
    expect(lookupStrings(const Locale('it')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Profile created · identity confirmation pending");
    expect(lookupStrings(const Locale('ja')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Profile created · identity confirmation pending");
    expect(lookupStrings(const Locale('ko')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Profile created · identity confirmation pending");
    expect(lookupStrings(const Locale('zh')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Profile created · identity confirmation pending");
    expect(lookupStrings(const Locale('es')).i18n131CreateCreating, "Creando…");
    expect(lookupStrings(const Locale('en')).i18n131CreateCreating, "Creating…");
    expect(lookupStrings(const Locale('pt')).i18n131CreateCreating, "Criando…");
    expect(lookupStrings(const Locale('de')).i18n131CreateCreating, "Creating…");
    expect(lookupStrings(const Locale('fr')).i18n131CreateCreating, "Creating…");
    expect(lookupStrings(const Locale('it')).i18n131CreateCreating, "Creating…");
    expect(lookupStrings(const Locale('ja')).i18n131CreateCreating, "Creating…");
    expect(lookupStrings(const Locale('ko')).i18n131CreateCreating, "Creating…");
    expect(lookupStrings(const Locale('zh')).i18n131CreateCreating, "Creating…");
    expect(lookupStrings(const Locale('es')).i18n131CreateRetryIdentity, "Reintentar identidad");
    expect(lookupStrings(const Locale('en')).i18n131CreateRetryIdentity, "Retry identity");
    expect(lookupStrings(const Locale('pt')).i18n131CreateRetryIdentity, "Repetir identidade");
    expect(lookupStrings(const Locale('de')).i18n131CreateRetryIdentity, "Retry identity");
    expect(lookupStrings(const Locale('fr')).i18n131CreateRetryIdentity, "Retry identity");
    expect(lookupStrings(const Locale('it')).i18n131CreateRetryIdentity, "Retry identity");
    expect(lookupStrings(const Locale('ja')).i18n131CreateRetryIdentity, "Retry identity");
    expect(lookupStrings(const Locale('ko')).i18n131CreateRetryIdentity, "Retry identity");
    expect(lookupStrings(const Locale('zh')).i18n131CreateRetryIdentity, "Retry identity");
  });
}
