# Translation workflow

`app_es.arb` is the authoritative template. Use `app_en.arb` to clarify
terminology, but check Spanish when their meanings differ. Translate only the
approved languages: Chinese, Brazilian Portuguese, German, French, Japanese,
Italian and Korean. Do not add Russian or change store listings here.

## Prepare a catalog

1. Start from the current template message keys, excluding `@` metadata keys.
   Never reuse an older draft based only on its total message count. Check
   missing and extra keys and review shared messages for changed meanings.
2. Write UTF-8 `lib/l10n/app_<locale>.arb`, including `@@locale`. For Brazilian
   Portuguese use `app_pt_BR.arb` and `"@@locale": "pt_BR"`; Flutter uses an
   underscore in ARB locale IDs. Use `zh`, `de`, `fr`, `ja`, `it` and `ko` for
   the other approved catalogs. The original template supplies placeholder
   types; translated catalogs need not duplicate its metadata.
3. Translate complete messages in small batches. Keep terminology consistent,
   preserve placeholders exactly, and retain the ICU argument types and all
   `select` cases. Every plural needs `other`. Chinese, Japanese and Korean
   use only `other`; rewrite the message naturally rather than keeping an
   English singular branch. Other languages may use their applicable ICU
   plural categories. Keep newlines, backticks, brand names, commands, URLs
   and technical identifiers intact. Do not change security or product claims.
4. Check each batch and finish the entire catalog. Do not fill missing keys
   with English just to obtain a passing key count. Treat all generated
   translations as automatic drafts until a native speaker has reviewed them.

## Validate

Run from the repository root (Python standard library only):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tool/l10n -p 'test_translate_check.py'
PYTHONDONTWRITEBYTECODE=1 python3 tool/l10n/mutation_check.py
PYTHONDONTWRITEBYTECODE=1 python3 tool/l10n/translate_check.py lib/l10n/app_zh.arb
PYTHONDONTWRITEBYTECODE=1 python3 tool/l10n/translate_check.py lib/l10n/app_pt_BR.arb lib/l10n/app_de.arb lib/l10n/app_fr.arb lib/l10n/app_ja.arb lib/l10n/app_it.arb lib/l10n/app_ko.arb
```

The checker rejects duplicate JSON keys, non-object catalogs, locale/filename
mismatches, missing/extra keys, non-string messages, malformed ICU, changed
argument names/types or structural occurrence counts, missing `other`, repeated/invalid plural selectors,
changed `select` cases, non-`other` CJK plurals, newline/backtick count changes,
and removal of the protected brands listed in `BRANDS`. Extend that list when
the product adopts another brand. The mutation script disables one guard at a
time in memory and requires the contract tests to detect every mutation.

This checker deliberately handles the unescaped ICU subset currently used
by the app. It is not Flutter's parser. It cannot verify translation quality,
commands/URLs/code semantics, correctness of security claims, every brand,
or whether a shared key's source meaning changed. A passing catalog still
needs source review, native review and Flutter checks.

The current only-`other` CJK rule can lose count-specific meaning from the
source, such as the incomplete-team qualifier in `roomAvatarMembers` for one
member. Flag such cases for an explicit source/ICU decision; do not turn a
conditional warning into an unconditional statement to make a check pass.

The base English catalog predates the stricter ICU-type rule: twelve existing
messages use plain arguments where Spanish uses plurals. This lane leaves the
template and English unchanged. Validate the new catalogs explicitly rather
than claiming that all historical catalogs satisfy the new structural rule.

When Flutter is available, the coordinator must run:

```sh
flutter gen-l10n
flutter test test/app_locale_selector_test.dart test/l10n_catalog_parity_test.dart test/l10n_no_duplicate_keys_test.dart
```

Do not install Flutter if absent. Record checks as not verified and hand off
the local commit. Generated `app_localizations*.dart` files are not committed.
The coordinator owns full suites, builds and device checks. Verify the native
language label in Settings, manual selection, persistence, system language,
English fallback and regional matching, especially `pt_BR` and Chinese.

## Text outside ARB

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tool/l10n/inventory_non_arb.py
```

The inventory reports literal `_text(es, en)` calls and other helpers with
Spanish/English parameters, common language-flag conditionals and literal UI
arguments. It ignores comments and generated
localization files. Counts are candidates, not an exhaustive Dart semantic
analysis: indirect bilingual copy classes, computed getters and custom
widgets need manual review. Some
candidates are intentional technical names or symbols. Text outside ARB
will retain its existing Spanish/English behavior; migrating it is a separate
task. Do not silently expand this lane's scope to change those screens.

Notifications (`NotifL10n`) and voice language selection (`effectiveVoiceLang`)
also have separate Spanish/English logic. Adding an ARB catalog does not add
notification translations or recognition/synthesis language support there.

Keep changes local and stage only explicit owned paths. Do not publish,
contact services or people, access production/mobile/credentials, or alter
the template's message keys without separate authorization.
