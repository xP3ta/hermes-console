import 'package:flutter/material.dart';
import 'package:hermes_android/core/models/activity_snapshot.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/turn_step_cards.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget turnSummaryHost(
  Widget child, {
  bool reduced = true,
  double scale = 1,
  String lang = 'es',
  ThemeData? theme,
}) => MaterialApp(
  locale: Locale(lang),
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  theme: theme ?? AppTheme.hermesRedDark,
  builder: (context, body) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: reduced,
      textScaler: TextScaler.linear(scale),
    ),
    child: body!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

TurnStepCardEntry summaryEntry(
  int index, {
  bool running = false,
  DateTime? start,
  DateTime Function()? clock,
}) => TurnStepCardEntry(
  id: 'tool-$index',
  kind: TurnStepCardKind.tool,
  title: running ? 'Leyendo' : 'Leyó',
  toolName: 'read_file',
  detail: activityToolDetail('read_file', {
    'path': '/private/project/file$index.dart',
  }),
  semanticsLabel: '${running ? 'Leyendo' : 'Leyó'} file$index.dart',
  running: running,
  duration: running ? null : Duration(seconds: index + 1),
  startedAt: start,
  clock: clock,
);
