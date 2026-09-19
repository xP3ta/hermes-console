import 'dart:io';
import '../models/hosted_groups.dart';
import 'bot_profile_client.dart';

abstract interface class BotRoomLinkGateway {
  Future<Map<String, dynamic>> roomLinkRequest(
    String method,
    Map<String, dynamic> params,
  );
}

/// Scoped grants remain in memory until registered on the room's authority.
final class BotRoomLink {
  final BotProfileRpc home;
  BotRoomLink(this.home);

  static Map<String, dynamic>? catalog(
    Map<String, dynamic> capabilities,
    String profile,
  ) {
    final link = capabilities['room_link'];
    if (link is! Map || link['enabled'] != true || link['profile'] != profile) {
      return null;
    }
    final raw = link['catalog'];
    if (raw is! Map) return null;
    final catalog = Map<String, dynamic>.from(raw);
    final endpoint = catalog['endpoint'];
    final policy = catalog['execution_policy'];
    if (catalog['text'] != true ||
        catalog['persistent_process'] != true ||
        catalog['link_modes'] is! List ||
        !(catalog['link_modes'] as List).contains('direct') ||
        endpoint is! Map ||
        endpoint['available'] != true ||
        endpoint['url'] is! String ||
        policy is! Map ||
        policy['target_profile'] != profile ||
        catalog['installation_id'] is! String ||
        catalog['catalog_digest'] is! String) {
      return null;
    }
    final uri = Uri.tryParse(endpoint['url'] as String);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final loopback =
        uri.host == 'localhost' ||
        uri.host.endsWith('.localhost') ||
        InternetAddress.tryParse(uri.host)?.isLoopback == true;
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) {
      return null;
    }
    if (catalog['protocol_versions'] is! List ||
        !(catalog['protocol_versions'] as List).contains(2) ||
        !RegExp(
          r'^[a-f0-9]{64}$',
        ).hasMatch(catalog['catalog_digest'] as String)) {
      return null;
    }
    return catalog;
  }

  Future<void> attach({
    required HostedGroupRoom room,
    required String memberId,
    required String profile,
    required BotProfileRpc target,
    required Map<String, dynamic> expectedCatalog,
  }) async {
    final capabilities = await home('groups.capabilities', {});
    final methods = capabilities['methods'];
    if (capabilities['driver'] != true ||
        methods is! List ||
        !methods.contains('groups.peer.register') ||
        capabilities['authority_gateway_id'] != room.authorityGatewayId) {
      throw StateError('Room linking unavailable');
    }
    final remote = await target('groups.capabilities', {'profile': profile});
    final fresh = catalog(remote, profile);
    if (fresh == null ||
        fresh['catalog_digest'] != expectedCatalog['catalog_digest'] ||
        remote['methods'] is! List ||
        !(remote['methods'] as List).contains('groups.peer.invite')) {
      throw StateError('Room peer changed');
    }
    final result = await target('groups.peer.invite', {
      'profile': profile,
      'room_id': room.roomId,
      'member_id': memberId,
      'home_install_id': room.authorityGatewayId,
      'authority_gateway_id': room.authorityGatewayId,
      'authority_epoch': room.authorityEpoch,
    });
    final grant = result['grant'];
    final offered = result['catalog'];
    if (grant is! String || grant.isEmpty) {
      throw StateError('Room grant unavailable');
    }
    try {
      if (offered is! Map ||
          offered['catalog_digest'] != fresh['catalog_digest'] ||
          result['target_profile'] != profile) {
        throw StateError('Room grant catalog changed');
      }
      final registered = await home('groups.peer.register', {
        'room_id': room.roomId,
        'member_id': memberId,
        'target_profile': profile,
        'catalog': fresh,
        'grant': grant,
        'target_url': (fresh['endpoint'] as Map)['url'],
      });
      if (registered['registered'] != true ||
          registered['target_profile'] != profile ||
          registered['target_install_id'] != fresh['installation_id']) {
        throw StateError('Room route unconfirmed');
      }
    } catch (_) {
      // Revoke an unconfirmed route instead of leaving an unnoticed execution grant.
      try {
        await target('groups.peer.revoke', {
          'profile': profile,
          'grant': grant,
        });
      } catch (_) {}
      rethrow;
    }
  }
}
