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
    expect(lookupStrings(const Locale('de')).i18n131ProfileUseAPngJpegWebpOrGif, "Verwende ein PNG-, JPEG-, WebP- oder GIF-Bild mit höchstens 15 MB.");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileUseAPngJpegWebpOrGif, "Utilise une image PNG, JPEG, WebP ou GIF de 15 Mo maximum.");
    expect(lookupStrings(const Locale('it')).i18n131ProfileUseAPngJpegWebpOrGif, "Usa un’immagine PNG, JPEG, WebP o GIF fino a 15 MB.");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileUseAPngJpegWebpOrGif, "15MB以下のPNG、JPEG、WebP、GIF画像を使ってください。");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileUseAPngJpegWebpOrGif, "15 MB 이하의 PNG, JPEG, WebP 또는 GIF 이미지를 사용하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileUseAPngJpegWebpOrGif, "请使用不超过15 MB的PNG、JPEG、WebP或GIF图片。");
    expect(lookupStrings(const Locale('es')).i18n131ProfileDiscardChanges, "¿Descartar cambios?");
    expect(lookupStrings(const Locale('en')).i18n131ProfileDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileDiscardChanges, "Descartar alterações?");
    expect(lookupStrings(const Locale('de')).i18n131ProfileDiscardChanges, "Änderungen verwerfen?");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileDiscardChanges, "Abandonner les modifications ?");
    expect(lookupStrings(const Locale('it')).i18n131ProfileDiscardChanges, "Scartare le modifiche?");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileDiscardChanges, "変更を破棄しますか？");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileDiscardChanges, "변경 사항을 버릴까요?");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileDiscardChanges, "放弃更改？");
    expect(lookupStrings(const Locale('es')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "La identidad del perfil todavía no se ha guardado.");
    expect(lookupStrings(const Locale('en')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "The profile identity has not been saved yet.");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "A identidade do perfil ainda não foi salva.");
    expect(lookupStrings(const Locale('de')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "Die Profilidentität wurde noch nicht gespeichert.");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "L’identité du profil n’a pas encore été enregistrée.");
    expect(lookupStrings(const Locale('it')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "L’identità del profilo non è ancora stata salvata.");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "プロフィールの外観はまだ保存されていません。");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "아직 프로필 정보가 저장되지 않았습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileTheProfileIdentityHasNotBeenSaved, "配置档形象尚未保存。");
    expect(lookupStrings(const Locale('es')).i18n131ProfileKeepEditing, "Seguir editando");
    expect(lookupStrings(const Locale('en')).i18n131ProfileKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileKeepEditing, "Continuar editando");
    expect(lookupStrings(const Locale('de')).i18n131ProfileKeepEditing, "Weiter bearbeiten");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileKeepEditing, "Continuer à modifier");
    expect(lookupStrings(const Locale('it')).i18n131ProfileKeepEditing, "Continua a modificare");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileKeepEditing, "編集を続ける");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileKeepEditing, "계속 편집");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileKeepEditing, "继续编辑");
    expect(lookupStrings(const Locale('es')).i18n131ProfileDiscard, "Descartar");
    expect(lookupStrings(const Locale('en')).i18n131ProfileDiscard, "Discard");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileDiscard, "Descartar");
    expect(lookupStrings(const Locale('de')).i18n131ProfileDiscard, "Verwerfen");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileDiscard, "Abandonner");
    expect(lookupStrings(const Locale('it')).i18n131ProfileDiscard, "Scarta");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileDiscard, "破棄");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileDiscard, "버리기");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileDiscard, "放弃");
    expect(lookupStrings(const Locale('es')).i18n131ProfileUnsaved, "Sin guardar");
    expect(lookupStrings(const Locale('en')).i18n131ProfileUnsaved, "Unsaved");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileUnsaved, "Não salvo");
    expect(lookupStrings(const Locale('de')).i18n131ProfileUnsaved, "Nicht gespeichert");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileUnsaved, "Non enregistré");
    expect(lookupStrings(const Locale('it')).i18n131ProfileUnsaved, "Non salvato");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileUnsaved, "未保存");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileUnsaved, "저장되지 않음");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileUnsaved, "未保存");
    expect(lookupStrings(const Locale('es')).i18n131ProfileTheProfilenameIdentifierDoesNotChange('console-builder'), "El identificador @console-builder no cambia");
    expect(lookupStrings(const Locale('en')).i18n131ProfileTheProfilenameIdentifierDoesNotChange('console-builder'), "The @console-builder identifier does not change");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileTheProfilenameIdentifierDoesNotChange('console-builder'), "O identificador @console-builder não muda");
    expect(lookupStrings(const Locale('de')).i18n131ProfileTheProfilenameIdentifierDoesNotChange('console-builder'), "Die Kennung @console-builder bleibt unverändert");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileTheProfilenameIdentifierDoesNotChange('console-builder'), "L’identifiant @console-builder ne change pas");
    expect(lookupStrings(const Locale('it')).i18n131ProfileTheProfilenameIdentifierDoesNotChange('console-builder'), "L’identificativo @console-builder non cambia");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileTheProfilenameIdentifierDoesNotChange('console-builder'), "識別子@console-builderは変わりません");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileTheProfilenameIdentifierDoesNotChange('console-builder'), "@console-builder 식별자는 변경되지 않습니다");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileTheProfilenameIdentifierDoesNotChange('console-builder'), "标识符@console-builder不会改变");
    expect(lookupStrings(const Locale('es')).i18n131ProfileCustomize, "Personalizar");
    expect(lookupStrings(const Locale('en')).i18n131ProfileCustomize, "Customize");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileCustomize, "Personalizar");
    expect(lookupStrings(const Locale('de')).i18n131ProfileCustomize, "Anpassen");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileCustomize, "Personnaliser");
    expect(lookupStrings(const Locale('it')).i18n131ProfileCustomize, "Personalizza");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileCustomize, "カスタマイズ");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileCustomize, "꾸미기");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileCustomize, "自定义");
    expect(lookupStrings(const Locale('es')).i18n131ProfileVisualIdentity, "Identidad visual");
    expect(lookupStrings(const Locale('en')).i18n131ProfileVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileVisualIdentity, "Identidade visual");
    expect(lookupStrings(const Locale('de')).i18n131ProfileVisualIdentity, "Visuelle Identität");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileVisualIdentity, "Identité visuelle");
    expect(lookupStrings(const Locale('it')).i18n131ProfileVisualIdentity, "Identità visiva");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileVisualIdentity, "外観");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileVisualIdentity, "외형 설정");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileVisualIdentity, "视觉形象");
    expect(lookupStrings(const Locale('es')).i18n131ProfilePet, "Mascota");
    expect(lookupStrings(const Locale('en')).i18n131ProfilePet, "Pet");
    expect(lookupStrings(const Locale('pt')).i18n131ProfilePet, "Mascote");
    expect(lookupStrings(const Locale('de')).i18n131ProfilePet, "Maskottchen");
    expect(lookupStrings(const Locale('fr')).i18n131ProfilePet, "Mascotte");
    expect(lookupStrings(const Locale('it')).i18n131ProfilePet, "Animaletto");
    expect(lookupStrings(const Locale('ja')).i18n131ProfilePet, "ペット");
    expect(lookupStrings(const Locale('ko')).i18n131ProfilePet, "펫");
    expect(lookupStrings(const Locale('zh')).i18n131ProfilePet, "宠物");
    expect(lookupStrings(const Locale('es')).i18n131ProfileImage, "Imagen");
    expect(lookupStrings(const Locale('en')).i18n131ProfileImage, "Image");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileImage, "Imagem");
    expect(lookupStrings(const Locale('de')).i18n131ProfileImage, "Bild");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileImage, "Image");
    expect(lookupStrings(const Locale('it')).i18n131ProfileImage, "Immagine");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileImage, "画像");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileImage, "이미지");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileImage, "图片");
    expect(lookupStrings(const Locale('es')).i18n131ProfileFace, "Cara");
    expect(lookupStrings(const Locale('en')).i18n131ProfileFace, "Face");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileFace, "Rosto");
    expect(lookupStrings(const Locale('de')).i18n131ProfileFace, "Gesicht");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileFace, "Visage");
    expect(lookupStrings(const Locale('it')).i18n131ProfileFace, "Volto");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileFace, "アイコン");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileFace, "얼굴");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileFace, "面孔");
    expect(lookupStrings(const Locale('es')).i18n131ProfileAutomatic, "Automático");
    expect(lookupStrings(const Locale('en')).i18n131ProfileAutomatic, "Automatic");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileAutomatic, "Automático");
    expect(lookupStrings(const Locale('de')).i18n131ProfileAutomatic, "Automatisch");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileAutomatic, "Automatique");
    expect(lookupStrings(const Locale('it')).i18n131ProfileAutomatic, "Automatico");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileAutomatic, "自動");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileAutomatic, "자동");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileAutomatic, "自动");
    expect(lookupStrings(const Locale('es')).i18n131ProfileDescription, "Descripción");
    expect(lookupStrings(const Locale('en')).i18n131ProfileDescription, "Description");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileDescription, "Descrição");
    expect(lookupStrings(const Locale('de')).i18n131ProfileDescription, "Beschreibung");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileDescription, "Description");
    expect(lookupStrings(const Locale('it')).i18n131ProfileDescription, "Descrizione");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileDescription, "説明");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileDescription, "설명");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileDescription, "描述");
    expect(lookupStrings(const Locale('es')).i18n131ProfileNoDescription, "Sin descripción");
    expect(lookupStrings(const Locale('en')).i18n131ProfileNoDescription, "No description");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileNoDescription, "Sem descrição");
    expect(lookupStrings(const Locale('de')).i18n131ProfileNoDescription, "Keine Beschreibung");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileNoDescription, "Aucune description");
    expect(lookupStrings(const Locale('it')).i18n131ProfileNoDescription, "Nessuna descrizione");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileNoDescription, "説明なし");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileNoDescription, "설명 없음");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileNoDescription, "暂无描述");
    expect(lookupStrings(const Locale('es')).i18n131ProfileViewSkills, "Ver skills");
    expect(lookupStrings(const Locale('en')).i18n131ProfileViewSkills, "View skills");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileViewSkills, "Ver skills");
    expect(lookupStrings(const Locale('de')).i18n131ProfileViewSkills, "Fähigkeiten ansehen");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileViewSkills, "Voir les compétences");
    expect(lookupStrings(const Locale('it')).i18n131ProfileViewSkills, "Visualizza competenze");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileViewSkills, "スキルを表示");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileViewSkills, "스킬 보기");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileViewSkills, "查看技能");
    expect(lookupStrings(const Locale('es')).i18n131ProfileProfileFace, "Cara del perfil");
    expect(lookupStrings(const Locale('en')).i18n131ProfileProfileFace, "Profile face");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileProfileFace, "Rosto do perfil");
    expect(lookupStrings(const Locale('de')).i18n131ProfileProfileFace, "Profilgesicht");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileProfileFace, "Visage du profil");
    expect(lookupStrings(const Locale('it')).i18n131ProfileProfileFace, "Volto del profilo");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileProfileFace, "プロフィールのアイコン");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileProfileFace, "프로필 얼굴");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileProfileFace, "配置档面孔");
    expect(lookupStrings(const Locale('es')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP o GIF. Se recorta al centro y se guarda cuadrada.");
    expect(lookupStrings(const Locale('en')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('pt')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP ou GIF. Recortada no centro e salva quadrada.");
    expect(lookupStrings(const Locale('de')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP oder GIF. Wird mittig zugeschnitten und quadratisch gespeichert.");
    expect(lookupStrings(const Locale('fr')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP ou GIF. Recadrage centré et enregistrement au format carré.");
    expect(lookupStrings(const Locale('it')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP o GIF. Ritagliata al centro e salvata in formato quadrato.");
    expect(lookupStrings(const Locale('ja')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG、JPEG、WebP、GIFに対応。中央を切り抜き、正方形で保存します。");
    expect(lookupStrings(const Locale('ko')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP 또는 GIF. 가운데를 잘라 정사각형으로 저장합니다.");
    expect(lookupStrings(const Locale('zh')).i18n131ProfilePngJpegWebpOrGifCenterCropped, "支持PNG、JPEG、WebP或GIF，将居中裁剪并保存为正方形。");
    expect(lookupStrings(const Locale('es')).i18n131ProfileChooseImage, "Elegir imagen");
    expect(lookupStrings(const Locale('en')).i18n131ProfileChooseImage, "Choose image");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileChooseImage, "Escolher imagem");
    expect(lookupStrings(const Locale('de')).i18n131ProfileChooseImage, "Bild auswählen");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileChooseImage, "Choisir une image");
    expect(lookupStrings(const Locale('it')).i18n131ProfileChooseImage, "Scegli immagine");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileChooseImage, "画像を選択");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileChooseImage, "이미지 선택");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileChooseImage, "选择图片");
    expect(lookupStrings(const Locale('es')).i18n131ProfileChangeImage, "Cambiar imagen");
    expect(lookupStrings(const Locale('en')).i18n131ProfileChangeImage, "Change image");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileChangeImage, "Alterar imagem");
    expect(lookupStrings(const Locale('de')).i18n131ProfileChangeImage, "Bild ändern");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileChangeImage, "Changer l’image");
    expect(lookupStrings(const Locale('it')).i18n131ProfileChangeImage, "Cambia immagine");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileChangeImage, "画像を変更");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileChangeImage, "이미지 변경");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileChangeImage, "更换图片");
    expect(lookupStrings(const Locale('es')).i18n131ProfileASavedImageAlsoExistsThePet, "También hay una imagen guardada. La mascota tiene prioridad.");
    expect(lookupStrings(const Locale('en')).i18n131ProfileASavedImageAlsoExistsThePet, "A saved image also exists. The pet takes priority.");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileASavedImageAlsoExistsThePet, "Também existe uma imagem salva. O mascote tem prioridade.");
    expect(lookupStrings(const Locale('de')).i18n131ProfileASavedImageAlsoExistsThePet, "Es gibt auch ein gespeichertes Bild. Das Maskottchen hat Vorrang.");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileASavedImageAlsoExistsThePet, "Une image enregistrée existe aussi. La mascotte est prioritaire.");
    expect(lookupStrings(const Locale('it')).i18n131ProfileASavedImageAlsoExistsThePet, "Esiste anche un’immagine salvata. L’animaletto ha la precedenza.");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileASavedImageAlsoExistsThePet, "保存済みの画像もあります。ペットが優先されます。");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileASavedImageAlsoExistsThePet, "저장된 이미지도 있습니다. 펫이 우선 적용됩니다.");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileASavedImageAlsoExistsThePet, "也有已保存的图片，优先使用宠物。");
    expect(lookupStrings(const Locale('es')).i18n131ProfileUseImage, "Usar imagen");
    expect(lookupStrings(const Locale('en')).i18n131ProfileUseImage, "Use image");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileUseImage, "Usar imagem");
    expect(lookupStrings(const Locale('de')).i18n131ProfileUseImage, "Bild verwenden");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileUseImage, "Utiliser l’image");
    expect(lookupStrings(const Locale('it')).i18n131ProfileUseImage, "Usa immagine");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileUseImage, "画像を使う");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileUseImage, "이미지 사용");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileUseImage, "使用图片");
    expect(lookupStrings(const Locale('es')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Estado incierto: revisa y vuelve a guardar.");
    expect(lookupStrings(const Locale('en')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Uncertain state: review and save again.");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Estado incerto: revise e salve novamente.");
    expect(lookupStrings(const Locale('de')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Unklarer Status: prüfen und erneut speichern.");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileUncertainStateReviewAndSaveAgain, "État incertain : vérifie et enregistre à nouveau.");
    expect(lookupStrings(const Locale('it')).i18n131ProfileUncertainStateReviewAndSaveAgain, "Stato incerto: controlla e salva di nuovo.");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileUncertainStateReviewAndSaveAgain, "状態を確認できません。内容を確認して再度保存してください。");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileUncertainStateReviewAndSaveAgain, "상태가 불확실합니다. 확인한 후 다시 저장하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileUncertainStateReviewAndSaveAgain, "状态不确定，请检查后重新保存。");
    expect(lookupStrings(const Locale('es')).i18n131ProfileUnsavedChanges, "Cambios sin guardar");
    expect(lookupStrings(const Locale('en')).i18n131ProfileUnsavedChanges, "Unsaved changes");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileUnsavedChanges, "Alterações não salvas");
    expect(lookupStrings(const Locale('de')).i18n131ProfileUnsavedChanges, "Ungespeicherte Änderungen");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileUnsavedChanges, "Modifications non enregistrées");
    expect(lookupStrings(const Locale('it')).i18n131ProfileUnsavedChanges, "Modifiche non salvate");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileUnsavedChanges, "未保存の変更");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileUnsavedChanges, "저장하지 않은 변경 사항");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileUnsavedChanges, "未保存的更改");
    expect(lookupStrings(const Locale('es')).i18n131ProfileNoPendingChanges, "Sin cambios pendientes");
    expect(lookupStrings(const Locale('en')).i18n131ProfileNoPendingChanges, "No pending changes");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileNoPendingChanges, "Nenhuma alteração pendente");
    expect(lookupStrings(const Locale('de')).i18n131ProfileNoPendingChanges, "Keine ausstehenden Änderungen");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileNoPendingChanges, "Aucune modification en attente");
    expect(lookupStrings(const Locale('it')).i18n131ProfileNoPendingChanges, "Nessuna modifica in sospeso");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileNoPendingChanges, "未保存の変更はありません");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileNoPendingChanges, "변경 사항 없음");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileNoPendingChanges, "没有待保存的更改");
    expect(lookupStrings(const Locale('es')).i18n131ProfileSaving, "Guardando…");
    expect(lookupStrings(const Locale('en')).i18n131ProfileSaving, "Saving…");
    expect(lookupStrings(const Locale('pt')).i18n131ProfileSaving, "Salvando…");
    expect(lookupStrings(const Locale('de')).i18n131ProfileSaving, "Wird gespeichert…");
    expect(lookupStrings(const Locale('fr')).i18n131ProfileSaving, "Enregistrement…");
    expect(lookupStrings(const Locale('it')).i18n131ProfileSaving, "Salvataggio…");
    expect(lookupStrings(const Locale('ja')).i18n131ProfileSaving, "保存中…");
    expect(lookupStrings(const Locale('ko')).i18n131ProfileSaving, "저장 중…");
    expect(lookupStrings(const Locale('zh')).i18n131ProfileSaving, "正在保存…");
  });
}
