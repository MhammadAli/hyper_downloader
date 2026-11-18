# HyperDownload — Product & Functional Specification

> **Document Status:** Phase 0 Product Specification  
> **Target Platforms:** Windows Desktop (Windows 10/11 x64) and Android (API 26–36)

---

## 1. Product Vision

**HyperDownload** is a clean, reliable, cross-platform media and file download manager designed around transparent capabilities, dynamic format discovery, and rock-solid resume/queue recovery.

Unlike download managers that scrape protected platforms or fabricate quality presets, HyperDownload adheres strictly to official APIs, explicit source permissions, and verified network metadata:

1. **Paste or Share:** Enter a URL in the app or share a link from another Android application.
2. **Analyze:** Route the URL to the matching isolated `MediaProvider` adapter.
3. **Inspect Truthfully:** Display authentic metadata and *only* the technically discovered formats returned by the source or extractor, clearly distinguishing technical format discovery from legal authorization.
4. **Select & Download:** Pick an available format (single stream or video+audio muxed pair) or queue items from a playlist, and start downloading.
5. **Monitor in Real Time:** Track downloaded bytes, total size (when known), live transfer speed, and estimated time remaining (ETA).
6. **Control & Recover:** Pause, resume (when Range requests or `--continue` staging are supported), cancel, retry failures, and recover durable checkpoints across restarts or abrupt OS termination.

---

## 2. Core User Journeys

### Journey A: Direct File / Discovered Media Download
1. User pastes an HTTP/HTTPS URL (or receives it via Android `ACTION_SEND` Share Intent).
2. `MediaInspectionCubit` requests `inspect_url(url)` from Rust.
3. Provider executes `HEAD`/`Range` probe (`DirectHttp`) or extractor JSON inspection (`YtDlp`).
4. App displays resolved title/filename, container, codecs, resolution/FPS (when applicable), exact or approximate file size, and resume support badge—labeled explicitly as **Technically Discovered Formats** with a rights/ToS notice.
5. User selects a `DownloadFormatChoice` (single stream or separate video+audio muxing pair) and confirms destination path / filename.
6. Job enters `Queued` -> `Downloading` (-> `Merging` when FFmpeg muxing is required); UI renders live speed, progress bar (determinate or indeterminate when `total_bytes == null`), and ETA.
7. Upon completion, staged `.part` outputs are verified and atomically promoted to the final destination (or `MediaStore.Downloads` on Android).

### Journey B: Pause, Resume, Cancel & Crash Recovery
1. During active transfers, Rust persists durable SQLite checkpoints continuously (every 1 second / 1 MiB + phase transitions) alongside `.part` / staging files on disk.
2. User pauses an active download -> Rust triggers `CancellationToken`, cancels active HTTP streams or terminates Python/`libffmpeg.so`/`libqjs.so` subprocesses, flushes buffers, and records `Paused`.
3. User resumes ->
   - **`DirectHttp`:** Rust sends `Range: bytes=<bytes_received>-` and `If-Range: <etag_or_last_modified>`. If the server returns `206 Partial Content` with matching `Content-Range`, download appends safely; if `200 OK`, it truncates `.part` and restarts from byte 0 (**never appending**).
   - **`YtDlp`:** Invokes `yt-dlp --continue` over the preserved `<staging_dir>/<job_id>/` artifacts (re-running only FFmpeg muxing if killed during `MergingStreams`).
4. If the OS terminates the app with `SIGKILL` (zero callbacks), startup reconciliation (`reconcile_interrupted_jobs_on_startup`) inspects disk staging files and transitions interrupted jobs safely without data corruption.
5. User cancels -> User chooses whether to keep or delete partial staging files; job transitions to `Canceled`.

### Journey C: Playlist Discovery & Queue Control
1. User submits a playlist URL supported by an active provider.
2. Provider fetches playlist title, author, total item count, and ordered `PlaylistItemInfo` entries (preserving 0-based `order_index`).
3. Items are displayed with independent inspection states (`PendingInspection`, `Inspecting`, `Ready`, `Failed`). HyperDownload **never assumes** all items in a playlist share the same resolution, codec, or formats.
4. User inspects items individually or batches inspection, selects formats (`DownloadFormatChoice`), and queues jobs without creating duplicate active jobs for identical `(source_url, format_choice_key)` pairs.
5. User controls individual jobs or uses queue-level actions: **Pause All**, **Resume All**, **Retry Failed**, and **Cancel All**.

---

## 3. Extractor-Backed Media Integration (`yt-dlp` via `MediaExtractorBackend`)

HyperDownload's primary goal includes URL-based media downloading from publicly accessible videos and authorized media sources. Rather than reimplementing brittle extraction logic in Rust, HyperDownload integrates **`yt-dlp`** behind an independent `MediaExtractorBackend` abstraction (evaluated in detail in [YT_DLP_FEASIBILITY_AND_PROTOTYPE.md](./YT_DLP_FEASIBILITY_AND_PROTOTYPE.md) and [ADR-0002](./decisions/ADR-0002.md)).

### 3.1 Required Extraction & Media Capabilities

For publicly accessible videos and authorized media sources supported by `yt-dlp`:
1. **URL Inspection:** Parse video and playlist URLs without downloading media payloads (`--dump-single-json`).
2. **Dynamic Format Discovery:** Display **only** genuine formats returned by the extractor, showing actual `format_id`, container (`ext`), resolution (`width x height`), FPS, video/audio codecs (`vcodec`/`acodec`), bitrate (`tbr`), and exact (`filesize`) or explicitly flagged estimated (`filesize_approx`) file sizes. Never hardcode quality lists.
3. **Stream Selection & FFmpeg Muxing:** Support combined audio+video streams, audio-only streams, and separate DASH video-only + audio-only pairs automatically merged via FFmpeg (`Downloading -> Merging -> Completed`).
4. **Playlist Inspection & Management:** Fast flat playlist enumeration (`--flat-playlist`) preserving source order, followed by independent per-item format inspection, deduplication, and batch queue controls.
5. **Truthful Error Reporting:** Surface extraction failures (HTTP 403/404/410, missing JS runtime, unavailable/removed video, geo-restriction, DRM protection, missing FFmpeg for muxed pairs) clearly with retryable classification.

