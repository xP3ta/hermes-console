import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_consent_store.dart';
import 'package:hermes_android/core/widgets/chat/embeds/embed_detector.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every type is off by default', () async {
    final store = EmbedConsentStore.forTesting(
      await SharedPreferences.getInstance(),
    );
    for (final type in EmbedType.values) {
      expect(store.modeFor(type), EmbedMode.off, reason: type.name);
    }
    expect(EmbedConsentStore.shared.modeFor(EmbedType.youtube), EmbedMode.off);
  });

  test('modes persist per type across a reload', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = EmbedConsentStore.forTesting(prefs);
    await store.setMode(EmbedType.youtube, EmbedMode.always);
    await store.setMode(EmbedType.vimeo, EmbedMode.ask);
    final again = EmbedConsentStore.forTesting(prefs);
    expect(again.modeFor(EmbedType.youtube), EmbedMode.always);
    expect(again.modeFor(EmbedType.vimeo), EmbedMode.ask);
    expect(again.modeFor(EmbedType.spotify), EmbedMode.off);
  });

  test('turning a type off removes its key', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = EmbedConsentStore.forTesting(prefs);
    await store.setMode(EmbedType.svg, EmbedMode.ask);
    await store.setMode(EmbedType.svg, EmbedMode.off);
    expect(prefs.getKeys().where((k) => k.contains('embed')), isEmpty);
  });

  test('clear sends every always back to ask and keeps the rest', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = EmbedConsentStore.forTesting(prefs);
    await store.setMode(EmbedType.youtube, EmbedMode.always);
    await store.setMode(EmbedType.vimeo, EmbedMode.ask);
    expect(store.anyAllowed, isTrue);
    await store.clearAllowed();
    expect(store.modeFor(EmbedType.youtube), EmbedMode.ask);
    expect(store.modeFor(EmbedType.vimeo), EmbedMode.ask);
    expect(store.modeFor(EmbedType.tiktok), EmbedMode.off);
    expect(store.anyAllowed, isFalse);
    expect(
      EmbedConsentStore.forTesting(prefs).modeFor(EmbedType.youtube),
      EmbedMode.ask,
    );
  });

  test('an unknown stored value reads as off', () async {
    SharedPreferences.setMockInitialValues({
      '${EmbedConsentStore.keyPrefix}youtube': 'sometimes',
    });
    final store = EmbedConsentStore.forTesting(
      await SharedPreferences.getInstance(),
    );
    expect(store.modeFor(EmbedType.youtube), EmbedMode.off);
  });

  test('the store notifies on change', () async {
    final store = EmbedConsentStore.forTesting(
      await SharedPreferences.getInstance(),
    );
    var calls = 0;
    store.addListener(() => calls++);
    await store.setMode(EmbedType.maps, EmbedMode.ask);
    await store.setMode(EmbedType.maps, EmbedMode.ask);
    expect(calls, 1);
  });
}
