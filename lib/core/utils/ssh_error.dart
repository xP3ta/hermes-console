import '../../l10n/app_localizations.dart';
import '../services/ssh_manager.dart';

/// Localized, user-facing text for a typed SSH failure.
String localizedSshFailure(Strings strings, SshFailure failure) =>
    switch (failure) {
      SshFailure.notConfigured => strings.i18n1215SshNotConfigured,
      SshFailure.missingHost => strings.i18n1215SshMissingHost,
      SshFailure.missingUser => strings.i18n1215SshMissingUser,
      SshFailure.emptyKey => strings.sshcPasteKey,
      SshFailure.noKeyFound => strings.i18n1215SshNoKeyFound,
      SshFailure.wrongPassphrase => strings.i18n1215SshWrongPassphrase,
      SshFailure.unrecognizedKey => strings.i18n1215SshUnrecognizedKey,
      SshFailure.invalidKey => strings.i18n1215SshInvalidKey,
      SshFailure.authRejected => strings.i18n1215SshAuthRejected,
      SshFailure.handshakeFailed => strings.i18n1215SshHandshakeFailed,
      SshFailure.refused => strings.i18n1215SshRefused,
      SshFailure.timeout => strings.i18n1215SshTimeout,
      SshFailure.hostLookup => strings.i18n1215SshHostLookup,
      SshFailure.unknown => strings.sshConnError,
    };

/// Localized text for any error raised while connecting over SSH/SFTP. Raw
/// exception text is never shown.
String localizedSshError(Strings strings, Object error) =>
    localizedSshFailure(strings, SshManager.classifyError(error));
