// A Hermes that lists and sets a profile's model, for the screens that
// offer it: the bot's card, the profile editor and the create form.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/models/bot_visual_identity.dart';
import 'package:hermes_android/core/models/desktop_model_catalog.dart';
import 'package:hermes_android/core/models/profile_pet.dart';
import 'package:hermes_android/core/services/bot_profile_client.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

DesktopModelCatalog modelCatalog() => DesktopModelCatalog.fromJson({
  'providers': [
    {
      'slug': 'openai',
      'name': 'OpenAI',
      'authenticated': true,
      'models': ['gpt-5.5', 'gpt-5.5-mini'],
    },
  ],
});

/// What an identity editor needs that is not about the model.
base class FakeIdentityGateway
    implements
        HermesDesktopProfileAssetsGateway,
        HermesDesktopPetGateway,
        HermesDesktopBotCreationGateway {
  @override
  Stream<TuiGatewayEvent> get events => const Stream.empty();
  @override
  Future<AgentProfileAvatar?> profileAvatar(String profileName) async => null;
  @override
  Future<void> saveProfileBotMeta({
    required String profile,
    String? title,
    String? shape,
    String? colorHex,
    bool? hidden,
    bool? pinned,
    int? createdAtMs,
    BotVisualIdentity? identity,
  }) async {}
  @override
  Future<void> setProfileAvatar({
    required String profile,
    required String dataUri,
  }) async {}
  @override
  Future<void> clearProfileAvatar(String profile) async {}
  @override
  Future<ProfilePetInfo> profilePetInfo({
    String profile = '',
    String? knownRevision,
  }) async => ProfilePetInfo.disabled;
  @override
  Future<ProfilePetGallery> profilePetGallery({
    String profile = '',
    bool localOnly = false,
  }) async => const ProfilePetGallery(enabled: false, active: '', pets: []);
  @override
  Future<String?> profilePetThumb({
    String profile = '',
    required String slug,
    String url = '',
  }) async => null;
  @override
  Future<ProfilePetSelection> profilePetSelect({
    String profile = '',
    required String slug,
  }) async => ProfilePetSelection(slug: slug);
  @override
  Future<bool> profilePetDisable({String profile = ''}) async => true;
  @override
  Future<void> createProfileNative({
    required String name,
    String? cloneFrom,
    String description = '',
    String soul = '',
    String model = '',
    String provider = '',
    bool noSkills = false,
    bool shareAuth = true,
  }) async {}
  @override
  Future<List<DesktopProfileSkill>?> describeProfileSkills(
    String profile,
  ) async => const [];
  @override
  Future<void> setProfileDisabledSkills({
    required String profile,
    required List<String> disabledSkills,
  }) async {}
}

/// A Hermes with `model.options` and `profiles.configure`.
final class FakeModelGateway extends FakeIdentityGateway
    implements BotModelGateway, BotProfileGateway {
  /// `model.options` stays on the wire until [pending] is completed.
  bool hang = false;
  Completer<DesktopModelCatalog>? pending;
  bool confirmFirst = false;
  final catalogReads = <String>[];
  final configures = <(String, Map<String, dynamic>)>[];

  @override
  Future<DesktopModelCatalog> botModelOptions(String profile) {
    catalogReads.add(profile);
    if (hang) return (pending = Completer<DesktopModelCatalog>()).future;
    return Future.value(modelCatalog());
  }

  @override
  Future<String?> botReasoning(String profile) async => 'medium';
  @override
  Future<void> setBotReasoning(String profile, String effort) async {}
  @override
  Future<Map<String, dynamic>> describeBotProfile(String profile) async => {};
  @override
  Future<Map<String, dynamic>> configureBotProfile(
    String profile,
    Map<String, dynamic> changes,
  ) async {
    configures.add((profile, changes));
    if (confirmFirst && changes['confirm_expensive_model'] != true) {
      return {'confirm_required': true, 'confirm_message': 'Es de pago'};
    }
    return {
      'ok': true,
      'applied': {'model': true},
    };
  }

  @override
  Future<void> patchBotMetadata(
    String profile,
    Map<String, dynamic> patch, {
    Set<String> remove = const {},
  }) async {}
  @override
  Future<String> duplicateBotProfile(String profile) async => '$profile-2';
}

const modelBot = AgentProfile(
  name: 'builder',
  model: 'gpt-5.5',
  provider: 'openai',
  botModeUiMeta: {'title': 'Console Builder'},
);

Widget modelApp(Widget home) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: AppTheme.hermesRedDark,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: home,
);

Future<void> pumpModelUi(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void phoneView(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}
