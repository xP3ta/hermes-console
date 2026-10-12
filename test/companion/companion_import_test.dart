// Tests de importación custom local (Bloque 5). Todo OFFLINE: construye ZIPs en
// memoria, escribe en un directorio temporal y valida el servicio + el
// repositorio + el controller. No usa red, ni file_picker, ni path_provider.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/companion/data/companion_import_service.dart';
import 'package:hermes_android/core/companion/data/companion_preferences.dart';
import 'package:hermes_android/core/companion/data/companion_repository.dart';
import 'package:hermes_android/core/companion/models/companion.dart';
import 'package:hermes_android/core/companion/models/companion_animation_state.dart';
import 'package:hermes_android/core/companion/state/companion_controller.dart';
import 'package:hermes_android/core/models/profile_pet.dart';
import 'package:hermes_android/core/screens/companion/mascotas_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WebP mínimo válido para `_isWebp` (RIFF…WEBP). No es decodificable como
/// imagen, pero los tests no renderizan: solo validan los magic bytes.
Uint8List _fakeWebp([int extra = 64]) {
  final b = BytesBuilder();
  b.add(ascii.encode('RIFF'));
  b.add([0, 0, 0, 0]);
  b.add(ascii.encode('WEBP'));
  b.add(List.filled(extra, 0x20));
  return b.toBytes();
}

String _validManifest({
  String slug = 'kitty',
  String spritesheet = 'spritesheet.webp',
}) => json.encode({
  'slug': slug,
  'name': 'Kitty',
  'author': 'Tester',
  'license': 'CC0-1.0',
  'spritesheet': spritesheet,
  'fps': 8,
  'grid': {'frameWidth': 64, 'frameHeight': 64, 'cols': 4, 'rows': 2},
  'states': {
    'idle': {'row': 0, 'frameCount': 4, 'loop': true},
  },
});

/// WebP VP8L con cabecera de dimensiones reales (no decodificable, pero el
/// servicio solo lee la cabecera). Por defecto 1536×1872 = grid 8×9 de 192×208,
/// el estándar de Petdex. Las dimensiones se codifican en los bytes 21..24.
Uint8List _petdexWebp({int width = 1536, int height = 1872}) {
  final w = width - 1;
  final h = height - 1;
  final b21 = w & 0xFF;
  final b22 = ((w >> 8) & 0x3F) | ((h & 0x03) << 6);
  final b23 = (h >> 2) & 0xFF;
  final b24 = (h >> 10) & 0x0F;
  final out = BytesBuilder();
  out.add(ascii.encode('RIFF'));
  out.add([0, 0, 0, 0]); // file size (ignorado)
  out.add(ascii.encode('WEBP'));
  out.add(ascii.encode('VP8L'));
  out.add([0, 0, 0, 0]); // chunk size (ignorado)
  out.add([0x2F]); // firma VP8L
  out.add([b21, b22, b23, b24]);
  out.add(List.filled(32, 0));
  return out.toBytes();
}

/// pet.json en el formato MÍNIMO de Petdex (sin grid/states).
String _petdexManifest({
  String id = 'noir-webling',
  String displayName = 'Noir Webling',
  String spritesheetPath = 'spritesheet.webp',
}) => json.encode({
  'id': id,
  'displayName': displayName,
  'description': 'Un acompañante de Petdex.',
  'spritesheetPath': spritesheetPath,
});

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, data) {
    archive.addFile(ArchiveFile(name, data.length, data));
  });
  final out = ZipEncoder().encode(archive);
  return Uint8List.fromList(out);
}

const _remotePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

ProfilePetInfo _remoteInfo({
  String slug = 'zoro',
  String revision = 'rev-1',
  String spritesheetBase64 = _remotePngBase64,
}) => ProfilePetInfo(
  enabled: true,
  slug: slug,
  displayName: 'Zoro',
  mime: 'image/png',
  spritesheetBase64: spritesheetBase64,
  spritesheetRevision: revision,
  frameW: 1,
  frameH: 1,
  framesPerState: 1,
  framesByState: const {'idle': 1},
  framesByRow: const {'0': 1},
  loopMs: 1000,
  scale: 1,
  stateRows: const ['idle'],
);

/// Repo con una base fija + el escaneo real de importadas desde [root].
class _BaseAndImportedRepo extends CompanionRepository {
  _BaseAndImportedRepo(Directory root)
    : super(importedRootProvider: () async => root);

  @override
  Future<List<String>> availableSlugs() async => const ['core-base'];

