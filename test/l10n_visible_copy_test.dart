import 'package:hermes_android/core/models/agent_task_list.dart';
import 'package:hermes_android/core/utils/projected_content_copy.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hermes_android/core/models/session_artifact.dart';
import 'package:hermes_android/core/services/ssh_commands.dart';
import 'package:hermes_android/core/utils/api_error.dart';
import 'package:hermes_android/core/utils/artifact_name_copy.dart';
import 'package:hermes_android/core/utils/companion_error_copy.dart';
import 'package:hermes_android/core/utils/theme_error_copy.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('missing task descriptions retain provenance through merges and history', () {
    final first = AgentTaskList.empty.applyWrite({
      'merge': true,
      'todos': [{'id': 'a', 'status': 'in_progress'}],
    })!;
    expect(first.items.single.content, '(no description)');
    expect(first.items.single.isFallbackContent, isTrue);
    expect(first.asHistory.items.single.isFallbackContent, isTrue);
    final statusOnly = first.applyWrite({
      'merge': true,
      'todos': [{'id': 'a', 'status': 'completed'}],
    })!;
    expect(statusOnly.items.single.isFallbackContent, isTrue);
    final supplied = first.applyWrite({
      'merge': true,
      'todos': [{'id': 'a', 'content': '(no description)'}],
    })!;
    expect(supplied.items.single.isFallbackContent, isFalse);
  });

  for (final language in ['es', 'en', 'pt', 'de', 'fr', 'it', 'ja', 'ko', 'zh']) {
    final s = lookupStrings(Locale(language));
    test('$language: only app-generated transcript markers translate', () {
      const original = 'text\n\n*(imagen adjunta)*';
      expect(projectedContentCopy(s, const {}, original), original);
      expect(
        projectedContentCopy(s, const {'_structuredImageCount': 1}, original),
        'text\n\n*(${s.sa1215KindImage})*',
      );
      expect(projectedContentCopy(s, const {'_structuredImageCount': 0}, original), original);
      expect(projectedContentCopy(s, const {'_structuredImageCount': 1}, 'user text'), 'user text');
    });

    test('$language: local validation errors use catalog copy', () {
      expect(
        localizedApiError(s, http.ClientException('connection failed')),
        s.apiErrorNetwork,
      );
      expect(
        localizedApiError(s, Exception('HTTP 503: {}')),
        s.i18n131P6HttpError('503'),
      );
      expect(
        localizedApiError(s, StateError('SOUL changed during review. Reload and review again.')),
        s.i18n131P6SoulChanged,
      );
      expect(
        localizedApiError(s, const FormatException('Profile image unavailable')),
        s.i18n131P6ImageUnavailable,
      );
      expect(themeErrorCopy(s, 'payload_too_large'), s.i18n131P6ThemeTooLarge);
      expect(themeErrorCopy(s, 'profile_missing'), s.i18n131P6ThemeMissing);
      expect(
        themeErrorCopy(s, 'invalid_type', field: 'typography'),
        s.i18n131P6ThemeFieldError('typography', 'invalid_type'),
      );
      expect(companionErrorCopy(s, 'el ZIP supera el tamaño máximo permitido'), s.i18n131P6PetTooLarge('ZIP'));
      expect(companionErrorCopy(s, 'el spritesheet no es un WebP/PNG válido'), s.i18n131P6PetImageFormat);
      expect(companionErrorCopy(s, '"fps" debe ser > 0'), s.i18n131P6PetOutOfRange('fps (> 0)'));
      expect(companionErrorCopy(s, 'una mascota base ya usa el slug "nimbus"'), s.i18n131P6PetSlugUsed('nimbus'));
      expect(companionErrorCopy(s, 'ruta no permitida en el ZIP: "../file"'), s.i18n131P6PetArchivePath('../file'));
      expect(companionErrorCopy(s, 'estado "run": "row" fuera de rango'), s.i18n131P6PetOutOfRange('states.run.row'));
      expect(companionErrorCopy(s, '"fps" debe ser numérico'), s.i18n131P6PetFieldType('fps', 'num'));
      expect(companionErrorCopy(s, 'respuesta HTTP 404'), s.i18n131P6PetHttp('404'));
      expect(companionErrorCopy(s, 'spritesheet con dimensiones inesperadas (100x150); se espera múltiplo de 32x32'), s.i18n131P6PetDimensions('100x150', '32x32'));
      // User/backend data is not translated by guessing from substrings.
      expect(companionErrorCopy(s, 'nimbus custom server detail'), 'nimbus custom server detail');
    });

    test('$language: generic artifact names translate; real filenames stay exact', () {
      for (final kind in SessionArtifactKind.values) {
        final artifact = SessionArtifact(
          id: 'fixture',
          kind: kind,
          displayName: 'Image',
          hasExplicitDisplayName: false,
          sources: const [SessionArtifactSource(messageOrdinal: 0)],
        );
        final expected = switch (kind) {
          SessionArtifactKind.image => s.sa1215KindImage,
          SessionArtifactKind.file => s.sa1215KindFile,
          SessionArtifactKind.document => s.i18n131P6Document,
          SessionArtifactKind.generated => s.i18n131P6GeneratedArtifact,
          SessionArtifactKind.toolResult => s.i18n131P6ToolResult,
          SessionArtifactKind.unknown => s.i18n131P6Artifact,
        };
        expect(artifactNameCopy(s, artifact), expected);
        expect(artifactNameCopy(s, artifact.withSources(artifact.sources)), expected);
        final named = SessionArtifact(
          id: 'named',
          kind: kind,
          displayName: 'Image',
          sources: const [SessionArtifactSource(messageOrdinal: 0)],
        );
        expect(artifactNameCopy(s, named), 'Image');
      }
    });

    test('$language: default SSH labels translate and saved user labels stay exact', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = SshCommandsStore(prefs);
      final defaults = store.load('fixture', strings: s);
      expect(defaults.map((c) => c.label), [s.i18n131P6SshUptime, s.i18n131P6SshDisk, s.drawerMemory, s.i18n131P6SshCpu, s.i18n131P6SshStatus]);
      expect(defaults.map((c) => c.command), SshCommandsStore.defaults.map((c) => c.command));
      await store.save('fixture', const [SshQuickCommand('My label', 'uptime')]);
      expect(store.load('fixture', strings: s).single.label, 'My label');
    });
  }
}
