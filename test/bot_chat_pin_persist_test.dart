import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

void main() {
  test('pin persist stays fail-closed only for Desktop slot conflicts', () {
    expect(
      botChatPinPersistIsAuthoritativeConflict(
        const TuiGatewayRpcError(
          'profiles.configure',
          'Canonical Bot Chat pin changed concurrently',
        ),
      ),
      isTrue,
    );
    expect(
      botChatPinPersistIsAuthoritativeConflict(
        const TuiGatewayRpcError(
          'profiles.configure',
          'Canonical Bot Chat pin is malformed',
        ),
      ),
      isTrue,
    );
    expect(
      botChatPinPersistIsAuthoritativeConflict(
        const TuiGatewayRpcError(
          'session.title',
          'Hermes did not persist the canonical Bot Chat row',
        ),
      ),
      isFalse,
    );
    expect(
      botChatPinPersistIsAuthoritativeConflict(
        const TuiGatewayRpcError(
          'profiles.configure',
          'Hermes did not persist the canonical Bot Chat pin',
          code: -32601,
        ),
      ),
      isFalse,
    );
  });
}
