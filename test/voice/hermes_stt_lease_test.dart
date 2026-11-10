import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/voice/hermes_stt_lease.dart';
import 'package:hermes_android/core/services/voice/stt_engine.dart';
import 'package:hermes_android/core/services/voice/stt_hermes_server.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Desktop `lib/stt-lease.ts` over `POST /api/audio/stt-lease`
/// (`hermes_cli/web_routers/audio.py:482-513`), with fakes only.
class _Wire {
  final List<(String, bool)> calls = [];
  Completer<void>? hold;
  Object? fail;

  Future<Map<String, dynamic>> call(String lease, bool active) async {
    calls.add((lease, active));
    final gate = hold;
    if (gate != null) await gate.future;
    final error = fail;
    if (error != null) throw error;
    return {'ok': true, 'lease': lease, 'active': active};
  }
}

class _Recorder extends Fake implements AudioRecorder {
  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    File(path).writeAsBytesSync(const [1, 2, 3, 4]);
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async =>
      const Stream<Uint8List>.empty();

  @override
  Future<String?> stop() async => null;

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HermesSttLease (stt-lease.ts:57-95)', () {
    late _Wire wire;
    late HermesSttLease lease;

    setUp(() {
      wire = _Wire();
      lease = HermesSttLease(name: 'console:voice-input:x', request: wire.call);
    });

    test('acquire, then release, by name', () async {
      await lease.sync(true);
      await lease.sync(false);
      expect(wire.calls, [
        ('console:voice-input:x', true),
        ('console:voice-input:x', false),
      ]);
    });

    test('a release never acquired sends nothing', () async {
      await lease.sync(false);
      expect(wire.calls, isEmpty);
    });

    test('concurrent acquires share one request and one readiness', () async {
      wire.hold = Completer<void>();
      final first = lease.sync(true);
      final second = lease.sync(true);
      await pumpEventQueue();
      expect(wire.calls, hasLength(1));
      var ready = false;
      unawaited(second.then((_) => ready = true));
      await pumpEventQueue();
      expect(ready, isFalse, reason: 'readiness waits for the wire');
      wire.hold!.complete();
      await first;
      await second;
      expect(ready, isTrue);
    });

    test('on, off, on reach the wire in order', () async {
      wire.hold = Completer<void>();
      final on = lease.sync(true);
      await pumpEventQueue();
      final off = lease.sync(false);
      final again = lease.sync(true);
      wire.hold!.complete();
      wire.hold = null;
      await Future.wait([on, off, again]);
      // The queued release is superseded by the newer acquire: latest
      // intent wins (stt-lease.ts:73-77).
      expect(wire.calls.map((call) => call.$2), [true, true]);
    });

