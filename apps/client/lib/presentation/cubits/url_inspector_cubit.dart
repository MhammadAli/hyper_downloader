import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:hyper_download_client/core/platform/platform_intent_service.dart';
import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/platforms/platform_registry.dart';
import 'package:hyper_download_client/domain/usecases/inspect_url_usecase.dart';
import 'package:hyper_download_client/presentation/cubits/url_inspector_state.dart';

/// Coordinates URL input, share-intent intake, validation, and media/playlist inspection.
class UrlInspectorCubit extends Cubit<UrlInspectorState> {
  final InspectUrlUseCase _inspectUrlUseCase;
  final PlatformRegistry _platformRegistry;
  final PlatformIntentService _intentService;

  StreamSubscription<String>? _sharedUrlSubscription;
  int _inspectionRequestSeq = 0;

  UrlInspectorCubit({
    required this._inspectUrlUseCase,
    required this._platformRegistry,
    required this._intentService,
  }) : super(const UrlInspectorState());

  void initialize() {
    _sharedUrlSubscription?.cancel();
    _sharedUrlSubscription = _intentService.watchSharedUrls().listen(
      _handleIncomingSharedUrl,
    );
    unawaited(_consumeInitialSharedUrl());
  }

  Future<void> _consumeInitialSharedUrl() async {
    try {
      final url = await _intentService.consumeInitialSharedUrl();
      _handleIncomingSharedUrl(url);
    } catch (_) {
      // Ignore startup shared-intent read failures so manual paste still works.
    }
  }

  void _handleIncomingSharedUrl(String? rawUrl) {
    final cleaned = rawUrl?.trim() ?? '';
    if (cleaned.isEmpty) return;
    unawaited(analyzeUrl(cleaned));
  }

  void updateUrl(String url) {
    emit(state.copyWith(urlInput: url));
  }

  Future<void> analyzeUrl([String? overrideUrl]) async {
    final targetUrl = (overrideUrl ?? state.urlInput).trim();
    if (overrideUrl != null) {
      emit(state.copyWith(urlInput: overrideUrl));
    }

    if (targetUrl.isEmpty) {
      emit(
        state.copyWith(
          inspectionStatus: InspectionStatus.failure,
          inspectionError: 'Please paste or enter a media URL to analyze.',
        ),
      );
      return;
    }

    final seq = ++_inspectionRequestSeq;
    final statusMsg = _platformRegistry.analysisStatusForRawUrl(targetUrl);
    emit(
      state.copyWith(
        urlInput: targetUrl,
        inspectionStatus: InspectionStatus.loading,
        analysisStatusText: statusMsg,
        inspectionError: null,
      ),
    );

    try {
      final result = await _inspectUrlUseCase(targetUrl);
      if (isClosed || seq != _inspectionRequestSeq) return;

      if (result.kind == InspectionTargetKind.singleVideo &&
          result.video == null) {
        emit(
          state.copyWith(
            inspectionStatus: InspectionStatus.failure,
            inspectionError: 'No inspectable video or playlist was returned.',
          ),
        );
        return;
      }
      if (result.kind == InspectionTargetKind.playlist &&
          result.playlist == null) {
        emit(
          state.copyWith(
            inspectionStatus: InspectionStatus.failure,
            inspectionError: 'No inspectable video or playlist was returned.',
          ),
        );
        return;
      }

      emit(
        state.copyWith(
          inspectionStatus: InspectionStatus.loaded,
          targetKind: result.kind,
          lastResult: result,
          inspectionError: null,
          analysisId: state.analysisId + 1,
        ),
      );
    } catch (err) {
      if (isClosed || seq != _inspectionRequestSeq) return;
      emit(
        state.copyWith(
          inspectionStatus: InspectionStatus.failure,
          inspectionError: err.toString().trim(),
        ),
      );
    }
  }

  void cancelAnalysis() {
    if (state.inspectionStatus != InspectionStatus.loading) return;
    _inspectionRequestSeq++;
    emit(
      state.copyWith(
        inspectionStatus: state.lastResult != null
            ? InspectionStatus.loaded
            : InspectionStatus.initial,
        inspectionError: null,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _sharedUrlSubscription?.cancel();
    return super.close();
  }
}
