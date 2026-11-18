# HyperDownload — Testing Strategy

> **Document Status:** Phase 0 Testing Specification  
> **Mandate:** Every milestone must pass static analysis, formatter checks, unit tests, and relevant integration tests before proceeding. Synthetic media and local deterministic test servers are mandatory; never rely on live external websites for CI/engine verification.

---

## 1. Test Pyramid & Quality Gates

HyperDownload enforces three strict verification gates on every milestone:

### Gate 1 — Rust Workspace Quality Gate
```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

### Gate 2 — Flutter / Dart Quality Gate
```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

### Gate 3 — End-to-End & Platform Gate
- Cross-layer `integration_tests/` (Flutter UI + real compiled `engine_ffi` + local `test_server`)
- Android instrumentation / Espresso / Kotlin unit tests (Share Intent, UIDT `JobService`, notifications, storage export)

---

## 2. Local Programmable HTTP Test Server (`rust/crates/test_server`)

Built with `axum = "0.8.9"` and `tokio` inside `rust/crates/test_server`, binding to `127.0.0.1:0` (ephemeral OS-assigned port) so concurrent `cargo test` runs never collide on ports.

Each test server instance generates deterministic synthetic byte streams (seeded XOR/PRNG or SHA-256 verifiable byte patterns) on the fly so multi-megabyte test files require minimal memory and zero checked-in binary fixtures.

### Mandatory Test Endpoints & Scenarios

| Endpoint | Simulated Behavior | Target Verification |
| :--- | :--- | :--- |
| `GET /files/normal.bin` | Standard `200 OK`, `Content-Length`, `Content-Disposition: attachment; filename="normal.bin"`, `ETag: "v1-normal"` | Basic transfer, filename extraction, exact SHA-256 checksum integrity, atomic `.part` promotion. |
| `GET /files/large.bin?mb=64` | Streams 64 MB of deterministic bytes with `Accept-Ranges: bytes` | Bounded RAM streaming (no full-file buffering), accurate speed/ETA calculation, FFI event throttling. |
| `GET /files/range-supported.bin` | Full `Accept-Ranges: bytes`, validates `Range: bytes=<start>-<end>` -> `206 Partial Content` + `Content-Range`, honors `If-Range` | Pause & resume accuracy without duplicate/skipped bytes; multi-connection segmented transfers (Milestone 4+). |
| `GET /files/no-range.bin` | Advertises `Accept-Ranges: none` and ignores `Range` headers by always returning `200 OK` from byte 0 | Verifies engine marks `supports_resume = false`, **never appends** byte-0 response onto `.part`, and restarts cleanly from 0 if retried. |
| `GET /files/drop-midway.bin?drop_at=524288` | Sends headers for 2 MB, streams 512 KB, then abruptly closes TCP socket (resets connection on first N attempts, succeeds on attempt N+1) | Premature EOF detection, automatic transient retry with exponential backoff, state persistence. |
| `GET /files/resume-etag-changed.bin` | Initially returns `ETag: "v1"` (`206`), then mutates content & `ETag: "v2"` on resume (`If-Range: "v1"` triggers full `200 OK` v2 response or `412`) | Ensures corrupted mixed-version `.part` files never occur; restarts safely with new content. |
| `GET /redirect/chain?hops=3` | Returns `301` -> `302` -> `307` -> `/files/normal.bin` (and `/redirect/loop` for infinite cycle testing) | Redirect resolution during inspection and download, plus max-hop loop error handling. |
| `GET /files/expired.bin` | Returns `206` on initial request, then returns `403 Forbidden` or `410 Gone` after token expiration | Non-retryable failure state transition (`ExpiredOrUnavailable` / `HttpStatus { 403 }`) preserving diagnostic info. |
| `GET /errors/{code}` (`403`, `404`, `500`, `429`) | Returns requested HTTP error status (with optional `Retry-After` on `429`) | Classifies `403`/`404` as non-retryable terminal errors; classifies `500`/`429` as retryable up to `max_retry_attempts`. |
| `GET /files/unknown-length.bin` | `Transfer-Encoding: chunked` without `Content-Length` | Ensures `total_bytes: None` flows cleanly through Rust -> SQLite -> FRB -> Flutter indeterminate progress UI (`bytesReceived` formatted without dividing by zero). |

---

## 3. Rust Unit & Integration Test Matrix

| Crate | Required Test Coverage |
| :--- | :--- |
| `media_models` | Serde round-trip serialization, `Option<T>` unknown field handling, `DownloadFormatChoice::canonical_key()` determinism, `ExecutionResumeState` (`DirectHttp` vs `Extractor`), `DownloadStatus` transitions, `ErrorCode` classification. |
| `persistence` | Schema creation from scratch, migration idempotency, job CRUD, unique active `(source_url, format_choice_key)` deduplication constraint (verifying `Single` vs `MergedVideoAudio` do not falsely collide), continuous checkpoint updates, `SIGKILL` startup reconciliation (`DirectHttp` `.part` disk reconciliation & `Extractor` `MergingStreams` vs `DownloadingPrimaryStream` cleanup), playlist order preservation (`order_index`). |
| `connection_manager` | `HEAD` + fallback `Range: bytes=0-0` probe, redirect chain resolution, `Content-Range` parser validation (valid, `bytes */total`, malformed headers), `If-Range` construction, timeout enforcement. |
| `download_core` | All 10 `test_server` scenarios executed headlessly; `.part` flush on `CancellationToken`; verification that `200 OK` on a non-zero `.part` truncates instead of appending; checksum verification on completed files. |
| `download_queue` | Concurrency limit enforcement (`max_concurrent_downloads`), FIFO ordering, `pause_all`/`resume_all`, `retry_failed_in_playlist`, duplicate job rejection, clean shutdown checkpointing. |
| `providers/direct_http` | URL scheme matching (`http`/`https`), `Content-Disposition` UTF-8/`filename*` parsing, `Accept-Ranges` probing, explicit single `MediaFormat` creation without fabricated variants. |
| `extractor_backend` & `providers/yt_dlp` | JSON fixture parsing for `--dump-single-json` and `--flat-playlist` (excluding storyboards and `has_drm == true` entries, preserving exact `filesize` vs `filesize_approx`, mapping `DiscoveredSingle`/`DiscoveredRequiresMuxing`), `--progress-template` (`download` & `postprocess`) line parser, URL validation (`http`/`https` only), anti-injection typed arg construction, subprocess termination on cancel, mocked and prototype integration runs against authorized CC/open media. |

