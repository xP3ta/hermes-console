// SPDX-License-Identifier: GPL-3.0-only
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/notifications/background_listener.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// i18n-approval (emulator QA H5): a cron run the server leaves untitled is
/// named «Tarea programada» by [Session.displayTitle], the Spanish source
/// fallback. Its notification speaks the notification language instead.
const _untitledCronRun = Session(
  id: 'cron_job-1_20260901_020000',
  title: '',
  model: '',
  source: 'cron',
  messageCount: 2,
  isActive: false,
  preview: '',
  startedAt: 20,
  endedAt: 21,
  updatedAt: 21,
  profile: 'default',
);

const _languages = ['es', 'en', 'de', 'fr', 'it', 'pt', 'ja', 'ko', 'zh'];

void main() {
  for (final lang in _languages) {
    test('an untitled cron run is named in the notification language '
        '($lang)', () {
      final strings = lookupStrings(Locale(lang));
      final executions = BackgroundCronWatch.mergeExecutionAuthority(
        jobExecutions: const [],
        sessions: const [_untitledCronRun],
        strings: strings,
      );

      expect(executions, hasLength(1));
      expect(executions.single.title, strings.i18n1215ScheduledTask);
      if (lang != 'es') {
        expect(executions.single.title, isNot('Tarea programada'));
      }
      expect(
        BackgroundCronWatch.cronSessionTitle(
          _untitledCronRun,
          fallback: 'Housing search',
          strings: strings,
        ),
        strings.i18n1215ScheduledTask,
      );
    });
  }

  test('without a session the job title stays', () {
    expect(
      BackgroundCronWatch.cronSessionTitle(
        null,
        fallback: 'Housing search',
        strings: lookupStrings(const Locale('en')),
      ),
      'Housing search',
    );
  });
}
