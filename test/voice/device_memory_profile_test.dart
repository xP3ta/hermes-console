import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/device_memory_profile.dart';

import '../support/remove_test_dir.dart';

/// Spec 048 / US4 — perfil de memoria del dispositivo
/// (contracts/model-residency.md): lectura de /proc/meminfo inyectable,
/// umbral conservador de 7,5 GiB y cero excepciones ante datos corruptos.
void main() {
  Future<File> meminfo(String content) async {
    final dir = await Directory.systemTemp.createTemp('hermes-meminfo');
    addTearDown(() => removeTestDir(dir));
    final file = File('${dir.path}/meminfo');
    await file.writeAsString(content);
    return file;
  }

  test('un dispositivo de 16 GiB es elegible para residencia', () async {
    final file = await meminfo(
      'MemTotal:       16384000 kB\nMemFree:         1234567 kB\n',
    );
    final profile = DeviceMemoryProfile.read(meminfoPath: file.path);

    expect(profile.memTotalBytes, 16384000 * 1024);
    expect(profile.residencyEligible, isTrue);
  });

  test('un dispositivo de 6 GiB no es elegible', () async {
    final file = await meminfo('MemTotal:        6144000 kB\n');
    final profile = DeviceMemoryProfile.read(meminfoPath: file.path);

    expect(profile.residencyEligible, isFalse);
  });

  test('el umbral de 7,5 GiB es exacto', () async {
    final justAbove = await meminfo(
      'MemTotal: ${(7.5 * 1024 * 1024).ceil() + 1} kB\n',
    );
    final justBelow = await meminfo(
      'MemTotal: ${(7.5 * 1024 * 1024).floor() - 1} kB\n',
    );

    expect(
      DeviceMemoryProfile.read(meminfoPath: justAbove.path).residencyEligible,
      isTrue,
    );
    expect(
      DeviceMemoryProfile.read(meminfoPath: justBelow.path).residencyEligible,
      isFalse,
    );
  });

  test('meminfo ausente o corrupto nunca lanza y no es elegible', () async {
    final missing = DeviceMemoryProfile.read(
      meminfoPath: '/definitivamente/no/existe',
    );
    expect(missing.memTotalBytes, 0);
    expect(missing.residencyEligible, isFalse);

    final corrupt = await meminfo('esto no es un meminfo\nMemTotal: patata kB');
    final profile = DeviceMemoryProfile.read(meminfoPath: corrupt.path);
    expect(profile.memTotalBytes, 0);
    expect(profile.residencyEligible, isFalse);
  });
}
