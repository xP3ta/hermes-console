import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
class _Real extends HttpOverrides {}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final redirect in [false, true]) {
    test('review Dashboard token origin redirect=$redirect', () => HttpOverrides.runZoned(() async {
      final a = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final b = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async { await a.close(force:true); await b.close(force:true); });
      final captures = <String?>[];
      a.listen((r) async {
        if (redirect) {
          r.response.statusCode = 302;
          r.response.headers.set('location', 'http://127.0.0.1:${b.port}/api/profiles');
        } else {
          captures.add(r.headers.value('x-hermes-session-token'));
          r.response.write('{"profiles":[]}');
        }
        await r.response.close();
      });
      b.listen((r) async {
        captures.add(r.headers.value('x-hermes-session-token'));
        r.response.write('{"profiles":[]}');
        await r.response.close();
      });
      final c = DashboardClient.forConnection(
        SavedConnection(id:'fixture-redirect',label:'fixture',host:'127.0.0.1',port:a.port,
          apiKey:'', dashboardUrl:'http://127.0.0.1:${a.port}',dashboardAuthMode:AuthMode.sessionToken),
        secrets: DashboardSecrets(sessionToken:'synthetic-redirect-fixture'),
      );
      addTearDown(c.close);
      try { await c.apiGet('profiles'); } catch (_) {}
      if (redirect) {
        expect(captures.where((v) => v == 'synthetic-redirect-fixture'), isEmpty,
          reason:'original credential must not be sent to another origin');
      } else {
        expect(captures, ['synthetic-redirect-fixture']);
      }
    }, createHttpClient:_Real().createHttpClient));
  }
}
