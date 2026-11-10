import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/stt_hermes_server.dart';
import 'package:hermes_android/core/services/voice/voice_microphone.dart';
import 'package:hermes_android/core/services/voice/voice_settings.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Backlog 1.4.x item 7: «Microphone: automatic / the phone's». `record`
/// starts Bluetooth SCO by default (`manageBluetooth: true`), which hands the
/// take to a car kit or a headset.
const _builtIn = InputDevice(
  id: '7',
  label: 'Pixel 9 (built-in microphone, bottom)',
);
const _car = InputDevice(
  id: '31',
  label: 'Car kit (Bluetooth telephony SCO, 00:11:22:33:44:55)',
);

class _Recorder extends Fake implements AudioRecorder {
  _Recorder({this.listFails = false});

  final List<InputDevice> devices = const [_car, _builtIn];
  final bool listFails;
  final List<RecordConfig> started = [];

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<List<InputDevice>> listInputDevices() async {
    if (listFails) throw StateError('no device list');
    return devices;
  }

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    started.add(config);
    File(path).writeAsBytesSync(const [1, 2, 3, 4]);
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    started.add(config);
    return const Stream<Uint8List>.empty();
  }

  @override
  Future<String?> stop() async => null;

  @override
  Future<void> dispose() async {}
}

void main() {
  test('stored ids; anything unknown is automatic', () {
    expect(VoiceMicrophone.from('phone'), VoiceMicrophone.phone);
    expect(VoiceMicrophone.from('automatic'), VoiceMicrophone.automatic);
    expect(VoiceMicrophone.from(null), VoiceMicrophone.automatic);
    expect(VoiceMicrophone.from('car'), VoiceMicrophone.automatic);
  });

  test('the built-in microphone is found by its record_android type', () {
    expect(builtInMicrophoneOf(const [_car, _builtIn]), _builtIn);
    expect(builtInMicrophoneOf(const [_car]), isNull);
  });

  test('automatic is the capture as it was', () {
    expect(
      recordConfigForMicrophone(
        kHermesServerSttRecordConfig,
        VoiceMicrophone.automatic,
        builtIn: _builtIn,
      ),
      same(kHermesServerSttRecordConfig),
    );
  });

  test('phone: no Bluetooth SCO, the built-in device, the rest unchanged', () {
    for (final base in [
      kHermesServerSttRecordConfig,
      kHermesServerLiveSttRecordConfig,
    ]) {
      final config = recordConfigForMicrophone(
        base,
        VoiceMicrophone.phone,
        builtIn: _builtIn,
      );
      expect(base.androidConfig.manageBluetooth, isTrue);
      expect(config.androidConfig.manageBluetooth, isFalse);
      expect(config.device, _builtIn);
      expect(config.encoder, base.encoder);
      expect(config.sampleRate, base.sampleRate);
      expect(config.numChannels, base.numChannels);
      expect(config.echoCancel, base.echoCancel);
      expect(config.noiseSuppress, base.noiseSuppress);
      expect(config.androidConfig.audioSource, base.androidConfig.audioSource);
    }
  });

  group('the Hermes server capture reads the choice per take', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('voice-mic');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    Future<RecordConfig> take(
      _Recorder recorder,
      VoiceMicrophone choice,
    ) async {
      final runtime = HermesServerSttRuntime(
        transcribeRequest: (_, _) async => <String, dynamic>{'ok': true},
        recorder: recorder,
        microphone: () => choice,
      );
      await runtime.start('${dir.path}/take.wav');
      await runtime.stop();
      return recorder.started.last;
    }

    test('automatic leaves record to choose', () async {
      final config = await take(_Recorder(), VoiceMicrophone.automatic);
      expect(config, same(kHermesServerSttRecordConfig));
    });

    test('phone asks for the built-in microphone', () async {
      final config = await take(_Recorder(), VoiceMicrophone.phone);
      expect(config.device, _builtIn);
      expect(config.androidConfig.manageBluetooth, isFalse);
    });

    test('phone without a device list still keeps SCO off', () async {
      final config = await take(
        _Recorder(listFails: true),
        VoiceMicrophone.phone,
      );
      expect(config.device, isNull);
      expect(config.androidConfig.manageBluetooth, isFalse);
    });
  });

  test('the setting persists and defaults to automatic', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(VoiceSettings.load(prefs).microphone, VoiceMicrophone.automatic);
    await const VoiceSettings(microphone: VoiceMicrophone.phone).save(prefs);
    expect(prefs.getString('voice_microphone'), 'phone');
    expect(VoiceSettings.load(prefs).microphone, VoiceMicrophone.phone);
  });
}