### 3.2 Security, Anti-Circumvention & Compliance Boundaries

HyperDownload enforces strict legal and technical guardrails:
- **No Access-Control Bypass:** HyperDownload **never** targets private, members-only, paid/subscription-gated, or DRM-protected streams. Formats flagged with DRM (`has_drm == true`) are excluded, and `--cookies` / `--cookies-from-browser` / account credential bypass mechanisms are explicitly forbidden.
- **Technical Availability != Download Authorization:** Technical discovery of a stream format by `yt-dlp` does not represent legal authorization or copyright clearance. Users remain responsible for respecting applicable copyright law and platform Terms of Service (including [YouTube Terms of Service](https://www.youtube.com/t/terms)).
- **Explicit Separation of Generic HTTP vs. Media Extraction:** Ordinary HTTP/HTTPS file links route through `providers/direct_http` + Rust's `download_core` (giving exact byte-range `206` control), while extractor-backed platform URLs route through `providers/yt_dlp` + `MediaExtractorBackend`.

---

## 4. Dynamic Format Discovery Rules

1. **Zero Hardcoded Quality Lists:** The format picker must render directly from `MediaInfo.formats`. If a server/source exposes a single binary or MP4 file, show exactly 1 format. If a provider returns `formats = []` with `download_restriction`, show the restriction state—never invent `1080p`, `720p`, or `Audio 128kbps` placeholders.
2. **Stream Composition Clarity:** Each `MediaFormat` explicitly declares:
   - `has_video` and `has_audio` (distinguishing **Muxed A+V**, **Video Only**, **Audio Only**, and **Captions/Binary Data**).
   - Exact discovered properties (`container`, `width`, `height`, `fps`, `video_codec`, `audio_codec`, `bitrate_bps`) with explicit `null` when unknown.
   - `file_size_bytes` paired with `is_size_estimated: bool` so users know whether a size comes from an authoritative `Content-Length` header or an estimate, or is completely unknown (`null`).
3. **FFmpeg Muxing Gate:** Stream merging via FFmpeg is enabled strictly when:
   - `FormatAvailability::DiscoveredRequiresMuxing` (or a `DownloadFormatChoice::MergedVideoAudio` video+audio pair is selected), AND
   - Validated local FFmpeg/FFprobe binaries are detected (Settings / `ExtractorStatus`).

---

## 5. Screen & Navigation Specification

The Flutter app uses a responsive adaptive shell (`NavigationRail` on Windows Desktop / wide tablets, `NavigationBar` on Android phones) sharing a unified Material 3 design language.

| Screen | Primary Purpose | Key UI Elements & States |
| :--- | :--- | :--- |
| **1. Home / URL Input** | Accept pasted links or shared Android intents; inspect history/quick actions. | URL text field with paste button, validation indicator, recent inspections, `Inspect` CTA, quick drop-in banner when an Android Share Intent arrives. |
| **2. Media Inspection** | Display truthful provider metadata, capabilities, and restriction status. | Thumbnail, title, provider badge (`Direct HTTP`, `yt-dlp`), channel/author, duration, capability chips (`Resume Supported`, `FFmpeg Muxing`, `DRM/Restricted`), explicit compliance banner noting technical discovery does not confer copyright or ToS authorization. |
| **3. Dynamic Format Selection** | Present technically discovered formats without fabrication. | Filter chips (All / Muxed A+V / Video Only / Audio Only), section heading **"Discovered Formats (Technically Available)"**, format rows showing real `format_id`, container, resolution/FPS/codecs or `Unknown`, exact vs approximate size (`~`), separate audio picker for video-only streams, filename override, `Start Download` CTA. |
| **4. Download Queue** | Manage `Queued`, `Analyzing`, `Downloading`, `Merging`, `Paused`, and `Failed` jobs. | Global queue toolbar (`Pause All`, `Resume All`, `Retry Failed`), per-job cards with status badge (including `Merging` phase), progress indicator (determinate or indeterminate when `total_bytes == null`), live speed (`MB/s`), ETA, pause/resume/cancel/retry buttons, clear error banners. |
| **5. Completed Downloads** | Browse finished files and verify outputs. | Completed file list, final size, completion timestamp, source provider, `Open File` / `Open Folder` (Windows) / `Share or Open` (Android), `Remove from History` (without deleting file unless requested). |
| **6. Playlist Details** | Manage multi-item collections while preserving order and independent item states. | Ordered item list (`#1`, `#2`, ...), per-item inspection status & individual format selector, bulk queue controls (`Inspect All`, `Queue Discovered Formats`, `Retry Failed`), duplicate-job guard indicator (`source_url` + `format_choice_key`). |
| **7. Settings & Notices** | Configure app behavior, storage, concurrency, extractor runtimes, and open-source notices. | Default download directory, max concurrent downloads (`1..5`), retry attempt limit, Wi-Fi-only toggle (Android), `yt-dlp` + `yt-dlp-ejs` version & update channel (`Stable` / `Nightly`), JS runtime status (`Deno >= 2.3` / `Node >= 22` / `QuickJS >= 2025-4-26`), FFmpeg binary detection, and **Open Source Licenses & Notices** viewer. |
