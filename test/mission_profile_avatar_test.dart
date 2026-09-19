import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/agent_profile.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/hermes_bot_face.dart';
import 'package:hermes_android/core/widgets/mission_profile_avatar.dart';

AgentProfileAvatar _avatar() => AgentProfileAvatar.fromDataUri(
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  test('cache deduplicates profiles and caps concurrent loads', () async {
    final gates = <String, Completer<AgentProfileAvatar?>>{};
    var active = 0;
    var peak = 0;
    var calls = 0;
    final cache = MissionProfileAvatarCache(
      maxConcurrent: 2,
      loader: (profile) {
        calls++;
        active++;
        if (active > peak) peak = active;
        final gate = gates.putIfAbsent(profile, Completer.new);
        return gate.future.whenComplete(() => active--);
      },
    );

    final first = cache.load('manager');
    final duplicate = cache.load('manager');
    final second = cache.load('infra');
    final queued = cache.load('security');
    await Future<void>.delayed(Duration.zero);

    expect(identical(first, duplicate), isTrue);
    expect(calls, 2);
    expect(peak, 2);
    gates['manager']!.complete(_avatar());
    await Future<void>.delayed(Duration.zero);
    expect(calls, 3);
    gates['infra']!.complete();
    gates['security']!.complete();
    await Future.wait([first, second, queued]);
    expect(peak, 2);
  });

  testWidgets('uses deterministic Blobatar when no asset or face exists', (
    tester,
  ) async {
    final cache = MissionProfileAvatarCache(loader: (_) async => null);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        home: Scaffold(
          body: MissionProfileAvatar(
            profileName: 'manager',
            hasAvatar: true,
            cache: cache,
            manager: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final face = tester.widget<HermesBotFace>(find.byType(HermesBotFace));
    expect(face.visual, isA<HermesBlobatarFaceVisual>());
    expect((face.visual as HermesBlobatarFaceVisual).seed, 'manager');
    expect(find.text('M'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('presents legacy classic metadata as deterministic Blobatar', (
    tester,
  ) async {
    final cache = MissionProfileAvatarCache(loader: (_) async => null);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        home: Scaffold(
          body: MissionProfileAvatar(
            profileName: 'infra',
            hasAvatar: true,
            cache: cache,
            shape: 'cloud',
            colorHex: '#38bdf8',
          ),
        ),
      ),
    );
    await tester.pump();

    final face = tester.widget<HermesBotFace>(find.byType(HermesBotFace));
    expect(face.visual, isA<HermesBlobatarFaceVisual>());
    final visual = face.visual as HermesBlobatarFaceVisual;
    expect(visual.shapeWire, 'blobatar');
    expect(visual.seed, 'infra');
    expect(find.text('I'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the persisted Blobatar wire with the shared renderer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        home: const Scaffold(
          body: MissionProfileAvatar(
            profileName: 'codex-qa',
            hasAvatar: false,
            cache: null,
            shape: 'blobatar::triangle',
            colorHex: '#f97316',
          ),
        ),
      ),
    );

    final face = tester.widget<HermesBotFace>(find.byType(HermesBotFace));
    expect(face.visual, isA<HermesBlobatarFaceVisual>());
    final visual = face.visual as HermesBlobatarFaceVisual;
    expect(visual.shapeWire, 'blobatar::triangle');
    expect(visual.seed, 'codex-qa');
    expect(visual.pinnedKind, 'triangle');
    expect(tester.takeException(), isNull);
  });

  testWidgets('ignores Desktop raster backfill for procedural faces', (
    tester,
  ) async {
    var loads = 0;
    final cache = MissionProfileAvatarCache(
      loader: (_) async {
        loads++;
        return _avatar();
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        home: Scaffold(
          body: MissionProfileAvatar(
            profileName: 'codex-qa',
            hasAvatar: true,
            cache: cache,
            shape: 'blobatar::triangle',
            imageKind: 'shape',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(loads, 0);
    expect(find.byType(Image), findsNothing);
    final face = tester.widget<HermesBotFace>(find.byType(HermesBotFace));
    expect((face.visual as HermesBlobatarFaceVisual).pinnedKind, 'triangle');
    expect(tester.takeException(), isNull);
  });

  test(
    'resolved lookup is synchronous once loaded and leaves with its entry',
    () async {
      final cache = MissionProfileAvatarCache(
        maxEntries: 1,
        loader: (profile) async => profile == 'none' ? null : _avatar(),
      );
      expect(cache.hasResolved('manager'), isFalse);
      final pending = cache.load('manager');
      expect(cache.hasResolved('manager'), isFalse, reason: 'still in flight');
      final loaded = await pending;
      expect(loaded, isNotNull);
      expect(cache.hasResolved('manager'), isTrue);
      expect(identical(cache.resolved('manager'), loaded), isTrue);
      expect(
        cache.hasResolved(' manager '),
        isTrue,
        reason: 'trimmed like load',
      );

      // A resolved "no avatar" is still a resolved answer, not a cache miss.
      await cache.load('none');
      expect(cache.hasResolved('none'), isTrue);
      expect(cache.resolved('none'), isNull);
      // maxEntries: 1 → loading `none` evicted `manager` together with its value.
      expect(cache.hasResolved('manager'), isFalse);

      cache.clear();
      expect(cache.hasResolved('none'), isFalse);
    },
  );

  test('an eviction before completion never resurrects the value', () async {
    final gate = Completer<AgentProfileAvatar?>();
    final cache = MissionProfileAvatarCache(
      maxEntries: 1,
      loader: (profile) => profile == 'slow' ? gate.future : Future.value(),
    );
    final slow = cache.load('slow');
    await cache.load('other'); // evicts `slow` while still in flight
    gate.complete(_avatar());
    await slow;
    expect(cache.hasResolved('slow'), isFalse);
    expect(cache.hasResolved('other'), isTrue);
  });

  testWidgets('a cached avatar paints on the first frame, no FutureBuilder', (
    tester,
  ) async {
    final cache = MissionProfileAvatarCache(loader: (_) async => _avatar());
    await cache.load('manager');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.fromId('dark'),
        home: Scaffold(
          body: MissionProfileAvatar(
            profileName: 'manager',
            hasAvatar: true,
            cache: cache,
          ),
        ),
      ),
    );
    // Deliberately no extra pump: the image must be there in the very first
    // frame instead of one microtask later (which showed the fallback face).
    expect(find.byType(FutureBuilder<AgentProfileAvatar?>), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(HermesBotFace), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
