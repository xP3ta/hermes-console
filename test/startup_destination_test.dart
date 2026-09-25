import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/startup_destination.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Issue #47: elegir con qué pantalla arranca la app.
///
/// El contrato que importa: quien no toca el ajuste ve exactamente lo de
/// siempre, y el valor elegido sobrevive al reinicio de la app.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('sin preferencia guardada arranca en Inicio', () async {
    expect(await StartupDestinationStore.load(), StartupDestination.home);
  });

  test('la elección sobrevive a un reinicio', () async {
    await StartupDestinationStore.save(StartupDestination.bots);
    expect(await StartupDestinationStore.load(), StartupDestination.bots);
  });

  test('volver a Inicio no deja ajuste huérfano', () async {
    await StartupDestinationStore.save(StartupDestination.bots);
    await StartupDestinationStore.save(StartupDestination.home);
    expect(await StartupDestinationStore.load(), StartupDestination.home);

    // Volver al valor por defecto limpia la clave: un usuario que no usa la
    // preferencia no debe arrastrar estado guardado.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('startup_destination'), isNull);
  });

  test('un valor desconocido cae a Inicio, no rompe el arranque', () async {
    SharedPreferences.setMockInitialValues({
      'startup_destination': 'pantalla-que-ya-no-existe',
    });
    expect(await StartupDestinationStore.load(), StartupDestination.home);
  });

  test('fromStorage acepta las claves publicadas y rechaza el resto', () {
    expect(StartupDestination.fromStorage('bots'), StartupDestination.bots);
    expect(StartupDestination.fromStorage('home'), StartupDestination.home);
    expect(StartupDestination.fromStorage(null), StartupDestination.home);
    expect(StartupDestination.fromStorage(''), StartupDestination.home);
    // Las claves guardadas son contrato: cambiarlas invalida la preferencia
    // de quien ya la tenía elegida.
    expect(StartupDestination.bots.storageKey, 'bots');
    expect(StartupDestination.home.storageKey, 'home');
  });
}
