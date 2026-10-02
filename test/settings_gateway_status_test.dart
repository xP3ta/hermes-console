import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  test('muestra únicamente el canal API usado por Hermes Console', () {
    final states = currentGatewayPlatformStates(<String, dynamic>{
      'gateway_updated_at': '2026-07-14T11:01:38.717051+00:00',
      'gateway_platforms': <String, dynamic>{
        'telegram': <String, dynamic>{
          'state': 'disconnected',
          'updated_at': '2026-07-14T11:01:28.631572+00:00',
        },
        'api_server': <String, dynamic>{
          'state': 'connected',
          'updated_at': '2026-07-14T11:01:38.715309+00:00',
        },
        'whatsapp': <String, dynamic>{
          'state': 'error',
          'updated_at': '2026-07-14T11:01:40Z',
        },
      },
    });

    expect(states, {'api_server': 'connected'});
  });

  test('no muestra conectores de terceros aunque su fallo sea actual', () {
    final states = currentGatewayPlatformStates(<String, dynamic>{
      'gateway_updated_at': '2026-07-14T11:01:38Z',
      'gateway_platforms': <String, dynamic>{
        'telegram': <String, dynamic>{
          'state': 'disconnected',
          'updated_at': '2026-07-14T11:01:40Z',
        },
        'slack': 'error',
      },
    });

    expect(states, isEmpty);
  });

  test('el contador se explica como actividad reciente, no chats abiertos', () {
    final s = lookupStrings(const Locale('es'));

    expect(s.setActiveSessions, 'Hermes ahora');
    expect(s.setActiveSessionsIdle, 'en reposo');
    expect(s.setActiveSessionsRunning(1), '1 sesión reciente');
    expect(s.setActiveSessionsNote, contains('últimos 5 minutos'));
  });

  test('platform states follow the app language', () {
    final en = lookupStrings(const Locale('en'));
    final es = lookupStrings(const Locale('es'));

    expect(gatewayPlatformStateLabel(en, 'connected'), 'connected');
    expect(gatewayPlatformStateLabel(en, 'disconnected'), 'disconnected');
    expect(gatewayPlatformStateLabel(en, 'connecting'), 'connecting');
    expect(gatewayPlatformStateLabel(en, 'error'), 'error');
    expect(gatewayPlatformStateLabel(en, 'starting'), 'starting');
    expect(gatewayPlatformStateLabel(en, 'stopped'), 'stopped');
    expect(
      en.setPlatformStatus(
        'api_server',
        gatewayPlatformStateLabel(en, 'disconnected'),
      ),
      'Platform api_server: disconnected.',
    );

    expect(gatewayPlatformStateLabel(es, 'connected'), 'conectada');
    expect(gatewayPlatformStateLabel(es, 'disconnected'), 'desconectada');
    expect(gatewayPlatformStateLabel(es, 'connecting'), 'conectando');
    expect(gatewayPlatformStateLabel(es, 'error'), 'con error');
    expect(gatewayPlatformStateLabel(es, 'starting'), 'arrancando');
    expect(gatewayPlatformStateLabel(es, 'stopped'), 'detenida');

    // Unknown upstream states are shown raw rather than hidden.
    expect(gatewayPlatformStateLabel(en, 'draining'), 'draining');
  });
}
