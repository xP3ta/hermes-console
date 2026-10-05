import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

typedef AssistantSuggestionCallback = Future<bool> Function(String suggestion);

/// Compact stadium chip shared by every suggestion rail (assistant offers
/// and the inline quick replies), so they read as one component.
ButtonStyle hermesSuggestionButtonStyle(
  HermesThemeColors colors, {
  required double maxWidth,
  bool highlighted = false,
}) => OutlinedButton.styleFrom(
  foregroundColor: colors.textPrimary,
  disabledForegroundColor: colors.textPrimary,
  backgroundColor: Colors.transparent,
  disabledBackgroundColor: Colors.transparent,
  overlayColor: colors.accent.withValues(alpha: 0.08),
  side: BorderSide(
    width: 0.8,
    color: highlighted
        ? colors.accent.withValues(alpha: 0.52)
        : colors.divider.withValues(alpha: 0.62),
  ),
  minimumSize: const Size(0, 48),
  maximumSize: Size(maxWidth, double.infinity),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
  shape: const StadiumBorder(),
  textStyle: const TextStyle(
    fontSize: 13,
    height: 1.2,
    fontWeight: FontWeight.w500,
  ),
);

/// Width cap of one suggestion chip for the current screen.
double hermesSuggestionMaxWidth(BuildContext context) =>
    (MediaQuery.sizeOf(context).width * 0.78).clamp(160.0, 288.0).toDouble();

/// Acciones sugeridas sin cabecera ni tarjeta contenedora.
///
/// Replica el patrón de AI Elements en una adaptación táctil para Android: un
/// único carrusel horizontal de botones compactos. Las frases largas quedan
/// acotadas sin convertir una opción en una barra de pantalla completa;
/// TalkBack y el tooltip conservan siempre el texto completo.
class HermesSuggestions extends StatefulWidget {
  const HermesSuggestions({
    required this.suggestions,
    required this.onSelected,
    super.key,
  });

  final List<String> suggestions;
  final AssistantSuggestionCallback onSelected;

  @override
  State<HermesSuggestions> createState() => _HermesSuggestionsState();
}

class _HermesSuggestionsState extends State<HermesSuggestions> {
  int? _submittingIndex;
  int? _submittedIndex;
  int? _rejectedIndex;
  Timer? _feedbackTimer;

  bool get _canSubmit => _submittingIndex == null && _submittedIndex == null;

  Future<void> _submit(int index) async {
    if (_submittingIndex != null || _submittedIndex != null) return;
    _feedbackTimer?.cancel();
    setState(() {
      _submittingIndex = index;
      _rejectedIndex = null;
    });
    unawaited(HapticFeedback.lightImpact());
    try {
      final accepted = await widget.onSelected(widget.suggestions[index]);
      if (!mounted) return;
      if (!accepted) {
        setState(() {
          _submittingIndex = null;
          _rejectedIndex = index;
        });
        unawaited(HapticFeedback.mediumImpact());
        _feedbackTimer = Timer(const Duration(milliseconds: 700), () {
          if (mounted) setState(() => _rejectedIndex = null);
        });
        return;
      }
      setState(() {
        _submittingIndex = null;
        _submittedIndex = index;
      });
      unawaited(HapticFeedback.selectionClick());
      _feedbackTimer = Timer(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _submittedIndex = null);
      });
    } catch (error, stackTrace) {
      if (mounted) {
        setState(() {
          _submittingIndex = null;
          _rejectedIndex = index;
        });
        _feedbackTimer = Timer(const Duration(milliseconds: 700), () {
          if (mounted) setState(() => _rejectedIndex = null);
        });
      }
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'hermes suggestions',
          context: ErrorDescription('while submitting an assistant suggestion'),
        ),
      );
    }
  }

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.suggestions.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    final suggestions = widget.suggestions.take(3).toList(growable: false);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final itemMaxWidth = hermesSuggestionMaxWidth(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          key: const ValueKey('assistant-suggestions-rail'),
          scrollDirection: Axis.horizontal,
          primary: false,
          padding: const EdgeInsets.only(right: 16),
          child: Row(
            key: const ValueKey('assistant-suggestions-row'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var index = 0; index < suggestions.length; index++) ...[
                if (index > 0) const SizedBox(width: 8),
                Semantics(
                  container: true,
                  excludeSemantics: true,
                  button: true,
                  enabled: _canSubmit,
                  selected: _submittedIndex == index,
                  liveRegion:
                      _submittingIndex == index || _submittedIndex == index,
                  label: suggestions[index],
                  onTap: _canSubmit ? () => unawaited(_submit(index)) : null,
                  child: Tooltip(
                    message: suggestions[index],
                    excludeFromSemantics: true,
                    child: OutlinedButton(
                      key: ValueKey('assistant-suggestion-$index'),
                      onPressed: _canSubmit
                          ? () => unawaited(_submit(index))
                          : null,
                      style: hermesSuggestionButtonStyle(
                        colors,
                        maxWidth: itemMaxWidth,
                        highlighted:
                            _submittingIndex == index ||
                            _submittedIndex == index ||
                            _rejectedIndex == index,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedSwitcher(
                            duration: reduceMotion
                                ? Duration.zero
                                : const Duration(milliseconds: 140),
                            child: _submittingIndex == index
                                ? Padding(
                                    key: const ValueKey('suggestion-sending'),
                                    padding: const EdgeInsets.only(right: 8),
                                    child: reduceMotion
                                        ? Icon(
                                            Icons.hourglass_top_rounded,
                                            size: 15,
                                            color: colors.accent,
                                          )
                                        : SizedBox.square(
                                            dimension: 13,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.7,
                                              color: colors.accent,
                                            ),
                                          ),
                                  )
                                : _submittedIndex == index
                                ? Padding(
                                    key: const ValueKey('suggestion-sent'),
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Icon(
                                      Icons.check_rounded,
                                      size: 16,
                                      color: colors.accent,
                                    ),
                                  )
                                : _rejectedIndex == index
                                ? Padding(
                                    key: const ValueKey('suggestion-rejected'),
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Icon(
                                      Icons.refresh_rounded,
                                      size: 16,
                                      color: colors.textSecondary,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          Flexible(
                            child: Text(
                              suggestions[index],
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
