import 'dart:ui' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/provider_auth_failure.dart';
import 'package:hermes_android/core/widgets/provider_reauth.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  const compaction = ProviderAuthFailure(
    provider: 'anthropic',
    label: 'Anthropic',
    kind: ProviderAuthKind.oauth,
    origin: ProviderAuthOrigin.compaction,
  );

  test(
    'compaction auth body keeps the sign-in hint and adds a restart hint',
    () async {
      final es = await Strings.delegate.load(const Locale('es'));
      final en = await Strings.delegate.load(const Locale('en'));
      final esBody = providerAuthBody(es, compaction);
      final enBody = providerAuthBody(en, compaction);
      expect(esBody, contains('Vuelve a iniciar sesión'));
      expect(esBody, contains('reinicia el servidor de Hermes'));
      expect(enBody, contains('Sign in again'));
      expect(enBody, contains('restart the Hermes server'));
    },
  );
}
