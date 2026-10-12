import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/modal.dart'
    show HermesDialogAction, HermesDialogActionStyle, showHermesDialog;
import '../design/tokens.dart';
import '../theme/app_theme.dart';
import 'hermes_app_bar.dart';

/// Opens a create/edit form as a full-screen route. Every multi-field or
/// long-text form uses this instead of a floating card, so the user sees
/// what they write and the page (not a tiny inner box) scrolls.
Future<T?> pushHermesFormPage<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String? name,
}) => Navigator.of(context).push<T>(
  MaterialPageRoute<T>(
    fullscreenDialog: true,
    settings: RouteSettings(name: name),
    builder: builder,
  ),
);

/// The one scaffold shared by create/edit forms: close ✕ on the left, the
/// title, and the primary action (Create/Save) on the right, disabled until
/// [onSubmit] is non-null. The body is a single page scroll with comfortable
/// spacing, so multiline fields grow with their content instead of
/// scrolling inside a small box, and the keyboard never hides the action.
///
/// While [dirty], leaving (✕, system back, swipe) asks before discarding;
/// a programmatic `Navigator.pop` with a result (the form's own submit)
/// always goes through. While [busy] the page cannot be left and the action
/// shows progress.
class HermesFormPage extends StatefulWidget {
  final String title;
  final String submitLabel;
  final VoidCallback? onSubmit;
  final List<Widget> children;
  final bool dirty;
  final bool busy;
  final Key? submitKey;
  final Key? bodyKey;
  final Key closeKey;
  final double maxContentWidth;

  const HermesFormPage({
    super.key,
    required this.title,
    required this.submitLabel,
    required this.onSubmit,
    required this.children,
    this.dirty = false,
    this.busy = false,
    this.submitKey,
    this.bodyKey,
    this.closeKey = const ValueKey('form-page-close'),
    this.maxContentWidth = 640,
  });

  @override
  State<HermesFormPage> createState() => _HermesFormPageState();
}

class _HermesFormPageState extends State<HermesFormPage> {
  bool _allowPop = false;
  bool _asking = false;

  Future<void> _confirmDiscard() async {
    if (_asking || widget.busy) return;
    _asking = true;
    final s = Strings.of(context);
    final discard = await showHermesDialog<bool>(
      context: context,
      surfaceKey: const ValueKey('form-page-discard-dialog'),
      title: s.fp1215DiscardTitle,
      message: s.fp1215DiscardBody,
      actions: [
        HermesDialogAction(
          key: const ValueKey('form-page-keep-editing'),
          label: s.fp1215KeepEditing,
          value: false,
          style: HermesDialogActionStyle.cancel,
        ),
        HermesDialogAction(
          key: const ValueKey('form-page-discard'),
          label: s.fp1215Discard,
          value: true,
          style: HermesDialogActionStyle.destructive,
        ),
      ],
    );
    _asking = false;
    if (discard != true || !mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final canPop = !widget.busy && (_allowPop || !widget.dirty);
    // The action never pushes the title off a 320 dp phone at large text.
    final actionMaxWidth = MediaQuery.sizeOf(context).width * 0.42;
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmDiscard());
      },
      child: Scaffold(
        appBar: HermesAppBar(
          centerTitle: false,
          leading: IconButton(
            key: widget.closeKey,
            tooltip: s.commonClose,
            icon: const Icon(Icons.close_rounded),
            onPressed: widget.busy
                ? null
                : () => Navigator.of(context).maybePop(),
          ),
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: FilledButton(
                key: widget.submitKey,
                onPressed: widget.busy ? null : widget.onSubmit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 40),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(HermesRadius.control),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                child: widget.busy
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.textSecondary,
                        ),
                      )
                    : ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: actionMaxWidth),
                        child: Text(
                          widget.submitLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textScaler: MediaQuery.textScalerOf(
                            context,
                          ).clamp(maxScaleFactor: 1.3),
                        ),
                      ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxContentWidth),
              // Not a lazy list: every field stays mounted, so Form
              // validation sees all of them and a field scrolled away keeps
              // its state; forms are short enough to build at once.
              child: SingleChildScrollView(
                clipBehavior: hermesUnderHeader,
                key: widget.bodyKey,
                padding: const EdgeInsets.fromLTRB(
                  HermesSpace.pageH,
                  HermesSpace.pageTop,
                  HermesSpace.pageH,
                  HermesSpace.pageBottom + 24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled block inside a [HermesFormPage]: a small sentence-case label,
/// optional help text, then the control, with the page's vertical rhythm.
class HermesFormSection extends StatelessWidget {
  final String? label;
  final String? help;
  final Widget child;

  const HermesFormSection({
    super.key,
    this.label,
    this.help,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.only(top: HermesSpace.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                label!,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          child,
          if (help != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 6),
              child: Text(
                help!,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
