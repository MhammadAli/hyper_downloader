# HyperDownload — Phase 2A Windows `yt-dlp` Prototype

This standalone Windows prototype validates `yt-dlp.exe` media inspection, genuine dynamic format discovery, flat + per-item playlist enumeration, structured download progress/speed/ETA reporting, FFmpeg LGPL stream muxing, and cancel/resume behavior before implementing the Phase 4 Rust `MediaExtractorBackend`.

> **Scope:** Phase 2A prototype only. Downloaded binaries (`bin/`) and downloaded media files (`output/`) are excluded from Git via [.gitignore](./.gitignore) and the root [.gitignore](../../.gitignore).

---

## 1. Provisioned Tools & Verified Versions

Provisioned and verified with all Python directories removed from `$env:Path` (confirming zero reliance on global Python):

| Tool | Source / Provisioning | Verified Version / Details |
| :--- | :--- | :--- |
| **`yt-dlp.exe`** | Official standalone release (`github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe`) | **`2026.10.26`** (SHA-256: `F5389D3698ECDE4EF06F4E6B1CE0294FE9AC1396228C8990B8D3416D6D177A7D`) |
| **Node.js (EJS Runtime)** | Host system binary (`C:\Program Files\nodejs\node.exe`) | **`v24.16.0`** (satisfies `yt-dlp` EJS minimum `>= 22.0.0`, invoked via `--js-runtimes "node:C:\Program Files\nodejs\node.exe"`) |
| **`ffmpeg.exe` & `ffprobe.exe`** | Official LGPL shared Win64 build (`BtbN/FFmpeg-Builds`: `ffmpeg-n9.0-latest-win64-lgpl-shared-9.0.zip`) | **`ffmpeg version n9.0.2-57-gd838f9f9ae-20261118`** / **`ffprobe version n9.0.2-57-gd838f9f9ae-20261118`** |

### Provisioning Command
```powershell
powershell -ExecutionPolicy Bypass -File tools/windows_media_prototype/scripts/provision_tools.ps1
```

---

## 2. Prototype Scripts & Exact Commands

### Task 2: Single Video Inspection (`scripts/inspect_video.ps1`)
- **Test URL (Creative Commons Attribution):** `https://www.youtube.com/watch?v=aqz-KE-bpKQ` (*Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film*)
- **Exact `yt-dlp` Invocation:**
  ```powershell
  yt-dlp.exe --dump-single-json --no-playlist --no-warnings --ignore-config `
    --js-runtimes "node:C:\Program Files\nodejs\node.exe" `
    "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
  ```
- **Run Prototype Script:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools/windows_media_prototype/scripts/inspect_video.ps1 `
    -Url "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
  ```
- **Observed Results ([video_inspection_sample.json](./fixtures/video_inspection_sample.json)):**
  - **Title:** `Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film`
  - **Uploader / License:** `Blender` / `Creative Commons Attribution license (reuse allowed)`
  - **Duration / Thumbnail:** `635 s` / `https://i.ytimg.com/vi_webp/aqz-KE-bpKQ/maxresdefault.webp`
  - **Discovered Formats:** **`54` genuine formats** (`7` storyboard images excluded, `0` DRM-restricted formats excluded) spanning `144p` to `2160p` (`60 fps`), `avc1`, `vp9`/`vp09`, `av01`, `mp4a`, `opus`, `ac-3`, `ec-3`.
  - **Size Distinction Verified:**
    - **Exact (`filesize` present):** e.g. `139` (`m4a`, `3,871,021` bytes), `396` (`640x360 mp4 av01`, `15,298,808` bytes), `401` (`3840x2160 mp4 av01 60fps`, `712,445,280` bytes).
    - **Estimated (`filesize` null, `filesize_approx` present):** e.g. `18` (`640x360 mp4 muxed_av`, `28,526,904` bytes).
    - **Unknown (both null):** HLS streams such as `602`–`628` (`m3u8_native`).

---

### Task 3: Playlist Inspection (`scripts/inspect_playlist.ps1`)
- **Test Playlist URL:** `https://www.youtube.com/playlist?list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd` (*Blender Conference 2025*, public Blender Foundation playlist)
- **Exact `yt-dlp` Invocations:**
  - Flat enumeration:
    ```powershell
    yt-dlp.exe --dump-single-json --flat-playlist --no-warnings --ignore-config `
      --playlist-end 5 --js-runtimes "node:C:\Program Files\nodejs\node.exe" `
      "https://www.youtube.com/playlist?list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd"
    ```
  - Per-item format discovery: `yt-dlp.exe --dump-single-json --no-playlist ... "<item_url>"`