    test('a failure never surfaces and is forgotten', () async {
      wire.fail = StateError('older host');
      await expectLater(lease.sync(true), completes);
      // Forgotten: the release has nothing to send, the next acquire retries.
      await lease.sync(false);
      expect(wire.calls, hasLength(1));
      wire.fail = null;
      await lease.sync(true);
      expect(wire.calls, hasLength(2));
    });
  });

  group('HermesServerSttRuntime', () {
    late Directory dir;
    late _Wire wire;
    late HermesSttLease lease;
    late List<String> uploads;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('stt-lease');
      wire = _Wire();
      lease = HermesSttLease(name: 'console:voice-input:x', request: wire.call);
      uploads = [];
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    HermesServerSttRuntime runtime() => HermesServerSttRuntime(
      transcribeRequest: (dataUrl, _) async {
        uploads.add(dataUrl);
        return {'ok': true, 'transcript': 'hola'};
      },
      recorder: _Recorder(),
      sttLease: () => lease,
    );

    Future<String> transcribe(HermesServerSttRuntime rt, String path) =>
        rt.transcribe(
          model: WhisperModel.tiny,
          audioPath: path,
          lang: 'es',
          threads: 2,
        );

    test('each capture acquires; the clip waits for the warm-up', () async {
      final rt = runtime();
      final path = '${dir.path}/turn.wav';
      wire.hold = Completer<void>();
      rt.prepareCapture(continuous: false, onPartial: (_) {});
      await rt.start(path);
      await pumpEventQueue();
      expect(wire.calls, [('console:voice-input:x', true)]);

      final text = transcribe(rt, path);
      await pumpEventQueue();
      expect(uploads, isEmpty, reason: 'readiness first');
      wire.hold!.complete();
      wire.hold = null;
      expect(await text, 'hola');
      expect(uploads, hasLength(1));
    });

    test('a conversation keeps the lease until it ends', () async {
      final rt = runtime();
      final path = '${dir.path}/turn.wav';
      rt.prepareCapture(continuous: false, onPartial: (_) {});
      await rt.start(path);
      await transcribe(rt, path);
      rt.discardCapture(path);
      await pumpEventQueue();
      expect(wire.calls.map((call) => call.$2), [true]);

      await rt.dispose();
      expect(wire.calls.map((call) => call.$2), [true, false]);
    });

    test('a dictation releases when its take is over', () async {
      final rt = runtime();
      addTearDown(rt.dispose);
      final path = '${dir.path}/take.wav';
      rt.prepareCapture(continuous: true, onPartial: (_) {});
      await rt.start(path);
      await transcribe(rt, path);
      rt.discardCapture(path);
      await pumpEventQueue();
      expect(wire.calls.map((call) => call.$2), [true, false]);
    });

    test('a failing lease never blocks the transcription', () async {
      wire.fail = StateError('no route');
      final rt = runtime();
      addTearDown(rt.dispose);
      final path = '${dir.path}/turn.wav';
      rt.prepareCapture(continuous: false, onPartial: (_) {});
      await rt.start(path);
      expect(await transcribe(rt, path), 'hola');
    });

    test('without a lease nothing is sent', () async {
      final rt = HermesServerSttRuntime(
        transcribeRequest: (_, _) async => {'ok': true, 'transcript': 'x'},
        recorder: _Recorder(),
      );
      final path = '${dir.path}/turn.wav';
      await rt.start(path);
      await transcribe(rt, path);
      await rt.dispose();
      expect(wire.calls, isEmpty);
    });
  });

  test('DashboardClient.setSttLease posts Desktop body and profile', () async {
    final requests = <http.Request>[];
    final dashboard = DashboardClient(
      host: '192.168.1.20',
      port: 9119,
      manualToken: 'test-token',
      httpClientOverride: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({'ok': true, 'lease': 'l', 'active': true}),
          200,
        );
      }),
    );
    addTearDown(dashboard.close);

    await dashboard.setSttLease('console:voice-input:x', active: true);
    await dashboard.setSttLease(
      'console:voice-input:x',
      active: false,
      profile: 'work',
    );

    expect(requests.map((r) => r.method), ['POST', 'POST']);
    expect(requests.first.url.path, '/api/audio/stt-lease');
    expect(requests.first.url.queryParameters, isEmpty);
    expect(jsonDecode(requests.first.body), {
      'lease': 'console:voice-input:x',
      'active': true,
    });
    expect(requests.last.url.queryParameters['profile'], 'work');
    expect(jsonDecode(requests.last.body)['active'], isFalse);
    expect(
      DashboardClient.audioSttLeaseRequestTimeout,
      const Duration(seconds: 180),
    );
  });

  test('the STT lease name shares the install id of the TTS lease', () async {
    SharedPreferences.setMockInitialValues({
      'app_locale': 'es',
      'voice_tts_lease_id_v1': 'install-1',
    });
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    expect(voice.debugSttLeaseName, 'console:voice-input:install-1');
  });

  test('dictation holds its own lease, apart from the conversation '
      '(REVIEW-R5-B #27)', () async {
    SharedPreferences.setMockInitialValues({
      'app_locale': 'es',
      'voice_tts_lease_id_v1': 'install-1',
    });
    final prefs = await SharedPreferences.getInstance();
    final voice = VoiceService(prefs, SecureStorage());
    addTearDown(voice.dispose);
    expect(
      voice.debugDictationSttLeaseName,
      'console:voice-input:install-1:dictation',
    );
    expect(voice.debugDictationSttLeaseName, isNot(voice.debugSttLeaseName));
  });

  // REVIEW-R5-B #5: a lease left hanging by a dropped network must not fail
  // every transcription for minutes.
  group('a hanging lease', () {
    test('later acquires stop waiting on it after 10 s', () async {
      final wire = _Wire()..hold = Completer<void>();
      var now = DateTime.utc(2026, 10, 27, 9);
      final lease = HermesSttLease(
        name: 'console:voice-input:x',
        request: wire.call,
        now: () => now,
      );
      final first = lease.sync(true);
      now = now.add(const Duration(seconds: 5));
      expect(identical(lease.sync(true), first), isTrue);

      now = now.add(const Duration(seconds: 5));
      final later = lease.sync(true);
      expect(identical(later, first), isFalse);
      await later;
      expect(wire.calls, hasLength(1));
      wire.hold!.complete();
      await first;
    });

    test('the transcription goes on after the warm-up wait', () async {
      final dir = await Directory.systemTemp.createTemp('stt-lease-hang');
      addTearDown(() => dir.delete(recursive: true));
      final wire = _Wire()..hold = Completer<void>();
      final uploads = <String>[];
      final rt = HermesServerSttRuntime(
        transcribeRequest: (dataUrl, _) async {
          uploads.add(dataUrl);
          return {'ok': true, 'transcript': 'hola'};
        },
        recorder: _Recorder(),
        sttLease: () =>
            HermesSttLease(name: 'console:voice-input:x', request: wire.call),
        warmupWait: const Duration(milliseconds: 50),
      );
      final path = '${dir.path}/turn.wav';
      rt.prepareCapture(continuous: false, onPartial: (_) {});
      await rt.start(path);

      final text = await rt.transcribe(
        model: WhisperModel.tiny,
        audioPath: path,
        lang: 'es',
        threads: 2,
      );
      expect(text, 'hola');
      expect(uploads, hasLength(1));
      wire.hold!.complete();
    });
  });
}