  @override
  Future<Companion?> load(String slug) async => Companion(
    slug: slug,
    name: 'Base',
    author: 'Hermes',
    license: 'CC0-1.0',
    spritesheetAsset: 'assets/companions/$slug/spritesheet.webp',
    frameWidth: 64,
    frameHeight: 64,
    cols: 4,
    rows: 2,
    fps: 8,
    states: const {
      CompanionAnimationState.idle: RowSpec(row: 0, frameCount: 4, loop: true),
    },
    // origin base por defecto.
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final service = const CompanionImportService();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('companion_import_test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('CompanionImportService', () {
    test(
      'materializa el payload oficial como remoto protegido y file-backed',
      () async {
        final pet = await service.materializeProfilePet(
          _remoteInfo(),
          storageRoot: root,
        );

        expect(pet.slug, 'zoro');
        expect(pet.origin, CompanionOrigin.remote);
        expect(pet.isFileBacked, isTrue);
        expect(pet.isProtected, isTrue);
        expect(pet.frameWidth, 1);
        expect(pet.frameHeight, 1);
        expect(pet.states[CompanionAnimationState.idle]?.frameCount, 1);
        expect(
          File(pet.spritesheetAsset).readAsBytesSync(),
          base64Decode(_remotePngBase64),
        );
      },
    );

    test(
      'payload remoto corrupto no sustituye la materialización válida',
      () async {
        final first = await service.materializeProfilePet(
          _remoteInfo(),
          storageRoot: root,
        );
        final beforeSprite = File(first.spritesheetAsset).readAsBytesSync();
        final manifest = File('${root.path}/zoro/pet.json');
        final beforeManifest = manifest.readAsBytesSync();

        await expectLater(
          service.materializeProfilePet(
            _remoteInfo(
              revision: 'rev-bad',
              spritesheetBase64: '%%% no es base64 %%%',
            ),
            storageRoot: root,
          ),
          throwsA(isA<CompanionImportException>()),
        );

        expect(File(first.spritesheetAsset).readAsBytesSync(), beforeSprite);
        expect(manifest.readAsBytesSync(), beforeManifest);
      },
    );

    test('importa un ZIP válido y deja los ficheros en el sandbox', () async {
      final zip = _zip({
        'pet.json': utf8.encode(_validManifest()),
        'spritesheet.webp': _fakeWebp(),
      });

      final pet = await service.importFromZipBytes(zip, storageRoot: root);

      expect(pet.slug, 'kitty');
      expect(pet.origin, CompanionOrigin.imported);
      expect(pet.isImported, isTrue);
      expect(pet.isProtected, isFalse);
      // El spritesheet apunta a un fichero real ya copiado.
      expect(File(pet.spritesheetAsset).existsSync(), isTrue);
      expect(File('${root.path}/kitty/pet.json').existsSync(), isTrue);
      // No queda ningún directorio temporal de importación.
      final leftovers = root.listSync().whereType<Directory>().where(
        (d) => d.path.split(Platform.pathSeparator).last.startsWith('.import-'),
      );
      expect(leftovers, isEmpty);
    });

    test('rechaza un slug no permitido', () async {
      final zip = _zip({
        'pet.json': utf8.encode(_validManifest(slug: 'Bad/Slug')),
        'spritesheet.webp': _fakeWebp(),
      });
      expect(
        () => service.importFromZipBytes(zip, storageRoot: root),
        throwsA(isA<CompanionImportException>()),
      );
    });

    test('rechaza un pet.json no válido', () async {
      final zip = _zip({
        'pet.json': utf8.encode('{ no es json'),
        'spritesheet.webp': _fakeWebp(),
      });
      expect(
        () => service.importFromZipBytes(zip, storageRoot: root),
        throwsA(isA<CompanionImportException>()),
      );
      // Sin instalación parcial.
      expect(root.listSync(), isEmpty);
    });

    test('rechaza un spritesheet con magic bytes inválidos', () async {
      final zip = _zip({
        'pet.json': utf8.encode(_validManifest()),
        'spritesheet.webp': List.filled(64, 0x00), // ni WebP ni PNG
      });
      expect(
        () => service.importFromZipBytes(zip, storageRoot: root),
        throwsA(isA<CompanionImportException>()),
      );
      expect(root.listSync(), isEmpty); // sin parcial
    });

    test('rechaza un spritesheet que excede el tamaño máximo', () async {
      final small = const CompanionImportService(maxSpritesheetBytes: 16);
      final zip = _zip({
        'pet.json': utf8.encode(_validManifest()),
        'spritesheet.webp': _fakeWebp(256),
      });
      expect(
        () => small.importFromZipBytes(zip, storageRoot: root),
        throwsA(isA<CompanionImportException>()),
      );
    });

    test('nunca sobrescribe una mascota base (slug protegido)', () async {
      final zip = _zip({
        'pet.json': utf8.encode(_validManifest(slug: 'core-base')),
        'spritesheet.webp': _fakeWebp(),
      });
      expect(
        () => service.importFromZipBytes(
          zip,
          storageRoot: root,
          protectedSlugs: const {'core-base'},
        ),
        throwsA(isA<CompanionImportException>()),
      );
      expect(root.listSync(), isEmpty);
    });

    test(
      'adapta e importa un ZIP en formato Petdex (pet.json mínimo)',
      () async {
        final zip = _zip({
          'pet.json': utf8.encode(_petdexManifest()),
          'spritesheet.webp': _petdexWebp(),
        });

        final pet = await service.importFromZipBytes(zip, storageRoot: root);

        expect(pet.slug, 'noir-webling');
        expect(pet.name, 'Noir Webling');
        expect(pet.origin, CompanionOrigin.imported);
        // Geometría estándar Petdex inferida del spritesheet 1536×1872.
        expect(pet.frameWidth, 192);
        expect(pet.frameHeight, 208);
        expect(pet.cols, 8);
        expect(pet.rows, 9);
        expect(pet.fps, 8);
        expect(
          pet.states.keys.map((e) => e.name),
          containsAll(['idle', 'run', 'waiting', 'wave', 'failed']),
        );
        expect(File(pet.spritesheetAsset).existsSync(), isTrue);
      },
    );

    test(
      'Petdex: spritesheetPath inexistente cae al spritesheet real del ZIP',
      () async {
        // pet.json declara "spritesheet-hq.webp" (no presente); el ZIP solo trae
        // "spritesheet.webp". Debe instalar usando el real, no fallar.
        final zip = _zip({
          'pet.json': utf8.encode(
            _petdexManifest(spritesheetPath: 'spritesheet-hq.webp'),
          ),
          'spritesheet.webp': _petdexWebp(),
        });

        final pet = await service.importFromZipBytes(zip, storageRoot: root);

        expect(pet.slug, 'noir-webling');
        expect(pet.frameWidth, 192);
        expect(File(pet.spritesheetAsset).existsSync(), isTrue);
      },
    );

    test('Petdex: authorOverride fija el autor real', () async {
      final zip = _zip({
        'pet.json': utf8.encode(_petdexManifest()),
        'spritesheet.webp': _petdexWebp(),
      });

      final pet = await service.importFromZipBytes(
        zip,
        storageRoot: root,
        authorOverride: 'Serhat',
      );

      expect(pet.author, 'Serhat');
    });

    test(
      'rechaza un ZIP Petdex con spritesheet de dimensiones inesperadas',
      () async {
        final zip = _zip({
          'pet.json': utf8.encode(_petdexManifest()),
          // 100×100 no es múltiplo de 192×208 → no encaja en el grid Petdex.
          'spritesheet.webp': _petdexWebp(width: 100, height: 100),
        });
        expect(
          () => service.importFromZipBytes(zip, storageRoot: root),
          throwsA(isA<CompanionImportException>()),
        );
        expect(root.listSync(), isEmpty);
      },
    );

    test('detecta los frames reales por fila desde el buffer RGBA', () {
      const fw = 8, fh = 8, cols = 8, rows = 3;
      const w = cols * fw, h = rows * fh;
      final rgba = Uint8List(w * h * 4);
      void fillCell(int r, int c) {
        final x = c * fw, y = r * fh;
        rgba[(y * w + x) * 4 + 3] = 255; // alfa opaco en el pixel sup-izq
      }

      for (var c = 0; c < 6; c++) {
        fillCell(0, c); // fila 0 → 6 frames
      }
      for (var c = 0; c < 8; c++) {
        fillCell(1, c); // fila 1 → 8 frames
      }
      // fila 2 vacía → 0 frames

      final counts = CompanionImportService.framesPerRowFromRgba(
        rgba,
        w,
        h,
        fw,
        fh,
      );
      expect(counts, [6, 8, 0]);
    });

    test('un fallo de validación no deja instalación parcial', () async {
      // pet.json sin "states" → falla al parsear tras escribir el temporal.
      final badManifest = json.encode({
        'slug': 'kitty',
        'spritesheet': 'spritesheet.webp',
        'fps': 8,
        'grid': {'frameWidth': 64, 'frameHeight': 64, 'cols': 4, 'rows': 2},
      });
      final zip = _zip({
        'pet.json': utf8.encode(badManifest),
        'spritesheet.webp': _fakeWebp(),
      });
      expect(
        () => service.importFromZipBytes(zip, storageRoot: root),
        throwsA(isA<CompanionImportException>()),
      );
      // Ni carpeta final ni temporal: limpieza completa.
      expect(root.listSync(), isEmpty);
    });
  });

