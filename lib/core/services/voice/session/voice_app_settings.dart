import 'package:flutter/services.dart';

const MethodChannel _androidApps = MethodChannel('hermes/android_apps');

/// Opens this app's page in the system settings, where the microphone
/// permission lives once the system stops asking. False when it cannot open.
/// [channel] exists for tests.
Future<bool> openAppSettingsForVoice({MethodChannel? channel}) async {
  try {
    return await (channel ?? _androidApps).invokeMethod<bool>(
          'openAppSettings',
        ) ??
        false;
  } catch (_) {
    return false;
  }
}
