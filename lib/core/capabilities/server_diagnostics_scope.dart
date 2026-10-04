import '../services/connection_manager.dart';

/// What orders the launches of doctor and the audit: the Dashboard endpoint
/// (scheme, host, port, path) and the profile, not the saved connection. Two
/// saved connections that reach the same Dashboard share it. Credentials,
/// query and fragment of the URL never take part.
String diagnosticsLaunchScope(SavedConnection connection, String profile) {
  final uri = Uri.tryParse(connection.effectiveDashboardUrl);
  final String endpoint;
  if (uri == null || uri.host.isEmpty) {
    endpoint = '${connection.host.toLowerCase()}:${connection.port}';
  } else {
    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    endpoint =
        '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:${uri.port}$path';
  }
  final owner = profile.trim().isEmpty ? 'default' : profile.trim();
  return '$endpoint|$owner';
}
