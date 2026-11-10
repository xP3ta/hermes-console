// Lo que se ve al guardar en el móvil (1.4.0, orden DESCARGAS-DIRECTAS): el
// motivo de cada fallo con «Reintentar», y lo que se puede hacer con un
// documento ya guardado (Abrir, Compartir, Guardar otra copia…). Lo usan
// todos los «Guardar» de la app y las descargas SFTP.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart' show HermesAction, showHermesMenu;
import '../feedback/feedback_policy.dart';
import '../services/save_to_device.dart';
import 'hermes_notice.dart' show HermesNoticeAction;

/// Says why [failure] happened, with «Reintentar» when [retry] is given.
/// A save the user stopped is said as such, without a retry.
void notifySaveFailure(
  FeedbackSink notice,
  Strings strings,
  SaveFailure failure, {
  VoidCallback? retry,
}) {
  final cancelled = failure.problem == SaveProblem.cancelled;
  notice.notify(
    cancelled ? FeedbackKind.routine : FeedbackKind.critical,
    saveProblemMessage(strings, failure.problem),
    warning: !cancelled,
    action: cancelled || retry == null
        ? null
        : HermesNoticeAction(label: strings.commonRetry, onPressed: retry),
  );
}

/// «Guardado: name», with «Ver» for what can be done with it.
void notifySaved(
  BuildContext context,
  SavedDocument saved, {
  SaveToDevice device = const SaveToDevice(),
}) {
  final strings = Strings.of(context);
  final navigator = Navigator.of(context);
  AppFeedback.of(context).notify(
    FeedbackKind.critical,
    strings.saveSaved(saved.name),
    action: HermesNoticeAction(
      label: strings.sftpDlShow,
      onPressed: () {
        if (!navigator.mounted) return;
        // Under the navigator (its overlay), where menus and notices live,
        // even once the screen that saved it is gone.
        final menuContext = navigator.overlay?.context ?? navigator.context;
        unawaited(showSavedDocumentActions(menuContext, saved, device: device));
      },
    ),
  );
}

/// Asks where to save the app's file [file] (as [name]), copies it there
/// by blocks and says how it went. Null when the dialog was closed or it
/// failed (the reason is said, with «Reintentar»). [source] names the
/// button in logcat (`[save] tap source=…`).
Future<SavedDocument?> saveFileToDevice(
  BuildContext context,
  File file, {
  required String name,
  required String source,
  SaveToDevice device = const SaveToDevice(),
}) => _save(
  context,
  source,
  () => device.saveFile(file, name: name),
  device,
  retry: (context) => saveFileToDevice(
    context,
    file,
    name: name,
    source: source,
    device: device,
  ),
);

/// Asks where to save [data] (as [name]) and writes it straight there,
/// block by block; says how it went.
Future<SavedDocument?> saveBytesToDevice(
  BuildContext context,
  Uint8List data, {
  required String name,
  required String source,
  SaveToDevice device = const SaveToDevice(),
}) => _save(
  context,
  source,
  () => device.saveBytes(data, name: name),
  device,
  retry: (context) => saveBytesToDevice(
    context,
    data,
    name: name,
    source: source,
    device: device,
  ),
);

Future<SavedDocument?> _save(
  BuildContext context,
  String source,
  Future<SavedDocument?> Function() save,
  SaveToDevice device, {
  required Future<SavedDocument?> Function(BuildContext context) retry,
}) async {
  saveLog('tap source=$source');
  final strings = Strings.of(context);
  final notice = AppFeedback.of(context);
  try {
    final saved = await save();
    if (saved != null && context.mounted) {
      notifySaved(context, saved, device: device);
    }
    return saved;
  } on SaveFailure catch (failure) {
    notifySaveFailure(
      notice,
      strings,
      failure,
      retry: () {
        if (context.mounted) unawaited(retry(context));
      },
    );
    return null;
  }
}

/// The menu of a saved document: Abrir, Compartir, Guardar otra copia….
Future<void> showSavedDocumentActions(
  BuildContext context,
  SavedDocument saved, {
  SaveToDevice device = const SaveToDevice(),
}) async {
  final strings = Strings.of(context);
  final notice = AppFeedback.of(context);
  saveLog('tap source=saved_menu');
  final action = await showHermesMenu<String>(
    context: context,
    title: saved.name,
    surfaceKey: const ValueKey('saved-document-menu'),
    actions: [
      HermesAction(
        value: 'open',
        icon: Icons.open_in_new_rounded,
        label: strings.commonOpen,
      ),
      HermesAction(
        value: 'share',
        icon: Icons.share_outlined,
        label: strings.commonShare,
      ),
      HermesAction(
        value: 'copy',
        icon: Icons.save_alt_rounded,
        label: strings.saveAnotherCopy,
      ),
    ],
  );
  saveLog('menu choice=${action ?? 'none'} mounted=${context.mounted}');
  if (action == null || !context.mounted) return;
  try {
    switch (action) {
      case 'open':
        await device.open(saved.uri);
      case 'share':
        await device.share(saved.uri);
      case 'copy':
        final copy = await device.saveAnotherCopy(saved);
        if (copy != null && context.mounted) {
          notifySaved(context, copy, device: device);
        }
    }
  } on SaveFailure catch (failure) {
    notifySaveFailure(
      notice,
      strings,
      failure,
      retry: () {
        if (context.mounted) {
          unawaited(showSavedDocumentActions(context, saved, device: device));
        }
      },
    );
  }
}
