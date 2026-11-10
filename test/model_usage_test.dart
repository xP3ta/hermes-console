import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/model_usage.dart';

void main() {
  const a = (provider: 'p', model: 'a');
  const b = (provider: 'p', model: 'b');
  const c = (provider: 'q', model: 'c');

  test('counts picks and ranks the frequent ones, ties by catalog order', () {
    var usage = ModelUsage.empty;
    for (final pick in [b, b, c, c, a]) {
      usage = usage.bumped(pick.provider, pick.model);
    }
    // a has one pick: below the bar. b and c tie: catalog order decides.
    expect(usage.top([a, b, c]), [b, c]);
    expect(usage.top([c, b, a]), [c, b]);
    usage = usage.bumped('q', 'c');
    expect(usage.top([a, b, c]), [c, b]);
    expect(usage.top([a, b, c], limit: 1), [c]);
  });

  test('round-trips and survives garbage', () {
    final usage = ModelUsage.empty.bumped('p', 'a').bumped('p', 'a');
    expect(ModelUsage.decode(usage.encode()).countOf('p', 'a'), 2);
    expect(ModelUsage.decode('not json').countOf('p', 'a'), 0);
    expect(ModelUsage.decode('[1,2]').countOf('p', 'a'), 0);
    expect(
      ModelUsage.decode('{"x":"y","p|a":-3,"p|b":2}').countOf('p', 'b'),
      2,
    );
    expect(ModelUsage.decode('{"p|a":-3}').countOf('p', 'a'), 0);
    expect(ModelUsage.empty.bumped('', 'a').countOf('', 'a'), 0);
  });

  test('stays bounded', () {
    var usage = ModelUsage.empty.bumped('p', 'm0').bumped('p', 'm0');
    for (var i = 1; i < ModelUsage.maxEntries + 10; i++) {
      usage = usage.bumped('p', 'm$i');
    }
    final kept = [
      for (var i = 0; i < ModelUsage.maxEntries + 10; i++)
        if (usage.countOf('p', 'm$i') > 0) i,
    ];
    expect(kept.length, ModelUsage.maxEntries);
    expect(kept, contains(0));
  });
}
