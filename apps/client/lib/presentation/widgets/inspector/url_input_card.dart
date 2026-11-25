import 'package:flutter/material.dart';
import 'package:hyper_download_client/presentation/widgets/common/section_card.dart';

class UrlInputCard extends StatelessWidget {
  final TextEditingController controller;
  final String urlInput;
  final String analysisStatusText;
  final bool hasUrlText;
  final bool isAnalyzing;
  final ValueChanged<String> onUrlChanged;
  final VoidCallback onClear;
  final VoidCallback onPaste;
  final VoidCallback onAnalyze;
  final VoidCallback onCancelAnalysis;

  const UrlInputCard({
    super.key,
    required this.controller,
    required this.urlInput,
    required this.analysisStatusText,
    required this.hasUrlText,
    required this.isAnalyzing,
    required this.onUrlChanged,
    required this.onClear,
    required this.onPaste,
    required this.onAnalyze,
    required this.onCancelAnalysis,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SectionCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
            final textField = TextField(
              key: const Key('url_input_field'),
              controller: controller,
              enabled: !isAnalyzing,
              onChanged: onUrlChanged,
              onSubmitted: (_) => onAnalyze(),
              decoration: InputDecoration(
                labelText: 'Paste YouTube or Instagram Reel link',
                hintText:
                    'YouTube video, Shorts, playlist, or Instagram Reel URL',
                prefixIcon: Icon(Icons.link_rounded, color: scheme.secondary),
                suffixIcon: hasUrlText && !isAnalyzing
                    ? IconButton(
                        tooltip: 'Clear URL',
                        onPressed: onClear,
                        icon: const Icon(Icons.close_rounded, size: 18),
                      )
                    : null,
              ),
            );

            final actions = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('paste_url_button'),
                  onPressed: isAnalyzing ? null : onPaste,
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  label: const Text('Paste'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  key: const Key('analyze_url_button'),
                  onPressed: isAnalyzing ? null : onAnalyze,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    foregroundColor: Colors.white,
                  ),
                  icon: isAnalyzing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: Text(isAnalyzing ? 'Analyzing...' : 'Analyze'),
                ),
              ],
            );

            final inputRow = constraints.maxWidth < 560
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      textField,
                      const SizedBox(height: 12),
                      Align(alignment: Alignment.centerRight, child: actions),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: textField),
                      const SizedBox(width: 12),
                      actions,
                    ],
                  );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                inputRow,
                if (isAnalyzing) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.secondary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          analysisStatusText,
                          key: const Key('analysis_status_text'),
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        key: const Key('cancel_analysis_button'),
                        onPressed: onCancelAnalysis,
                        icon: const Icon(Icons.close_rounded, size: 16),
                        label: const Text('Cancel'),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
    );
  }
}