  group('CompanionRepository (importadas) + CompanionController', () {
    Future<CompanionController> controller() async {
      final prefs = await CompanionPreferences.load();
      final c = CompanionController(_BaseAndImportedRepo(root), prefs);
      await c.init();
      return c;
    }

    test('la importada aparece en la galería y queda seleccionada', () async {
      final c = await controller();
      expect(c.available.map((e) => e.slug), ['core-base']);

      final zip = _zip({
        'pet.json': utf8.encode(_validManifest()),
        'spritesheet.webp': _fakeWebp(),
      });
      await c.importFromZipBytes(zip);

      expect(
        c.available.map((e) => e.slug),
        containsAll(['core-base', 'kitty']),
      );
      expect(c.selectedSlug, 'kitty');
      expect(c.activeCompanion?.slug, 'kitty');
    });

    test('borrar la importada la quita del catálogo y del disco', () async {
      final c = await controller();
      final zip = _zip({
        'pet.json': utf8.encode(_validManifest()),
        'spritesheet.webp': _fakeWebp(),
      });
      await c.importFromZipBytes(zip);
      expect(Directory('${root.path}/kitty').existsSync(), isTrue);

      final removed = await c.delete('kitty');
      expect(removed, isTrue);
      expect(c.available.map((e) => e.slug), ['core-base']);
      expect(Directory('${root.path}/kitty').existsSync(), isFalse);
    });

    test('una mascota base nunca se borra', () async {
      final c = await controller();
      final removed = await c.delete('core-base');
      expect(removed, isFalse);
      expect(c.available.map((e) => e.slug), ['core-base']);
    });
  });

