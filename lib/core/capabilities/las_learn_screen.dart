// Learn a skill: the user says what the agent should learn (a link, a
// repository or a described task) and the profile's agent does the rest in a
// chat of its own. This form only checks and words the request: it reads no
// link, downloads nothing and talks to no server. It closes with the request
// text; the hub opens the chat.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../design/hermes_design.dart';
import '../theme/app_theme.dart';
import '../widgets/form_page.dart';
import 'las_request.dart';

class LasLearnScreen extends StatefulWidget {
  /// `<server label> · <profile>`: whose agent will learn the skill.
  final String destinationLabel;

  const LasLearnScreen({super.key, this.destinationLabel = ''});

  @override
  State<LasLearnScreen> createState() => _LasLearnScreenState();
}

class _LasLearnScreenState extends State<LasLearnScreen> {
  final _text = TextEditingController();
  bool _showErrors = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  LasIssue? get _issue => LasRequest.check(_text.text);

  void _submit() {
    if (_issue != null) {
      setState(() => _showErrors = true);
      return;
    }
    Navigator.of(context).pop(_text.text);
  }

  String? _errorText(Strings s) => switch (_issue) {
    LasIssue.tooLong => s.lasErrTooLong,
    LasIssue.empty when _showErrors => s.lasErrEmpty,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    final colors = Theme.of(context).hermes;
    final links = LasRequest.links(_text.text);
    return HermesFormPage(
      bodyKey: const ValueKey('las-body'),
      title: s.lasTitle,
      submitLabel: s.lasSubmit,
      submitKey: const ValueKey('las-submit'),
      dirty: _text.text.trim().isNotEmpty,
      onSubmit: _submit,
      children: [
        HermesInlineNotice(
          key: const ValueKey('las-agent-note'),
          icon: Icons.info_outline_rounded,
          message: s.lasAgentNote,
        ),
        const SizedBox(height: HermesSpace.x4),
        TextField(
          key: const ValueKey('las-field'),
          controller: _text,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          minLines: 6,
          maxLines: null,
          enableIMEPersonalizedLearning: false,
          decoration: InputDecoration(
            labelText: s.lasFieldLabel,
            helperText: s.lasFieldHelp,
            helperMaxLines: 3,
            alignLabelWithHint: true,
            counterText: s.sppCharCount(
              LasRequest.length(_text.text),
              LasRequest.maxChars,
            ),
            errorText: _errorText(s),
            errorMaxLines: 3,
          ),
          style: HermesType.text.copyWith(color: colors.textPrimary),
        ),
        if (links.any) ...[
          const SizedBox(height: HermesSpace.x3),
          Semantics(
            liveRegion: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (links.insecure)
                  HermesInlineNotice(
                    key: const ValueKey('las-warn-http'),
                    tone: HermesStatusTone.warn,
                    icon: Icons.warning_amber_rounded,
                    message: s.lasLinkHttp,
                  ),
                if (links.insecure && links.unusual)
                  const SizedBox(height: HermesSpace.x2),
                if (links.unusual)
                  HermesInlineNotice(
                    key: const ValueKey('las-warn-odd'),
                    tone: HermesStatusTone.warn,
                    icon: Icons.warning_amber_rounded,
                    message: s.lasLinkOdd,
                  ),
              ],
            ),
          ),
        ],
        if (widget.destinationLabel.isNotEmpty) ...[
          const SizedBox(height: HermesSpace.x4),
          Text(
            widget.destinationLabel,
            key: const ValueKey('las-destination'),
            style: HermesType.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      ],
    );
  }
}
