import 'package:flutter/material.dart';
import 'package:hyper_download_client/presentation/cubits/single_download_state.dart';
import 'package:hyper_download_client/presentation/widgets/common/animated_entrance.dart';
import 'package:hyper_download_client/presentation/widgets/single/download_controls_card.dart';
import 'package:hyper_download_client/presentation/widgets/single/media_metadata_card.dart';
import 'package:hyper_download_client/presentation/widgets/single/quality_selection_card.dart';

/// Composite view for inspected single-media metadata, quality options, and transfer controls.
class SingleDownloadView extends StatelessWidget {
  final SingleDownloadState state;
  final ValueChanged<String> onOpenFile;
  final ValueChanged<String> onRevealInFolder;

  const SingleDownloadView({
    super.key,
    required this.state,
    required this.onOpenFile,
    required this.onRevealInFolder,
  });

  @override
  Widget build(BuildContext context) {
    final inspection = state.inspection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (inspection != null) ...[
          AnimatedEntrance(
            key: ValueKey('meta_${inspection.id}'),
            child: MediaMetadataCard(inspection: inspection),
          ),
          const SizedBox(height: 16),
          AnimatedEntrance(
            key: ValueKey('qual_${inspection.id}'),
            child: QualitySelectionCard(state: state),
          ),
        ],
        AnimatedCollapsibleSection(
          visible: state.hasTransferOrInspection,
          topSpacing: inspection != null ? 16 : 0,
          child: DownloadControlsCard(
            state: state,
            onOpenFile: onOpenFile,
            onRevealInFolder: onRevealInFolder,
          ),
        ),
      ],
    );
  }
}
