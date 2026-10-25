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
    expect(lookupStrings(const Locale('de')).i18n131CreateUseAPngJpegWebpOrGif, "Verwende ein PNG-, JPEG-, WebP- oder GIF-Bild mit höchstens 15 MB.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateUseAPngJpegWebpOrGif, "Utilise une image PNG, JPEG, WebP ou GIF de 15 Mo maximum.");
    expect(lookupStrings(const Locale('it')).i18n131CreateUseAPngJpegWebpOrGif, "Usa un’immagine PNG, JPEG, WebP o GIF fino a 15 MB.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateUseAPngJpegWebpOrGif, "15MB以下のPNG、JPEG、WebP、GIF画像を使ってください。");
    expect(lookupStrings(const Locale('ko')).i18n131CreateUseAPngJpegWebpOrGif, "15 MB 이하의 PNG, JPEG, WebP 또는 GIF 이미지를 사용하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateUseAPngJpegWebpOrGif, "请使用不超过15 MB的PNG、JPEG、WebP或GIF图片。");
    expect(lookupStrings(const Locale('es')).i18n131CreateTheProfileExistsButItsIdentityIs, "El perfil existe, pero no sabemos si su identidad se guardó. Revísala y vuelve a intentarlo.");
    expect(lookupStrings(const Locale('en')).i18n131CreateTheProfileExistsButItsIdentityIs, "The profile exists, but its identity is uncertain. Review it and try again.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateTheProfileExistsButItsIdentityIs, "O perfil existe, mas não sabemos se a identidade foi salva. Revise-a e tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131CreateTheProfileExistsButItsIdentityIs, "Das Profil existiert, aber seine Identität ist unklar. Prüfe sie und versuche es erneut.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateTheProfileExistsButItsIdentityIs, "Le profil existe, mais son identité est incertaine. Vérifie-la et réessaie.");
    expect(lookupStrings(const Locale('it')).i18n131CreateTheProfileExistsButItsIdentityIs, "Il profilo esiste, ma la sua identità è incerta. Controlla e riprova.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateTheProfileExistsButItsIdentityIs, "プロフィールは存在しますが、外観の状態を確認できません。確認して再試行してください。");
    expect(lookupStrings(const Locale('ko')).i18n131CreateTheProfileExistsButItsIdentityIs, "프로필이 생성되었지만 설정 상태가 불확실합니다. 확인한 후 다시 시도하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateTheProfileExistsButItsIdentityIs, "配置档已存在，但形象状态不确定。请检查后重试。");
    expect(lookupStrings(const Locale('es')).i18n131CreateTheProfileExistsButItsIdentityCould, "El perfil existe, pero no se pudo aplicar su identidad. Corrige el problema y vuelve a intentarlo.");
    expect(lookupStrings(const Locale('en')).i18n131CreateTheProfileExistsButItsIdentityCould, "The profile exists, but its identity could not be applied. Fix the issue and try again.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateTheProfileExistsButItsIdentityCould, "O perfil existe, mas não foi possível aplicar a identidade. Corrija o problema e tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131CreateTheProfileExistsButItsIdentityCould, "Das Profil existiert, aber seine Identität konnte nicht angewendet werden. Behebe das Problem und versuche es erneut.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateTheProfileExistsButItsIdentityCould, "Le profil existe, mais son identité n’a pas pu être appliquée. Corrige le problème et réessaie.");
    expect(lookupStrings(const Locale('it')).i18n131CreateTheProfileExistsButItsIdentityCould, "Il profilo esiste, ma non è stato possibile applicarne l’identità. Risolvi il problema e riprova.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateTheProfileExistsButItsIdentityCould, "プロフィールは存在しますが、外観を適用できませんでした。問題を修正して再試行してください。");
    expect(lookupStrings(const Locale('ko')).i18n131CreateTheProfileExistsButItsIdentityCould, "프로필이 존재하지만 프로필 정보를 적용하지 못했습니다. 문제를 해결한 후 다시 시도하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateTheProfileExistsButItsIdentityCould, "配置档已存在，但无法应用其形象。请解决问题后重试。");
    expect(lookupStrings(const Locale('es')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Elige una identidad válida antes de crear el perfil.");
    expect(lookupStrings(const Locale('en')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Choose a valid identity before creating the profile.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Escolha uma identidade válida antes de criar o perfil.");
    expect(lookupStrings(const Locale('de')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Wähle vor dem Erstellen des Profils eine gültige Identität.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Choisis une identité valide avant de créer le profil.");
    expect(lookupStrings(const Locale('it')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "Scegli un’identità valida prima di creare il profilo.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "プロフィールの作成前に有効な外観を選んでください。");
    expect(lookupStrings(const Locale('ko')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "프로필을 만들기 전에 유효한 프로필 정보를 선택하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateChooseAValidIdentityBeforeCreatingThe, "请先选择有效形象，再创建配置档。");
    expect(lookupStrings(const Locale('es')).i18n131CreateDiscardChanges, "¿Descartar cambios?");
    expect(lookupStrings(const Locale('en')).i18n131CreateDiscardChanges, "Discard changes?");
    expect(lookupStrings(const Locale('pt')).i18n131CreateDiscardChanges, "Descartar alterações?");
    expect(lookupStrings(const Locale('de')).i18n131CreateDiscardChanges, "Änderungen verwerfen?");
    expect(lookupStrings(const Locale('fr')).i18n131CreateDiscardChanges, "Abandonner les modifications ?");
    expect(lookupStrings(const Locale('it')).i18n131CreateDiscardChanges, "Scartare le modifiche?");
    expect(lookupStrings(const Locale('ja')).i18n131CreateDiscardChanges, "変更を破棄しますか？");
    expect(lookupStrings(const Locale('ko')).i18n131CreateDiscardChanges, "변경 사항을 버릴까요?");
    expect(lookupStrings(const Locale('zh')).i18n131CreateDiscardChanges, "放弃更改？");
    expect(lookupStrings(const Locale('es')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "El perfil ya existe, pero su configuración visual no terminó. Si sales, no se abrirá su chat automático.");
    expect(lookupStrings(const Locale('en')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "The profile already exists, but its visual setup is incomplete. Leaving will not open its automatic chat.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "O perfil já existe, mas a configuração visual não terminou. Se você sair, o chat automático não será aberto.");
    expect(lookupStrings(const Locale('de')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "Das Profil existiert bereits, aber seine visuelle Einrichtung ist unvollständig. Beim Verlassen wird sein automatischer Chat nicht geöffnet.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "Le profil existe déjà, mais sa configuration visuelle est incomplète. Quitter n’ouvrira pas sa conversation automatique.");
    expect(lookupStrings(const Locale('it')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "Il profilo esiste già, ma la configurazione visiva è incompleta. Uscendo, la sua chat non si aprirà automaticamente.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "プロフィールは既に存在しますが、外観の設定が完了していません。ここで閉じると、チャットは自動で開きません。");
    expect(lookupStrings(const Locale('ko')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "프로필이 이미 존재하지만 외형 설정이 완료되지 않았습니다. 나가면 자동 대화가 열리지 않습니다.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateTheProfileAlreadyExistsButItsVisual, "配置档已存在，但视觉设置尚未完成。离开后不会自动打开其对话。");
    expect(lookupStrings(const Locale('es')).i18n131CreateYouWillLoseThisProfileSetup, "Perderás la configuración de este perfil.");
    expect(lookupStrings(const Locale('en')).i18n131CreateYouWillLoseThisProfileSetup, "You will lose this profile setup.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateYouWillLoseThisProfileSetup, "Você perderá a configuração deste perfil.");
    expect(lookupStrings(const Locale('de')).i18n131CreateYouWillLoseThisProfileSetup, "Diese Profileinrichtung geht verloren.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateYouWillLoseThisProfileSetup, "Tu perdras cette configuration du profil.");
    expect(lookupStrings(const Locale('it')).i18n131CreateYouWillLoseThisProfileSetup, "Perderai questa configurazione del profilo.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateYouWillLoseThisProfileSetup, "このプロフィールの設定は失われます。");
    expect(lookupStrings(const Locale('ko')).i18n131CreateYouWillLoseThisProfileSetup, "이 프로필 설정 내용이 사라집니다.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateYouWillLoseThisProfileSetup, "将丢失此配置档的设置。");
    expect(lookupStrings(const Locale('es')).i18n131CreateKeepEditing, "Seguir editando");
    expect(lookupStrings(const Locale('en')).i18n131CreateKeepEditing, "Keep editing");
    expect(lookupStrings(const Locale('pt')).i18n131CreateKeepEditing, "Continuar editando");
    expect(lookupStrings(const Locale('de')).i18n131CreateKeepEditing, "Weiter bearbeiten");
    expect(lookupStrings(const Locale('fr')).i18n131CreateKeepEditing, "Continuer à modifier");
    expect(lookupStrings(const Locale('it')).i18n131CreateKeepEditing, "Continua a modificare");
    expect(lookupStrings(const Locale('ja')).i18n131CreateKeepEditing, "編集を続ける");
    expect(lookupStrings(const Locale('ko')).i18n131CreateKeepEditing, "계속 편집");
    expect(lookupStrings(const Locale('zh')).i18n131CreateKeepEditing, "继续编辑");
    expect(lookupStrings(const Locale('es')).i18n131CreateDiscard, "Descartar");
    expect(lookupStrings(const Locale('en')).i18n131CreateDiscard, "Discard");
    expect(lookupStrings(const Locale('pt')).i18n131CreateDiscard, "Descartar");
    expect(lookupStrings(const Locale('de')).i18n131CreateDiscard, "Verwerfen");
    expect(lookupStrings(const Locale('fr')).i18n131CreateDiscard, "Abandonner");
    expect(lookupStrings(const Locale('it')).i18n131CreateDiscard, "Scarta");
    expect(lookupStrings(const Locale('ja')).i18n131CreateDiscard, "破棄");
    expect(lookupStrings(const Locale('ko')).i18n131CreateDiscard, "버리기");
    expect(lookupStrings(const Locale('zh')).i18n131CreateDiscard, "放弃");
    expect(lookupStrings(const Locale('es')).i18n131CreateCustomize, "Personalizar");
    expect(lookupStrings(const Locale('en')).i18n131CreateCustomize, "Customize");
    expect(lookupStrings(const Locale('pt')).i18n131CreateCustomize, "Personalizar");
    expect(lookupStrings(const Locale('de')).i18n131CreateCustomize, "Anpassen");
    expect(lookupStrings(const Locale('fr')).i18n131CreateCustomize, "Personnaliser");
    expect(lookupStrings(const Locale('it')).i18n131CreateCustomize, "Personalizza");
    expect(lookupStrings(const Locale('ja')).i18n131CreateCustomize, "カスタマイズ");
    expect(lookupStrings(const Locale('ko')).i18n131CreateCustomize, "꾸미기");
    expect(lookupStrings(const Locale('zh')).i18n131CreateCustomize, "自定义");
    expect(lookupStrings(const Locale('es')).i18n131CreateOptional, "opcional");
    expect(lookupStrings(const Locale('en')).i18n131CreateOptional, "optional");
    expect(lookupStrings(const Locale('pt')).i18n131CreateOptional, "opcional");
    expect(lookupStrings(const Locale('de')).i18n131CreateOptional, "optional");
    expect(lookupStrings(const Locale('fr')).i18n131CreateOptional, "facultatif");
    expect(lookupStrings(const Locale('it')).i18n131CreateOptional, "facoltativo");
    expect(lookupStrings(const Locale('ja')).i18n131CreateOptional, "任意");
    expect(lookupStrings(const Locale('ko')).i18n131CreateOptional, "선택 사항");
    expect(lookupStrings(const Locale('zh')).i18n131CreateOptional, "可选");
    expect(lookupStrings(const Locale('es')).i18n131CreateVisualIdentity, "Identidad visual");
    expect(lookupStrings(const Locale('en')).i18n131CreateVisualIdentity, "Visual identity");
    expect(lookupStrings(const Locale('pt')).i18n131CreateVisualIdentity, "Identidade visual");
    expect(lookupStrings(const Locale('de')).i18n131CreateVisualIdentity, "Visuelle Identität");
    expect(lookupStrings(const Locale('fr')).i18n131CreateVisualIdentity, "Identité visuelle");
    expect(lookupStrings(const Locale('it')).i18n131CreateVisualIdentity, "Identità visiva");
    expect(lookupStrings(const Locale('ja')).i18n131CreateVisualIdentity, "外観");
    expect(lookupStrings(const Locale('ko')).i18n131CreateVisualIdentity, "외형 설정");
    expect(lookupStrings(const Locale('zh')).i18n131CreateVisualIdentity, "视觉形象");
    expect(lookupStrings(const Locale('es')).i18n131CreatePet, "Mascota");
    expect(lookupStrings(const Locale('en')).i18n131CreatePet, "Pet");
    expect(lookupStrings(const Locale('pt')).i18n131CreatePet, "Mascote");
    expect(lookupStrings(const Locale('de')).i18n131CreatePet, "Maskottchen");
    expect(lookupStrings(const Locale('fr')).i18n131CreatePet, "Mascotte");
    expect(lookupStrings(const Locale('it')).i18n131CreatePet, "Animaletto");
    expect(lookupStrings(const Locale('ja')).i18n131CreatePet, "ペット");
    expect(lookupStrings(const Locale('ko')).i18n131CreatePet, "펫");
    expect(lookupStrings(const Locale('zh')).i18n131CreatePet, "宠物");
    expect(lookupStrings(const Locale('es')).i18n131CreateImage, "Imagen");
    expect(lookupStrings(const Locale('en')).i18n131CreateImage, "Image");
    expect(lookupStrings(const Locale('pt')).i18n131CreateImage, "Imagem");
    expect(lookupStrings(const Locale('de')).i18n131CreateImage, "Bild");
    expect(lookupStrings(const Locale('fr')).i18n131CreateImage, "Image");
    expect(lookupStrings(const Locale('it')).i18n131CreateImage, "Immagine");
    expect(lookupStrings(const Locale('ja')).i18n131CreateImage, "画像");
    expect(lookupStrings(const Locale('ko')).i18n131CreateImage, "이미지");
    expect(lookupStrings(const Locale('zh')).i18n131CreateImage, "图片");
    expect(lookupStrings(const Locale('es')).i18n131CreateFace, "Cara");
    expect(lookupStrings(const Locale('en')).i18n131CreateFace, "Face");
    expect(lookupStrings(const Locale('pt')).i18n131CreateFace, "Rosto");
    expect(lookupStrings(const Locale('de')).i18n131CreateFace, "Gesicht");
    expect(lookupStrings(const Locale('fr')).i18n131CreateFace, "Visage");
    expect(lookupStrings(const Locale('it')).i18n131CreateFace, "Volto");
    expect(lookupStrings(const Locale('ja')).i18n131CreateFace, "アイコン");
    expect(lookupStrings(const Locale('ko')).i18n131CreateFace, "얼굴");
    expect(lookupStrings(const Locale('zh')).i18n131CreateFace, "面孔");
    expect(lookupStrings(const Locale('es')).i18n131CreateTitleAndDescription, "Título y descripción");
    expect(lookupStrings(const Locale('en')).i18n131CreateTitleAndDescription, "Title and description");
    expect(lookupStrings(const Locale('pt')).i18n131CreateTitleAndDescription, "Título e descrição");
    expect(lookupStrings(const Locale('de')).i18n131CreateTitleAndDescription, "Titel und Beschreibung");
    expect(lookupStrings(const Locale('fr')).i18n131CreateTitleAndDescription, "Titre et description");
    expect(lookupStrings(const Locale('it')).i18n131CreateTitleAndDescription, "Titolo e descrizione");
    expect(lookupStrings(const Locale('ja')).i18n131CreateTitleAndDescription, "タイトルと説明");
    expect(lookupStrings(const Locale('ko')).i18n131CreateTitleAndDescription, "직함 및 설명");
    expect(lookupStrings(const Locale('zh')).i18n131CreateTitleAndDescription, "标题和描述");
    expect(lookupStrings(const Locale('es')).i18n131CreateNotFilledIn, "Sin rellenar");
    expect(lookupStrings(const Locale('en')).i18n131CreateNotFilledIn, "Not filled in");
    expect(lookupStrings(const Locale('pt')).i18n131CreateNotFilledIn, "Não preenchido");
    expect(lookupStrings(const Locale('de')).i18n131CreateNotFilledIn, "Nicht ausgefüllt");
    expect(lookupStrings(const Locale('fr')).i18n131CreateNotFilledIn, "Non renseigné");
    expect(lookupStrings(const Locale('it')).i18n131CreateNotFilledIn, "Non compilato");
    expect(lookupStrings(const Locale('ja')).i18n131CreateNotFilledIn, "未入力");
    expect(lookupStrings(const Locale('ko')).i18n131CreateNotFilledIn, "입력되지 않음");
    expect(lookupStrings(const Locale('zh')).i18n131CreateNotFilledIn, "未填写");
    expect(lookupStrings(const Locale('es')).i18n131CreateSoulCloneFrom, "Soul · Clonar de");
    expect(lookupStrings(const Locale('en')).i18n131CreateSoulCloneFrom, "Soul · Clone from");
    expect(lookupStrings(const Locale('pt')).i18n131CreateSoulCloneFrom, "Soul · Clonar de");
    expect(lookupStrings(const Locale('de')).i18n131CreateSoulCloneFrom, "SOUL · Klonen von");
    expect(lookupStrings(const Locale('fr')).i18n131CreateSoulCloneFrom, "SOUL · Cloner un profil");
    expect(lookupStrings(const Locale('it')).i18n131CreateSoulCloneFrom, "Anima · Clona da");
    expect(lookupStrings(const Locale('ja')).i18n131CreateSoulCloneFrom, "SOULの複製元");
    expect(lookupStrings(const Locale('ko')).i18n131CreateSoulCloneFrom, "페르소나 · 복제 원본");
    expect(lookupStrings(const Locale('zh')).i18n131CreateSoulCloneFrom, "灵魂 · 克隆来源");
    expect(lookupStrings(const Locale('es')).i18n131CreateProfileFace, "Cara del perfil");
    expect(lookupStrings(const Locale('en')).i18n131CreateProfileFace, "Profile face");
    expect(lookupStrings(const Locale('pt')).i18n131CreateProfileFace, "Rosto do perfil");
    expect(lookupStrings(const Locale('de')).i18n131CreateProfileFace, "Profilgesicht");
    expect(lookupStrings(const Locale('fr')).i18n131CreateProfileFace, "Visage du profil");
    expect(lookupStrings(const Locale('it')).i18n131CreateProfileFace, "Volto del profilo");
    expect(lookupStrings(const Locale('ja')).i18n131CreateProfileFace, "プロフィールのアイコン");
    expect(lookupStrings(const Locale('ko')).i18n131CreateProfileFace, "프로필 얼굴");
    expect(lookupStrings(const Locale('zh')).i18n131CreateProfileFace, "配置档面孔");
    expect(lookupStrings(const Locale('es')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP o GIF. Se recorta al centro y se guarda cuadrada.");
    expect(lookupStrings(const Locale('en')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP, or GIF. Center-cropped and saved square.");
    expect(lookupStrings(const Locale('pt')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP ou GIF. Recortada no centro e salva quadrada.");
    expect(lookupStrings(const Locale('de')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP oder GIF. Wird mittig zugeschnitten und quadratisch gespeichert.");
    expect(lookupStrings(const Locale('fr')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP ou GIF. Recadrage centré et enregistrement au format carré.");
    expect(lookupStrings(const Locale('it')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP o GIF. Ritagliata al centro e salvata in formato quadrato.");
    expect(lookupStrings(const Locale('ja')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG、JPEG、WebP、GIFに対応。中央を切り抜き、正方形で保存します。");
    expect(lookupStrings(const Locale('ko')).i18n131CreatePngJpegWebpOrGifCenterCropped, "PNG, JPEG, WebP 또는 GIF. 가운데를 잘라 정사각형으로 저장합니다.");
    expect(lookupStrings(const Locale('zh')).i18n131CreatePngJpegWebpOrGifCenterCropped, "支持PNG、JPEG、WebP或GIF，将居中裁剪并保存为正方形。");
    expect(lookupStrings(const Locale('es')).i18n131CreateChooseImage, "Elegir imagen");
    expect(lookupStrings(const Locale('en')).i18n131CreateChooseImage, "Choose image");
    expect(lookupStrings(const Locale('pt')).i18n131CreateChooseImage, "Escolher imagem");
    expect(lookupStrings(const Locale('de')).i18n131CreateChooseImage, "Bild auswählen");
    expect(lookupStrings(const Locale('fr')).i18n131CreateChooseImage, "Choisir une image");
    expect(lookupStrings(const Locale('it')).i18n131CreateChooseImage, "Scegli immagine");
    expect(lookupStrings(const Locale('ja')).i18n131CreateChooseImage, "画像を選択");
    expect(lookupStrings(const Locale('ko')).i18n131CreateChooseImage, "이미지 선택");
    expect(lookupStrings(const Locale('zh')).i18n131CreateChooseImage, "选择图片");
    expect(lookupStrings(const Locale('es')).i18n131CreateChangeImage, "Cambiar imagen");
    expect(lookupStrings(const Locale('en')).i18n131CreateChangeImage, "Change image");
    expect(lookupStrings(const Locale('pt')).i18n131CreateChangeImage, "Alterar imagem");
    expect(lookupStrings(const Locale('de')).i18n131CreateChangeImage, "Bild ändern");
    expect(lookupStrings(const Locale('fr')).i18n131CreateChangeImage, "Changer l’image");
    expect(lookupStrings(const Locale('it')).i18n131CreateChangeImage, "Cambia immagine");
    expect(lookupStrings(const Locale('ja')).i18n131CreateChangeImage, "画像を変更");
    expect(lookupStrings(const Locale('ko')).i18n131CreateChangeImage, "이미지 변경");
    expect(lookupStrings(const Locale('zh')).i18n131CreateChangeImage, "更换图片");
    expect(lookupStrings(const Locale('es')).i18n131CreateUncertainStateReviewAndTryAgain, "Estado incierto: revisa y vuelve a intentar.");
    expect(lookupStrings(const Locale('en')).i18n131CreateUncertainStateReviewAndTryAgain, "Uncertain state: review and try again.");
    expect(lookupStrings(const Locale('pt')).i18n131CreateUncertainStateReviewAndTryAgain, "Estado incerto: revise e tente novamente.");
    expect(lookupStrings(const Locale('de')).i18n131CreateUncertainStateReviewAndTryAgain, "Unklarer Status: prüfen und erneut versuchen.");
    expect(lookupStrings(const Locale('fr')).i18n131CreateUncertainStateReviewAndTryAgain, "État incertain : vérifie et réessaie.");
    expect(lookupStrings(const Locale('it')).i18n131CreateUncertainStateReviewAndTryAgain, "Stato incerto: controlla e riprova.");
    expect(lookupStrings(const Locale('ja')).i18n131CreateUncertainStateReviewAndTryAgain, "状態を確認できません。内容を確認して再試行してください。");
    expect(lookupStrings(const Locale('ko')).i18n131CreateUncertainStateReviewAndTryAgain, "상태가 불확실합니다. 확인한 후 다시 시도하세요.");
    expect(lookupStrings(const Locale('zh')).i18n131CreateUncertainStateReviewAndTryAgain, "状态不确定，请检查后重试。");
    expect(lookupStrings(const Locale('es')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Perfil creado · falta confirmar la identidad");
    expect(lookupStrings(const Locale('en')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Profile created · identity confirmation pending");
    expect(lookupStrings(const Locale('pt')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Perfil criado · falta confirmar a identidade");
    expect(lookupStrings(const Locale('de')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Profil erstellt · Identitätsbestätigung ausstehend");
    expect(lookupStrings(const Locale('fr')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Profil créé · confirmation de l’identité en attente");
    expect(lookupStrings(const Locale('it')).i18n131CreateProfileCreatedIdentityConfirmationPending, "Profilo creato · conferma dell’identità in sospeso");
    expect(lookupStrings(const Locale('ja')).i18n131CreateProfileCreatedIdentityConfirmationPending, "プロフィール作成済み・外観の確認待ち");
    expect(lookupStrings(const Locale('ko')).i18n131CreateProfileCreatedIdentityConfirmationPending, "프로필 생성됨 · 프로필 정보 확인 대기 중");
    expect(lookupStrings(const Locale('zh')).i18n131CreateProfileCreatedIdentityConfirmationPending, "配置档已创建 · 形象待确认");
    expect(lookupStrings(const Locale('es')).i18n131CreateCreating, "Creando…");
    expect(lookupStrings(const Locale('en')).i18n131CreateCreating, "Creating…");
    expect(lookupStrings(const Locale('pt')).i18n131CreateCreating, "Criando…");
    expect(lookupStrings(const Locale('de')).i18n131CreateCreating, "Wird erstellt…");
    expect(lookupStrings(const Locale('fr')).i18n131CreateCreating, "Création…");
    expect(lookupStrings(const Locale('it')).i18n131CreateCreating, "Creazione…");
    expect(lookupStrings(const Locale('ja')).i18n131CreateCreating, "作成中…");
    expect(lookupStrings(const Locale('ko')).i18n131CreateCreating, "생성 중…");
    expect(lookupStrings(const Locale('zh')).i18n131CreateCreating, "正在创建…");
    expect(lookupStrings(const Locale('es')).i18n131CreateRetryIdentity, "Reintentar identidad");
    expect(lookupStrings(const Locale('en')).i18n131CreateRetryIdentity, "Retry identity");
    expect(lookupStrings(const Locale('pt')).i18n131CreateRetryIdentity, "Repetir identidade");
    expect(lookupStrings(const Locale('de')).i18n131CreateRetryIdentity, "Identität erneut anwenden");
    expect(lookupStrings(const Locale('fr')).i18n131CreateRetryIdentity, "Réessayer d’appliquer l’identité");
    expect(lookupStrings(const Locale('it')).i18n131CreateRetryIdentity, "Riprova a impostare l’identità");
    expect(lookupStrings(const Locale('ja')).i18n131CreateRetryIdentity, "外観の設定を再試行");
    expect(lookupStrings(const Locale('ko')).i18n131CreateRetryIdentity, "프로필 정보 다시 적용");
    expect(lookupStrings(const Locale('zh')).i18n131CreateRetryIdentity, "重试设置形象");
  });
}