---

## 4. Flutter Unit, Bloc & Integration Test Matrix

### 4.1 Bloc / Cubit & Widget Unit Tests (`apps/client/test/`)
Using `bloc_test ^10.0.0` and `mocktail ^1.0.5` against an abstract `DownloadEngineClient` interface:
- **`LinkInputCubit`**: Empty/malformed URL validation, clipboard extraction, Android Share Intent incoming URL handling.
- **`MediaInspectionCubit`**: Loading -> Ready (`SingleMedia` vs `Playlist`), DRM/access-restricted error states, network/HTTP error mapping, and `ExtractorNotReady` / `JsRuntimeMissing` diagnostics.
- **`FormatSelectionCubit`**: Renders exact discovered formats only, toggles muxed/video-only/audio-only filters, validates `video_id + audio_id` FFmpeg pairing requirements, and disables restricted/unavailable formats.
- **`DownloadQueueBloc`**: Hydrates initial SQLite state from `list_downloads()`, merges throttled `JobProgress` stream updates without rebuilding unrelated job cards, handles `Downloading -> Merging -> Completed` transitions, `Pause`, `Resume`, `Cancel`, `Retry`, `PauseAll`, `ResumeAll`, and `total_bytes == null` indeterminate progress display.
- **`PlaylistCubit`**: Preserves `order_index`, updates single item inspection states independently, prevents duplicate active jobs, invokes `retry_failed_in_playlist`.
- **`SettingsCubit`**: Persists download directory, concurrency cap, retry limit, extractor update channel (`Stable`/`Nightly`), JS runtime status, and FFmpeg path validation.

### 4.2 End-to-End Integration Tests (`integration_tests/`)
Bootstraps the real Flutter client wired to the real Rust `engine_ffi` library talking to a local `test_server` instance:
1. Submit a direct HTTP URL -> verify metadata inspection -> select format -> start download -> assert progress updates -> assert completed file matches SHA-256 checksum on disk.
2. Submit a large resumable URL -> pause mid-transfer -> verify `Paused` state & partial file size -> resume -> verify completion checksum.
3. Submit `/errors/404` and `/files/no-range.bin` -> verify accurate error banner and clean restart behavior.
4. Submit an authorized open test media URL via `providers/yt_dlp` -> verify genuine dynamic formats render (resolutions, FPS, codecs, exact/approximate sizes) -> select video+audio pair -> verify `Downloading -> Merging -> Completed` lifecycle via FFmpeg.

---

## 5. Android Native, Chaquopy & 16 KB Alignment Tests

Located under `apps/client/android/app/src/test/` and `src/androidTest/`:
1. **16 KB ELF Page Alignment Check:** Run `llvm-objdump -p` on `libengine_ffi.so`, `libqjs.so`, `libffmpeg.so`, `libffprobe.so`, and packaged Chaquopy `.so` artifacts (`arm64-v8a`, `x86_64`) to assert all `LOAD` segments have `align 2**14` (16 KB) or `2**16`.
2. **Share Intent Parsing Unit & Activity Test:** Launch `MainActivity` with `Intent(ACTION_SEND)` containing `EXTRA_TEXT = "Check this out https://example.com/file.zip"` -> assert clean URL extraction and forwarding to Flutter `MethodChannel`.
3. **Headless `HyperDownloadJobService` (UIDT API 34+) & JNI Bridge Test:** Detach/kill Flutter UI, trigger `HyperDownloadJobService.onStartJob()` -> assert Rust queue initializes via `NativeEngineJni.ensureEngineInitialized`, invokes Chaquopy `yt-dlp` + `libqjs.so`, updates progress notification, and calls `jobFinished` on `onQueueIdle()`.
4. **Abrupt `SIGKILL` Crash Recovery Test (No `onStopJob` Callback):** Terminate process mid-transfer during `DirectHttp`, during `yt-dlp` primary stream download, and during `libffmpeg.so` `MergingStreams`; relaunch and verify `reconcile_interrupted_jobs_on_startup` restores accurate byte offsets and re-runs FFmpeg merge without re-downloading completed streams.
5. **Subprocess Cancellation Verification:** Trigger `cancelTask(jobId)` during active `libffmpeg.so` muxing and `libqjs.so` challenge evaluation -> verify child processes terminate cleanly with zero zombie processes remaining.
6. **API 26–33 Fallback Worker & Storage Export Test:** Verify `WorkManager` `CoroutineWorker` (`FOREGROUND_SERVICE_TYPE_DATA_SYNC`), `.part` staging inside `getExternalFilesDir`, and publication to `MediaStore.Downloads`.
