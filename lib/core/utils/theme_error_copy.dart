import '../../l10n/app_localizations.dart';

/// Theme services keep stable diagnostic codes; screens own translated copy.
/// Field paths and codes are technical identifiers, not English UI sentences.
String themeErrorCopy(Strings strings, String code, {String field = ''}) =>
    switch (code) {
      'payload_too_large' => strings.i18n131P6ThemeTooLarge,
      'invalid_utf8' => strings.themesInvalidUtf8,
      'unsupported_schema' => strings.themesFutureSchema,
      'file_unreadable' => strings.i18n131P6ThemeUnreadable,
      'builtin_immutable' ||
      'builtin_export_requires_copy' ||
      'builtin_delete' => strings.i18n131P6ThemeBuiltin,
      'profile_missing' ||
      'replace_target_missing' => strings.i18n131P6ThemeMissing,
      'profile_limit' => strings.themesLimitTitle,
      'profile_not_activatable' => strings.themesUnsafeContrast,
      'invalid_profile' => strings.themesInvalidFields,
      'id_collision' => strings.i18n131P6ThemeIdFailed,
      _ => strings.i18n131P6ThemeFieldError(
        field.isEmpty ? 'JSON' : field,
        code,
      ),
    };
