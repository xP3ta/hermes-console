// «Guardar en el móvil» (orden DESCARGAS-DIRECTAS, points 4-6, and the
// addendum from the Fold): one helper over `hermes/save_to_device`. The
// name reaches Android's «Guardar como» made safe; a file is copied by
// blocks on Android's side (its path, never its bytes); bytes in memory are
// written in blocks; a write that fails halfway deletes the document; every
// exception says why (MissingPlugin and a call that never answers too); a
// «Guardar como» that never shows is noticed instead of waiting forever.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/save_to_device.dart';

const _channel = MethodChannel('hermes/save_to_device');
const _doc = 'content://com.android.providers.downloads.documents/document/7';

/// Every call on Android's side, answered by [answer]: a value, a
/// [PlatformException] to throw, or a Future (one that never completes
/// hangs the call).
List<MethodCall> _android(Object? Function(MethodCall call) answer) {
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_channel, (call) async {
    calls.add(call);
    final result = answer(call);
    if (result is PlatformException) throw result;
    if (result is Future) return await result;
    return result;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
  return calls;
}

Map<Object?, Object?> _args(MethodCall call) =>
    (call.arguments as Map?) ?? const {};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the name «Guardar como» suggests', () {
    test('hostile server names reach the dialog made safe', () async {
      final calls = _android((call) => null);
      const device = SaveToDevice();
      for (final (raw, safe) in const [
        ('../../.ssh/authorized_keys', 'authorized_keys'),
        ('/etc/passwd', 'passwd'),
        (r'..\..\Windows\system.ini', 'system.ini'),
        ('photo\u202egpj.exe', 'photogpj.exe'),
        ('line\nbreak\r.txt', 'linebreak.txt'),
        ('what?<>:"|*.txt', 'what_______.txt'),
        ('..', 'download'),
        ('', 'download'),
      ]) {
        expect(await device.pick(raw), isNull, reason: raw);
        expect(_args(calls.last)['name'], safe, reason: raw);
      }
      expect(calls.map((c) => c.method).toSet(), {'pick'});
    });

    test('the dialog closed is no error: nothing is written', () async {
      final calls = _android((call) => null);
      final dir = await Directory.systemTemp.createTemp('save-cancel');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.txt')..writeAsStringSync('abc');
      final saved = await const SaveToDevice().saveFile(file, name: 'a.txt');
      expect(saved, isNull);
      expect(calls.map((c) => c.method), ['pick']);
    });
  });

  group('a file of the app', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('save-file');
    });
    tearDown(() => dir.delete(recursive: true));

    test('is copied by blocks from its path, never its bytes', () async {
      final file = File('${dir.path}/informe.pdf')
        ..writeAsBytesSync(List<int>.filled(3 * 1024 * 1024, 7));
      final calls = _android(
        (call) => switch (call.method) {
          'pick' => _doc,
          'copy' => 3 * 1024 * 1024,
          _ => null,
        },
      );
      final saved = await const SaveToDevice().saveFile(
        file,
        name: 'informe.pdf',
      );
      expect(saved!.uri, _doc);
      expect(saved.name, 'informe.pdf');
      expect(saved.bytes, 3 * 1024 * 1024);
      expect(calls.map((c) => c.method), ['pick', 'copy']);
      final copy = _args(calls.last);
      expect(copy['path'], file.path);
      expect(copy['uri'], _doc);
      // Nothing of the file crosses the channel.
      expect(copy.containsKey('bytes'), isFalse);
      expect(copy.values.whereType<Uint8List>(), isEmpty);
    });

    test('a file that is gone says so before asking where', () async {
      final calls = _android((call) => _doc);
      await expectLater(
        const SaveToDevice().saveFile(
          File('${dir.path}/gone.txt'),
          name: 'gone.txt',
        ),
        throwsA(
          isA<SaveFailure>()
              .having((f) => f.problem, 'problem', SaveProblem.sourceMissing)
              .having((f) => f.stage, 'stage', SaveStage.picker),
        ),
      );
      expect(calls, isEmpty);
    });

    test('each Android code becomes its reason', () async {
      final file = File('${dir.path}/x.bin')..writeAsBytesSync([1, 2, 3]);
      for (final (code, problem) in const [
        ('no_space', SaveProblem.noSpace),
        ('permission', SaveProblem.permission),
        ('unsupported', SaveProblem.unsupported),
        ('source_missing', SaveProblem.sourceMissing),
        ('picker_not_shown', SaveProblem.pickerNotShown),
        ('failed', SaveProblem.failed),
        ('something_new', SaveProblem.failed),
      ]) {
        _android(
          (call) =>
              call.method == 'pick' ? _doc : PlatformException(code: code),
        );
        await expectLater(
          const SaveToDevice().saveFile(file, name: 'x.bin'),
          throwsA(
            isA<SaveFailure>()
                .having((f) => f.problem, 'problem', problem)
                .having((f) => f.stage, 'stage', SaveStage.copy),
          ),
          reason: code,
        );
      }
    });
  });

  group('bytes in memory', () {
    test('are written straight to the document, block by block', () async {
      final data = Uint8List(SaveToDevice.blockBytes * 2 + 10);
      final calls = _android(
        (call) => switch (call.method) {
          'pick' => _doc,
          'begin' => 4,
          'write' => 0,
          'finish' => data.length,
          _ => null,
        },
      );
      final saved = await const SaveToDevice().saveBytes(data, name: 'a.zip');
      expect(saved!.bytes, data.length);
      expect(calls.map((c) => c.method), [
        'pick',
        'begin',
        'write',
        'write',
        'write',
        'finish',
      ]);
      final blocks = [
        for (final c in calls.where((c) => c.method == 'write'))
          (_args(c)['bytes']! as Uint8List).length,
      ];
      expect(blocks, [SaveToDevice.blockBytes, SaveToDevice.blockBytes, 10]);
      for (final c in calls.where((c) => c.method == 'write')) {
        expect(_args(c)['writer'], 4);
      }
    });

    test('a write that fails halfway deletes the partial document', () async {
      final data = Uint8List(SaveToDevice.blockBytes * 3);
      var writes = 0;
      final calls = _android((call) {
        switch (call.method) {
          case 'pick':
            return _doc;
          case 'begin':
            return 9;
          case 'write':
            return ++writes == 2 ? PlatformException(code: 'no_space') : 0;
        }
        return null;
      });
      await expectLater(
        const SaveToDevice().saveBytes(data, name: 'a.zip'),
        throwsA(
          isA<SaveFailure>()
              .having((f) => f.problem, 'problem', SaveProblem.noSpace)
              .having((f) => f.stage, 'stage', SaveStage.copy)
              .having((f) => f.bytes, 'bytes', SaveToDevice.blockBytes),
        ),
      );
      expect(calls.map((c) => c.method), [
        'pick',
        'begin',
        'write',
        'write',
        'abort',
      ]);
      expect(_args(calls.last)['writer'], 9);
    });

    test('a document that cannot be opened is deleted', () async {
      final calls = _android(
        (call) => switch (call.method) {
          'pick' => _doc,
          'begin' => PlatformException(code: 'unsupported'),
          _ => null,
        },
      );
      await expectLater(
        const SaveToDevice().saveBytes(Uint8List(3), name: 'a.txt'),
        throwsA(
          isA<SaveFailure>().having(
            (f) => f.problem,
            'problem',
            SaveProblem.unsupported,
          ),
        ),
      );
      expect(calls.map((c) => c.method), ['pick', 'begin', 'delete']);
      expect(_args(calls.last)['uri'], _doc);
    });
  });

  test('without its Android side (MissingPlugin) it says so', () async {
    // No handler on the channel at all.
    await expectLater(
      const SaveToDevice().pick('a.txt'),
      throwsA(
        isA<SaveFailure>()
            .having((f) => f.problem, 'problem', SaveProblem.unavailable)
            .having((f) => f.stage, 'stage', SaveStage.picker),
      ),
    );
    await expectLater(
      const SaveToDevice().open(_doc),
      throwsA(
        isA<SaveFailure>().having(
          (f) => f.problem,
          'problem',
          SaveProblem.unavailable,
        ),
      ),
    );
  });

  test('«Guardar otra copia…» copies the document itself', () async {
    const another = 'content://com.google.android.apps.docs.storage/document/9';
    final calls = _android(
      (call) => switch (call.method) {
        'pick' => another,
        'copy' => 5,
        _ => null,
      },
    );
    final copy = await const SaveToDevice().saveAnotherCopy(
      const SavedDocument(uri: _doc, name: 'notes.txt', bytes: 5),
    );
    expect(copy!.uri, another);
    expect(calls.map((c) => c.method), ['pick', 'copy']);
    expect(_args(calls[0])['name'], 'notes.txt');
    expect(_args(calls[1])['source'], _doc);
    expect(_args(calls[1])['uri'], another);
    expect(_args(calls[1]).containsKey('path'), isFalse);
  });

  group('a call that never answers', () {
    testWidgets('«Guardar como» that never shows is said, not waited for', (
      tester,
    ) async {
      final calls = _android(
        (call) => call.method == 'pick' ? Completer<String?>().future : null,
      );
      Object? failure;
      unawaited(
        const SaveToDevice().pick('a.txt').then<void>(
          (_) {},
          onError: (Object error) => failure = error,
        ),
      );
      await tester.pump(
        SaveToDevice.pickerShowTimeout - const Duration(seconds: 1),
      );
      expect(failure, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(
        failure,
        isA<SaveFailure>()
            .having((f) => f.problem, 'problem', SaveProblem.pickerNotShown)
            .having((f) => f.stage, 'stage', SaveStage.picker),
      );
      // Android is told: a late answer has nobody waiting.
      expect(calls.map((c) => c.method), ['pick', 'cancelPick']);
    });

    testWidgets('while the dialog covers the app, there is no limit', (
      tester,
    ) async {
      final answer = Completer<String?>();
      final calls = _android(
        (call) => call.method == 'pick' ? answer.future : null,
      );
      String? uri;
      unawaited(const SaveToDevice().pick('a.txt').then((v) => uri = v));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      // The user takes their time in the dialog.
      await tester.pump(const Duration(minutes: 3));
      answer.complete(_doc);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(uri, _doc);
      expect(calls.map((c) => c.method), ['pick']);
    });

    testWidgets('back from the dialog with no answer, it is said', (
      tester,
    ) async {
      final calls = _android(
        (call) => call.method == 'pick' ? Completer<String?>().future : null,
      );
      Object? failure;
      unawaited(
        const SaveToDevice().pick('a.txt').then<void>(
          (_) {},
          onError: (Object error) => failure = error,
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(minutes: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(SaveToDevice.pickerAnswerTimeout);
      expect(
        failure,
        isA<SaveFailure>().having(
          (f) => f.problem,
          'problem',
          SaveProblem.pickerNotShown,
        ),
      );
      expect(calls.map((c) => c.method), ['pick', 'cancelPick']);
    });

    testWidgets('writing that hangs ends in «did not answer in time»', (
      tester,
    ) async {
      final calls = _android(
        (call) => switch (call.method) {
          'pick' => _doc,
          'begin' => 3,
          'write' => Completer<int>().future,
          _ => null,
        },
      );
      Object? failure;
      unawaited(
        const SaveToDevice()
            .saveBytes(Uint8List(10), name: 'a.txt')
            .then<void>((_) {}, onError: (Object error) => failure = error),
      );
      await tester.pump();
      await tester.pump(SaveToDevice.stepTimeout);
      await tester.pump();
      expect(
        failure,
        isA<SaveFailure>()
            .having((f) => f.problem, 'problem', SaveProblem.timeout)
            .having((f) => f.stage, 'stage', SaveStage.copy),
      );
      // The half-written document goes.
      expect(calls.map((c) => c.method), ['pick', 'begin', 'write', 'abort']);
    });
  });
}