- **Run Prototype Script:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools/windows_media_prototype/scripts/inspect_playlist.ps1 `
    -PlaylistUrl "https://www.youtube.com/playlist?list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd" `
    -MaxPlaylistEntries 5 -MaxItemsToInspectFormats 3
  ```
- **Observed Results ([playlist_inspection_sample.json](./fixtures/playlist_inspection_sample.json)):**
  - Reported total items: `84`; enumerated first `5` items preserving exact 0-based `order_index` (`0..4`).
  - Independent format inspection proved playlist items do **not** share uniform formats:
    - Item `#0` (`JXm0-ilIknE`, `Keynote — Blender Conference 2025`, `1508 s`): **`22` formats** (`14` exact, `1` approx)
    - Item `#1` (`hFzg41j68hg`, `Compositing 5.0`, `1248 s`): **`22` formats** (`14` exact, `1` approx)
    - Item `#2` (`JP59Xan_54w`, `Inside Blue Zoo's R&D`, `3002 s`): **`45` formats** (`28` exact, `1` approx, including `vp09.*` and `-drc` tracks absent from `#0` and `#1`)
    - Items `#3` and `#4`: left in `pending_inspection` state (on-demand lazy inspection).

---

### Task 4: Download, Progress/Speed/ETA, FFmpeg Merge & Cancel/Resume (`scripts/test_download_and_merge.ps1`)
- **Run Prototype Script:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools/windows_media_prototype/scripts/test_download_and_merge.ps1 `
    -Url "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
  ```
- **Observed Results ([download_test_report.json](./fixtures/download_test_report.json)):**
  1. **Single Discovered Format (`format_id=139`, `m4a`):**
     - Downloaded `output/single_stream/aqz-KE-bpKQ_139.m4a` (`3,863,745` bytes after `FixupM4a`).
     - Captured `14` `HYPERDL|downloading|...` progress events reporting real-time `downloaded_bytes`, `total_bytes` (`3871021`), `speed` (B/s), and `eta` (seconds).
     - `ffprobe` verified `stream 0: audio (aac)`.
  2. **Separate Video + Audio Stream Merge via FFmpeg (`-f 396+139 --merge-output-format mp4`):**
     - Downloaded separate video (`396`, `640x360 av1`) and audio (`139`, `aac`), invoked `--ffmpeg-location bin/`, and captured postprocessor progress events (`Merger` `started` -> `finished`, `MoveFiles` `started` -> `finished`).
     - Output `output/merged_stream/aqz-KE-bpKQ_merged.mp4` (`19,273,475` bytes) verified via `ffprobe`: `stream 0: video (av1, 640x360)` and `stream 1: audio (aac)`.
  3. **Cancellation & `--continue` Resume (`format_id=139`):**
     - Throttled transfer (`--limit-rate 250K`), terminated entire process tree (`taskkill.exe /F /T /PID <pid>`) after `514,054` streamed bytes; retained `aqz-KE-bpKQ_resume.m4a.part` (`770,621` bytes on disk).
     - Resumed cleanly with `--continue`: `[download] Resuming download at byte 770621`, first resumed progress update at `771,645` bytes, completed file = `3,863,745` bytes (`ffprobe` verified `audio aac`).

---

## 3. Critical Empirical Findings & Issues Encountered (Important for Phase 4 Rust Engine)

1. **Windows PyInstaller Process Tree Cancellation (`WinError 32` Fix):**
   - Official `yt-dlp.exe` is a PyInstaller `--onefile` binary that launches a bootloader process (`PID A`) which spawns a child `yt-dlp.exe` worker (`PID B`).
   - In the initial prototype run, killing only `PID A` via `Process.Kill()` left child `PID B` alive holding an exclusive Windows file lock on `.part`, causing `[WinError 32] The process cannot access the file because it is being used by another process` during resume rename.
   - **Fix Verified:** Killing the entire process tree (`taskkill.exe /F /T /PID <pid>`) cleanly releases all `.part` file handles. Phase 4's Windows Rust `MediaExtractorBackend` must use a **Win32 Job Object (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`)** or process-tree termination before transitioning a canceled/paused job.
2. **Postprocessor Progress Template Variable:**
   - `--progress-template "postprocess:..."` exposes the postprocessor name via **`%(progress.postprocessor)s`** (not `%(info.postprocessor)s`, which resolves to `NA`).
3. **Stderr Warning Handling (`WARNING: Unknown codec iamf.001.001.Opus`):**
   - Even with `--no-warnings`, `yt-dlp` / extractor plugins can emit non-fatal warnings to `stderr` (`Unknown codec iamf.001.001.Opus`). Subprocess wrappers must read `stdout` and `stderr` asynchronously without treating non-zero `stderr` text as failure when the process exit code is `0`.
