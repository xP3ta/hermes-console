// SPDX-FileCopyrightText: 2026 Hermes Console contributors
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/platform/android_apps.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hermes/android_apps');
  const apps = AndroidApps();
  final calls = <MethodCall>[];

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  test('client bridge retires command APIs and native dispatch', () {
    final dart = File(
      'lib/core/services/platform/android_apps.dart',
    ).readAsStringSync();
    for (final method in [
      'runInTermux',
      'probeTermux',
      'launchTermuxForeground',
    ]) {
      expect(dart, isNot(contains(method)), reason: 'Dart API: $method');
    }
  });

  test('native bridge retires command dispatch and exclusive helpers', () {
    final native = File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/MainActivity.kt',
    ).readAsStringSync();
    for (final method in [
      'runInTermux',
      'probeTermux',
      'launchTermuxForeground',
    ]) {
      expect(native, isNot(contains(method)), reason: 'Native API: $method');
    }
    for (final obsolete in [
      'com.termux',
      'hasTermuxRunPermission',
      'whitelistTermux',
      'startServiceCompat',
      'termuxPermissionRequestCode',
    ]) {
      expect(native, isNot(contains(obsolete)));
    }
    expect(native, contains('else -> result.notImplemented()'));
    for (final capability in [
      '"isInstalled"',
      '"launch"',
      '"deviceInfo"',
      '"openAppSettings"',
      '"hermes/security"',
      '"hermes/share"',
      '"hermes/pcm_stream"',
      'NewSessionLaunchContract.parse(intent)',
      'HermesRichNotifications.attach(applicationContext, it)',
    ]) {
      expect(native, contains(capability));
    }
  });

  test('legitimate package and device calls retain channel payloads', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'isInstalled':
            case 'launch':
              return true;
            case 'deviceInfo':
              return {
                'totalRamBytes': 8589934592,
                'availRamBytes': 4294967296,
                'freeDiskBytes': 2147483648,
                'abis': ['arm64-v8a'],
              };
            default:
              throw MissingPluginException();
          }
        });
    expect(await apps.isInstalled('org.example.client'), isTrue);
    expect(await apps.launch('org.example.client'), isTrue);
    final info = await apps.deviceInfo();
    expect(info.totalRamBytes, 8589934592);
    expect(info.availRamBytes, 4294967296);
    expect(info.freeDiskBytes, 2147483648);
    expect(info.abis, ['arm64-v8a']);
    expect(calls.map((call) => call.method), [
      'isInstalled',
      'launch',
      'deviceInfo',
    ]);
    expect(calls[0].arguments, {'package': 'org.example.client'});
    expect(calls[1].arguments, {'package': 'org.example.client'});
    expect(calls[2].arguments, isNull);
  });

  for (final failure in [
    PlatformException(code: 'denied'),
    MissingPluginException(),
  ]) {
    test(
      'client bridge keeps safe fallback for ${failure.runtimeType}',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              throw failure;
            });
        expect(await apps.isInstalled('org.example.client'), isFalse);
        expect(await apps.launch('org.example.client'), isFalse);
        expect(await apps.deviceInfo(), same(DeviceInfo.unknown));
        expect(calls, hasLength(3));
      },
    );
  }

  test('AppBridge can be implemented with client-only capabilities', () async {
    final AppBridge bridge = _ClientOnlyBridge();
    expect(await bridge.isInstalled('org.example.client'), isTrue);
    expect(await bridge.launch('org.example.client'), isTrue);
    expect(await bridge.installFromFDroid('org.example.client'), isFalse);
    expect(await bridge.deviceInfo(), same(DeviceInfo.unknown));
    expect(calls, isEmpty);
  });

  test('client bridge keeps null-result defaults and F-Droid URL', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    expect(await apps.isInstalled('org.example.client'), isFalse);
    expect(await apps.launch('org.example.client'), isFalse);
    expect(await apps.deviceInfo(), same(DeviceInfo.unknown));
    expect(
      AndroidApps.fdroidWebUrl('org.example.client').toString(),
      'https://f-droid.org/en/packages/org.example.client/',
    );
  });
}

class _ClientOnlyBridge implements AppBridge {
  @override
  Future<bool> isInstalled(String package) async => true;

  @override
  Future<bool> launch(String package) async => true;

  @override
  Future<bool> installFromFDroid(String package) async => false;

  @override
  Future<DeviceInfo> deviceInfo() async => DeviceInfo.unknown;
}
