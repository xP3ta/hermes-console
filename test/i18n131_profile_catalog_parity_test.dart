import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const keys = <String>{
    'i18n131ProfileUseAPngJpegWebpOrGif',
    'i18n131ProfileDiscardChanges',
    'i18n131ProfileTheProfileIdentityHasNotBeenSaved',
    'i18n131ProfileKeepEditing',
    'i18n131ProfileDiscard',
    'i18n131ProfileUnsaved',
    'i18n131ProfileTheProfilenameIdentifierDoesNotChange',
    'i18n131ProfileCustomize',
    'i18n131ProfileVisualIdentity',
    'i18n131ProfilePet',
    'i18n131ProfileImage',
    'i18n131ProfileFace',
    'i18n131ProfileAutomatic',
    'i18n131ProfileDescription',
    'i18n131ProfileNoDescription',
    'i18n131ProfileViewSkills',
    'i18n131ProfileProfileFace',
    'i18n131ProfilePngJpegWebpOrGifCenterCropped',
    'i18n131ProfileChooseImage',
    'i18n131ProfileChangeImage',
    'i18n131ProfileASavedImageAlsoExistsThePet',
    'i18n131ProfileUseImage',
    'i18n131ProfileUncertainStateReviewAndSaveAgain',
    'i18n131ProfileUnsavedChanges',
    'i18n131ProfileNoPendingChanges',
    'i18n131ProfileSaving'
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
      expect(catalog.keys.where((key) => key.startsWith('i18n131Profile')), unorderedEquals(keys));
      for (final key in keys) {
        expect((catalog[key] as String).trim(), isNotEmpty, reason: key);
        expect(arguments(catalog[key] as String), arguments(catalogs['en']![key] as String), reason: key);
      }
    }
  });
  test('generated accessors preserve literal and parameterized copy', () {
    expect(lookupStrings(const Locale('es')).i18n131ProfileUseAPngJpegWebpOrGif, "Usa una imagen PNG, JPEG, WebP o GIF de hasta 15 MB.");
    expect(lookupStrings(const Locale('en')).i18n131ProfileUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileUseAPngJpegWebpOrGif, "Use uma imagem PNG, JPEG, WebP ou GIF de até 15 MB.");
    expect(lookupStrings(const Locale('de')).i18n131ProfileUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('it')).i18n131ProfileUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileUseAPngJpegWebpOrGif, "Use a PNG, JPEG, WebP, or GIF image up to 15 MB.");
    expect(lookupStrings(const Locale('es')).i18n131ProfileDiscardChanges, "¿Descartar cambios?");
    expect(lookupStrings(const Locale('en')).i18n131ProfileDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileDiscardChanges, "Descartar alterações?");
    expect(lookupStrings(const Locale('de')).i18n131ProfileDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('it')).i18n131ProfileDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('es')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "La identidad del perfil todavía no se ha guardado.");
    expect(lookupStrings(const Locale('en')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "The profile identity has not been saved yet.");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "A identidade do perfil ainda não foi salva.");
    expect(lookupStrings(const Locale('de')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "The profile identity has not been saved yet.");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "The profile identity has not been saved yet.");
    expect(lookupStrings(const Locale('it')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "The profile identity has not been saved yet.");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "The profile identity has not been saved yet.");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "The profile identity has not been saved yet.");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "The profile identity has not been saved yet.");
    expect(lookupStrings(const Locale('es')).i18n131ProfileKeepEditing, "Seguir editando");
    expect(lookupStrings(const Locale('en')).i18n131ProfileKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileKeepEditing, "Continuar editando");
    expect(lookupStrings(const Locale('de')).i18n131ProfileKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('it')).i18n131ProfileKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('es')).i18n131ProfileDiscard, "Descartar");
    expect(lookupStrings(const Locale('en')).i18n131ProfileDiscard, "Discard");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileDiscard, "Descartar");
    expect(lookupStrings(const Locale('de')).i18n131ProfileDiscard, "Discard");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileDiscard, "Discard");
    expect(lookupStrings(const Locale('it')).i18n131ProfileDiscard, "Discard");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileDiscard, "Discard");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileDiscard, "Discard");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileDiscard, "Discard");
    expect(lookupStrings(const Locale('es')).i18n131ProfileUnsaved, "Sin guardar");
    expect(lookupStrings(const Locale('en')).i18n131ProfileUnsaved, "Unsaved");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileUnsaved, "Não salvo");
    expect(lookupStrings(const Locale('de')).i18n131ProfileUnsaved, "Unsaved");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileUnsaved, "Unsaved");
    expect(lookupStrings(const Locale('it')).i18n131ProfileUnsaved, "Unsaved");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileUnsaved, "Unsaved");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileUnsaved, "Unsaved");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileUnsaved, "Unsaved");
    expect(lookupStrings(const Locale('es')).i18n131ProfileTheProfilenameIdentifierDoesNotChange, "El identificador @\$_profileName no cambia");
    expect(lookupStrings(const Locale('en')).i18n131ProfileTheProfilenameIdentifierDoesNotChange, "The @\$_profileName identifier does not change");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileTheProfilenameIdentifierDoesNotChange, "O identificador @\$_profileName não muda");
    expect(lookupStrings(const Locale('de')).i18n131ProfileTheProfilenameIdentifierDoesNotChange, "The @\$_profileName identifier does not change");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileTheProfilenameIdentifierDoesNotChange, "The @\$_profileName identifier does not change");
    expect(lookupStrings(const Locale('it')).i18n131ProfileTheProfilenameIdentifierDoesNotChange, "The @\$_profileName identifier does not change");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileTheProfilenameIdentifierDoesNotChange, "The @\$_profileName identifier does not change");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileTheProfilenameIdentifierDoesNotChange, "The @\$_profileName identifier does not change");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileTheProfilenameIdentifierDoesNotChange, "The @\$_profileName identifier does not change");
    expect(lookupStrings(const Locale('es')).i18n131ProfileCustomize, "Personalizar");
    expect(lookupStrings(const Locale('en')).i18n131ProfileCustomize, "Customize");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileCustomize, "Personalizar");
    expect(lookupStrings(const Locale('de')).i18n131ProfileCustomize, "Customize");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileCustomize, "Customize");
    expect(lookupStrings(const Locale('it')).i18n131ProfileCustomize, "Customize");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileCustomize, "Customize");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileCustomize, "Customize");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileCustomize, "Customize");
    expect(lookupStrings(const Locale('es')).i18n131ProfileVisualIdentity, "Identidad visual");
    expect(lookupStrings(const Locale('en')).i18n131ProfileVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileVisualIdentity, "Identidade visual");
    expect(lookupStrings(const Locale('de')).i18n131ProfileVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('it')).i18n131ProfileVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('es')).i18n131ProfilePet, "Mascota");
    expect(lookupStrings(const Locale('en')).i18n131ProfilePet, "Pet");
    expect(lookupStrings(const Locale('pt')).i18n131ProfilePet, "Mascote");
    expect(lookupStrings(const Locale('de')).i18n131ProfilePet, "Pet");
    expect(lookupStrings(const Locale('fr')).i18n131ProfilePet, "Pet");
    expect(lookupStrings(const Locale('it')).i18n131ProfilePet, "Pet");
    expect(lookupStrings(const Locale('ja')).i18n131ProfilePet, "Pet");
    expect(lookupStrings(const Locale('ko')).i18n131ProfilePet, "Pet");
    expect(lookupStrings(const Locale('zh')).i18n131ProfilePet, "Pet");
    expect(lookupStrings(const Locale('es')).i18n131ProfileImage, "Imagen");
    expect(lookupStrings(const Locale('en')).i18n131ProfileImage, "Image");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileImage, "Imagem");
    expect(lookupStrings(const Locale('de')).i18n131ProfileImage, "Image");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileImage, "Image");
    expect(lookupStrings(const Locale('it')).i18n131ProfileImage, "Image");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileImage, "Image");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileImage, "Image");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileImage, "Image");
    expect(lookupStrings(const Locale('es')).i18n131ProfileFace, "Cara");
    expect(lookupStrings(const Locale('en')).i18n131ProfileFace, "Face");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileFace, "Rosto");
    expect(lookupStrings(const Locale('de')).i18n131ProfileFace, "Face");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileFace, "Face");
    expect(lookupStrings(const Locale('it')).i18n131ProfileFace, "Face");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileFace, "Face");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileFace, "Face");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileFace, "Face");
    expect(lookupStrings(const Locale('es')).i18n131ProfileAutomatic, "Automático");
    expect(lookupStrings(const Locale('en')).i18n131ProfileAutomatic, "Automatic");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileAutomatic, "Automático");
    expect(lookupStrings(const Locale('de')).i18n131ProfileAutomatic, "Automatic");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileAutomatic, "Automatic");
    expect(lookupStrings(const Locale('it')).i18n131ProfileAutomatic, "Automatic");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileAutomatic, "Automatic");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileAutomatic, "Automatic");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileAutomatic, "Automatic");
    expect(lookupStrings(const Locale('es')).i18n131ProfileDescription, "Descripción");
    expect(lookupStrings(const Locale('en')).i18n131ProfileDescription, "Description");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileDescription, "Descrição");
    expect(lookupStrings(const Locale('de')).i18n131ProfileDescription, "Description");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileDescription, "Description");
    expect(lookupStrings(const Locale('it')).i18n131ProfileDescription, "Description");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileDescription, "Description");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileDescription, "Description");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileDescription, "Description");
    expect(lookupStrings(const Locale('es')).i18n131ProfileNoDescription, "Sin descripción");
    expect(lookupStrings(const Locale('en')).i18n131ProfileNoDescription, "No description");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileNoDescription, "Sem descrição");
    expect(lookupStrings(const Locale('de')).i18n131ProfileNoDescription, "No description");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileNoDescription, "No description");
    expect(lookupStrings(const Locale('it')).i18n131ProfileNoDescription, "No description");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileNoDescription, "No description");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileNoDescription, "No description");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileNoDescription, "No description");
    expect(lookupStrings(const Locale('es')).i18n131ProfileViewSkills, "Ver skills");
    expect(lookupStrings(const Locale('en')).i18n131ProfileViewSkills, "View skills");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileViewSkills, "Ver skills");
    expect(lookupStrings(const Locale('de')).i18n131ProfileViewSkills, "View skills");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileViewSkills, "View skills");
    expect(lookupStrings(const Locale('it')).i18n131ProfileViewSkills, "View skills");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileViewSkills, "View skills");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileViewSkills, "View skills");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileViewSkills, "View skills");
    expect(lookupStrings(const Locale('es')).i18n131ProfileProfileFace, "Cara del perfil");
    expect(lookupStrings(const Locale('en')).i18n131ProfileProfileFace, "Profile face");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileProfileFace, "Rosto do perfil");
    expect(lookupStrings(const Locale('de')).i18n131ProfileProfileFace, "Profile face");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileProfileFace, "Profile face");
    expect(lookupStrings(const Locale('it')).i18n131ProfileProfileFace, "Profile face");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileProfileFace, "Profile face");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileProfileFace, "Profile face");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileProfileFace, "Profile face");
    expect(lookupStrings(const Locale('es')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP o GIF. Se recorta al centro y se guarda cuadrada.");
    expect(lookupStrings(const Locale('en')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('pt')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP ou GIF. Recortada no centro e salva quadrada.");
    expect(lookupStrings(const Locale('de')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('fr')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('it')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('ja')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('ko')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('zh')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('es')).i18n131ProfileChooseImage, "Elegir imagen");
    expect(lookupStrings(const Locale('en')).i18n131ProfileChooseImage, "Choose image");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileChooseImage, "Escolher imagem");
    expect(lookupStrings(const Locale('de')).i18n131ProfileChooseImage, "Choose image");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileChooseImage, "Choose image");
    expect(lookupStrings(const Locale('it')).i18n131ProfileChooseImage, "Choose image");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileChooseImage, "Choose image");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileChooseImage, "Choose image");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileChooseImage, "Choose image");
    expect(lookupStrings(const Locale('es')).i18n131ProfileChangeImage, "Cambiar imagen");
    expect(lookupStrings(const Locale('en')).i18n131ProfileChangeImage, "Change image");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileChangeImage, "Alterar imagem");
    expect(lookupStrings(const Locale('de')).i18n131ProfileChangeImage, "Change image");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileChangeImage, "Change image");
    expect(lookupStrings(const Locale('it')).i18n131ProfileChangeImage, "Change image");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileChangeImage, "Change image");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileChangeImage, "Change image");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileChangeImage, "Change image");
    expect(lookupStrings(const Locale('es')).i18n131ProfileASavedImageAlsoExistsThePet, "También hay una imagen guardada. La mascota tiene prioridad.");
    expect(lookupStrings(const Locale('en')).i18n131ProfileASavedImageAlsoExistsThePet, "A saved image also exists. The pet takes priority.");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileASavedImageAlsoExistsThePet, "Também existe uma imagem salva. O mascote tem prioridade.");
    expect(lookupStrings(const Locale('de')).i18n131ProfileASavedImageAlsoExistsThePet, "A saved image also exists. The pet takes priority.");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileASavedImageAlsoExistsThePet, "A saved image also exists. The pet takes priority.");
    expect(lookupStrings(const Locale('it')).i18n131ProfileASavedImageAlsoExistsThePet, "A saved image also exists. The pet takes priority.");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileASavedImageAlsoExistsThePet, "A saved image also exists. The pet takes priority.");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileASavedImageAlsoExistsThePet, "A saved image also exists. The pet takes priority.");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileASavedImageAlsoExistsThePet, "A saved image also exists. The pet takes priority.");
    expect(lookupStrings(const Locale('es')).i18n131ProfileUseImage, "Usar imagen");
    expect(lookupStrings(const Locale('en')).i18n131ProfileUseImage, "Use image");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileUseImage, "Usar imagem");
    expect(lookupStrings(const Locale('de')).i18n131ProfileUseImage, "Use image");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileUseImage, "Use image");
    expect(lookupStrings(const Locale('it')).i18n131ProfileUseImage, "Use image");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileUseImage, "Use image");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileUseImage, "Use image");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileUseImage, "Use image");
    expect(lookupStrings(const Locale('es')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Estado incierto: revisa y vuelve a guardar.");
    expect(lookupStrings(const Locale('en')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Uncertain state: review and save again.");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Estado incerto: revise e salve novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Uncertain state: review and save again.");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Uncertain state: review and save again.");
    expect(lookupStrings(const Locale('it')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Uncertain state: review and save again.");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Uncertain state: review and save again.");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Uncertain state: review and save again.");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Uncertain state: review and save again.");
    expect(lookupStrings(const Locale('es')).i18n131ProfileUnsavedChanges, "Cambios sin guardar");
    expect(lookupStrings(const Locale('en')).i18n131ProfileUnsavedChanges, "Unsaved changes");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileUnsavedChanges, "Alterações não salvas");
    expect(lookupStrings(const Locale('de')).i18n131ProfileUnsavedChanges, "Unsaved changes");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileUnsavedChanges, "Unsaved changes");
    expect(lookupStrings(const Locale('it')).i18n131ProfileUnsavedChanges, "Unsaved changes");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileUnsavedChanges, "Unsaved changes");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileUnsavedChanges, "Unsaved changes");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileUnsavedChanges, "Unsaved changes");
    expect(lookupStrings(const Locale('es')).i18n131ProfileNoPendingChanges, "Sin cambios pendientes");
    expect(lookupStrings(const Locale('en')).i18n131ProfileNoPendingChanges, "No pending changes");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileNoPendingChanges, "Nenhuma alteração pendente");
    expect(lookupStrings(const Locale('de')).i18n131ProfileNoPendingChanges, "No pending changes");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileNoPendingChanges, "No pending changes");
    expect(lookupStrings(const Locale('it')).i18n131ProfileNoPendingChanges, "No pending changes");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileNoPendingChanges, "No pending changes");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileNoPendingChanges, "No pending changes");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileNoPendingChanges, "No pending changes");
    expect(lookupStrings(const Locale('es')).i18n131ProfileSaving, "Guardando…");
    expect(lookupStrings(const Locale('en')).i18n131ProfileSaving, "Saving…");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileSaving, "Salvando…");
    expect(lookupStrings(const Locale('de')).i18n131ProfileSaving, "Saving…");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileSaving, "Saving…");
    expect(lookupStrings(const Locale('it')).i18n131ProfileSaving, "Saving…");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileSaving, "Saving…");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileSaving, "Saving…");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileSaving, "Saving…");
  });
}