  group('MascotasScreen — botón Importar (cableado UI, sin IO real)', () {
    Future<CompanionController> noStorageController() async {
      final prefs = await CompanionPreferences.load();
      // Repo SIN importedRootProvider → la importación responde "no disponible"
      // sin tocar disco; ideal para probar el cableado de la UI.
      final c = CompanionController(_NoStorageRepo(), prefs);
      await c.init();
      return c;
    }

    Future<void> pump(
      WidgetTester tester,
      CompanionController c, {
      required ZipPicker picker,
    }) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: Strings.localizationsDelegates,
          supportedLocales: Strings.supportedLocales,
          home: MascotasScreen(
            controller: c,
            picker: picker,
            petdexVerified: false,
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('muestra la fila "Importar mascota"', (tester) async {
      final c = await noStorageController();
      await pump(tester, c, picker: () async => null);
      expect(find.text('Importar mascota'), findsOneWidget);
    });

    testWidgets('cancelar el selector no muestra ningún aviso', (tester) async {
      final c = await noStorageController();
      var calls = 0;
      await pump(
        tester,
        c,
        picker: () async {
          calls++;
          return null; // usuario canceló
        },
      );

      await tester.tap(find.text('Importar mascota'));
      await tester.pump();

      expect(calls, 1);
      expect(find.textContaining('No se pudo importar'), findsNothing);
    });

    testWidgets(
      'un ZIP elegido sin almacenamiento disponible avisa del error',
      (tester) async {
        final c = await noStorageController();
        final zip = _zip({
          'pet.json': utf8.encode(_validManifest()),
          'spritesheet.webp': _fakeWebp(),
        });
        await pump(tester, c, picker: () async => zip);

        await tester.tap(find.text('Importar mascota'));
        await tester.pump();

        expect(find.textContaining('No se pudo importar'), findsOneWidget);
      },
    );
  });
}

/// Repo con una base fija y SIN importación (no toca disco).
class _NoStorageRepo extends CompanionRepository {
  @override
  Future<List<Companion>> loadAll() async => [
    Companion(
      slug: 'core-base',
      name: 'Base',
      author: 'Hermes',
      license: 'CC0-1.0',
      spritesheetAsset: 'assets/companions/core-base/spritesheet.webp',
      frameWidth: 64,
      frameHeight: 64,
      cols: 4,
      rows: 2,
      fps: 8,
      states: const {
        CompanionAnimationState.idle: RowSpec(
          row: 0,
          frameCount: 4,
          loop: true,
        ),
      },
    ),
  ];
}
