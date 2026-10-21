// NET-1 on the wire: the real chat service and shared gateway pool against a
// real `hermes serve`, cut in user space by tool/e2e/flap_proxy.py (§3.1).
//   E2E_FLAP=1 tool/e2e/run_local.sh --plain-name net1
// Thresholds are the contract's §3 targets, never tuned to a result.
@Timeout(Duration(minutes: 10))
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/flap.dart';
import 'support/real_gateway.dart';

final _env = E2eEnv.current;

const _opensPerCut = 1; // per physical cut window, backoff redials included
const _historyReadsPerRecovery = 2;
const _idleProbesPerMinute = 6; // the heartbeat (gateway.ping) not counted
const _liveSocketsPerLane = 2;
const _restLimitMs = 11000; // the Dashboard client's 10 s deadline + 1 s
final _run = DateTime.now().millisecondsSinceEpoch.toRadixString(36);

String _prompt(String kind, String tag) => '[E2E:$kind:$tag$_run] please';

Future<void> _wait(int s) => Future<void>.delayed(Duration(seconds: s));

void main() {
  useRealNetwork();

  late FlapConsole phone;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    phone = FlapConsole(_env);
    await phone.proxy('pass');
  });
  tearDown(() async {
    // ignore: avoid_print
    print('[e2e-wire]\n${phone.meter.wireTrace()}');
    await phone.close();
  });

  final skip =
      (_env.vars['HERMES_E2E_PROXY_CONTROL'] ?? '').isEmpty ||
          _env.skipReason != null
      ? 'net1 flap: needs the proxy (E2E_FLAP=1 tool/e2e/run_local.sh)'
      : null;

  Future<ActiveChat> openIdle(String id) async {
    final chat = phone.open(id);
    await chat.loadMessages();
    await waitFor(
      () => chat.desktopRuntimeSessionId != null,
      what: 'runtime attach of $id',
    );
    return chat;
  }

  bool says(ActiveChat chat, String needle) => chat.messages.any(
    (m) => m['role'] == 'assistant' && '${m['content']}'.contains(needle),
  );

  Future<bool> send(ActiveChat chat, String text) => chat.send(
    fullText: text,
    model: 'fake-model',
    history: chat.buildHistory(),
  );

  /// Reports the proxy's numbers and checks the §3 targets: [cuts] is what the
  /// scenario inflicted; opens are bounded by one per cut window (the backoff
  /// dials in windows nobody validated too). Every miss is listed. An idle chat
  /// redials lazily, so a cut need not cause a redial (<= only). With
  /// [measured], a run whose cuts severed no live socket is invalid, not a pass.
  Future<void> judge(String name, int cuts, {bool measured = false}) async {
    final s = await phone.proxy('stats');
    reportBudget(name, {
      'proxy': s.brief,
      'qaAborted': phone.qaCount(' aborted '),
      'qaProbeTimeouts': phone.qaCount('reason=probe_timeout'),
      'qaBackoffs': phone.qaCount('ws backoff'),
    });
    final flap = flapVerdict(
      cuts: s['cuts'] as int,
      expectedCuts: cuts,
      opens: s.wsOpens,
      opensByWindow: measured ? s.opensByWindow : const {},
      severed: s.severedWs,
      maxOpens: cuts * _opensPerCut,
      requireSevered: measured,
    );
    final misses = [
      ...flap.problems,
      if (s.restWaitMs > _restLimitMs) 'REST unanswered ${s.restWaitMs} ms',
      if ((s['ws_live_max'] as int) > _liveSocketsPerLane)
        'live sockets ${s['ws_live_max']}',
      if (s.historyReads > _historyReadsPerRecovery * s.wsOpens.clamp(1, 99))
        'history reads ${s.historyReads}',
    ];
    expect(misses, isEmpty, reason: '$name: ${s.brief}');
  }

  /// One more prompt after the cut must still be answered exactly once.
  Future<void> expectConverged(ActiveChat chat, String tag) async {
    expect(await send(chat, _prompt('STREAM', tag)), isTrue);
    await waitFor(
      () => says(chat, 'streamed reply $tag$_run'),
      timeout: const Duration(seconds: 60),
      what: 'a reply after the cut ($tag)',
      chat: chat,
    );
    expect(await _env.modelTurnsFor('[E2E:STREAM:$tag$_run]'), 1);
  }

  /// Takes the link down with [mode] for [seconds]: `lost` goes first and a
  /// validated `available` when it returns, as Android sends them.
  Future<void> outage(
    String mode,
    int seconds, {
    void Function()? during,
  }) async {
    await phone.proxy('reset');
    await phone.proxy(mode);
    phone.signal('lost');
    during?.call();
    await _wait(seconds);
    await phone.proxy('pass');
    phone.signal('available');
  }

  test('net1 S1: three open chats through ten 3 s cuts', () async {
    final chats = [
      for (final n in [1, 2, 3]) await openIdle('e2e-chat-0$n'),
    ];
    await phone.proxy('reset');
    // Each window is driven here, in step with the platform signals, so the
    // proxy's cut and the client's `lost` cannot drift apart (a proxy-side
    // `flap 10 3 2` runs on its own timers).
    for (var i = 0; i < 10; i++) {
      await phone.proxy('rst');
      phone.signal('lost');
      await _wait(3);
      await phone.proxy('pass');
      // Odd cycles come back on a network Android never validated: no event.
      if (i.isEven) phone.signal('available');
      await _wait(2);
    }
    await _wait(15);
    await judge('net1-s1-flap', 10, measured: true);
    await expectConverged(chats.first, 's1');
  }, skip: skip);

  test('net1 S2: blackhole 20 s with a long turn in flight', () async {
    final chat = await openIdle('e2e-chat-04');
    expect(await send(chat, _prompt('SLEEP', 's2')), isTrue);
    final dash = phone.dashboard();
    await dash.getServerStatus(); // signed in before the link half-opens
    await _wait(3);
    await outage(
      'blackhole',
      20,
      // A REST call on the half-open link must stop at its deadline.
      during: () => dash.getServerStatus().ignore(),
    );
    await waitFor(
      () =>
          says(chat, 'slept s2$_run') &&
          chat.state == ChatPipelineState.completed,
      timeout: const Duration(seconds: 120),
      what: 'the turn to converge after the blackhole',
      chat: chat,
    );
    await _wait(5);
    await judge('net1-s2-blackhole', 1);
    expect(await _env.modelTurnsFor('[E2E:SLEEP:s2$_run]'), 1);
    int rows(String role, String text) => chat.messages
        .where((m) => m['role'] == role && '${m['content']}'.contains(text))
        .length;
    expect(
      [rows('user', 'E2E:SLEEP:s2$_run'), rows('assistant', 'slept s2$_run')],
      [1, 1],
      reason: 'prompt and reply, neither duplicated nor lost',
    );
  }, skip: skip);

  test('net1 S3: rst 30 s, then refuse 30 s (the backoff ladder)', () async {
    final chat = await openIdle('e2e-chat-05');
    for (final mode in ['rst', 'refuse']) {
      phone.qaNet.clear();
      await outage(mode, 30);
      await _wait(20);
      await judge('net1-s3-$mode', 1);
    }
    await expectConverged(chat, 's3');
  }, skip: skip);

  test('net1 S4: 120 s idle with a visible chat', () async {
    await openIdle('e2e-chat-01');
    await _wait(3);
    phone.meter.mark();
    await _wait(120);
    final rpc = phone.meter.rpcSinceMark();
    final pings = rpc.where((m) => m == 'gateway.ping').length;
    final perMinute = (rpc.length - pings) / 2;
    reportBudget('net1-s4-idle', {
      'probesPerMin': perMinute,
      'pingsPerMin': pings / 2,
      'rpc': rpc.join(','),
    });
    expect(perMinute, lessThanOrEqualTo(_idleProbesPerMinute));
  }, skip: skip);
}
