import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/theme_profile.dart';
import 'package:hermes_android/core/theme/theme_profile_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/theme_profile_fixtures.dart';

Matcher _storeError(String code) => isA<ThemeProfileStoreException>().having(
  (error) => error.code,
  'code',
  code,
);

Future<(SharedPreferences, ThemeProfileStore)> _newStore(
  Map<String, Object> values, {
  List<String> generatedIds = const [],
}) async {
  SharedPreferences.setMockInitialValues(values);
  final prefs = await SharedPreferences.getInstance();
  var nextId = 0;
  return (
    prefs,
    ThemeProfileStore(
      prefs,
      idFactory: () => generatedIds.isEmpty
          ? 'generated-${nextId++}'
          : generatedIds[nextId++],
    ),
  );
}

void main() {
  group('ThemeProfileStore migration and restart safety', () {
    test(
      'migrates legacy preset selection without writing custom payload',
      () async {
        final (prefs, store) = await _newStore({'theme_mode': 'oled'});

        final snapshot = await store.load();

        expect(snapshot.activeProfileId, 'amber');
        expect(snapshot.customProfiles, isEmpty);
        expect(prefs.getString(ThemeProfileStore.activeProfileKey), 'amber');
        expect(prefs.getString(ThemeProfileStore.customProfilesKey), isNull);
        expect(prefs.getInt(ThemeProfileStore.schemaVersionKey), isNull);
      },
    );

    test(
      'persists a valid custom profile and active id across store restart',
      () async {
        final (prefs, store) = await _newStore({});
        final profile = validCustomTheme(
          id: 'saved-theme',
          name: 'Saved theme',
        );

        await store.save(profile);
        await store.activate(profile.id);
        final restarted = ThemeProfileStore(prefs);
        final snapshot = await restarted.load();

        expect(snapshot.customProfiles, [profile]);
        expect(snapshot.activeProfileId, profile.id);
        expect(
          prefs.getInt(ThemeProfileStore.schemaVersionKey),
          themeProfileSchemaVersion,
        );
      },
    );

    test(
      'invalid active custom theme falls back to Amber but remains a draft candidate',
      () async {
        final document = validThemeDocument(id: 'low-contrast');
        final profile = document['profile'] as Map<String, dynamic>;
        final palette = profile['palette'] as Map<String, dynamic>;
        palette['accent_text'] = palette['background'];
        final raw = jsonEncode([document]);
        final (prefs, store) = await _newStore({
          ThemeProfileStore.customProfilesKey: raw,
          ThemeProfileStore.schemaVersionKey: 1,
          ThemeProfileStore.activeProfileKey: 'low-contrast',
        });

        final snapshot = await store.load();

        expect(snapshot.customProfiles.single.id, 'low-contrast');
        expect(snapshot.activeProfileId, 'console');
        expect(prefs.getString(ThemeProfileStore.activeProfileKey), 'console');
      },
    );

    test(
      'saving the active profile as an unsafe draft falls back immediately',
      () async {
        final (prefs, store) = await _newStore({});
        final profile = validCustomTheme(
          id: 'active-edit',
          name: 'Active edit',
        );
        await store.save(profile);
        await store.activate(profile.id);

        final unsafeDraft = profile.copyWith(
          draft: true,
          palette: profile.palette.copyWith(
            accentText: profile.palette.background,
          ),
        );
        await store.save(unsafeDraft);
        final snapshot = await store.load();

        expect(snapshot.activeProfileId, 'console');
        expect(snapshot.customById(profile.id), unsafeDraft);
        expect(prefs.getString(ThemeProfileStore.activeProfileKey), 'console');
        expect(prefs.getString(ThemeProfileStore.legacyThemeKey), 'console');
      },
    );

    test(
      'corrupt active profile is quarantined, removed, and stays safe after restart',
      () async {
        final document = validThemeDocument(id: 'corrupt-theme');
        final profile = document['profile'] as Map<String, dynamic>;
        final palette = profile['palette'] as Map<String, dynamic>;
        palette['accent'] = 'var(--remote)';
        final (prefs, store) = await _newStore({
          ThemeProfileStore.customProfilesKey: jsonEncode([document]),
          ThemeProfileStore.schemaVersionKey: 1,
          ThemeProfileStore.activeProfileKey: 'corrupt-theme',
        });

        final first = await store.load();
        final second = await ThemeProfileStore(prefs).load();

        expect(first.activeProfileId, 'console');
        expect(first.customProfiles, isEmpty);
        expect(first.quarantinedPayload, contains('var(--remote)'));
        expect(second.activeProfileId, 'console');
        expect(second.customProfiles, isEmpty);
        expect(second.quarantinedPayload, first.quarantinedPayload);
      },
    );

    test('never quarantines operational or secret-bearing keys', () async {
      final document = validThemeDocument();
      final profile = document['profile'] as Map<String, dynamic>;
      final metadata = profile['metadata'] as Map<String, dynamic>;
      metadata['authorization'] = 'Bearer private';
      final (prefs, store) = await _newStore({
        ThemeProfileStore.customProfilesKey: jsonEncode([document]),
      });

      final snapshot = await store.load();

      expect(snapshot.customProfiles, isEmpty);
      expect(snapshot.quarantinedPayload, isNull);
      expect(prefs.getString(ThemeProfileStore.quarantineKey), isNull);
    });

    test(
      'quarantine key scanning does not censor ordinary visible words',
      () async {
        const malformed = 'not JSON, for host operators and path lovers';
        final (_, store) = await _newStore({
          ThemeProfileStore.customProfilesKey: malformed,
        });

        final snapshot = await store.load();

        expect(snapshot.quarantinedPayload, malformed);
      },
    );

    test(
      'preserves a bounded future schema without quarantine or rewrite',
      () async {
        final future = validThemeDocument()..['schema_version'] = 2;
        final raw = ' [ ${jsonEncode(future)} ] ';
        final (prefs, store) = await _newStore({
          ThemeProfileStore.customProfilesKey: raw,
          ThemeProfileStore.schemaVersionKey: 1,
          ThemeProfileStore.activeProfileKey:
              (future['profile'] as Map<String, dynamic>)['id'] as String,
        });

        final snapshot = await store.load();

        expect(snapshot.hasFutureSchema, isTrue);
        expect(snapshot.customProfiles, isEmpty);
        expect(snapshot.activeProfileId, 'console');
        expect(snapshot.quarantinedPayload, isNull);
        expect(prefs.getString(ThemeProfileStore.customProfilesKey), raw);
      },
    );
  });

  group('ThemeProfileStore collisions and limits', () {
    test(
      'handles identical, id, name and builtin collisions deterministically',
      () async {
        final (_, store) = await _newStore(
          {},
          generatedIds: [
            'generated-id-collision',
            'generated-builtin-collision',
          ],
        );
        final originalRaw = validThemeJson(id: 'import-id', name: 'Imported');

        final first = await store.importProfile(originalRaw);
        final identical = await store.importProfile(originalRaw);

        final changed = validThemeDocument(id: 'import-id', name: 'Imported');
        final changedMetadata =
            ((changed['profile'] as Map<String, dynamic>)['metadata']
                as Map<String, dynamic>);
        changedMetadata['description'] = 'Different body';
        final idCollision = await store.importProfile(jsonEncode(changed));

        final sameName = await store.importProfile(
          validThemeJson(id: 'different-id', name: 'Imported'),
        );
        final builtinCollision = await store.importProfile(
          validThemeJson(id: 'amber', name: 'Builtin collision'),
        );

        expect(first.status, ThemeImportStatus.added);
        expect(identical.status, ThemeImportStatus.alreadyImported);
        expect(idCollision.profile.id, 'generated-id-collision');
        expect(idCollision.profile.name, 'Imported (2)');
        expect(sameName.profile.id, 'different-id');
        expect(sameName.profile.name, 'Imported (3)');
        expect(builtinCollision.profile.id, 'generated-builtin-collision');
        expect(
          store.load().then((value) => value.customProfiles.length),
          completion(4),
        );
      },
    );

    test(
      'enforces 16 profiles and allows only explicit replacement at the limit',
      () async {
        final (_, store) = await _newStore({});
        for (
          var index = 0;
          index < ThemeProfileStore.maxCustomProfiles;
          index++
        ) {
          await store.save(
            validCustomTheme(id: 'theme-$index', name: 'Theme $index'),
          );
        }

        await expectLater(
          store.save(validCustomTheme(id: 'overflow', name: 'Overflow')),
          throwsA(_storeError('profile_limit')),
        );
        await expectLater(
          store.save(
            validCustomTheme(id: 'replacement-body', name: 'Replacement'),
            replaceId: 'missing-target',
          ),
          throwsA(_storeError('replace_target_missing')),
        );

        final replacement = await store.save(
          validCustomTheme(id: 'replacement-body', name: 'Replacement'),
          replaceId: 'theme-0',
        );
        final snapshot = await store.load();

        expect(replacement.id, 'theme-0');
        expect(
          snapshot.customProfiles.length,
          ThemeProfileStore.maxCustomProfiles,
        );
        expect(snapshot.customById('theme-0')?.name, 'Replacement');
        expect(snapshot.customById('replacement-body'), isNull);
      },
    );

    test(
      'an import at the limit replaces only an explicitly selected target',
      () async {
        final (_, store) = await _newStore({});
        for (
          var index = 0;
          index < ThemeProfileStore.maxCustomProfiles;
          index++
        ) {
          await store.save(
            validCustomTheme(id: 'theme-$index', name: 'Theme $index'),
          );
        }

        await expectLater(
          store.importProfile(validThemeJson(id: 'new-id', name: 'New theme')),
          throwsA(_storeError('profile_limit')),
        );
        final result = await store.importProfile(
          validThemeJson(id: 'new-id', name: 'New theme'),
          replaceId: 'theme-7',
        );

        expect(result.status, ThemeImportStatus.replaced);
        expect(result.profile.id, 'theme-7');
        expect((await store.load()).customProfiles.length, 16);
      },
    );
  });

  group('ThemeProfileStore activation and component profile', () {
    test('saves a contrast-invalid draft but refuses to activate it', () async {
      final (_, store) = await _newStore({});
      final original = validCustomTheme(id: 'draft-theme', draft: true);
      final draft = original.copyWith(
        palette: original.palette.copyWith(
          accentText: original.palette.background,
        ),
      );

      await store.save(draft);

      await expectLater(
        store.activate(draft.id),
        throwsA(_storeError('profile_not_activatable')),
      );
      expect((await store.load()).activeProfileId, 'console');
    });

    test(
      'deleting the active custom profile falls back to the default',
      () async {
        final (prefs, store) = await _newStore({});
        final profile = validCustomTheme(id: 'active-theme');
        await store.save(profile);
        await store.activate(profile.id);

        await store.delete(profile.id);

        final snapshot = await store.load();
        expect(snapshot.activeProfileId, 'console');
        expect(snapshot.customProfiles, isEmpty);
        expect(prefs.getString(ThemeProfileStore.activeProfileKey), 'console');
        expect(prefs.getString(ThemeProfileStore.legacyThemeKey), 'console');
      },
    );

    test('migrates legacy component preferences to unified minimal', () async {
      for (final legacy in ['terminal', 'future-components']) {
        final (prefs, store) = await _newStore({
          ThemeProfileStore.activeComponentProfileKey: legacy,
        });

        final snapshot = await store.load();

        expect(snapshot.activeComponentProfileId, 'minimal');
        expect(
          prefs.getString(ThemeProfileStore.activeComponentProfileKey),
          'minimal',
        );
      }
    });

    test(
      'activating saved themes never restores embedded component skins',
      () async {
        final (prefs, store) = await _newStore({});
        final soft = validCustomTheme(
          id: 'soft-theme',
          name: 'Soft theme',
        ).copyWith(componentProfileId: 'soft');
        final terminal = validCustomTheme(
          id: 'terminal-theme',
          name: 'Terminal theme',
        ).copyWith(componentProfileId: 'terminal');
        await store.save(soft);
        await store.save(terminal);

        await store.activate(soft.id);
        expect((await store.load()).activeComponentProfileId, 'minimal');

        await store.activate(terminal.id);
        final restarted = await ThemeProfileStore(prefs).load();
        expect(restarted.activeProfileId, terminal.id);
        expect(restarted.activeComponentProfileId, 'minimal');
        expect(
          prefs.getString(ThemeProfileStore.activeComponentProfileKey),
          'minimal',
        );
      },
    );

    test(
      'builtin palette changes also keep the unified minimal style',
      () async {
        final (_, store) = await _newStore({
          ThemeProfileStore.activeComponentProfileKey: 'soft',
        });

        await store.activate('steel-light');

        final snapshot = await store.load();
        expect(snapshot.activeProfileId, 'steel-light');
        expect(snapshot.activeComponentProfileId, 'minimal');
      },
    );
  });

  group('ThemeProfileStore 1.2.15 removed themes', () {
    const removed = {
      'amber-oled': 'amber',
      'crimson': 'bordeaux',
      'hermes-console': 'slate',
      'mocha': 'catppuccin-dark',
      'phosphor': 'cyberpunk',
      'graphite': 'mono',
    };

    removed.forEach((stored, target) {
      test('$stored is migrated to $target once and persisted', () async {
        final (prefs, store) = await _newStore({
          ThemeProfileStore.activeProfileKey: stored,
          ThemeProfileStore.legacyThemeKey: stored,
        });

        final snapshot = await store.load();

        expect(snapshot.activeProfileId, target);
        expect(prefs.getString(ThemeProfileStore.activeProfileKey), target);
        expect(prefs.getString(ThemeProfileStore.legacyThemeKey), target);

        // A restart reads the migrated id as-is.
        final restarted = await ThemeProfileStore(prefs).load();
        expect(restarted.activeProfileId, target);
      });
    });

    test('a removed id kept only in the legacy key is migrated too', () async {
      final (prefs, store) = await _newStore({
        ThemeProfileStore.legacyThemeKey: 'crimson',
      });

      final snapshot = await store.load();

      expect(snapshot.activeProfileId, 'bordeaux');
      expect(prefs.getString(ThemeProfileStore.activeProfileKey), 'bordeaux');
      expect(prefs.getString(ThemeProfileStore.legacyThemeKey), 'bordeaux');
    });

    test('an unknown id falls back to the default without throwing', () async {
      final (prefs, store) = await _newStore({
        ThemeProfileStore.activeProfileKey: 'no-such-theme',
      });

      final snapshot = await store.load();

      expect(snapshot.activeProfileId, 'console');
      expect(prefs.getString(ThemeProfileStore.activeProfileKey), 'console');
    });

    test(
      'a custom theme derived from a removed preset keeps working',
      () async {
        final document = validThemeDocument(id: 'from-crimson');
        final profile = document['profile'] as Map<String, dynamic>;
        profile['base_preset_id'] = 'crimson';
        final (prefs, store) = await _newStore({
          ThemeProfileStore.customProfilesKey: jsonEncode([document]),
          ThemeProfileStore.schemaVersionKey: 1,
          ThemeProfileStore.activeProfileKey: 'from-crimson',
        });

        final snapshot = await store.load();

        expect(snapshot.activeProfileId, 'from-crimson');
        expect(snapshot.customById('from-crimson')?.basePresetId, 'crimson');
        expect(
          prefs.getString(ThemeProfileStore.activeProfileKey),
          'from-crimson',
        );
      },
    );
  });

  group('default theme for new installs (1.2.15)', () {
    test('an install that never chose a theme gets Console', () async {
      final (prefs, store) = await _newStore({});

      final snapshot = await store.load();

      expect(snapshot.activeProfileId, 'console');
      // Nothing is written: the default stays a default, so a later default
      // change can still reach installs that never chose.
      expect(prefs.getString(ThemeProfileStore.activeProfileKey), isNull);
      expect(prefs.getString(ThemeProfileStore.legacyThemeKey), isNull);
    });

    test('a saved Amber choice is kept (never moved to Console)', () async {
      for (final values in <Map<String, Object>>[
        {ThemeProfileStore.activeProfileKey: 'amber'},
        {ThemeProfileStore.legacyThemeKey: 'amber'},
        {
          ThemeProfileStore.activeProfileKey: 'amber',
          ThemeProfileStore.legacyThemeKey: 'amber',
        },
      ]) {
        final (prefs, store) = await _newStore(values);
        expect(
          (await store.load()).activeProfileId,
          'amber',
          reason: '$values',
        );
        expect(
          prefs.getString(ThemeProfileStore.activeProfileKey),
          values[ThemeProfileStore.activeProfileKey],
        );
      }
    });
  });
}
