import 'package:equatable/equatable.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';

/// URL inspection lifecycle status.
enum InspectionStatus { initial, loading, loaded, failure }

const Object _unset = Object();

class UrlInspectorState extends Equatable {
  final String urlInput;
  final InspectionStatus inspectionStatus;
  final String analysisStatusText;
  final InspectionTargetKind? targetKind;
  final String? inspectionError;
  final UrlInspectionResult? lastResult;
  final int analysisId;

  const UrlInspectorState({
    this.urlInput = '',
    this.inspectionStatus = InspectionStatus.initial,
    this.analysisStatusText =
        'Analyzing link and discovering available qualities...',
    this.targetKind,
    this.inspectionError,
    this.lastResult,
    this.analysisId = 0,
  });

  bool get isAnalyzing => inspectionStatus == InspectionStatus.loading;

  UrlInspectorState copyWith({
    String? urlInput,
    InspectionStatus? inspectionStatus,
    String? analysisStatusText,
    Object? targetKind = _unset,
    Object? inspectionError = _unset,
    Object? lastResult = _unset,
    int? analysisId,
  }) {
    return UrlInspectorState(
      urlInput: urlInput ?? this.urlInput,
      inspectionStatus: inspectionStatus ?? this.inspectionStatus,
      analysisStatusText: analysisStatusText ?? this.analysisStatusText,
      targetKind: identical(targetKind, _unset)
          ? this.targetKind
          : targetKind as InspectionTargetKind?,
      inspectionError: identical(inspectionError, _unset)
          ? this.inspectionError
          : inspectionError as String?,
      lastResult: identical(lastResult, _unset)
          ? this.lastResult
          : lastResult as UrlInspectionResult?,
      analysisId: analysisId ?? this.analysisId,
    );
  }

  @override
  List<Object?> get props => [
    urlInput,
    inspectionStatus,
    analysisStatusText,
    targetKind,
    inspectionError,
    lastResult,
    analysisId,
  ];
}
