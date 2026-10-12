import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/admin_integrations.dart';
import '../screens/admin_integrations_copy.dart';
import '../theme/app_theme.dart';
import 'form_page.dart';
import 'hermes_ui.dart';
import '../design/hermes_design.dart' show HermesOption, HermesSelectField;

const List<String> webhookDeliveryOptions = [
  'log',
  'telegram',
  'discord',
  'slack',
  'email',
  'github_comment',
];

class WebhookDraftSurface extends StatefulWidget {
  const WebhookDraftSurface({super.key});

  @override
  State<WebhookDraftSurface> createState() => _WebhookDraftSurfaceState();
}

class _WebhookDraftSurfaceState extends State<WebhookDraftSurface> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _prompt = TextEditingController();
  final _events = TextEditingController();
  final _skills = TextEditingController();
  String _deliver = 'log';
  bool _deliverOnly = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    for (final controller in [_name, _description, _prompt, _events, _skills]) {
      controller.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _dirty =>
      [
        _name,
        _description,
        _prompt,
        _events,
        _skills,
      ].any((controller) => controller.text.trim().isNotEmpty) ||
      _deliver != 'log' ||
      _deliverOnly;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _prompt.dispose();
    _events.dispose();
    _skills.dispose();
    super.dispose();
  }

  List<String> _commaSeparated(String raw) => raw
      .split(RegExp(r'[,\n]'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);

  void _submit() {
    final copy = AdminIntegrationsCopy.of(context);
    setState(() => _formError = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    try {
      final draft = WebhookDraft(
        name: _name.text,
        description: _description.text,
        prompt: _prompt.text,
        events: _commaSeparated(_events.text),
        skills: _commaSeparated(_skills.text),
        deliver: _deliver,
        deliverOnly: _deliverOnly,
      );
      Navigator.pop(context, draft);
    } on FormatException {
      setState(() => _formError = copy.invalidForm);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = AdminIntegrationsCopy.of(context);
    final colors = Theme.of(context).hermes;
    return Form(
      key: _formKey,
      child: HermesFormPage(
        bodyKey: const ValueKey('webhook-create-surface'),
        title: copy.webhookFormTitle,
        submitLabel: copy.createWebhook,
        submitKey: const ValueKey('webhook-draft-submit'),
        onSubmit: _name.text.trim().isEmpty ? null : _submit,
        dirty: _dirty,
        children: [
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, constraints) {
              final name = TextFormField(
                key: const ValueKey('webhook-draft-name'),
                controller: _name,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                validator: (value) => value == null || value.trim().isEmpty
                    ? copy.invalidForm
                    : null,
                decoration: InputDecoration(
                  labelText: copy.name,
                  hintText: 'github-push',
                ),
              );
              final description = TextFormField(
                key: const ValueKey('webhook-draft-description'),
                controller: _description,
                decoration: InputDecoration(
                  labelText: copy.description,
                  hintText: copy.descriptionHint,
                ),
              );
              if (constraints.maxWidth >= 500) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: name),
                    const SizedBox(width: 10),
                    Expanded(child: description),
                  ],
                );
              }
              return Column(
                children: [name, const SizedBox(height: 12), description],
              );
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('webhook-draft-prompt'),
            controller: _prompt,
            keyboardType: TextInputType.multiline,
            minLines: 5,
            maxLines: null,
            decoration: InputDecoration(
              labelText: copy.prompt,
              hintText: copy.promptHint,
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final events = TextFormField(
                key: const ValueKey('webhook-draft-events'),
                controller: _events,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: copy.events,
                  helperText: copy.eventsHint,
                ),
              );
              final skills = TextFormField(
                key: const ValueKey('webhook-draft-skills'),
                controller: _skills,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: copy.skills,
                  helperText: copy.skillsHint,
                ),
              );
              if (constraints.maxWidth >= 500) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: events),
                    const SizedBox(width: 10),
                    Expanded(child: skills),
                  ],
                );
              }
              return Column(
                children: [events, const SizedBox(height: 12), skills],
              );
            },
          ),
          const SizedBox(height: 12),
          HermesSelectField<String>(
            key: ValueKey('webhook-deliver-$_deliver'),
            value: _deliver,
            decoration: InputDecoration(labelText: copy.delivery),
            options: [
              for (final option in webhookDeliveryOptions)
                HermesOption(value: option, label: copy.deliveryLabel(option)),
            ],
            onChanged: (value) {
              setState(() {
                _deliver = value;
                if (value == 'log') _deliverOnly = false;
              });
            },
          ),
          const SizedBox(height: 6),
          HermesSwitchTile(
            controlKey: const ValueKey('webhook-draft-deliver-only'),
            contentPadding: EdgeInsets.zero,
            title: copy.deliverOnly,
            subtitle: copy.deliverOnlyHint,
            value: _deliverOnly,
            onChanged: _deliver == 'log'
                ? null
                : (value) => setState(() => _deliverOnly = value),
          ),
          if (_formError != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(_formError!, style: TextStyle(color: colors.error)),
            ),
          ],
        ],
      ),
    );
  }
}

class WebhookReceiptSurface extends StatefulWidget {
  final WebhookCreateReceipt receipt;

  const WebhookReceiptSurface({required this.receipt, super.key});

  @override
  State<WebhookReceiptSurface> createState() => _WebhookReceiptSurfaceState();
}

class _WebhookReceiptSurfaceState extends State<WebhookReceiptSurface> {
  String? _copiedLabel;

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) setState(() => _copiedLabel = label);
  }

  @override
  Widget build(BuildContext context) {
    final copy = AdminIntegrationsCopy.of(context);
    final colors = Theme.of(context).hermes;
    final uri = widget.receipt.route.url?.toString();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.key_rounded, color: colors.warning, size: 25),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  copy.secretTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            copy.secretBody,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          if (uri != null)
            _CopyValueRow(
              label: copy.webhookUrl,
              value: uri,
              copyTooltip: copy.copy,
              onCopy: () => _copy(copy.webhookUrl, uri),
            ),
          if (uri != null) const SizedBox(height: 10),
          _CopyValueRow(
            key: const ValueKey('webhook-one-shot-secret'),
            label: copy.webhookSecret,
            value: widget.receipt.secret,
            copyTooltip: copy.copy,
            onCopy: () => _copy(copy.webhookSecret, widget.receipt.secret),
          ),
          if (_copiedLabel != null) ...[
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(
                '${_copiedLabel!}: ${copy.copied}',
                style: TextStyle(color: colors.success),
              ),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton(
            key: const ValueKey('webhook-receipt-done'),
            onPressed: () => Navigator.pop(context),
            child: Text(copy.done),
          ),
        ],
      ),
    );
  }
}

class _CopyValueRow extends StatelessWidget {
  final String label;
  final String value;
  final String copyTooltip;
  final VoidCallback onCopy;

  const _CopyValueRow({
    required this.label,
    required this.value,
    required this.copyTooltip,
    required this.onCopy,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 5),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceVariant.withValues(alpha: 0.58),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
                IconButton(
                  tooltip: copyTooltip,
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_rounded, size: 19),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
