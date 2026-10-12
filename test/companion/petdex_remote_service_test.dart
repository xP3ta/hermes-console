import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/petdex_remote_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Client _json(Object body) => MockClient((req) async {
  return http.Response(jsonEncode(body), 200);
});

void main() {
  group('PetdexRemoteService.fetchManifest', () {
    test(
      'parsea entradas válidas y descarta las de host no permitido',
      () async {
        final client = _json({
          'generatedAt': 'now',
          'total': 2,
          'pets': [
            {
              'slug': 'boba',
              'displayName': 'Boba',
              'submittedBy': 'Ada',
              'spritesheetUrl':
                  'https://assets.petdex.dev/pets/boba/sprite.webp',
              'petJsonUrl': 'https://assets.petdex.dev/pets/boba/petjson.json',
              'zipUrl': 'https://assets.petdex.dev/pets/boba/zip.zip',
            },
            {
              // host no permitido → descartada
              'slug': 'evil',
              'displayName': 'Evil',
              'spritesheetUrl': 'https://evil.example.com/x/sprite.webp',
              'petJsonUrl': 'https://evil.example.com/x/petjson.json',
              'zipUrl': 'https://evil.example.com/x/zip.zip',
            },
          ],
        });
        final svc = PetdexRemoteService(client: client);
        final pets = await svc.fetchManifest();
        expect(pets, hasLength(1));
        expect(pets.first.slug, 'boba');
        expect(pets.first.author, 'Ada');
        expect(pets.first.zipUrl.host, 'assets.petdex.dev');
      },
    );

    test('parsea kind (categoría) en minúsculas', () async {
      final client = _json({
        'pets': [
          {
            'slug': 'c',
            'displayName': 'C',
            'kind': 'Creature',
            'spritesheetUrl': 'https://assets.petdex.dev/pets/c/sprite.webp',
            'petJsonUrl': 'https://assets.petdex.dev/pets/c/petjson.json',
            'zipUrl': 'https://assets.petdex.dev/pets/c/zip.zip',
          },
        ],
      });
      final pets = await PetdexRemoteService(client: client).fetchManifest();
      expect(pets.first.kind, 'creature');
    });

    test('displayName/author caen a defaults', () async {
      final client = _json({
        'pets': [
          {
            'slug': 'nodisplay',
            'spritesheetUrl': 'https://assets.petdex.dev/pets/n/sprite.webp',
            'petJsonUrl': 'https://assets.petdex.dev/pets/n/petjson.json',
            'zipUrl': 'https://assets.petdex.dev/pets/n/zip.zip',
          },
        ],
      });
      final pets = await PetdexRemoteService(client: client).fetchManifest();
      expect(pets.first.displayName, 'nodisplay'); // cae al slug
      expect(pets.first.author, 'Petdex'); // sin submittedBy
    });

    test('JSON inválido → PetdexRemoteException (sin crash)', () async {
      final client = MockClient((req) async => http.Response('no-json{', 200));
      expect(
        PetdexRemoteService(client: client).fetchManifest(),
        throwsA(isA<PetdexRemoteException>()),
      );
    });

    test('formato inesperado (sin pets) → excepción', () async {
      final client = _json({'foo': 'bar'});
      expect(
        PetdexRemoteService(client: client).fetchManifest(),
        throwsA(isA<PetdexRemoteException>()),
      );
    });

    test('HTTP != 200 → excepción', () async {
      final client = MockClient((req) async => http.Response('nope', 404));
      expect(
        PetdexRemoteService(client: client).fetchManifest(),
        throwsA(isA<PetdexRemoteException>()),
      );
    });

    test('sin red el error dice que no se llegó a Petdex; con respuesta '
        'inservible, no', () async {
      Future<PetdexRemoteException> failure(http.Client client) async {
        try {
          await PetdexRemoteService(client: client).fetchManifest();
        } on PetdexRemoteException catch (error) {
          return error;
        }
        throw StateError('fetchManifest did not fail');
      }

      final unreachable = await failure(
        MockClient((req) async => throw http.ClientException('no route')),
      );
      expect(unreachable.offline, isTrue);
      final refused = await failure(
        MockClient((req) async => http.Response('nope', 503)),
      );
      expect(refused.offline, isFalse);
      final garbled = await failure(
        MockClient((req) async => http.Response('no-json{', 200)),
      );
      expect(garbled.offline, isFalse);
    });

    test('todas las entradas inválidas → excepción (lista vacía)', () async {
      final client = _json({
        'pets': [
          {'slug': '', 'zipUrl': 'https://assets.petdex.dev/x/zip.zip'},
        ],
      });
      expect(
        PetdexRemoteService(client: client).fetchManifest(),
        throwsA(isA<PetdexRemoteException>()),
      );
    });
  });

  group('PetdexRemoteService.downloadPetZip', () {
    final pet = PetdexRemotePet(
      slug: 'boba',
      displayName: 'Boba',
      submittedBy: 'Ada',
      kind: 'character',
      spritesheetUrl: Uri.parse(
        'https://assets.petdex.dev/pets/boba/sprite.webp',
      ),
      petJsonUrl: Uri.parse('https://assets.petdex.dev/pets/boba/petjson.json'),
      zipUrl: Uri.parse('https://assets.petdex.dev/pets/boba/zip.zip'),
    );

    test('devuelve los bytes del ZIP', () async {
      final payload = Uint8List.fromList([80, 75, 3, 4, 1, 2, 3]);
      final client = MockClient.streaming((req, body) async {
        return http.StreamedResponse(Stream.value(payload), 200);
      });
      final bytes = await PetdexRemoteService(
        client: client,
      ).downloadPetZip(pet);
      expect(bytes, payload);
    });

    test('rechaza un zipUrl fuera de la allowlist', () async {
      final evil = PetdexRemotePet(
        slug: 'x',
        displayName: 'x',
        submittedBy: '',
        kind: 'object',
        spritesheetUrl: Uri.parse('https://evil.com/s.webp'),
        petJsonUrl: Uri.parse('https://evil.com/p.json'),
        zipUrl: Uri.parse('https://evil.com/z.zip'),
      );
      final client = MockClient((req) async => http.Response('x', 200));
      expect(
        PetdexRemoteService(client: client).downloadPetZip(evil),
        throwsA(isA<PetdexRemoteException>()),
      );
    });
  });
}
