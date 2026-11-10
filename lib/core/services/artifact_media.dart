import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'connection_manager.dart';
import 'generated_media_service.dart';

/// Brings a user attachment of a conversation (an `@image:`/`@file:` path on
/// the Hermes machine, or an `https` source) into the app-private media
/// cache, by the route the chat's own media uses: the Dashboard's
/// managed-files download, and `/api/media` for an image outside the managed
/// root (Hermes' images, screenshots and cache roots). The cache keeps the
/// per-kind byte limits and its total cap.
///
/// [fetchServerPath] replaces the network for a server path (tests).
Future<File> downloadUserServerMedia({
  required SavedConnection connection,
  required String profile,
  required GeneratedMediaReference reference,
  Future<void> Function(String path, File destination)? fetchServerPath,
}) {
  final maxBytes = reference.kind == GeneratedMediaKind.image
      ? GeneratedMediaService.maxImageBytes
      : GeneratedMediaService.maxFileBytes;
  return GeneratedMediaService.ensureDownloaded(
    '${connection.id}\u0000$profile',
    reference,
    fetchServerPathToFile: (path, destination) async {
      if (fetchServerPath != null) return fetchServerPath(path, destination);
      final client = DashboardClient.lazy(connection);
      try {
        await client.apiDownloadToFile(
          'files/download?path=${Uri.encodeQueryComponent(path)}',
          destination,
          maxBytes: maxBytes,
          profile: profile,
        );
      } on DashboardHttpException catch (error) {
        if (reference.kind != GeneratedMediaKind.image ||
            (error.statusCode != 400 && error.statusCode != 403)) {
          rethrow;
        }
        final media = await client.apiGet(
          'media?path=${Uri.encodeQueryComponent(path)}',
        );
        final dataUrl = media['data_url'];
        final data = dataUrl is String && dataUrl.startsWith('data:')
            ? Uri.tryParse(dataUrl)?.data
            : null;
        if (data == null || !data.isBase64) rethrow;
        await destination.writeAsBytes(data.contentAsBytes(), flush: true);
      } finally {
        client.close();
      }
    },
  );
}

/// Why an item of «Artefactos» could not be shown or opened, so the view can
/// say it instead of a bare «Sin vista previa».
enum ArtifactFetchProblem {
  /// An `https` image or file the phone could not download (the site
  /// refused it, sent something else, or did not answer in time).
  remote,

  /// A plain `http:` address: the app only fetches over TLS.
  insecure,

  /// A path relative to a conversation's folder, and that folder is not
  /// known (no conversation, or the conversation has no working folder).
  noFolder,

  /// The Hermes machine has no such file (moved, deleted, never written).
  notFound,

  /// Larger than what the app previews or keeps.
  tooLarge,

  /// Hermes refuses to read it (a sensitive file, outside what may be read).
  denied,

  /// Not something the app reads: another scheme, credentials in the URL,
  /// a sensitive name or path, a request Hermes turned down as invalid.
  unsupported,

  /// Hermes did not answer: the server is down, unreachable or failing
  /// (5xx), or the connection broke.
  unreachable,

  /// The download did not finish in time.
  timedOut,

  /// What arrived is not a picture (an «image» whose content is text).
  notImage,

  /// It looks like a picture but cannot be drawn (damaged, unknown format).
  undecodable,

  /// Anything else: the download broke for a reason the app cannot name.
  failed,
}

/// Total time an «Artefactos» download may take, body included: a minute,
/// plus a second per 256 KiB it may carry (about 2 Mbit/s). A server or
/// host that trickles bytes frees its slot instead of holding it forever.
Duration artifactDownloadDeadline(int maxBytes) =>
    Duration(seconds: 60 + maxBytes ~/ (256 * 1024));

class ArtifactFetchFailure implements Exception {
  const ArtifactFetchFailure(this.problem);

  final ArtifactFetchProblem problem;

  @override
  String toString() => 'ArtifactFetchFailure(${problem.name})';
}

/// The conversation an item came from, as Desktop's `GatewayFileOrigin`:
/// its profile and its session, whose folder a relative path is resolved
/// against.
class ArtifactOwner {
  const ArtifactOwner({required this.profile, this.sessionId});

  final String profile;
  final String? sessionId;
}

/// What [value] is, or why the app will not fetch it.
GeneratedMediaReference artifactReferenceOrThrow(String value) {
  final reference = GeneratedMediaService.artifactReference(value);
  if (reference != null) return reference;
  final lower = value.trim().toLowerCase();
  throw ArtifactFetchFailure(
    lower.startsWith('http:')
        ? ArtifactFetchProblem.insecure
        : ArtifactFetchProblem.unsupported,
  );
}

bool _isAbsoluteServerPath(String value) =>
    value.startsWith('/') ||
    value.startsWith('~') ||
    value.toLowerCase().startsWith('file:') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
    value.startsWith(r'\\');

