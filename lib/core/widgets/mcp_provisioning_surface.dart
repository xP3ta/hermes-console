import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/admin_integrations.dart';
import '../screens/admin_integrations_copy.dart';
import '../services/desktop_control_gateway.dart';
import '../theme/app_theme.dart';
import 'form_page.dart';
import 'hermes_premium_ui.dart';
import '../design/hermes_design.dart' show HermesOption, HermesSelectField;

typedef McpExternalUriLauncher = Future<bool> Function(Uri uri);

const List<Duration> _defaultOAuthPollDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 3),
  Duration(seconds: 5),
  Duration(seconds: 5),
  Duration(seconds: 5),
  Duration(seconds: 5),
  Duration(seconds: 5),
];

Future<bool> _launchMcpAuthorization(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

Future<void> showMcpOAuthFlowSurface({
  required BuildContext context,
  required HermesMcpProvisioningGateway gateway,
  required McpOAuthFlow initialFlow,
  McpExternalUriLauncher? launcher,
  List<Duration>? pollDelays,
}) async {
  await showHermesFloatingSurface<void>(
    context: context,
    surfaceKey: const ValueKey('mcp-oauth-flow-surface'),
    maxWidth: 520,
    barrierDismissible: false,
    builder: (_) => McpOAuthFlowSurface(
      gateway: gateway,
      initialFlow: initialFlow,
      launcher: launcher ?? _launchMcpAuthorization,
      pollDelays: pollDelays ?? _defaultOAuthPollDelays,
    ),
  );
}

class McpOAuthFlowSurface extends StatefulWidget {
  final HermesMcpProvisioningGateway gateway;
  final McpOAuthFlow initialFlow;
  final McpExternalUriLauncher launcher;
  final List<Duration> pollDelays;

  const McpOAuthFlowSurface({
    required this.gateway,
    required this.initialFlow,
    this.launcher = _launchMcpAuthorization,
    this.pollDelays = _defaultOAuthPollDelays,
    super.key,
  });

  @override
  State<McpOAuthFlowSurface> createState() => _McpOAuthFlowSurfaceState();
}

class _McpOAuthFlowSurfaceState extends State<McpOAuthFlowSurface>
    with WidgetsBindingObserver {
  late McpOAuthFlow _flow;
  Timer? _pollTimer;
  int _pollIndex = 0;
  bool _polling = false;
  bool _browserOpened = false;
  bool _launchFailed = false;
  bool _visible = true;
  Object? _pollFailure;

  bool get _terminalForUi =>
      _flow.terminal || _flow.status == McpOAuthStatus.unknown;

  @override
  void initState() {
    super.initState();
    _flow = widget.initialFlow;
    WidgetsBinding.instance.addObserver(this);
    _scheduleNextPoll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (_visible == visible) return;
    _visible = visible;
    if (visible) {
      _scheduleNextPoll(immediate: true);
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  @override
  void dispose() {
    _visible = false;
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _scheduleNextPoll({bool immediate = false}) {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_visible || _terminalForUi || _polling || !mounted) return;
    if (_pollIndex >= widget.pollDelays.length) return;
    final delay = immediate ? Duration.zero : widget.pollDelays[_pollIndex];
    _pollTimer = Timer(delay, () {
      _pollTimer = null;
      _pollIndex++;
      unawaited(_poll());
    });
  }

  Future<void> _poll() async {
    if (!_visible || _terminalForUi || _polling || !mounted) return;
    setState(() {
      _polling = true;
      _pollFailure = null;
    });
    try {
      final next = await widget.gateway.mcpOAuthFlow(_flow.flowId);
      if (!mounted || !_visible) return;
      setState(() => _flow = next);
    } catch (error) {
      if (!mounted || !_visible) return;
      setState(() => _pollFailure = error);
    } finally {
      if (mounted) {
        setState(() => _polling = false);
        _scheduleNextPoll();
      }
    }
  }

  Future<void> _openBrowser() async {
    final uri = _flow.authorizationUri;
    if (uri == null) return;
    setState(() => _launchFailed = false);
    final opened = await widget.launcher(uri);
    if (!mounted) return;
    setState(() {
      _browserOpened = opened;
      _launchFailed = !opened;
    });
    if (opened) _scheduleNextPoll(immediate: true);
  }

  @override
  Widget build(BuildContext context) {
    final copy = AdminIntegrationsCopy.of(context);
    final colors = Theme.of(context).hermes;
    final approved = _flow.status == McpOAuthStatus.approved;
    final terminalFailure = switch (_flow.status) {
      McpOAuthStatus.error => copy.oauthError,
      McpOAuthStatus.expired => copy.oauthExpired,
      McpOAuthStatus.unknown => copy.oauthUnknown,
      _ => null,
    };
    final canOpen = _flow.authorizationUri != null && !_terminalForUi;
    final exhausted =
        !_terminalForUi && _pollIndex >= widget.pollDelays.length && !_polling;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      copy.oauthTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _flow.serverName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('mcp-oauth-close'),
                tooltip: copy.close,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            copy.oauthBody,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          Semantics(
            liveRegion: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_polling)
                      const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        approved
                            ? Icons.check_circle_outline_rounded
                            : terminalFailure != null
                            ? Icons.error_outline_rounded
                            : Icons.hourglass_top_rounded,
                        color: approved
                            ? colors.success
                            : terminalFailure != null
                            ? colors.error
                            : colors.accent,
                        size: 22,
                      ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        approved
                            ? copy.oauthApproved
                            : terminalFailure ?? copy.oauthWaiting,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (approved && _flow.tools.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              copy.oauthTools(_flow.tools.length),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ],
          if (_launchFailed) ...[
            const SizedBox(height: 10),
            Text(
              copy.openingBrowserFailed,
              style: TextStyle(color: colors.error),
            ),
          ],
          if (_pollFailure != null) ...[
            const SizedBox(height: 10),
            Text(copy.unavailable, style: TextStyle(color: colors.warning)),
          ],
          const SizedBox(height: 18),
          if (canOpen)
            FilledButton.icon(
              key: const ValueKey('mcp-oauth-open-browser'),
              onPressed: _openBrowser,
              icon: Icon(
                _browserOpened
                    ? Icons.open_in_new_rounded
                    : Icons.language_rounded,
              ),
              label: Text(copy.openBrowser),
            ),
          if (exhausted && !approved) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('mcp-oauth-check-now'),
              onPressed: _poll,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(copy.refresh),
            ),
          ],
          if (approved || terminalFailure != null) ...[
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('mcp-oauth-done'),
              onPressed: () => Navigator.pop(context),
              child: Text(copy.done),
            ),
          ],
        ],
      ),
    );
  }
}

