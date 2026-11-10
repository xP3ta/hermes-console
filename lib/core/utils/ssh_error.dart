import '../../l10n/app_localizations.dart';
import '../services/ssh_dashboard_tunnel.dart';
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
      SshFailure.hostKeyRejected => strings.sshHostKeyRejected,
      SshFailure.permissionDenied => strings.sshPermissionDenied,
      SshFailure.noSuchFile => strings.sshNoSuchFile,
      SshFailure.unknown => strings.sshConnError,
    };

/// Localized text for any error raised while connecting over SSH/SFTP. Raw
/// exception text is never shown.
String localizedSshError(Strings strings, Object error) =>
    localizedSshFailure(strings, SshManager.classifyError(error));

/// Localized text for a failure while opening the Dashboard tunnel.
String localizedTunnelError(Strings strings, Object error) {
  if (error is SshTunnelException) {
    return switch (error.failure) {
      SshTunnelFailure.dashboardRefused => strings.sshTDashboardRefused,
      SshTunnelFailure.publicKey => strings.sshTPublicKey,
      SshTunnelFailure.passphraseNeeded => strings.sshTPassphraseNeeded,
      SshTunnelFailure.otherAddress => strings.sshTOtherAddress,
      SshTunnelFailure.ssh => _tunnelSsh(strings, error.ssh),
    };
  }
  return _tunnelSsh(strings, SshManager.classifyError(error));
}

String _tunnelSsh(Strings strings, SshFailure? failure) =>
    failure == SshFailure.hostLookup
    ? strings.sshTServerNotFound
    : localizedSshFailure(strings, failure ?? SshFailure.unknown);