/// Brings an item of «Artefactos» into the app-private media cache the way
/// Hermes Desktop saves it (`saveGatewayFile`): `GET /api/fs/download` with
/// `path`, `profile` and `session_id`, which resolves `~` and a relative
/// path against that session's folder and applies Hermes' read guards. An
/// `https` source is fetched by the phone, following redirects to other
/// `https` hosts as a browser image does. The cache keeps its per-kind byte
/// limits and total cap.
///
/// Throws [ArtifactFetchFailure] with the reason. [fetchServerPath] and
/// [baseDir] replace the network and the cache root (tests).
Future<File> fetchArtifactMedia({
  required SavedConnection connection,
  required ArtifactOwner owner,
  required GeneratedMediaReference reference,
  Future<void> Function(Uri request, File destination)? fetchServerPath,
  Directory? baseDir,
}) async {
  final https = reference.sourceKind == GeneratedMediaSourceKind.https;
  final trimmed = owner.sessionId?.trim();
  // A blank id is no session: it is not sent at all.
  final session = trimmed == null || trimmed.isEmpty ? null : trimmed;
  final hasSession = session != null;
  if (!https && !_isAbsoluteServerPath(reference.source) && !hasSession) {
    throw const ArtifactFetchFailure(ArtifactFetchProblem.noFolder);
  }
  final maxBytes = switch (reference.kind) {
    GeneratedMediaKind.image => GeneratedMediaService.maxImageBytes,
    GeneratedMediaKind.video => GeneratedMediaService.maxVideoBytes,
    GeneratedMediaKind.audio ||
    GeneratedMediaKind.file => GeneratedMediaService.maxFileBytes,
  };
  final deadline = artifactDownloadDeadline(maxBytes);
  // A relative path names a different file in each conversation.
  final scope = [
    connection.id,
    owner.profile,
    if (!https && !_isAbsoluteServerPath(reference.source)) session ?? '',
  ].join('\u0000');
  try {
    return await GeneratedMediaService.ensureDownloaded(
      scope,
      reference,
      baseDir: baseDir,
      followCrossOriginRedirects: true,
      deadline: deadline,
      fetchServerPathToFile: (path, destination) async {
        final request = Uri(
          path: 'fs/download',
          queryParameters: {'path': path, 'session_id': ?session},
        );
        if (fetchServerPath != null) {
          return fetchServerPath(request, destination);
        }
        final client = DashboardClient.lazy(connection);
        try {
          await client.apiDownloadToFile(
            request.toString(),
            destination,
            maxBytes: maxBytes,
            profile: owner.profile,
            deadline: deadline,
          );
        } finally {
          client.close();
        }
      },
    );
  } on ArtifactFetchFailure {
    rethrow;
  } catch (error) {
    throw ArtifactFetchFailure(artifactFetchProblemOf(error, https: https));
  }
}

/// The reason behind a failed «Artefactos» download, from what the
/// transport threw. [https] is a phone-side fetch from another host.
ArtifactFetchProblem artifactFetchProblemOf(
  Object error, {
  required bool https,
}) {
  // Hermes cannot resolve a relative path without the session's folder.
  if (error is DashboardHttpException &&
      error.statusCode == 400 &&
      error.body.contains('working directory')) {
    return ArtifactFetchProblem.noFolder;
  }
  final down = https
      ? ArtifactFetchProblem.remote
      : ArtifactFetchProblem.unreachable;
  return switch (error) {
    DashboardHttpException(statusCode: 404) => ArtifactFetchProblem.notFound,
    DashboardHttpException(statusCode: 413) => ArtifactFetchProblem.tooLarge,
    DashboardHttpException(statusCode: 401 || 403) =>
      ArtifactFetchProblem.denied,
    DashboardHttpException(statusCode: 400) => ArtifactFetchProblem.unsupported,
    DashboardHttpException(statusCode: 408 || 504) =>
      ArtifactFetchProblem.timedOut,
    DashboardHttpException(statusCode: >= 500) =>
      ArtifactFetchProblem.unreachable,
    TimeoutException() => ArtifactFetchProblem.timedOut,
    // apiDownloadToFile's byte cap.
    StateError(:final message) when message.contains('exceeds') =>
      ArtifactFetchProblem.tooLarge,
    // The media cache: over its cap, or bytes that are not the kind.
    FormatException(:final message) when message.contains('size limit') =>
      ArtifactFetchProblem.tooLarge,
    FormatException(:final message) when message.contains('signature') =>
      ArtifactFetchProblem.notImage,
    HttpException(:final message) when message.contains('too large') =>
      ArtifactFetchProblem.tooLarge,
    SocketException() || http.ClientException() || HttpException() => down,
    _ when https => ArtifactFetchProblem.remote,
    _ => ArtifactFetchProblem.failed,
  };
}