class McpServerDraftSurface extends StatefulWidget {
  const McpServerDraftSurface({super.key});

  @override
  State<McpServerDraftSurface> createState() => _McpServerDraftSurfaceState();
}

class _McpServerDraftSurfaceState extends State<McpServerDraftSurface> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _command = TextEditingController();
  final _arguments = TextEditingController();
  final _url = TextEditingController();
  final _bearer = TextEditingController();
  final List<_EnvironmentControllers> _environment = [
    _EnvironmentControllers(),
  ];
  McpTransport _transport = McpTransport.stdio;
  McpAuthMode _auth = McpAuthMode.none;
  String? _formError;

  @override
  void initState() {
    super.initState();
    for (final controller in [_name, _command, _url]) {
      controller.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// The required fields of the chosen transport are filled; the rest is
  /// checked by the field validators on submit.
  bool get _canSubmit =>
      _name.text.trim().isNotEmpty &&
      (_transport == McpTransport.stdio
          ? _command.text.trim().isNotEmpty
          : _url.text.trim().isNotEmpty);

  bool get _dirty =>
      _name.text.trim().isNotEmpty ||
      _command.text.trim().isNotEmpty ||
      _arguments.text.trim().isNotEmpty ||
      _url.text.trim().isNotEmpty ||
      _bearer.text.isNotEmpty ||
      _environment.any(
        (row) => row.key.text.isNotEmpty || row.value.text.isNotEmpty,
      );

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _arguments.dispose();
    _url.dispose();
    _bearer
      ..clear()
      ..dispose();
    for (final row in _environment) {
      row.dispose();
    }
    _environment.clear();
    super.dispose();
  }

  void _setTransport(McpTransport transport) {
    setState(() {
      _transport = transport;
      _auth = McpAuthMode.none;
      _formError = null;
    });
  }

  void _addEnvironmentRow() {
    setState(() => _environment.add(_EnvironmentControllers()));
  }

  void _removeEnvironmentRow(int index) {
    if (_environment.length == 1) {
      _environment.single.clear();
      setState(() {});
      return;
    }
    final removed = _environment.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  String? _required(String? value) => value == null || value.trim().isEmpty
      ? AdminIntegrationsCopy.of(context).invalidForm
      : null;

  void _submit() {
    final copy = AdminIntegrationsCopy.of(context);
    setState(() => _formError = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;

    try {
      late final McpServerDraft draft;
      if (_transport == McpTransport.stdio) {
        final environment = <String, String>{};
        for (final row in _environment) {
          final key = row.key.text.trim();
          final value = row.value.text;
          if (key.isEmpty && value.isEmpty) continue;
          if (key.isEmpty || value.isEmpty) {
            setState(() => _formError = copy.incompleteEnvironment);
            return;
          }
          environment[key] = value;
        }
        final args = _arguments.text
            .split('\n')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false);
        draft = McpServerDraft.stdio(
          name: _name.text,
          command: _command.text,
          args: args,
          environment: environment,
        );
      } else {
        draft = McpServerDraft.http(
          name: _name.text,
          url: _url.text,
          auth: _auth,
          bearerToken: _auth == McpAuthMode.header ? _bearer.text : null,
        );
      }
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
        bodyKey: const ValueKey('mcp-manual-create-surface'),
        title: copy.mcpFormTitle,
        submitLabel: copy.createMcp,
        submitKey: const ValueKey('mcp-draft-submit'),
        onSubmit: _canSubmit ? _submit : null,
        dirty: _dirty,
        children: [
          const SizedBox(height: 4),
          Text(copy.transport, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 7),
          HermesSegmentedControl<McpTransport>(
            value: _transport,
            semanticLabel: copy.transport,
            onChanged: _setTransport,
            segments: [
              HermesSegment(
                key: const ValueKey('mcp-transport-stdio'),
                value: McpTransport.stdio,
                label: copy.stdio,
              ),
              HermesSegment(
                key: const ValueKey('mcp-transport-http'),
                value: McpTransport.http,
                label: copy.http,
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextFormField(
            key: const ValueKey('mcp-draft-name'),
            controller: _name,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            validator: _required,
            decoration: InputDecoration(
              labelText: copy.name,
              hintText: copy.nameHint,
            ),
          ),
          const SizedBox(height: 12),
          if (_transport == McpTransport.stdio) ...[
            TextFormField(
              key: const ValueKey('mcp-draft-command'),
              controller: _command,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              validator: _required,
              decoration: InputDecoration(
                labelText: copy.command,
                hintText: copy.commandHint,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('mcp-draft-arguments'),
              controller: _arguments,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.multiline,
              minLines: 3,
              maxLines: null,
              decoration: InputDecoration(
                labelText: copy.arguments,
                helperText: copy.argumentsHint,
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              copy.environment,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              copy.environmentHint,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: 10),
            for (var index = 0; index < _environment.length; index++) ...[
              _EnvironmentRow(
                index: index,
                controllers: _environment[index],
                copy: copy,
                onRemove: () => _removeEnvironmentRow(index),
              ),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('mcp-add-environment'),
                onPressed: _environment.length >= 40
                    ? null
                    : _addEnvironmentRow,
                icon: const Icon(Icons.add_rounded),
                label: Text(copy.addVariable),
              ),
            ),
          ] else ...[
            TextFormField(
              key: const ValueKey('mcp-draft-url'),
              controller: _url,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              validator: _required,
              decoration: InputDecoration(
                labelText: copy.endpointUrl,
                hintText: 'https://mcp.example/mcp',
                helperText: copy.endpointHint,
              ),
            ),
            const SizedBox(height: 12),
            HermesSelectField<McpAuthMode>(
              key: ValueKey('mcp-auth-${_auth.name}'),
              value: _auth,
              decoration: InputDecoration(labelText: copy.authentication),
              options: [
                HermesOption(value: McpAuthMode.none, label: copy.authNone),
                HermesOption(value: McpAuthMode.header, label: copy.authHeader),
                HermesOption(value: McpAuthMode.oauth, label: copy.authOauth),
              ],
              onChanged: (value) => setState(() => _auth = value),
            ),
            if (_auth == McpAuthMode.header) ...[
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mcp-draft-bearer'),
                controller: _bearer,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                validator: _required,
                decoration: InputDecoration(
                  labelText: copy.bearerToken,
                  helperText: copy.bearerHint,
                ),
              ),
            ],
          ],
          if (_formError != null) ...[
            const SizedBox(height: 12),
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

final class _EnvironmentControllers {
  final TextEditingController key = TextEditingController();
  final TextEditingController value = TextEditingController();

  void clear() {
    key.clear();
    value.clear();
  }

  void dispose() {
    clear();
    key.dispose();
    value.dispose();
  }
}

class _EnvironmentRow extends StatelessWidget {
  final int index;
  final _EnvironmentControllers controllers;
  final AdminIntegrationsCopy copy;
  final VoidCallback onRemove;

  const _EnvironmentRow({
    required this.index,
    required this.controllers,
    required this.copy,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final keyField = TextFormField(
        key: ValueKey('mcp-env-key-$index'),
        controller: controllers.key,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(labelText: copy.variableName),
      );
      final valueField = TextFormField(
        key: ValueKey('mcp-env-value-$index'),
        controller: controllers.value,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(labelText: copy.variableValue),
      );
      final remove = IconButton(
        tooltip: copy.removeVariable,
        onPressed: onRemove,
        icon: const Icon(Icons.remove_circle_outline_rounded),
      );
      if (constraints.maxWidth >= 460) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: keyField),
            const SizedBox(width: 8),
            Expanded(child: valueField),
            remove,
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          keyField,
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: valueField),
              remove,
            ],
          ),
        ],
      );
    },
  );
}
