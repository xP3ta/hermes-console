// Which microphone the Hermes server capture records from (backlog 1.4.x
// item 7: no voice with the phone connected to the car).
//
// `record` defaults to `manageBluetooth: true`: whenever a Bluetooth SCO input
// is listed (a car kit or a headset) it calls `startBluetoothSco()`, so the
// take comes from that microphone, and nothing is heard until the SCO link is
// up (`record_android` RecorderWrapper.maybeStartBluetooth, BluetoothReceiver).
// «Phone» turns that off and asks for the built-in microphone.

import 'package:record/record.dart';

enum VoiceMicrophone {
  /// Android and `record` choose, Bluetooth included (the behaviour so far).
  automatic('automatic'),

  /// The phone's own microphone, even with a car or headset connected.
  phone('phone');

  const VoiceMicrophone(this.id);
  final String id;

  static VoiceMicrophone from(String? value) => values.firstWhere(
    (item) => item.id == value,
    orElse: () => VoiceMicrophone.automatic,
  );
}

/// `record_android` labels each input `productName (type, address)` with a
/// fixed English type name (`DeviceUtils.typeToString`).
const String _kBuiltInMicrophoneType = '(built-in microphone';

/// The built-in microphone among [devices], or null when it is not listed.
/// The Hermes server capture asks for it when the setting is «phone».
InputDevice? builtInMicrophoneOf(List<InputDevice> devices) {
  for (final device in devices) {
    if (device.label.contains(_kBuiltInMicrophoneType)) return device;
  }
  return null;
}

/// [base] for [choice]. «Phone» never starts Bluetooth SCO and, when the
/// built-in microphone is listed, asks for it explicitly.
RecordConfig recordConfigForMicrophone(
  RecordConfig base,
  VoiceMicrophone choice, {
  InputDevice? builtIn,
}) {
  if (choice == VoiceMicrophone.automatic) return base;
  final android = base.androidConfig;
  return RecordConfig(
    encoder: base.encoder,
    bitRate: base.bitRate,
    sampleRate: base.sampleRate,
    numChannels: base.numChannels,
    device: builtIn ?? base.device,
    autoGain: base.autoGain,
    echoCancel: base.echoCancel,
    noiseSuppress: base.noiseSuppress,
    androidConfig: AndroidRecordConfig(
      useLegacy: android.useLegacy,
      muteAudio: android.muteAudio,
      manageBluetooth: false,
      audioSource: android.audioSource,
      speakerphone: android.speakerphone,
      audioManagerMode: android.audioManagerMode,
    ),
    iosConfig: base.iosConfig,
    audioInterruption: base.audioInterruption,
    streamBufferSize: base.streamBufferSize,
  );
}
