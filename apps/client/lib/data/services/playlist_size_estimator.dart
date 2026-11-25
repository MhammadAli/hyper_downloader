import 'dart:async';

import 'package:hyper_download_client/domain/entities/media_entities.dart';
import 'package:hyper_download_client/domain/entities/playlist_entities.dart';
import 'package:hyper_download_client/domain/repositories/media_inspection_repository.dart';
import 'package:hyper_download_client/domain/services/media_option_synthesizer.dart';

class _ActiveEstimationHandle {
  final String estimationId;
  bool canceled = false;
  final Completer<void> done = Completer<void>();
  bool isRunning = true;

  _ActiveEstimationHandle(this.estimationId);
}

/// Shared pure-Dart progressive playlist size estimator (4 concurrent workers)
/// reused across both Windows and Android implementations.
class PlaylistSizeEstimator {
  static const int _maxConcurrentInspections = 4;

  final MediaInspectionRepository _inspectionRepository;
  final MediaOptionSynthesizer _synthesizer;
  final StreamController<PlaylistSizeEstimate> _controller =
      StreamController<PlaylistSizeEstimate>.broadcast();
  final Map<String, MediaInspection> _cache = {};

  int _idSeq = 0;
  _ActiveEstimationHandle? _active;

  PlaylistSizeEstimator({
    required this._inspectionRepository,
    this._synthesizer = const MediaOptionSynthesizer(),
  });

  Stream<PlaylistSizeEstimate> watchEstimates() => _controller.stream;

  Future<void> cancelEstimation(String estimationId) async {
    final current = _active;
    if (current == null ||
        current.estimationId != estimationId ||
        !current.isRunning) {
      return;
    }
    current.canceled = true;
    await current.done.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
  }

  Future<PlaylistSizeEstimate> estimate(
    EstimatePlaylistSizeRequest request,
  ) async {
    final prev = _active;
    if (prev != null && prev.isRunning) {
      prev.canceled = true;
      await prev.done.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    }

    final estimationId =
        'est-${++_idSeq}-${DateTime.now().microsecondsSinceEpoch}';
    final initialResults =
        <int, ({MediaInspection? inspection, String? error})>{};
    final uncachedEntries = <PlaylistEntrySummary>[];

    for (final entry in request.playlist.entries) {
      if (entry.availability != PlaylistEntryAvailability.available) continue;
      final key = _cacheKey(entry);
      final hit = _cache[key];
      if (hit != null) {
        initialResults[entry.orderIndex] = (inspection: hit, error: null);
      } else {
        uncachedEntries.add(entry);
      }
    }

    if (uncachedEntries.isEmpty) {
      final estimate = _synthesizer.buildPlaylistSizeEstimate(
        estimationId: estimationId,
        playlist: request.playlist,
        mediaMode: request.mediaMode,
        qualityCap: request.qualityCap,
        results: initialResults,
        isCalculating: false,
        wasCanceled: false,
      );
      _controller.add(estimate);
      return estimate;
    }

    final handle = _ActiveEstimationHandle(estimationId);
    _active = handle;

    final initialEstimate = _synthesizer.buildPlaylistSizeEstimate(
      estimationId: estimationId,
      playlist: request.playlist,
      mediaMode: request.mediaMode,
      qualityCap: request.qualityCap,
      results: initialResults,
      isCalculating: true,
      wasCanceled: false,
    );
    _controller.add(initialEstimate);

    unawaited(_runWorkers(handle, request, initialResults, uncachedEntries));
    return initialEstimate;
  }

  Future<void> _runWorkers(
    _ActiveEstimationHandle handle,
    EstimatePlaylistSizeRequest request,
    Map<int, ({MediaInspection? inspection, String? error})> resultsMap,
    List<PlaylistEntrySummary> uncachedEntries,
  ) async {
    var cursor = 0;

    Future<void> worker() async {
      while (!handle.canceled) {
        if (cursor >= uncachedEntries.length) return;
        final entry = uncachedEntries[cursor++];

        try {
          final media = await _inspectionRepository.inspectMedia(entry.url);
          if (handle.canceled) return;
          _cache[_cacheKey(entry)] = media;
          resultsMap[entry.orderIndex] = (inspection: media, error: null);
        } catch (err) {
          if (handle.canceled) return;
          resultsMap[entry.orderIndex] = (
            inspection: null,
            error: err.toString(),
          );
        }

        if (handle.canceled) return;
        _controller.add(
          _synthesizer.buildPlaylistSizeEstimate(
            estimationId: handle.estimationId,
            playlist: request.playlist,
            mediaMode: request.mediaMode,
            qualityCap: request.qualityCap,
            results: resultsMap,
            isCalculating: true,
            wasCanceled: false,
          ),
        );
      }
    }

    final workerCount = uncachedEntries.length < _maxConcurrentInspections
        ? uncachedEntries.length
        : _maxConcurrentInspections;
    await Future.wait(List.generate(workerCount, (_) => worker()));

    final finalSnapshot = _synthesizer.buildPlaylistSizeEstimate(
      estimationId: handle.estimationId,
      playlist: request.playlist,
      mediaMode: request.mediaMode,
      qualityCap: request.qualityCap,
      results: resultsMap,
      isCalculating: false,
      wasCanceled: handle.canceled,
    );
    handle.isRunning = false;
    _controller.add(finalSnapshot);
    if (!handle.done.isCompleted) {
      handle.done.complete();
    }
  }

  static String _cacheKey(PlaylistEntrySummary entry) {
    final vid = entry.videoId.trim();
    return vid.isNotEmpty ? vid : entry.url.trim();
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
