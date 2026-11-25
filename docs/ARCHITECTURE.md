# Hyper Download Architecture

Hyper Download (`apps/client`) is a pure-Dart Flutter application structured with **Clean Architecture** (`Presentation -> Domain <- Data`), `flutter_bloc`, `equatable`, `get_it`, and atomic JSON persistence.

## Layer Overview

### 1. Core (`lib/core/`)
Cross-cutting primitives shared across layers:
- `error/app_exception.dart` — typed `AppException` hierarchy (`InvalidUrlException`, `ToolUnavailableException`, `ProcessExecutionException`, `ParseException`, `DownloadBusyException`, `JobNotFoundException`).
- `utils/filename_sanitizer.dart` — Windows-safe filename and ordered playlist stem formatting.
- `utils/formatters.dart` — human-readable byte sizes, transfer speeds, durations, ETAs, and display paths.
- `platform/platform_intent_service.dart` — MethodChannel/EventChannel wrapper for incoming Android share intents.
- `di/injection_container.dart` — `get_it` composition root (`initDependencies`).
- `theme/app_theme.dart` — dark theme tokens and typography.

### 2. Domain (`lib/domain/`)
Pure Dart only (zero `flutter`, `dart:io`, `dart:ffi`, `data/`, or `presentation/` imports):
- `entities/` — immutable `Equatable` domain models (`MediaInspection`, `MediaFormatOption`, `DownloadProgressEvent`, `PlaylistInspection`, `PlaylistSessionSnapshot`, `PlaylistSizeEstimate`, etc.) using native 64-bit `int` byte and ETA counts.
- `platforms/` — `PlatformStrategy` extensibility contract and `PlatformRegistry` supporting YouTube, Instagram, Generic HTTP/yt-dlp, plus pre-wired placeholders for TikTok and Facebook.
- `services/media_option_synthesizer.dart` — deterministic quality option synthesis, playlist quality-cap selection, and playlist size estimation.
- `repositories/` — abstract contracts for inspection, single download, playlist download, playlist session persistence, and file launching.
- `usecases/` — focused orchestrators (`InspectUrlUseCase`, `ManageSingleDownloadUseCase`, `ManagePlaylistDownloadUseCase`, `EstimatePlaylistSizeUseCase`).

### 3. Data (`lib/data/`)
Platform-specific implementations and serialization:
- `parsers/` — `YtDlpJsonParser` (offloading payloads >50 KB via `Isolate.run`) and `YtDlpProgressParser`.
- `datasources/local/json_playlist_session_local_datasource.dart` — atomic `.tmp` + rename JSON manifest persistence (`.hyperdl_playlist_session.json`) with crash reconciliation.
- `services/playlist_size_estimator.dart` — 4-worker bounded concurrent playlist size estimator.
- `datasources/windows/` — `yt-dlp`/`ffmpeg` tool resolution, Win32 Job Object process-tree management (`dart:ffi`), Shell PIDL file launcher, and CLI runner.
- `datasources/android/` — thin `MethodChannel` / `EventChannel` bridge (`com.hyperdownload/media_engine`) to Chaquopy (`extract_raw_info`) and `HyperDownloadTransferService` / `AndroidMediaStoreExporter`.
- `repositories/` — Windows and Android repository implementations registered conditionally in `get_it`.

### 4. Presentation (`lib/presentation/`)
Reactive UI built with `flutter_bloc`:
- `cubits/` — `UrlInspectorCubit`, `SingleDownloadCubit`, and `PlaylistDownloadCubit`.
- `widgets/` & `pages/` — modular cards for URL inspection, single media selection/controls, and playlist batch workflows (`MediaDownloadPage`).

## Android Native Boundary
Kotlin (`MainActivity`, `AndroidDownloadEngine`, `HyperDownloadTransferService`, `AndroidMediaStoreExporter`) and Chaquopy Python (`hyperdl_worker.py`) handle only embedded `yt-dlp` execution, `ffmpeg` remuxing, background ForegroundService/UIDT transfers, and MediaStore export. All URL normalization, metadata parsing, quality synthesis, and playlist size estimation live in Dart.
