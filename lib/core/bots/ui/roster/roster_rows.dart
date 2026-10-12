import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Row time like a messenger: "now", HH:mm today, "yesterday", weekday this
/// week, otherwise d MMM.
String rosterTime(BuildContext context, DateTime at, {DateTime? now}) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  final english = Localizations.localeOf(context).languageCode == 'en';
  final current = now ?? DateTime.now();
  final diff = current.difference(at);
  if (diff.inSeconds.abs() < 60) return english ? 'now' : 'ahora';
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(at.year, at.month, at.day);
  final days = today.difference(day).inDays;
  if (days <= 0) return DateFormat.Hm(locale).format(at);
  if (days == 1) return english ? 'yesterday' : 'ayer';
  if (days < 7) return DateFormat.E(locale).format(at);
  return DateFormat.MMMd(locale).format(at);
}
