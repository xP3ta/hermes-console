import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';

import '../companion/models/companion.dart';
import 'agent_profile.dart';

enum ProfileIdentityKind { pet, image, face }

/// What was read for one profile: whether the answer is known at all (a
/// profile without a pet is a known answer) and the pet when it has one.
typedef ProfileIdentityRead = ({bool known, Companion? pet});

/// THE source of a profile's pet identity, for every surface that draws a
/// profile (Home, Bots, the switcher, the chat island, room members). It
/// holds what the profile's own stores say (the server's `pet.info` for that
/// profile, and the copy of its last answer kept on this device), and never
/// the app's floating pet nor the device record Mascotas used to write.
/// Reading is synchronous; the reads start after paint.
final class ProfileIdentities extends ChangeNotifier {
  static final instance = ProfileIdentities();
  String? Function()? connectionId;

  /// Last answer kept on this device: local only, no network.
  Future<ProfileIdentityRead> Function(String connection, String profile)?
  cacheReader;

  /// The profile's server answer (falls back to the device copy offline).
  Future<ProfileIdentityRead> Function(String connection, String profile)?
  loader;
  final Map<(String, String), Companion> _pets = {};
  final Set<(String, String)> _known = {};
  final Set<(String, String)> _asked = {};
  final Map<(String, String), int> _epochs = {};
  final Queue<(String, String)> _queue = Queue();
  int _loading = 0;

  static String owner(String name) =>
      name.trim().isEmpty ? 'default' : name.trim();

  String _connection(String? connection) =>
      connection ?? connectionId?.call() ?? '';

  Companion? pet(String? connection, String name) =>
      _pets[(_connection(connection), owner(name))];

  /// Whether the profile's pet answer (even "none") has been read from the
  /// device copy or the server, or the attempt has ended. Until then a
  /// surface draws nothing for the profile rather than a stand-in. Without
  /// a reader wired nothing is ever pending.
  bool isKnown(String? connection, String name) =>
      loader == null || _known.contains((_connection(connection), owner(name)));

  void requestAfterPaint(String? connection, String name) {
    final id = _connection(connection);
    if (id.isEmpty || loader == null) return;
    final key = (id, owner(name));
    if (!_asked.add(key)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_asked.contains(key)) return;
      _queue.add(key);
      _pump();
    });
  }

  void _pump() {
    final read = loader;
    if (read == null) return;
    while (_loading < 2 && _queue.isNotEmpty) {
      final key = _queue.removeFirst();
      final epoch = _epochs[key] ?? 0;
      _loading++;
      unawaited(() async {
        try {
          final cached = cacheReader;
          if (cached != null && !_known.contains(key)) {
            final local = await cached(key.$1, key.$2);
            if ((_epochs[key] ?? 0) == epoch &&
                _asked.contains(key) &&
                local.known) {
              publish(key.$1, key.$2, local.pet);
            }
          }
          final answer = await read(key.$1, key.$2);
          if ((_epochs[key] ?? 0) == epoch &&
              _asked.contains(key) &&
              answer.known) {
            publish(key.$1, key.$2, answer.pet);
          }
        } catch (_) {
          // Cosmetic reads fail to the identity already known.
        } finally {
          // Settled: whatever could be read has been; a surface waiting for
          // it stops waiting (a profile whose answer could not be read draws
          // as one with no pet).
          if (_known.add(key)) notifyListeners();
          _loading--;
          _pump();
        }
      }());
    }
  }

  /// A profile's identity may have changed (it was edited, the server said
  /// so): every profile of [connection] already asked about is read again.
  void refresh(String connection) {
    for (final key in _asked.where((key) => key.$1 == connection).toList()) {
      _epochs[key] = (_epochs[key] ?? 0) + 1;
      _queue.add(key);
    }
    _pump();
  }

  /// A profile's identity, as just read. [pet] null means it has none.
  void publish(String connection, String name, Companion? pet) {
    final key = (connection, owner(name));
    final changed = !identical(_pets[key], pet) || !_known.contains(key);
    _known.add(key);
    if (pet == null) {
      _pets.remove(key);
    } else {
      _pets[key] = pet;
    }
    if (changed) notifyListeners();
  }

  /// The app is going away: no more reads, and nothing stays published.
  void detach() {
    _asked.clear();
    _queue.clear();
    _epochs.clear();
    loader = null;
    cacheReader = null;
    connectionId = null;
  }

  @visibleForTesting
  void reset() {
    _pets.clear();
    _known.clear();
    detach();
  }
}

/// One priority on every profile surface: its own pet, then its image,
/// then its configured face. Desktop's shape backfill is never a photo.
({ProfileIdentityKind kind, Companion? pet}) profileIdentityFor({
  required String profileName,
  String? connectionId,
  AgentProfile? profile,
  bool? hasAvatar,
  String? imageKind,
  String? shape,
}) {
  final pet = ProfileIdentities.instance.pet(connectionId, profileName);
  if (pet != null && pet.isValid) {
    return (kind: ProfileIdentityKind.pet, pet: pet);
  }
  final image =
      profile?.botPaintsPhoto ??
      ((hasAvatar ?? false) &&
          imageKind != 'shape' &&
          (imageKind == 'photo' || shape == null));
  return (
    kind: image ? ProfileIdentityKind.image : ProfileIdentityKind.face,
    pet: null,
  );
}
