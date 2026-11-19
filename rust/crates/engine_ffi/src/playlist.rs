//! Full YouTube playlist inspection, quality-cap resolution reuse,
//! Windows filename sanitization, persistent session manifests, and
//! sequential batch download coordination for Phase 2D.

use crate::frb_generated::StreamSink;
use crate::models::{
    AudioTrackMetadata, EstimatePlaylistSizeRequest, FileSizeAccuracy, InspectionTargetKind,
    MediaInspection, PlaylistEntryAvailability, PlaylistEntrySummary, PlaylistEventKind,
    PlaylistInspection, PlaylistItemSizeInfo, PlaylistItemState, PlaylistItemStatus,
    PlaylistMediaMode, PlaylistProgressEvent, PlaylistQualityCap, PlaylistSessionSnapshot,
    PlaylistSizeEstimate, PlaylistSizeStatus, StartDownloadRequest, StartPlaylistDownloadRequest,
    UrlInspectionResult,
};
use crate::selection::{format_bytes_human, format_display_size, select_playlist_item_option};
use crate::win_job::ProcessTreeJob;
use crate::yt_dlp::{
    build_download_args, build_inspect_args, configure_subprocess, extract_thumbnail_url,
    infer_provider_from_url, json_f64, json_non_empty_str, json_u64, parse_progress_line,
    parse_yt_dlp_inspection_json, shared_runtime, validate_media_url, EngineError, ParsedYtDlpLine,
    ToolPaths,
};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::{broadcast, Mutex, Notify, Semaphore};
use url::Url;
use uuid::Uuid;

const MANIFEST_FILENAME: &str = ".hyperdl_playlist_session.json";
const STOP_WAIT_TIMEOUT_SECS: u64 = 5;
const MAX_CONCURRENT_SIZE_INSPECTIONS: usize = 4;

/// Returns `true` when `raw_url` targets a finite playlist rather than a single video/mix.
pub fn is_playlist_url(raw_url: &str) -> bool {
    let Ok(parsed) = Url::parse(raw_url.trim()) else {
        return false;
    };
    if !matches!(parsed.scheme(), "http" | "https") {
        return false;
    }

    let list_param = parsed
        .query_pairs()
        .find(|(k, _)| k == "list")
        .map(|(_, v)| v.trim().to_string())
        .filter(|v| !v.is_empty());

    let path_lower = parsed.path().to_ascii_lowercase();
    if path_lower.contains("/playlist") {
        return list_param.is_some();
    }

    // Ignore YouTube auto-generated infinite mixes (`RD...`) on `/watch` links.
    matches!(list_param, Some(ref list_id) if !list_id.starts_with("RD"))
}

/// Normalizes playlist URLs (e.g. `/watch?v=...&list=PL...`) to canonical playlist URLs
/// so `yt-dlp --flat-playlist --yes-playlist` enumerates the entire collection cleanly.
pub fn normalize_playlist_url(raw_url: &str) -> Result<String, EngineError> {
    let validated = validate_media_url(raw_url)?;
    let parsed = Url::parse(&validated).map_err(|e| EngineError::InvalidUrl(e.to_string()))?;

    let is_youtube = parsed
        .host_str()
        .is_some_and(|h| h.contains("youtube.com") || h.contains("youtu.be"));

    if is_youtube {
        if let Some((_, list_id)) = parsed
            .query_pairs()
            .find(|(k, v)| k == "list" && !v.is_empty())
        {
            return Ok(format!("https://www.youtube.com/playlist?list={list_id}"));
        }
    }

    Ok(validated)
}

/// Builds typed `yt-dlp` arguments for complete, untruncated playlist enumeration.
pub fn build_playlist_inspect_args(paths: &ToolPaths, url: &str) -> Vec<OsString> {
    vec![
        OsString::from("--dump-single-json"),
        OsString::from("--flat-playlist"),
        OsString::from("--yes-playlist"),
        OsString::from("--no-warnings"),
        OsString::from("--ignore-config"),
        OsString::from("--js-runtimes"),
        OsString::from(format!("node:{}", paths.node_exe.display())),
        OsString::from("--ffmpeg-location"),
        paths.ffmpeg_dir().into_os_string(),
        OsString::from("--"),
        OsString::from(url),
    ]
}

/// Inspects any URL: dispatches playlist links to complete playlist enumeration and
/// video/Shorts links to single-video inspection.
pub async fn inspect_url_async(url: &str) -> Result<UrlInspectionResult, EngineError> {
    let validated = validate_media_url(url)?;
    if is_playlist_url(&validated) {
        let playlist = inspect_playlist_async(&validated).await?;
        Ok(UrlInspectionResult {
            kind: InspectionTargetKind::Playlist,
            video: None,
            playlist: Some(playlist),
        })
    } else {
        let video = crate::yt_dlp::inspect_media_async(&validated).await?;
        Ok(UrlInspectionResult {
            kind: InspectionTargetKind::SingleVideo,
            video: Some(video),
            playlist: None,
        })
    }
}

/// Enumerates all accessible items in a playlist without truncation.
pub async fn inspect_playlist_async(url: &str) -> Result<PlaylistInspection, EngineError> {
    let canonical = normalize_playlist_url(url)?;
    let paths = ToolPaths::resolve()?;
    inspect_playlist_with_paths(&paths, &canonical).await
}

async fn inspect_playlist_with_paths(
    paths: &ToolPaths,
    canonical_url: &str,
) -> Result<PlaylistInspection, EngineError> {
    let args = build_playlist_inspect_args(paths, canonical_url);
    let mut cmd = Command::new(&paths.yt_dlp_exe);
    cmd.args(&args);
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());
    configure_subprocess(&mut cmd);

    let output = cmd.output().await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(EngineError::ProcessFailed {
            exit_code: output.status.code(),
            stderr: if stderr.is_empty() {
                "yt-dlp playlist enumeration exited with non-zero status".into()
            } else {
                stderr
            },
        });
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_yt_dlp_playlist_json(&stdout, canonical_url)
}

/// Parses structured JSON from `yt-dlp --dump-single-json --flat-playlist` preserving order
/// and explicitly classifying private/deleted/unavailable entries.
pub fn parse_yt_dlp_playlist_json(
    raw_json: &str,
    fallback_url: &str,
) -> Result<PlaylistInspection, EngineError> {
    let cleaned = raw_json.trim_start_matches('\u{feff}').trim();
    let root: Value =
        serde_json::from_str(cleaned).map_err(|err| EngineError::JsonParse(err.to_string()))?;
    let obj = root
        .as_object()
        .ok_or_else(|| EngineError::JsonParse("Expected top-level playlist JSON object.".into()))?;

    let raw_entries = obj
        .get("entries")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            EngineError::JsonParse("Missing 'entries' array in yt-dlp playlist output.".into())
        })?;

    let playlist_id = json_non_empty_str(obj.get("id"))
        .or_else(|| {
            Url::parse(fallback_url).ok().and_then(|u| {
                u.query_pairs()
                    .find(|(k, _)| k == "list")
                    .map(|(_, v)| v.into())
            })
        })
        .unwrap_or_else(|| "playlist".to_string());
    let title = json_non_empty_str(obj.get("title")).unwrap_or_else(|| playlist_id.clone());
    let uploader = json_non_empty_str(obj.get("uploader"))
        .or_else(|| json_non_empty_str(obj.get("channel")))
        .or_else(|| json_non_empty_str(obj.get("creator")));
    let webpage_url = json_non_empty_str(obj.get("webpage_url"))
        .or_else(|| json_non_empty_str(obj.get("original_url")))
        .unwrap_or_else(|| fallback_url.to_string());
    let provider_name = json_non_empty_str(obj.get("extractor_key"))
        .or_else(|| json_non_empty_str(obj.get("extractor")))
        .unwrap_or_else(|| infer_provider_from_url(&webpage_url));

    let mut entries = Vec::with_capacity(raw_entries.len());
    for (idx, item) in raw_entries.iter().enumerate() {
        entries.push(parse_playlist_entry(idx as u32, item));
    }

    let root_thumb = extract_thumbnail_url(obj).or_else(|| {
        entries
            .iter()
            .find(|e| e.availability == PlaylistEntryAvailability::Available)
            .and_then(|e| e.thumbnail_url.clone())
    });

    let reported_count = json_u64(obj.get("playlist_count"))
        .and_then(|c| u32::try_from(c).ok())
        .unwrap_or(0);
    let total_item_count = reported_count.max(entries.len() as u32);

    Ok(PlaylistInspection {
        id: playlist_id,
        title,
        uploader,
        thumbnail_url: root_thumb,
        webpage_url,
        provider_name,
        total_item_count,
        entries,
    })
}

fn parse_playlist_entry(order_index: u32, raw_entry: &Value) -> PlaylistEntrySummary {
    let Some(obj) = raw_entry.as_object() else {
        return PlaylistEntrySummary {
            order_index,
            video_id: format!("unavailable_{order_index}"),
            title: "[Unavailable video]".into(),
            url: String::new(),
            uploader: None,
            duration_seconds: None,
            thumbnail_url: None,
            availability: PlaylistEntryAvailability::Unavailable,
            availability_reason: Some("Entry metadata missing from playlist".into()),
        };
    };

    let video_id = json_non_empty_str(obj.get("id")).unwrap_or_default();
    let title = json_non_empty_str(obj.get("title"))
        .unwrap_or_else(|| format!("Video {}", order_index + 1));
    let raw_url =
        json_non_empty_str(obj.get("url")).or_else(|| json_non_empty_str(obj.get("webpage_url")));
    let url = match raw_url {
        Some(u) if u.starts_with("http://") || u.starts_with("https://") => u,
        _ if !video_id.is_empty() => format!("https://www.youtube.com/watch?v={video_id}"),
        _ => String::new(),
    };

    let uploader =
        json_non_empty_str(obj.get("uploader")).or_else(|| json_non_empty_str(obj.get("channel")));
    let duration_seconds = json_f64(obj.get("duration"));
    let thumbnail_url = extract_thumbnail_url(obj);
    let availability_str = json_non_empty_str(obj.get("availability"));

    let (availability, availability_reason) =
        classify_entry_availability(&title, &url, availability_str.as_deref());

    PlaylistEntrySummary {
        order_index,
        video_id: if video_id.is_empty() {
            format!("item_{order_index}")
        } else {
            video_id
        },
        title,
        url,
        uploader,
        duration_seconds,
        thumbnail_url,
        availability,
        availability_reason,
    }
}

fn classify_entry_availability(
    title: &str,
    url: &str,
    availability_flag: Option<&str>,
) -> (PlaylistEntryAvailability, Option<String>) {
    let lower_title = title.trim().to_ascii_lowercase();
    let lower_flag = availability_flag
        .map(str::trim)
        .map(str::to_ascii_lowercase);

    if lower_title == "[private video]" || lower_flag.as_deref() == Some("private") {
        return (
            PlaylistEntryAvailability::Private,
            Some("Private video (skipped automatically)".into()),
        );
    }
    if lower_title == "[deleted video]"
        || lower_title == "[removed video]"
        || lower_flag.as_deref() == Some("deleted")
    {
        return (
            PlaylistEntryAvailability::Removed,
            Some("Removed or deleted video (skipped automatically)".into()),
        );
    }
    if lower_title == "[unavailable video]"
        || url.is_empty()
        || matches!(
            lower_flag.as_deref(),
            Some("unavailable" | "needs_auth" | "subscriber_only" | "premium_only")
        )
    {
        let reason = match lower_flag.as_deref() {
            Some("needs_auth" | "subscriber_only" | "premium_only") => {
                "Restricted or members-only video (skipped automatically)".into()
            }
            _ => "Unavailable playlist entry (skipped automatically)".into(),
        };
        return (PlaylistEntryAvailability::Unavailable, Some(reason));
    }

    (PlaylistEntryAvailability::Available, None)
}

/// Sanitizes a title or folder name safely for Windows NTFS paths while preserving Unicode (e.g. Arabic).
pub fn sanitize_windows_filename(raw: &str, max_chars: usize) -> String {
    let mut cleaned = String::with_capacity(raw.len());
    let mut prev_space = true;

    for ch in raw.chars() {
        let forbidden =
            matches!(ch, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || ch.is_control();
        let mapped = if forbidden || ch.is_whitespace() {
            ' '
        } else {
            ch
        };

        if mapped == ' ' {
            if !prev_space {
                cleaned.push(' ');
                prev_space = true;
            }
        } else {
            cleaned.push(mapped);
            prev_space = false;
        }
    }

    let trimmed = cleaned
        .trim_matches(|c: char| c == ' ' || c == '.')
        .to_string();
    let mut truncated: String = trimmed.chars().take(max_chars).collect();
    truncated = truncated
        .trim_matches(|c: char| c == ' ' || c == '.')
        .to_string();

    if truncated.is_empty() {
        truncated = "Untitled".to_string();
    }

    let upper = truncated.to_ascii_uppercase();
    let is_reserved_device = matches!(
        upper.as_str(),
        "CON"
            | "PRN"
            | "AUX"
            | "NUL"
            | "COM1"
            | "COM2"
            | "COM3"
            | "COM4"
            | "COM5"
            | "COM6"
            | "COM7"
            | "COM8"
            | "COM9"
            | "LPT1"
            | "LPT2"
            | "LPT3"
            | "LPT4"
            | "LPT5"
            | "LPT6"
            | "LPT7"
            | "LPT8"
            | "LPT9"
    );
    if is_reserved_device {
        format!("_{truncated}")
    } else {
        truncated
    }
}

/// Computes the dedicated destination subfolder `<base_dir>/<sanitized_title> [<playlist_id>]`.
pub fn playlist_folder_path(base_dir: &Path, playlist_title: &str, playlist_id: &str) -> PathBuf {
    let safe_title = sanitize_windows_filename(playlist_title, 72);
    let safe_id = sanitize_windows_filename(playlist_id, 48);
    base_dir.join(format!("{safe_title} [{safe_id}]"))
}

/// Builds a collision-free numeric-prefixed file stem (`001 - Title`, `001 - Title (2)`).
pub fn format_ordered_filename_stem(
    order_index: u32,
    total_count: u32,
    title: &str,
    used_stems: &mut HashSet<String>,
) -> String {
    let width = total_count.max(1).to_string().len().max(3);
    let safe_title = sanitize_windows_filename(title, 90);
    let base_stem = format!("{:0width$} - {safe_title}", order_index + 1, width = width);

    if used_stems.insert(base_stem.to_lowercase()) {
        return base_stem;
    }

    let mut suffix = 2u32;
    loop {
        let candidate = format!("{base_stem} ({suffix})");
        if used_stems.insert(candidate.to_lowercase()) {
            return candidate;
        }
        suffix += 1;
    }
}

/// Atomically persists the lightweight playlist session manifest inside `playlist_dir`.
pub async fn save_manifest_atomic(
    playlist_dir: &Path,
    snapshot: &PlaylistSessionSnapshot,
) -> Result<(), EngineError> {
    tokio::fs::create_dir_all(playlist_dir).await?;
    let target = playlist_dir.join(MANIFEST_FILENAME);
    let temp = playlist_dir.join(format!("{MANIFEST_FILENAME}.tmp"));
    let json = serde_json::to_string_pretty(snapshot)
        .map_err(|e| EngineError::JsonParse(e.to_string()))?;
    tokio::fs::write(&temp, json).await?;
    if tokio::fs::try_exists(&target).await.unwrap_or(false) {
        let _ = tokio::fs::remove_file(&target).await;
    }
    tokio::fs::rename(&temp, &target).await?;
    Ok(())
}

/// Restores a playlist session manifest from disk if present and reconciles interrupted
/// in-progress items or missing output files safely.
pub async fn load_saved_playlist_session(
    base_dir: &Path,
    playlist_id: &str,
) -> Result<Option<PlaylistSessionSnapshot>, EngineError> {
    if !base_dir.is_dir() {
        return Ok(None);
    }

    let mut read_dir = tokio::fs::read_dir(base_dir).await?;
    while let Some(entry) = read_dir.next_entry().await? {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let manifest_path = path.join(MANIFEST_FILENAME);
        if !manifest_path.is_file() {
            continue;
        }
        let Ok(raw) = tokio::fs::read_to_string(&manifest_path).await else {
            continue;
        };
        let Ok(mut snapshot) = serde_json::from_str::<PlaylistSessionSnapshot>(&raw) else {
            continue;
        };
        if snapshot.playlist_id != playlist_id {
            continue;
        }

        reconcile_recovered_snapshot(&mut snapshot);
        return Ok(Some(snapshot));
    }

    Ok(None)
}

/// Resets interrupted mid-flight statuses to `Pending` after restart and verifies completed files.
fn reconcile_recovered_snapshot(snapshot: &mut PlaylistSessionSnapshot) {
    snapshot.is_running = false;
    for item in &mut snapshot.items {
        match item.status {
            PlaylistItemStatus::Analyzing
            | PlaylistItemStatus::Ready
            | PlaylistItemStatus::Downloading
            | PlaylistItemStatus::Merging => {
                item.status = PlaylistItemStatus::Pending;
            }
            PlaylistItemStatus::Completed => {
                let exists_non_empty = item
                    .output_path
                    .as_deref()
                    .and_then(|p| std::fs::metadata(p).ok())
                    .is_some_and(|m| m.is_file() && m.len() > 0);
                if !exists_non_empty {
                    item.status = PlaylistItemStatus::Pending;
                    item.output_path = None;
                    item.downloaded_bytes = 0;
                }
            }
            PlaylistItemStatus::Pending
            | PlaylistItemStatus::Failed
            | PlaylistItemStatus::Skipped
            | PlaylistItemStatus::Canceled => {}
        }
    }
    recompute_counters(snapshot);
}

fn recompute_counters(snapshot: &mut PlaylistSessionSnapshot) {
    snapshot.completed_count = snapshot
        .items
        .iter()
        .filter(|i| i.status == PlaylistItemStatus::Completed)
        .count() as u32;
    snapshot.failed_count = snapshot
        .items
        .iter()
        .filter(|i| i.status == PlaylistItemStatus::Failed)
        .count() as u32;
    snapshot.skipped_count = snapshot
        .items
        .iter()
        .filter(|i| i.status == PlaylistItemStatus::Skipped)
        .count() as u32;
    snapshot.total_count = snapshot.items.len() as u32;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StopMode {
    Pause,
    Cancel,
}

#[derive(Debug)]
pub(crate) struct ItemExecutionProgress {
    downloaded_bytes: u64,
    total_bytes: Option<u64>,
    is_total_estimated: bool,
    speed_bytes_per_sec: Option<f64>,
    eta_seconds: Option<u64>,
    is_merging: bool,
    status_message: Option<String>,
}

/// Pluggable execution backend so `PlaylistManager` can run real `yt-dlp.exe`
/// in production and deterministic fakes in fast unit tests.
pub(crate) trait PlaylistItemExecutor: Send + Sync {
    fn inspect_item<'a>(
        &'a self,
        url: &'a str,
        paths: &'a ToolPaths,
        stop_notify: Arc<Notify>,
    ) -> Pin<Box<dyn Future<Output = Result<MediaInspection, EngineError>> + Send + 'a>>;

    fn download_item<'a>(
        &'a self,
        paths: &'a ToolPaths,
        request: &'a StartDownloadRequest,
        output_template: &'a str,
        job_slot: Arc<Mutex<Option<Arc<ProcessTreeJob>>>>,
        stop_notify: Arc<Notify>,
        on_progress: Box<dyn Fn(ItemExecutionProgress) + Send + Sync + 'a>,
    ) -> Pin<Box<dyn Future<Output = Result<String, EngineError>> + Send + 'a>>;
}

struct YtDlpPlaylistExecutor;

impl PlaylistItemExecutor for YtDlpPlaylistExecutor {
    fn inspect_item<'a>(
        &'a self,
        url: &'a str,
        paths: &'a ToolPaths,
        stop_notify: Arc<Notify>,
    ) -> Pin<Box<dyn Future<Output = Result<MediaInspection, EngineError>> + Send + 'a>> {
        Box::pin(async move {
            let validated = validate_media_url(url)?;
            let args = build_inspect_args(paths, &validated);
            let mut cmd = Command::new(&paths.yt_dlp_exe);
            cmd.args(&args);
            cmd.stdin(std::process::Stdio::null());
            cmd.stdout(std::process::Stdio::piped());
            cmd.stderr(std::process::Stdio::piped());
            cmd.kill_on_drop(true);
            configure_subprocess(&mut cmd);

            let child = cmd.spawn()?;
            let _tree_guard = ProcessTreeJob::attach(&child).ok();

            let output = tokio::select! {
                res = child.wait_with_output() => res?,
                () = stop_notify.notified() => {
                    return Err(EngineError::InvalidRequest("Stopped by user".into()));
                }
            };

            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
                return Err(EngineError::ProcessFailed {
                    exit_code: output.status.code(),
                    stderr: if stderr.is_empty() {
                        "yt-dlp item inspection exited with non-zero status".into()
                    } else {
                        stderr
                    },
                });
            }

            let stdout = String::from_utf8_lossy(&output.stdout);
            parse_yt_dlp_inspection_json(&stdout)
        })
    }

    fn download_item<'a>(
        &'a self,
        paths: &'a ToolPaths,
        request: &'a StartDownloadRequest,
        output_template: &'a str,
        job_slot: Arc<Mutex<Option<Arc<ProcessTreeJob>>>>,
        stop_notify: Arc<Notify>,
        on_progress: Box<dyn Fn(ItemExecutionProgress) + Send + Sync + 'a>,
    ) -> Pin<Box<dyn Future<Output = Result<String, EngineError>> + Send + 'a>> {
        Box::pin(async move {
            match run_yt_dlp_download_once(
                paths,
                request,
                output_template,
                &job_slot,
                &stop_notify,
                on_progress.as_ref(),
            )
            .await
            {
                Ok(path) => Ok(path),
                Err(err) if is_transient_http_403(&err) => {
                    tokio::select! {
                        () = tokio::time::sleep(std::time::Duration::from_millis(1500)) => {}
                        () = stop_notify.notified() => {
                            return Err(EngineError::InvalidRequest("Stopped by user".into()));
                        }
                    }
                    run_yt_dlp_download_once(
                        paths,
                        request,
                        output_template,
                        &job_slot,
                        &stop_notify,
                        on_progress.as_ref(),
                    )
                    .await
                }
                Err(err) => Err(err),
            }
        })
    }
}

pub(crate) fn is_transient_http_403(err: &EngineError) -> bool {
    matches!(
        err,
        EngineError::ProcessFailed { stderr, .. } if stderr.contains("HTTP Error 403")
    )
}

async fn run_yt_dlp_download_once(
    paths: &ToolPaths,
    request: &StartDownloadRequest,
    output_template: &str,
    job_slot: &Arc<Mutex<Option<Arc<ProcessTreeJob>>>>,
    stop_notify: &Arc<Notify>,
    on_progress: &(dyn Fn(ItemExecutionProgress) + Send + Sync),
) -> Result<String, EngineError> {
    let args = build_download_args(paths, request, output_template)?;
    let temp_id = Uuid::new_v4().to_string();
    let path_record_file = std::env::temp_dir().join(format!("hyperdl_pl_path_{temp_id}.txt"));
    let _ = tokio::fs::remove_file(&path_record_file).await;

    let mut cmd = Command::new(&paths.yt_dlp_exe);
    cmd.arg("--no-quiet")
        .arg("--print-to-file")
        .arg("after_move:%(filepath)s")
        .arg(&path_record_file)
        .args(&args);
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());
    configure_subprocess(&mut cmd);

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(err) => {
            let _ = tokio::fs::remove_file(&path_record_file).await;
            return Err(EngineError::Io(err));
        }
    };

    if let Ok(proc_job) = ProcessTreeJob::attach(&child) {
        let mut guard = job_slot.lock().await;
        *guard = Some(Arc::new(proc_job));
    }

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    let stderr_task = tokio::spawn(async move {
        let mut lines = Vec::new();
        if let Some(err_stream) = stderr {
            let mut reader = BufReader::new(err_stream).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                lines.push(line);
            }
        }
        lines.join("\n")
    });

    let mut last_downloaded = 0u64;
    let mut last_total: Option<u64> = None;
    let mut last_estimated = false;
    let mut detected_output_path: Option<String> = None;

    if let Some(out_stream) = stdout {
        let mut reader = BufReader::new(out_stream);
        let mut raw_buf = Vec::with_capacity(512);
        loop {
            raw_buf.clear();
            let read_res = tokio::select! {
                res = reader.read_until(b'\n', &mut raw_buf) => res,
                () = stop_notify.notified() => break,
            };
            match read_res {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            let line = String::from_utf8_lossy(&raw_buf);
            match parse_progress_line(&line) {
                ParsedYtDlpLine::DownloadProgress {
                    status,
                    downloaded_bytes,
                    total_bytes,
                    is_total_estimated,
                    speed_bytes_per_sec,
                    eta_seconds,
                } => {
                    last_downloaded = downloaded_bytes;
                    if total_bytes.is_some() {
                        last_total = total_bytes;
                        last_estimated = is_total_estimated;
                    }
                    on_progress(ItemExecutionProgress {
                        downloaded_bytes,
                        total_bytes: last_total,
                        is_total_estimated: last_estimated,
                        speed_bytes_per_sec,
                        eta_seconds,
                        is_merging: false,
                        status_message: if status == "finished" {
                            Some("Stream downloaded, preparing next step...".into())
                        } else {
                            None
                        },
                    });
                }
                ParsedYtDlpLine::PostprocessProgress {
                    status: _,
                    postprocessor,
                } => {
                    on_progress(ItemExecutionProgress {
                        downloaded_bytes: last_downloaded,
                        total_bytes: last_total,
                        is_total_estimated: last_estimated,
                        speed_bytes_per_sec: None,
                        eta_seconds: None,
                        is_merging: true,
                        status_message: Some(format!("Running {postprocessor} with FFmpeg...")),
                    });
                }
                ParsedYtDlpLine::OutputPathDetected(path) => {
                    detected_output_path = Some(path);
                }
                ParsedYtDlpLine::Other => {}
            }
        }
    }

    let wait_result = child.wait().await;
    {
        let mut guard = job_slot.lock().await;
        *guard = None;
    }
    let stderr_text = stderr_task.await.unwrap_or_default();
    let recorded_output_path = tokio::fs::read_to_string(&path_record_file)
        .await
        .ok()
        .and_then(|content| {
            content
                .lines()
                .rev()
                .map(str::trim)
                .find(|l| !l.is_empty())
                .map(str::to_string)
        });
    let _ = tokio::fs::remove_file(&path_record_file).await;

    match wait_result {
        Ok(status) if status.success() => {
            let final_path = recorded_output_path
                .or(detected_output_path)
                .ok_or_else(|| {
                    EngineError::JsonParse(
                        "Download exited cleanly but final file path could not be determined."
                            .into(),
                    )
                })?;
            Ok(final_path)
        }
        Ok(status) => Err(EngineError::ProcessFailed {
            exit_code: status.code(),
            stderr: if stderr_text.trim().is_empty() {
                format!("yt-dlp exited with code {:?}", status.code())
            } else {
                stderr_text.trim().to_string()
            },
        }),
        Err(err) => Err(EngineError::Io(err)),
    }
}

#[derive(Debug)]
struct ActiveSizeEstimationRuntime {
    estimation_id: String,
    stop_notify: Arc<Notify>,
    canceled_flag: Arc<AtomicBool>,
    done_notify: Arc<Notify>,
    is_running: bool,
}

#[derive(Debug)]
struct ActivePlaylistRuntime {
    snapshot: PlaylistSessionSnapshot,
    item_stems: Vec<String>,
    stop_mode: Option<StopMode>,
    stop_notify: Arc<Notify>,
    process_job: Arc<Mutex<Option<Arc<ProcessTreeJob>>>>,
    done_notify: Arc<Notify>,
}

/// Coordinates sequential playlist batch execution, recovery manifests, pause/resume/cancel,
/// failure isolation/retry, and cached pre-download total size estimation.
pub struct PlaylistManager {
    tx: broadcast::Sender<PlaylistProgressEvent>,
    size_tx: broadcast::Sender<PlaylistSizeEstimate>,
    runtime: Mutex<Option<ActivePlaylistRuntime>>,
    inspection_cache: Arc<Mutex<HashMap<String, MediaInspection>>>,
    size_runtime: Mutex<Option<ActiveSizeEstimationRuntime>>,
    executor: Arc<dyn PlaylistItemExecutor>,
}

impl PlaylistManager {
    pub fn global() -> &'static Arc<Self> {
        static INSTANCE: OnceLock<Arc<PlaylistManager>> = OnceLock::new();
        INSTANCE.get_or_init(|| Self::with_executor(Arc::new(YtDlpPlaylistExecutor)))
    }

    pub(crate) fn with_executor(executor: Arc<dyn PlaylistItemExecutor>) -> Arc<Self> {
        let (tx, _) = broadcast::channel(512);
        let (size_tx, _) = broadcast::channel(256);
        Arc::new(Self {
            tx,
            size_tx,
            runtime: Mutex::new(None),
            inspection_cache: Arc::new(Mutex::new(HashMap::new())),
            size_runtime: Mutex::new(None),
            executor,
        })
    }

    pub fn subscribe_broadcast(&self) -> broadcast::Receiver<PlaylistProgressEvent> {
        self.tx.subscribe()
    }

    pub fn subscribe_size_broadcast(&self) -> broadcast::Receiver<PlaylistSizeEstimate> {
        self.size_tx.subscribe()
    }

    pub fn subscribe(&self, sink: StreamSink<PlaylistProgressEvent>) {
        let mut rx = self.tx.subscribe();
        shared_runtime().spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(event) => {
                        if sink.add(event).is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    pub fn subscribe_size_estimates(&self, sink: StreamSink<PlaylistSizeEstimate>) {
        let mut rx = self.size_tx.subscribe();
        shared_runtime().spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(event) => {
                        if sink.add(event).is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    /// Cancels any active size calculation while keeping cached item inspections intact.
    pub async fn cancel_size_estimation(&self, estimation_id: &str) -> Result<(), EngineError> {
        let (stop_notify, canceled_flag, done_notify) = {
            let guard = self.size_runtime.lock().await;
            let Some(active) = guard.as_ref() else {
                return Ok(());
            };
            if active.estimation_id != estimation_id || !active.is_running {
                return Ok(());
            }
            (
                active.stop_notify.clone(),
                active.canceled_flag.clone(),
                active.done_notify.clone(),
            )
        };

        canceled_flag.store(true, Ordering::SeqCst);
        stop_notify.notify_waiters();
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(STOP_WAIT_TIMEOUT_SECS),
            done_notify.notified(),
        )
        .await;
        Ok(())
    }

    /// Calculates expected playlist total size by resolving the chosen format for each
    /// accessible entry, reusing cached per-item inspections when mode or cap changes.
    pub async fn estimate_playlist_size(
        self: &Arc<Self>,
        request: EstimatePlaylistSizeRequest,
    ) -> Result<PlaylistSizeEstimate, EngineError> {
        // Cancel any previous in-flight calculation cleanly without flushing cached items.
        let prev = {
            let guard = self.size_runtime.lock().await;
            guard.as_ref().filter(|r| r.is_running).map(|r| {
                (
                    r.stop_notify.clone(),
                    r.canceled_flag.clone(),
                    r.done_notify.clone(),
                )
            })
        };
        if let Some((old_stop, old_canceled, old_done)) = prev {
            old_canceled.store(true, Ordering::SeqCst);
            old_stop.notify_waiters();
            let _ = tokio::time::timeout(
                std::time::Duration::from_secs(STOP_WAIT_TIMEOUT_SECS),
                old_done.notified(),
            )
            .await;
        }

        let estimation_id = Uuid::new_v4().to_string();
        let mut initial_results: HashMap<u32, Result<MediaInspection, String>> = HashMap::new();
        let mut uncached_entries: Vec<PlaylistEntrySummary> = Vec::new();

        {
            let cache = self.inspection_cache.lock().await;
            for entry in &request.playlist.entries {
                if entry.availability != PlaylistEntryAvailability::Available {
                    continue;
                }
                let key = inspection_cache_key(entry);
                if let Some(hit) = cache.get(&key) {
                    initial_results.insert(entry.order_index, Ok(hit.clone()));
                } else {
                    uncached_entries.push(entry.clone());
                }
            }
        }

        if uncached_entries.is_empty() {
            let estimate = build_playlist_size_estimate(
                &estimation_id,
                &request.playlist,
                request.media_mode,
                request.quality_cap,
                &initial_results,
                false,
                false,
            );
            let _ = self.size_tx.send(estimate.clone());
            return Ok(estimate);
        }

        let paths = ToolPaths::resolve()?;
        let stop_notify = Arc::new(Notify::new());
        let canceled_flag = Arc::new(AtomicBool::new(false));
        let done_notify = Arc::new(Notify::new());

        {
            let mut guard = self.size_runtime.lock().await;
            *guard = Some(ActiveSizeEstimationRuntime {
                estimation_id: estimation_id.clone(),
                stop_notify: stop_notify.clone(),
                canceled_flag: canceled_flag.clone(),
                done_notify: done_notify.clone(),
                is_running: true,
            });
        }

        let initial_estimate = build_playlist_size_estimate(
            &estimation_id,
            &request.playlist,
            request.media_mode,
            request.quality_cap,
            &initial_results,
            true,
            false,
        );
        let _ = self.size_tx.send(initial_estimate.clone());

        let manager = self.clone();
        let results_arc = Arc::new(Mutex::new(initial_results));
        let playlist = request.playlist;
        let media_mode = request.media_mode;
        let quality_cap = request.quality_cap;
        let eid = estimation_id.clone();

        shared_runtime().spawn(async move {
            let semaphore = Arc::new(Semaphore::new(MAX_CONCURRENT_SIZE_INSPECTIONS));
            let mut handles = Vec::with_capacity(uncached_entries.len());

            for entry in uncached_entries {
                let sem = semaphore.clone();
                let mgr = manager.clone();
                let res_map = results_arc.clone();
                let pl = playlist.clone();
                let paths_cloned = paths.clone();
                let stop = stop_notify.clone();
                let canceled = canceled_flag.clone();
                let eid_task = eid.clone();

                handles.push(tokio::spawn(async move {
                    let permit = tokio::select! {
                        acquired = sem.acquire_owned() => match acquired {
                            Ok(p) => p,
                            Err(_) => return,
                        },
                        () = stop.notified() => return,
                    };
                    if canceled.load(Ordering::SeqCst) {
                        drop(permit);
                        return;
                    }

                    let inspected = mgr
                        .executor
                        .inspect_item(&entry.url, &paths_cloned, stop.clone())
                        .await;
                    drop(permit);

                    if canceled.load(Ordering::SeqCst) {
                        return;
                    }

                    match inspected {
                        Ok(media) => {
                            let cache_key = inspection_cache_key(&entry);
                            {
                                let mut cache_guard = mgr.inspection_cache.lock().await;
                                cache_guard.insert(cache_key, media.clone());
                            }
                            let mut map_guard = res_map.lock().await;
                            map_guard.insert(entry.order_index, Ok(media));
                            let snapshot = build_playlist_size_estimate(
                                &eid_task,
                                &pl,
                                media_mode,
                                quality_cap,
                                &map_guard,
                                true,
                                false,
                            );
                            let _ = mgr.size_tx.send(snapshot);
                        }
                        Err(err) => {
                            let mut map_guard = res_map.lock().await;
                            map_guard.insert(entry.order_index, Err(err.to_string()));
                            let snapshot = build_playlist_size_estimate(
                                &eid_task,
                                &pl,
                                media_mode,
                                quality_cap,
                                &map_guard,
                                true,
                                false,
                            );
                            let _ = mgr.size_tx.send(snapshot);
                        }
                    }
                }));
            }

            for handle in handles {
                let _ = handle.await;
            }

            let was_canceled = canceled_flag.load(Ordering::SeqCst);
            let final_snapshot = {
                let map_guard = results_arc.lock().await;
                build_playlist_size_estimate(
                    &eid,
                    &playlist,
                    media_mode,
                    quality_cap,
                    &map_guard,
                    false,
                    was_canceled,
                )
            };

            {
                let mut rt_guard = manager.size_runtime.lock().await;
                if let Some(active) = rt_guard.as_mut().filter(|r| r.estimation_id == eid) {
                    active.is_running = false;
                }
            }
            let _ = manager.size_tx.send(final_snapshot);
            done_notify.notify_waiters();
        });

        Ok(initial_estimate)
    }

    /// Loads any saved playlist manifest and stores it as the active resumable session if idle.
    pub async fn load_saved_session(
        &self,
        playlist_id: &str,
        custom_output_dir: Option<String>,
    ) -> Result<Option<PlaylistSessionSnapshot>, EngineError> {
        let base_dir = resolve_base_output_dir(custom_output_dir)?;
        let Some(snapshot) = load_saved_playlist_session(&base_dir, playlist_id).await? else {
            return Ok(None);
        };

        let mut guard = self.runtime.lock().await;
        if let Some(existing) = guard.as_ref() {
            if existing.snapshot.is_running {
                return Ok(Some(snapshot));
            }
        }

        let stems = compute_stems_for_items(&snapshot.items);
        *guard = Some(ActivePlaylistRuntime {
            snapshot: snapshot.clone(),
            item_stems: stems,
            stop_mode: None,
            stop_notify: Arc::new(Notify::new()),
            process_job: Arc::new(Mutex::new(None)),
            done_notify: Arc::new(Notify::new()),
        });
        Ok(Some(snapshot))
    }

    /// Creates/updates a playlist batch session, persists initial manifest, and starts sequential download.
    pub async fn start_playlist_download(
        self: &Arc<Self>,
        request: StartPlaylistDownloadRequest,
    ) -> Result<PlaylistSessionSnapshot, EngineError> {
        if request.playlist.entries.is_empty() {
            return Err(EngineError::InvalidRequest(
                "Playlist contains zero entries to download.".into(),
            ));
        }

        let paths = ToolPaths::resolve()?;
        let base_dir = match request
            .output_directory
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            Some(dir) => PathBuf::from(dir),
            None => paths.default_output_dir.clone(),
        };

        let playlist_dir =
            playlist_folder_path(&base_dir, &request.playlist.title, &request.playlist.id);
        tokio::fs::create_dir_all(&playlist_dir).await?;

        let previous_manifest =
            load_saved_playlist_session(&base_dir, &request.playlist.id).await?;
        let snapshot = build_initial_snapshot(&request, &playlist_dir, previous_manifest);
        let stems = compute_stems_for_items(&snapshot.items);
        save_manifest_atomic(&playlist_dir, &snapshot).await?;

        self.launch_runtime(snapshot.clone(), stems, paths).await?;
        Ok(snapshot)
    }

    /// Pauses the running playlist batch cleanly (retaining `.part` and completed files).
    pub async fn pause_playlist(&self, session_id: &str) -> Result<(), EngineError> {
        self.request_stop(session_id, StopMode::Pause).await
    }

    /// Cancels remaining playlist items cleanly while preserving already completed files.
    pub async fn cancel_playlist(&self, session_id: &str) -> Result<(), EngineError> {
        self.request_stop(session_id, StopMode::Cancel).await
    }

    /// Resumes a paused, canceled, or recovered playlist session sequentially.
    pub async fn resume_playlist(
        self: &Arc<Self>,
        session_id: &str,
    ) -> Result<PlaylistSessionSnapshot, EngineError> {
        let paths = ToolPaths::resolve()?;
        let (snapshot, stems) = {
            let guard = self.runtime.lock().await;
            let active = guard
                .as_ref()
                .ok_or_else(|| EngineError::JobNotFound(session_id.to_string()))?;
            if active.snapshot.session_id != session_id {
                return Err(EngineError::JobNotFound(session_id.to_string()));
            }
            if active.snapshot.is_running {
                return Err(EngineError::Busy(format!(
                    "Playlist session '{session_id}' is already running."
                )));
            }

            let mut updated = active.snapshot.clone();
            updated.is_paused = false;
            for item in &mut updated.items {
                if item.status == PlaylistItemStatus::Canceled {
                    item.status = PlaylistItemStatus::Pending;
                    item.error_message = None;
                }
            }
            reconcile_recovered_snapshot(&mut updated);
            (updated, active.item_stems.clone())
        };

        save_manifest_atomic(Path::new(&snapshot.output_directory), &snapshot).await?;
        self.launch_runtime(snapshot.clone(), stems, paths).await?;
        Ok(snapshot)
    }

    /// Resets only failed playlist items back to `Pending` and re-runs the batch sequentially.
    pub async fn retry_failed(
        self: &Arc<Self>,
        session_id: &str,
    ) -> Result<PlaylistSessionSnapshot, EngineError> {
        let paths = ToolPaths::resolve()?;
        let (snapshot, stems) = {
            let guard = self.runtime.lock().await;
            let active = guard
                .as_ref()
                .ok_or_else(|| EngineError::JobNotFound(session_id.to_string()))?;
            if active.snapshot.session_id != session_id {
                return Err(EngineError::JobNotFound(session_id.to_string()));
            }
            if active.snapshot.is_running {
                return Err(EngineError::Busy(format!(
                    "Playlist session '{session_id}' is already running."
                )));
            }

            let mut updated = active.snapshot.clone();
            let mut failed_count = 0usize;
            for item in &mut updated.items {
                if item.status == PlaylistItemStatus::Failed {
                    item.status = PlaylistItemStatus::Pending;
                    item.error_message = None;
                    item.downloaded_bytes = 0;
                    item.total_bytes = None;
                    failed_count += 1;
                }
            }
            if failed_count == 0 {
                return Err(EngineError::InvalidRequest(
                    "There are no failed playlist items to retry.".into(),
                ));
            }
            updated.is_paused = false;
            recompute_counters(&mut updated);
            (updated, active.item_stems.clone())
        };

        save_manifest_atomic(Path::new(&snapshot.output_directory), &snapshot).await?;
        self.launch_runtime(snapshot.clone(), stems, paths).await?;
        Ok(snapshot)
    }

    async fn request_stop(&self, session_id: &str, mode: StopMode) -> Result<(), EngineError> {
        let (stop_notify, job_slot, done_notify) = {
            let mut guard = self.runtime.lock().await;
            let active = guard
                .as_mut()
                .ok_or_else(|| EngineError::JobNotFound(session_id.to_string()))?;
            if active.snapshot.session_id != session_id {
                return Err(EngineError::JobNotFound(session_id.to_string()));
            }
            if !active.snapshot.is_running {
                return Err(EngineError::InvalidRequest(format!(
                    "Playlist session '{session_id}' is not currently running."
                )));
            }
            active.stop_mode = Some(mode);
            (
                active.stop_notify.clone(),
                active.process_job.clone(),
                active.done_notify.clone(),
            )
        };

        stop_notify.notify_waiters();
        if let Some(handle) = job_slot.lock().await.clone() {
            let _ = handle.terminate();
        }

        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(STOP_WAIT_TIMEOUT_SECS),
            done_notify.notified(),
        )
        .await;

        Ok(())
    }

    async fn launch_runtime(
        self: &Arc<Self>,
        mut snapshot: PlaylistSessionSnapshot,
        stems: Vec<String>,
        paths: ToolPaths,
    ) -> Result<(), EngineError> {
        snapshot.is_running = true;
        snapshot.is_paused = false;

        let stop_notify = Arc::new(Notify::new());
        let process_job = Arc::new(Mutex::new(None));
        let done_notify = Arc::new(Notify::new());

        {
            let mut guard = self.runtime.lock().await;
            if let Some(existing) = guard.as_ref() {
                if existing.snapshot.is_running {
                    return Err(EngineError::Busy(
                        "Another playlist download is already in progress. Pause or cancel it first."
                            .into(),
                    ));
                }
            }
            *guard = Some(ActivePlaylistRuntime {
                snapshot: snapshot.clone(),
                item_stems: stems,
                stop_mode: None,
                stop_notify: stop_notify.clone(),
                process_job: process_job.clone(),
                done_notify: done_notify.clone(),
            });
        }

        let _ = self.tx.send(make_batch_event(
            &snapshot,
            PlaylistEventKind::PlaylistStarted,
            Some(format!(
                "Starting playlist '{}' ({} items)...",
                snapshot.playlist_title, snapshot.total_count
            )),
        ));

        let manager = self.clone();
        shared_runtime().spawn(async move {
            manager
                .run_playlist_worker(
                    snapshot.session_id,
                    paths,
                    stop_notify,
                    process_job,
                    done_notify,
                )
                .await;
        });

        Ok(())
    }

    async fn run_playlist_worker(
        self: Arc<Self>,
        session_id: String,
        paths: ToolPaths,
        stop_notify: Arc<Notify>,
        job_slot: Arc<Mutex<Option<Arc<ProcessTreeJob>>>>,
        done_notify: Arc<Notify>,
    ) {
        let item_count = {
            let guard = self.runtime.lock().await;
            guard
                .as_ref()
                .filter(|r| r.snapshot.session_id == session_id)
                .map(|r| r.snapshot.items.len())
                .unwrap_or(0)
        };

        let mut stopped_by: Option<StopMode> = None;

        for idx in 0..item_count {
            if let Some(mode) = self.current_stop_mode(&session_id).await {
                stopped_by = Some(mode);
                break;
            }

            let Some((item, stem, playlist_dir, media_mode, quality_cap, snapshot_copy)) =
                self.prepare_next_item(&session_id, idx).await
            else {
                continue;
            };

            // Check duplicate avoidance if file was already completed & still exists on disk.
            if item.status == PlaylistItemStatus::Completed {
                continue;
            }

            // Unavailable items already marked Skipped emit an informative skipped event once.
            if item.status == PlaylistItemStatus::Skipped {
                let _ = self.tx.send(make_item_event(
                    &snapshot_copy,
                    PlaylistEventKind::PlaylistItemSkipped,
                    idx as u32,
                    PlaylistItemStatus::Skipped,
                    None,
                    item.audio_language.clone(),
                    item.error_message.clone(),
                ));
                continue;
            }

            if item.status != PlaylistItemStatus::Pending {
                continue;
            }

            self.set_item_status(
                &session_id,
                idx,
                PlaylistItemStatus::Analyzing,
                None,
                None,
                None,
            )
            .await;
            let snap_started = self.snapshot_clone(&session_id).await;
            if let Some(ref snap) = snap_started {
                let _ = save_manifest_atomic(Path::new(&snap.output_directory), snap).await;
                let _ = self.tx.send(make_item_event(
                    snap,
                    PlaylistEventKind::PlaylistItemStarted,
                    idx as u32,
                    PlaylistItemStatus::Analyzing,
                    None,
                    None,
                    Some(format!("Analyzing '{}'...", item.title)),
                ));
            }

            let inspect_res = self
                .executor
                .inspect_item(&item.url, &paths, stop_notify.clone())
                .await;

            if let Some(mode) = self.current_stop_mode(&session_id).await {
                self.revert_interrupted_item(&session_id, idx, mode).await;
                stopped_by = Some(mode);
                break;
            }

            let inspection = match inspect_res {
                Ok(i) => i,
                Err(err) => {
                    self.record_item_failure(&session_id, idx, err.to_string())
                        .await;
                    continue;
                }
            };

            let resolved = match select_playlist_item_option(&inspection, media_mode, quality_cap) {
                Ok(r) => r,
                Err(reason) => {
                    self.record_item_failure(&session_id, idx, reason).await;
                    continue;
                }
            };

            self.set_item_ready(
                &session_id,
                idx,
                resolved.quality_label.clone(),
                resolved.audio_language.clone(),
            )
            .await;

            let output_template = Path::new(&playlist_dir)
                .join(format!("{stem}.%(ext)s"))
                .to_string_lossy()
                .into_owned();
            let dl_request = StartDownloadRequest {
                url: if inspection.webpage_url.is_empty() {
                    item.url.clone()
                } else {
                    inspection.webpage_url.clone()
                },
                title: Some(inspection.title.clone()),
                selection: resolved.selection.clone(),
                output_directory: Some(playlist_dir.clone()),
            };

            let tx_clone = self.tx.clone();
            let sid_clone = session_id.clone();
            let q_label = resolved.quality_label.clone();
            let audio_lang = resolved.audio_language.clone();
            let totals = self.snapshot_totals(&session_id).await;
            let p_dir_opt = Some(playlist_dir.clone());

            let dl_res = self
                .executor
                .download_item(
                    &paths,
                    &dl_request,
                    &output_template,
                    job_slot.clone(),
                    stop_notify.clone(),
                    Box::new(move |prog| {
                        let (c_cnt, f_cnt, s_cnt, t_cnt) = totals;
                        let kind = if prog.is_merging {
                            PlaylistEventKind::PlaylistItemMerging
                        } else {
                            PlaylistEventKind::PlaylistItemProgress
                        };
                        let status = if prog.is_merging {
                            PlaylistItemStatus::Merging
                        } else {
                            PlaylistItemStatus::Downloading
                        };
                        let _ = tx_clone.send(PlaylistProgressEvent {
                            session_id: sid_clone.clone(),
                            kind,
                            item_index: Some(idx as u32),
                            item_status: Some(status),
                            selected_quality: Some(q_label.clone()),
                            audio_language: audio_lang.clone(),
                            item_downloaded_bytes: prog.downloaded_bytes,
                            item_total_bytes: prog.total_bytes,
                            item_is_total_estimated: prog.is_total_estimated,
                            speed_bytes_per_sec: prog.speed_bytes_per_sec,
                            eta_seconds: prog.eta_seconds,
                            output_path: None,
                            completed_count: c_cnt,
                            failed_count: f_cnt,
                            skipped_count: s_cnt,
                            total_count: t_cnt,
                            playlist_output_dir: p_dir_opt.clone(),
                            message: prog.status_message,
                        });
                    }),
                )
                .await;

            if let Some(mode) = self.current_stop_mode(&session_id).await {
                self.revert_interrupted_item(&session_id, idx, mode).await;
                stopped_by = Some(mode);
                break;
            }

            match dl_res {
                Ok(final_path) => {
                    let disk_bytes = tokio::fs::metadata(&final_path)
                        .await
                        .ok()
                        .map(|m| m.len())
                        .unwrap_or(0);
                    self.record_item_completed(&session_id, idx, final_path, disk_bytes)
                        .await;
                }
                Err(err) => {
                    self.record_item_failure(&session_id, idx, err.to_string())
                        .await;
                }
            }
        }

        let final_snapshot = self.finalize_session(&session_id, stopped_by).await;
        if let Some(snap) = final_snapshot {
            let _ = save_manifest_atomic(Path::new(&snap.output_directory), &snap).await;
            let (kind, msg) = match stopped_by {
                Some(StopMode::Pause) => (
                    PlaylistEventKind::PlaylistPaused,
                    Some(
                        "Playlist paused. Completed files preserved; click Resume to continue."
                            .into(),
                    ),
                ),
                Some(StopMode::Cancel) => (
                    PlaylistEventKind::PlaylistCanceled,
                    Some("Playlist canceled. Completed files preserved on disk.".into()),
                ),
                None => (
                    PlaylistEventKind::PlaylistCompleted,
                    Some(format!(
                        "Playlist finished: {} completed, {} failed, {} skipped.",
                        snap.completed_count, snap.failed_count, snap.skipped_count
                    )),
                ),
            };
            let _ = self.tx.send(make_batch_event(&snap, kind, msg));
        }

        done_notify.notify_waiters();
    }

    async fn current_stop_mode(&self, session_id: &str) -> Option<StopMode> {
        let guard = self.runtime.lock().await;
        guard
            .as_ref()
            .filter(|r| r.snapshot.session_id == session_id)
            .and_then(|r| r.stop_mode)
    }

    async fn prepare_next_item(
        &self,
        session_id: &str,
        idx: usize,
    ) -> Option<(
        PlaylistItemState,
        String,
        String,
        PlaylistMediaMode,
        PlaylistQualityCap,
        PlaylistSessionSnapshot,
    )> {
        let guard = self.runtime.lock().await;
        let active = guard
            .as_ref()
            .filter(|r| r.snapshot.session_id == session_id)?;
        let item = active.snapshot.items.get(idx)?.clone();
        let stem = active.item_stems.get(idx)?.clone();
        Some((
            item,
            stem,
            active.snapshot.output_directory.clone(),
            active.snapshot.media_mode,
            active.snapshot.quality_cap,
            active.snapshot.clone(),
        ))
    }

    async fn snapshot_clone(&self, session_id: &str) -> Option<PlaylistSessionSnapshot> {
        let guard = self.runtime.lock().await;
        guard
            .as_ref()
            .filter(|r| r.snapshot.session_id == session_id)
            .map(|r| r.snapshot.clone())
    }

    async fn snapshot_totals(&self, session_id: &str) -> (u32, u32, u32, u32) {
        let guard = self.runtime.lock().await;
        guard
            .as_ref()
            .filter(|r| r.snapshot.session_id == session_id)
            .map(|r| {
                (
                    r.snapshot.completed_count,
                    r.snapshot.failed_count,
                    r.snapshot.skipped_count,
                    r.snapshot.total_count,
                )
            })
            .unwrap_or((0, 0, 0, 0))
    }

    async fn set_item_status(
        &self,
        session_id: &str,
        idx: usize,
        status: PlaylistItemStatus,
        selected_quality: Option<String>,
        audio_language: Option<AudioTrackMetadata>,
        error_message: Option<String>,
    ) {
        let mut guard = self.runtime.lock().await;
        if let Some(active) = guard
            .as_mut()
            .filter(|r| r.snapshot.session_id == session_id)
        {
            if let Some(item) = active.snapshot.items.get_mut(idx) {
                item.status = status;
                if selected_quality.is_some() {
                    item.selected_quality = selected_quality;
                }
                if audio_language.is_some() {
                    item.audio_language = audio_language;
                }
                item.error_message = error_message;
            }
            recompute_counters(&mut active.snapshot);
        }
    }

    async fn set_item_ready(
        &self,
        session_id: &str,
        idx: usize,
        quality_label: String,
        audio_language: Option<AudioTrackMetadata>,
    ) {
        self.set_item_status(
            session_id,
            idx,
            PlaylistItemStatus::Downloading,
            Some(quality_label),
            audio_language,
            None,
        )
        .await;
    }

    async fn record_item_completed(
        &self,
        session_id: &str,
        idx: usize,
        output_path: String,
        disk_bytes: u64,
    ) {
        let snap_opt = {
            let mut guard = self.runtime.lock().await;
            let active = guard
                .as_mut()
                .filter(|r| r.snapshot.session_id == session_id);
            if let Some(active) = active {
                if let Some(item) = active.snapshot.items.get_mut(idx) {
                    item.status = PlaylistItemStatus::Completed;
                    item.output_path = Some(output_path.clone());
                    item.downloaded_bytes = disk_bytes;
                    item.total_bytes = Some(disk_bytes);
                    item.is_total_estimated = false;
                    item.error_message = None;
                }
                recompute_counters(&mut active.snapshot);
                Some((
                    active.snapshot.clone(),
                    active.snapshot.items[idx].selected_quality.clone(),
                    active.snapshot.items[idx].audio_language.clone(),
                ))
            } else {
                None
            }
        };

        if let Some((snap, q, a)) = snap_opt {
            let _ = save_manifest_atomic(Path::new(&snap.output_directory), &snap).await;
            let mut ev = make_item_event(
                &snap,
                PlaylistEventKind::PlaylistItemCompleted,
                idx as u32,
                PlaylistItemStatus::Completed,
                q,
                a,
                Some("Item completed.".into()),
            );
            ev.output_path = Some(output_path);
            ev.item_downloaded_bytes = disk_bytes;
            ev.item_total_bytes = Some(disk_bytes);
            let _ = self.tx.send(ev);
        }
    }

    async fn record_item_failure(&self, session_id: &str, idx: usize, error_msg: String) {
        let snap_opt = {
            let mut guard = self.runtime.lock().await;
            let active = guard
                .as_mut()
                .filter(|r| r.snapshot.session_id == session_id);
            if let Some(active) = active {
                if let Some(item) = active.snapshot.items.get_mut(idx) {
                    item.status = PlaylistItemStatus::Failed;
                    item.error_message = Some(error_msg.clone());
                }
                recompute_counters(&mut active.snapshot);
                Some((
                    active.snapshot.clone(),
                    active.snapshot.items[idx].selected_quality.clone(),
                    active.snapshot.items[idx].audio_language.clone(),
                ))
            } else {
                None
            }
        };

        if let Some((snap, q, a)) = snap_opt {
            let _ = save_manifest_atomic(Path::new(&snap.output_directory), &snap).await;
            let _ = self.tx.send(make_item_event(
                &snap,
                PlaylistEventKind::PlaylistItemFailed,
                idx as u32,
                PlaylistItemStatus::Failed,
                q,
                a,
                Some(error_msg),
            ));
        }
    }

    async fn revert_interrupted_item(&self, session_id: &str, active_idx: usize, mode: StopMode) {
        let mut guard = self.runtime.lock().await;
        if let Some(active) = guard
            .as_mut()
            .filter(|r| r.snapshot.session_id == session_id)
        {
            if let Some(item) = active.snapshot.items.get_mut(active_idx) {
                item.status = match mode {
                    StopMode::Pause => PlaylistItemStatus::Pending,
                    StopMode::Cancel => PlaylistItemStatus::Canceled,
                };
            }
            if mode == StopMode::Cancel {
                for item in active.snapshot.items.iter_mut().skip(active_idx + 1) {
                    if item.status == PlaylistItemStatus::Pending {
                        item.status = PlaylistItemStatus::Canceled;
                    }
                }
            }
            recompute_counters(&mut active.snapshot);
        }
    }

    async fn finalize_session(
        &self,
        session_id: &str,
        stopped_by: Option<StopMode>,
    ) -> Option<PlaylistSessionSnapshot> {
        let mut guard = self.runtime.lock().await;
        let active = guard
            .as_mut()
            .filter(|r| r.snapshot.session_id == session_id)?;
        active.snapshot.is_running = false;
        active.snapshot.is_paused = stopped_by == Some(StopMode::Pause);
        active.stop_mode = None;
        recompute_counters(&mut active.snapshot);
        Some(active.snapshot.clone())
    }
}

fn resolve_base_output_dir(custom_output_dir: Option<String>) -> Result<PathBuf, EngineError> {
    if let Some(dir) = custom_output_dir
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        return Ok(PathBuf::from(dir));
    }
    Ok(ToolPaths::resolve()?.default_output_dir)
}

fn compute_stems_for_items(items: &[PlaylistItemState]) -> Vec<String> {
    let total = items.len() as u32;
    let mut used = HashSet::with_capacity(items.len());
    items
        .iter()
        .map(|item| format_ordered_filename_stem(item.order_index, total, &item.title, &mut used))
        .collect()
}

fn build_initial_snapshot(
    request: &StartPlaylistDownloadRequest,
    playlist_dir: &Path,
    previous_manifest: Option<PlaylistSessionSnapshot>,
) -> PlaylistSessionSnapshot {
    let reuse_completed = previous_manifest.as_ref().is_some_and(|prev| {
        prev.media_mode == request.media_mode && prev.quality_cap == request.quality_cap
    });

    let items: Vec<PlaylistItemState> = request
        .playlist
        .entries
        .iter()
        .map(|entry| {
            if entry.availability != PlaylistEntryAvailability::Available {
                return PlaylistItemState {
                    order_index: entry.order_index,
                    video_id: entry.video_id.clone(),
                    title: entry.title.clone(),
                    url: entry.url.clone(),
                    duration_seconds: entry.duration_seconds,
                    thumbnail_url: entry.thumbnail_url.clone(),
                    status: PlaylistItemStatus::Skipped,
                    selected_quality: None,
                    audio_language: None,
                    downloaded_bytes: 0,
                    total_bytes: None,
                    is_total_estimated: false,
                    output_path: None,
                    error_message: entry.availability_reason.clone(),
                };
            }

            if reuse_completed {
                if let Some(prev_item) = previous_manifest.as_ref().and_then(|m| {
                    m.items.iter().find(|i| {
                        i.video_id == entry.video_id && i.order_index == entry.order_index
                    })
                }) {
                    if prev_item.status == PlaylistItemStatus::Completed {
                        let exists_ok = prev_item
                            .output_path
                            .as_deref()
                            .and_then(|p| std::fs::metadata(p).ok())
                            .is_some_and(|m| m.is_file() && m.len() > 0);
                        if exists_ok {
                            return prev_item.clone();
                        }
                    }
                }
            }

            PlaylistItemState {
                order_index: entry.order_index,
                video_id: entry.video_id.clone(),
                title: entry.title.clone(),
                url: entry.url.clone(),
                duration_seconds: entry.duration_seconds,
                thumbnail_url: entry.thumbnail_url.clone(),
                status: PlaylistItemStatus::Pending,
                selected_quality: None,
                audio_language: None,
                downloaded_bytes: 0,
                total_bytes: None,
                is_total_estimated: false,
                output_path: None,
                error_message: None,
            }
        })
        .collect();

    let mut snap = PlaylistSessionSnapshot {
        session_id: Uuid::new_v4().to_string(),
        playlist_id: request.playlist.id.clone(),
        playlist_title: request.playlist.title.clone(),
        playlist_url: request.playlist.webpage_url.clone(),
        uploader: request.playlist.uploader.clone(),
        thumbnail_url: request.playlist.thumbnail_url.clone(),
        output_directory: playlist_dir.to_string_lossy().into_owned(),
        media_mode: request.media_mode,
        quality_cap: request.quality_cap,
        is_running: false,
        is_paused: false,
        completed_count: 0,
        failed_count: 0,
        skipped_count: 0,
        total_count: items.len() as u32,
        items,
    };
    recompute_counters(&mut snap);
    snap
}

fn make_batch_event(
    snap: &PlaylistSessionSnapshot,
    kind: PlaylistEventKind,
    message: Option<String>,
) -> PlaylistProgressEvent {
    PlaylistProgressEvent {
        session_id: snap.session_id.clone(),
        kind,
        item_index: None,
        item_status: None,
        selected_quality: None,
        audio_language: None,
        item_downloaded_bytes: 0,
        item_total_bytes: None,
        item_is_total_estimated: false,
        speed_bytes_per_sec: None,
        eta_seconds: None,
        output_path: None,
        completed_count: snap.completed_count,
        failed_count: snap.failed_count,
        skipped_count: snap.skipped_count,
        total_count: snap.total_count,
        playlist_output_dir: Some(snap.output_directory.clone()),
        message,
    }
}

fn make_item_event(
    snap: &PlaylistSessionSnapshot,
    kind: PlaylistEventKind,
    item_index: u32,
    item_status: PlaylistItemStatus,
    selected_quality: Option<String>,
    audio_language: Option<AudioTrackMetadata>,
    message: Option<String>,
) -> PlaylistProgressEvent {
    PlaylistProgressEvent {
        session_id: snap.session_id.clone(),
        kind,
        item_index: Some(item_index),
        item_status: Some(item_status),
        selected_quality,
        audio_language,
        item_downloaded_bytes: 0,
        item_total_bytes: None,
        item_is_total_estimated: false,
        speed_bytes_per_sec: None,
        eta_seconds: None,
        output_path: None,
        completed_count: snap.completed_count,
        failed_count: snap.failed_count,
        skipped_count: snap.skipped_count,
        total_count: snap.total_count,
        playlist_output_dir: Some(snap.output_directory.clone()),
        message,
    }
}

fn inspection_cache_key(entry: &PlaylistEntrySummary) -> String {
    if !entry.video_id.trim().is_empty() {
        entry.video_id.trim().to_string()
    } else {
        entry.url.trim().to_string()
    }
}

pub(crate) fn build_playlist_size_estimate(
    estimation_id: &str,
    playlist: &PlaylistInspection,
    media_mode: PlaylistMediaMode,
    quality_cap: PlaylistQualityCap,
    results: &HashMap<u32, Result<MediaInspection, String>>,
    is_calculating: bool,
    was_canceled: bool,
) -> PlaylistSizeEstimate {
    let mut unavailable_count = 0u32;
    let mut eligible_count = 0u32;
    let mut inspected_count = 0u32;
    let mut exact_count = 0u32;
    let mut estimated_count = 0u32;
    let mut unknown_count = 0u32;
    let mut failed_count = 0u32;
    let mut known_total_bytes = 0u64;
    let mut item_sizes = Vec::with_capacity(playlist.entries.len());

    for entry in &playlist.entries {
        if entry.availability != PlaylistEntryAvailability::Available {
            unavailable_count += 1;
            continue;
        }
        eligible_count += 1;

        match results.get(&entry.order_index) {
            Some(Ok(inspection)) => {
                inspected_count += 1;
                match select_playlist_item_option(inspection, media_mode, quality_cap) {
                    Ok(resolved) => {
                        let display_size = format_display_size(
                            resolved.expected_size_bytes,
                            resolved.size_accuracy,
                        );
                        match (resolved.expected_size_bytes, resolved.size_accuracy) {
                            (Some(bytes), FileSizeAccuracy::Exact) => {
                                exact_count += 1;
                                known_total_bytes = known_total_bytes.saturating_add(bytes);
                            }
                            (Some(bytes), FileSizeAccuracy::Estimated) => {
                                estimated_count += 1;
                                known_total_bytes = known_total_bytes.saturating_add(bytes);
                            }
                            _ => {
                                unknown_count += 1;
                            }
                        }
                        item_sizes.push(PlaylistItemSizeInfo {
                            order_index: entry.order_index,
                            selected_quality: Some(resolved.quality_label),
                            expected_size_bytes: resolved.expected_size_bytes,
                            size_accuracy: resolved.size_accuracy,
                            display_size,
                            failed: false,
                            error_message: None,
                        });
                    }
                    Err(err_msg) => {
                        failed_count += 1;
                        item_sizes.push(PlaylistItemSizeInfo {
                            order_index: entry.order_index,
                            selected_quality: None,
                            expected_size_bytes: None,
                            size_accuracy: FileSizeAccuracy::Unknown,
                            display_size: "Unavailable".into(),
                            failed: true,
                            error_message: Some(err_msg),
                        });
                    }
                }
            }
            Some(Err(err_msg)) => {
                inspected_count += 1;
                failed_count += 1;
                item_sizes.push(PlaylistItemSizeInfo {
                    order_index: entry.order_index,
                    selected_quality: None,
                    expected_size_bytes: None,
                    size_accuracy: FileSizeAccuracy::Unknown,
                    display_size: "Unavailable".into(),
                    failed: true,
                    error_message: Some(err_msg.clone()),
                });
            }
            None => {}
        }
    }

    let status = if is_calculating {
        PlaylistSizeStatus::Calculating
    } else if was_canceled {
        PlaylistSizeStatus::Canceled
    } else if eligible_count == 0 {
        PlaylistSizeStatus::Unknown
    } else if failed_count > 0 && exact_count == 0 && estimated_count == 0 {
        PlaylistSizeStatus::Failed
    } else if unknown_count > 0 || failed_count > 0 {
        if known_total_bytes > 0 || exact_count > 0 || estimated_count > 0 {
            PlaylistSizeStatus::Partial
        } else {
            PlaylistSizeStatus::Unknown
        }
    } else if estimated_count > 0 {
        PlaylistSizeStatus::Estimated
    } else if exact_count > 0 {
        PlaylistSizeStatus::Exact
    } else {
        PlaylistSizeStatus::Unknown
    };

    let (display_summary, status_message) = match status {
        PlaylistSizeStatus::Idle => ("Pending size check".to_string(), None),
        PlaylistSizeStatus::Calculating => (
            "Calculating playlist size...".to_string(),
            Some(format!(
                "Calculating sizes: {inspected_count} / {eligible_count} videos"
            )),
        ),
        PlaylistSizeStatus::Canceled => {
            let summary = if known_total_bytes > 0 {
                format!("At least {} · canceled", format_bytes_human(known_total_bytes))
            } else {
                "Size calculation canceled".to_string()
            };
            (
                summary,
                Some(format!(
                    "Canceled after inspecting {inspected_count} of {eligible_count} videos."
                )),
            )
        }
        PlaylistSizeStatus::Exact => (
            format!("{} (Exact)", format_bytes_human(known_total_bytes)),
            Some(format!(
                "{eligible_count} accessible video(s) with exact sizes."
            )),
        ),
        PlaylistSizeStatus::Estimated => (
            format!("~{} (Estimated)", format_bytes_human(known_total_bytes)),
            Some(format!(
                "{eligible_count} accessible video(s) ({exact_count} exact, {estimated_count} estimated/merged)."
            )),
        ),
        PlaylistSizeStatus::Partial => {
            let human = format_bytes_human(known_total_bytes);
            if unknown_count > 0 && failed_count == 0 {
                (
                    format!("At least {human} · {unknown_count} unknown"),
                    Some(format!(
                        "At least {human} · {unknown_count} video(s) have unknown sizes."
                    )),
                )
            } else if failed_count > 0 && unknown_count == 0 {
                (
                    format!("At least {human} · {failed_count} failed"),
                    Some("Some video sizes could not be determined.".to_string()),
                )
            } else {
                (
                    format!("At least {human} · {unknown_count} unknown, {failed_count} failed"),
                    Some("Some video sizes are unknown or could not be determined.".to_string()),
                )
            }
        }
        PlaylistSizeStatus::Failed => (
            "Some video sizes could not be determined".to_string(),
            Some(format!(
                "{failed_count} of {eligible_count} accessible video(s) failed size inspection."
            )),
        ),
        PlaylistSizeStatus::Unknown => {
            if eligible_count == 0 {
                ("No accessible videos to size".to_string(), None)
            } else {
                (
                    "Unknown size".to_string(),
                    Some(format!("{unknown_count} video(s) have unknown sizes.")),
                )
            }
        }
    };

    PlaylistSizeEstimate {
        estimation_id: estimation_id.to_string(),
        playlist_id: playlist.id.clone(),
        media_mode,
        quality_cap,
        status,
        known_total_bytes,
        total_entries_count: playlist.entries.len() as u32,
        unavailable_count,
        eligible_count,
        inspected_count,
        exact_count,
        estimated_count,
        unknown_count,
        failed_count,
        display_summary,
        status_message,
        item_sizes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{AudioSelectionConfidence, DownloadFormatSelection, DownloadSelectionKind};
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicU32, Ordering};
    use tempfile::TempDir;

    fn make_raw_inspection_json(
        id: &str,
        title: &str,
        lang: Option<&str>,
        formats_json: &str,
    ) -> MediaInspection {
        let lang_line = lang
            .map(|l| format!(r#""language": "{l}","#))
            .unwrap_or_default();
        let raw = format!(
            r#"{{
                "id": "{id}",
                "title": "{title}",
                {lang_line}
                "webpage_url": "https://www.youtube.com/watch?v={id}",
                "extractor_key": "Youtube",
                "formats": {formats_json}
            }}"#
        );
        parse_yt_dlp_inspection_json(&raw).expect("sample item JSON should parse")
    }

    #[test]
    fn detects_playlist_vs_single_video_vs_shorts_and_mix() {
        assert!(is_playlist_url(
            "https://www.youtube.com/playlist?list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd"
        ));
        assert!(is_playlist_url(
            "https://www.youtube.com/watch?v=JXm0-ilIknE&list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd"
        ));
        assert!(!is_playlist_url(
            "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
        ));
        assert!(!is_playlist_url(
            "https://www.youtube.com/shorts/aqz-KE-bpKQ"
        ));
        assert!(!is_playlist_url(
            "https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=RDaqz-KE-bpKQ"
        ));
        assert_eq!(
            normalize_playlist_url(
                "https://www.youtube.com/watch?v=JXm0-ilIknE&list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd"
            )
            .expect("normalizes watch+list"),
            "https://www.youtube.com/playlist?list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd"
        );
    }

    #[test]
    fn parses_playlist_preserves_order_classifies_unavailable_and_handles_large_playlists() {
        let mut entries_json = Vec::new();
        for i in 0..105u32 {
            let entry = match i {
                1 => r#"{"id": "priv1", "title": "[Private video]", "availability": "private"}"#
                    .to_string(),
                2 => r#"{"id": "del2", "title": "[Deleted video]", "availability": "deleted"}"#
                    .to_string(),
                3 => {
                    r#"{"id": "auth3", "title": "Members Talk", "availability": "subscriber_only"}"#
                        .to_string()
                }
                _ => format!(
                    r#"{{"id": "vid{i}", "title": "Talk Number {i}", "duration": 120, "uploader": "Blender", "url": "https://www.youtube.com/watch?v=vid{i}"}}"#
                ),
            };
            entries_json.push(entry);
        }

        let json = format!(
            r#"{{
                "id": "PLlarge105",
                "title": "Large Conference Playlist",
                "uploader": "Blender",
                "playlist_count": 105,
                "webpage_url": "https://www.youtube.com/playlist?list=PLlarge105",
                "extractor_key": "YoutubeTab",
                "entries": [{}]
            }}"#,
            entries_json.join(",")
        );

        let parsed =
            parse_yt_dlp_playlist_json(&json, "https://www.youtube.com/playlist?list=PLlarge105")
                .expect("large playlist must parse cleanly");
        assert_eq!(parsed.id, "PLlarge105");
        assert_eq!(parsed.total_item_count, 105);
        assert_eq!(parsed.entries.len(), 105);
        for (i, entry) in parsed.entries.iter().enumerate() {
            assert_eq!(entry.order_index, i as u32);
        }
        assert_eq!(
            parsed.entries[1].availability,
            PlaylistEntryAvailability::Private
        );
        assert_eq!(
            parsed.entries[2].availability,
            PlaylistEntryAvailability::Removed
        );
        assert_eq!(
            parsed.entries[3].availability,
            PlaylistEntryAvailability::Unavailable
        );
        assert_eq!(
            parsed.entries[104].availability,
            PlaylistEntryAvailability::Available
        );
    }

    #[test]
    fn resolves_quality_caps_different_languages_combined_and_missing_audio() {
        // Item A: English original + Arabic auto-dub, max 720p available when UpTo1080p requested.
        let item_a = make_raw_inspection_json(
            "vidA",
            "Item A",
            Some("en-US"),
            r#"[
                {"format_id": "140-0", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "tbr": 128.0, "language": "ar", "language_preference": -1, "protocol": "https", "format_note": "Arabic - dubbed-auto"},
                {"format_id": "140-19", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "tbr": 128.0, "language": "en-US", "language_preference": 10, "protocol": "https", "format_note": "English (US) original (default), medium"},
                {"format_id": "136", "ext": "mp4", "vcodec": "avc1.4D401F", "acodec": "none", "width": 1280, "height": 720, "fps": 30.0, "filesize": 10000000, "protocol": "https"}
            ]"#,
        );
        let res_a = select_playlist_item_option(
            &item_a,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::UpTo1080p,
        )
        .expect("720p fallback should succeed when 1080p is absent");
        assert!(res_a.quality_label.contains("720p"));
        assert_eq!(res_a.selection.kind, DownloadSelectionKind::VideoAndAudio);
        assert_eq!(res_a.selection.video_format_id.as_deref(), Some("136"));
        assert_eq!(res_a.selection.audio_format_id.as_deref(), Some("140-19"));
        assert_eq!(
            res_a
                .audio_language
                .as_ref()
                .and_then(|a| a.language.as_deref()),
            Some("en-US")
        );

        // Item B in same playlist: Arabic original + English dub, 2160p capped to 1080p!
        let item_b = make_raw_inspection_json(
            "vidB",
            "Item B Arabic",
            Some("ar"),
            r#"[
                {"format_id": "140-en", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "tbr": 128.0, "language": "en", "language_preference": -1, "protocol": "https", "format_note": "English - dubbed-auto"},
                {"format_id": "140-ar", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "tbr": 128.0, "language": "ar", "language_preference": 10, "protocol": "https", "format_note": "Arabic original (default), medium"},
                {"format_id": "401", "ext": "mp4", "vcodec": "av01.0.12M.08", "acodec": "none", "width": 3840, "height": 2160, "fps": 30.0, "filesize": 80000000, "protocol": "https"},
                {"format_id": "137", "ext": "mp4", "vcodec": "avc1.640028", "acodec": "none", "width": 1920, "height": 1080, "fps": 30.0, "filesize": 40000000, "protocol": "https"}
            ]"#,
        );
        let res_b = select_playlist_item_option(
            &item_b,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::UpTo1080p,
        )
        .expect("UpTo1080p cap picks 1080p over 4K");
        assert!(res_b.quality_label.contains("1080p"));
        assert_eq!(res_b.selection.video_format_id.as_deref(), Some("137"));
        assert_eq!(res_b.selection.audio_format_id.as_deref(), Some("140-ar"));
        assert_eq!(
            res_b
                .audio_language
                .as_ref()
                .map(|a| a.selection_confidence),
            Some(AudioSelectionConfidence::ConfirmedOriginal)
        );

        // Audio-only picks original Arabic `140-ar`, not dubbed `140-en`.
        let audio_b = select_playlist_item_option(
            &item_b,
            PlaylistMediaMode::AudioOnly,
            PlaylistQualityCap::BestAvailable,
        )
        .expect("Audio Only picks original track");
        assert_eq!(audio_b.selection, DownloadFormatSelection::single("140-ar"));

        // Item C: Combined muxed format chosen cleanly.
        let item_c = make_raw_inspection_json(
            "vidC",
            "Item C Muxed",
            None,
            r#"[
                {"format_id": "18", "ext": "mp4", "vcodec": "avc1.42001E", "acodec": "mp4a.40.2", "width": 640, "height": 360, "fps": 30.0, "filesize": 8000000, "protocol": "https"}
            ]"#,
        );
        let res_c = select_playlist_item_option(
            &item_c,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::UpTo480p,
        )
        .expect("Combined muxed option succeeds");
        assert_eq!(res_c.selection, DownloadFormatSelection::single("18"));

        // Item D: Missing audio track -> explicit Err.
        let item_d = make_raw_inspection_json(
            "vidD",
            "Silent Item",
            None,
            r#"[
                {"format_id": "137", "ext": "mp4", "vcodec": "avc1.640028", "acodec": "none", "width": 1920, "height": 1080, "fps": 30.0, "filesize": 12000000, "protocol": "https"}
            ]"#,
        );
        assert!(select_playlist_item_option(
            &item_d,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::BestAvailable
        )
        .is_err());
    }

    #[test]
    fn sanitizes_windows_filenames_keeps_arabic_and_prevents_duplicates() {
        assert_eq!(
            sanitize_windows_filename("Intro: <Part 1> / Test?", 80),
            "Intro Part 1 Test"
        );
        assert_eq!(sanitize_windows_filename("CON", 80), "_CON");
        assert_eq!(
            sanitize_windows_filename("مقدمة: شرح البرمجة؟", 80),
            "مقدمة شرح البرمجة؟"
        );

        let mut used = HashSet::new();
        assert_eq!(
            format_ordered_filename_stem(0, 12, "Same Title", &mut used),
            "001 - Same Title"
        );
        assert_eq!(
            format_ordered_filename_stem(0, 12, "Same Title", &mut used),
            "001 - Same Title (2)"
        );
        assert_eq!(
            format_ordered_filename_stem(1, 12, "Same Title", &mut used),
            "002 - Same Title"
        );
    }

    struct MockPlaylistExecutor {
        inspections: HashMap<String, MediaInspection>,
        fail_first_attempt_for: Mutex<HashSet<String>>,
        download_calls: AtomicU32,
        pause_trigger_tx: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
        delay_ms_for_url: HashMap<String, u64>,
    }

    impl PlaylistItemExecutor for MockPlaylistExecutor {
        fn inspect_item<'a>(
            &'a self,
            url: &'a str,
            _paths: &'a ToolPaths,
            _stop_notify: Arc<Notify>,
        ) -> Pin<Box<dyn Future<Output = Result<MediaInspection, EngineError>> + Send + 'a>>
        {
            Box::pin(async move {
                self.inspections
                    .get(url)
                    .cloned()
                    .ok_or_else(|| EngineError::ProcessFailed {
                        exit_code: Some(1),
                        stderr: format!("Simulated failure for {url}"),
                    })
            })
        }

        fn download_item<'a>(
            &'a self,
            _paths: &'a ToolPaths,
            request: &'a StartDownloadRequest,
            output_template: &'a str,
            _job_slot: Arc<Mutex<Option<Arc<ProcessTreeJob>>>>,
            stop_notify: Arc<Notify>,
            on_progress: Box<dyn Fn(ItemExecutionProgress) + Send + Sync + 'a>,
        ) -> Pin<Box<dyn Future<Output = Result<String, EngineError>> + Send + 'a>> {
            Box::pin(async move {
                self.download_calls.fetch_add(1, Ordering::SeqCst);

                {
                    let mut guard = self.fail_first_attempt_for.lock().await;
                    if guard.remove(&request.url) {
                        return Err(EngineError::ProcessFailed {
                            exit_code: Some(1),
                            stderr: "Transient network failure".into(),
                        });
                    }
                }

                on_progress(ItemExecutionProgress {
                    downloaded_bytes: 512,
                    total_bytes: Some(1024),
                    is_total_estimated: false,
                    speed_bytes_per_sec: Some(256.0),
                    eta_seconds: Some(2),
                    is_merging: false,
                    status_message: None,
                });

                if let Some(sender) = self.pause_trigger_tx.lock().await.take() {
                    let _ = sender.send(());
                }

                if let Some(ms) = self.delay_ms_for_url.get(&request.url) {
                    tokio::select! {
                        () = tokio::time::sleep(std::time::Duration::from_millis(*ms)) => {},
                        () = stop_notify.notified() => {
                            return Err(EngineError::InvalidRequest("Stopped by test".into()));
                        }
                    }
                }

                let final_path = output_template.replace("%(ext)s", "mp4");
                tokio::fs::write(&final_path, b"mock-mp4-data")
                    .await
                    .map_err(EngineError::Io)?;
                Ok(final_path)
            })
        }
    }

    #[tokio::test]
    async fn coordinator_continues_after_failure_retries_pauses_resumes_and_recovers_manifest() {
        let temp = TempDir::new().expect("temp dir");
        let url_0 = "https://www.youtube.com/watch?v=v0";
        let url_2 = "https://www.youtube.com/watch?v=v2";
        let url_3 = "https://www.youtube.com/watch?v=v3";

        let formats = r#"[
            {"format_id": "18", "ext": "mp4", "vcodec": "avc1.42001E", "acodec": "mp4a.40.2", "width": 640, "height": 360, "fps": 30.0, "filesize": 1024, "protocol": "https"}
        ]"#;
        let mut inspections = HashMap::new();
        inspections.insert(
            url_0.to_string(),
            make_raw_inspection_json("v0", "First", None, formats),
        );
        inspections.insert(
            url_2.to_string(),
            make_raw_inspection_json("v2", "Third", None, formats),
        );
        inspections.insert(
            url_3.to_string(),
            make_raw_inspection_json("v3", "Fourth", None, formats),
        );

        let mut fail_once = HashSet::new();
        fail_once.insert(url_0.to_string());

        let (pause_tx, pause_rx) = tokio::sync::oneshot::channel();
        let mut delays = HashMap::new();
        delays.insert(url_3.to_string(), 800u64);

        let executor = Arc::new(MockPlaylistExecutor {
            inspections,
            fail_first_attempt_for: Mutex::new(fail_once),
            download_calls: AtomicU32::new(0),
            pause_trigger_tx: Mutex::new(Some(pause_tx)),
            delay_ms_for_url: delays,
        });

        let manager = PlaylistManager::with_executor(executor.clone());
        let mut rx = manager.subscribe_broadcast();

        let playlist = PlaylistInspection {
            id: "PLmock".into(),
            title: "Mock Playlist".into(),
            uploader: Some("Tester".into()),
            thumbnail_url: None,
            webpage_url: "https://www.youtube.com/playlist?list=PLmock".into(),
            provider_name: "YouTube".into(),
            total_item_count: 4,
            entries: vec![
                PlaylistEntrySummary {
                    order_index: 0,
                    video_id: "v0".into(),
                    title: "First Fail Then Retry".into(),
                    url: url_0.into(),
                    uploader: None,
                    duration_seconds: Some(10.0),
                    thumbnail_url: None,
                    availability: PlaylistEntryAvailability::Available,
                    availability_reason: None,
                },
                PlaylistEntrySummary {
                    order_index: 1,
                    video_id: "priv1".into(),
                    title: "[Private video]".into(),
                    url: String::new(),
                    uploader: None,
                    duration_seconds: None,
                    thumbnail_url: None,
                    availability: PlaylistEntryAvailability::Private,
                    availability_reason: Some("Private video (skipped automatically)".into()),
                },
                PlaylistEntrySummary {
                    order_index: 2,
                    video_id: "v2".into(),
                    title: "Third Immediate".into(),
                    url: url_2.into(),
                    uploader: None,
                    duration_seconds: Some(12.0),
                    thumbnail_url: None,
                    availability: PlaylistEntryAvailability::Available,
                    availability_reason: None,
                },
                PlaylistEntrySummary {
                    order_index: 3,
                    video_id: "v3".into(),
                    title: "Fourth Paused".into(),
                    url: url_3.into(),
                    uploader: None,
                    duration_seconds: Some(15.0),
                    thumbnail_url: None,
                    availability: PlaylistEntryAvailability::Available,
                    availability_reason: None,
                },
            ],
        };

        let snap = manager
            .start_playlist_download(StartPlaylistDownloadRequest {
                playlist,
                media_mode: PlaylistMediaMode::VideoWithSound,
                quality_cap: PlaylistQualityCap::UpTo720p,
                output_directory: Some(temp.path().to_string_lossy().into_owned()),
            })
            .await
            .expect("start playlist succeeds");

        // Wait until item 3 starts downloading, then pause the playlist cleanly.
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                let ev = rx.recv().await.expect("event");
                if ev.kind == PlaylistEventKind::PlaylistItemProgress && ev.item_index == Some(3) {
                    break;
                }
            }
        })
        .await
        .expect("item 3 should start before pause");
        let _ = pause_rx.await;
        manager
            .pause_playlist(&snap.session_id)
            .await
            .expect("pause must succeed");

        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                let ev = rx.recv().await.expect("event");
                if ev.kind == PlaylistEventKind::PlaylistPaused {
                    assert_eq!(ev.completed_count, 1);
                    assert_eq!(ev.failed_count, 1);
                    assert_eq!(ev.skipped_count, 1);
                    break;
                }
            }
        })
        .await
        .expect("should emit PlaylistPaused");

        // Verify manifest saved to disk & recoverable after simulated app restart.
        let recovered = load_saved_playlist_session(temp.path(), "PLmock")
            .await
            .expect("manifest load succeeds")
            .expect("manifest exists");
        assert_eq!(recovered.completed_count, 1);
        assert_eq!(recovered.failed_count, 1);
        assert_eq!(recovered.skipped_count, 1);
        assert_eq!(recovered.items[3].status, PlaylistItemStatus::Pending);

        // Resume finishes item 3 without re-downloading already completed item 2!
        let calls_before_resume = executor.download_calls.load(Ordering::SeqCst);
        manager
            .resume_playlist(&snap.session_id)
            .await
            .expect("resume succeeds");
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                let ev = rx.recv().await.expect("event");
                if ev.kind == PlaylistEventKind::PlaylistCompleted {
                    assert_eq!(ev.completed_count, 2);
                    assert_eq!(ev.failed_count, 1);
                    assert_eq!(ev.skipped_count, 1);
                    break;
                }
            }
        })
        .await
        .expect("resume finishes playlist");
        assert_eq!(
            executor.download_calls.load(Ordering::SeqCst),
            calls_before_resume + 1
        );

        // Retry Failed re-downloads ONLY item 0 (skipping completed items 2 & 3).
        let calls_before_retry = executor.download_calls.load(Ordering::SeqCst);
        manager
            .retry_failed(&snap.session_id)
            .await
            .expect("retry_failed succeeds");
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                let ev = rx.recv().await.expect("event");
                if ev.kind == PlaylistEventKind::PlaylistCompleted {
                    assert_eq!(ev.completed_count, 3);
                    assert_eq!(ev.failed_count, 0);
                    assert_eq!(ev.skipped_count, 1);
                    break;
                }
            }
        })
        .await
        .expect("retry finishes all remaining items");
        assert_eq!(
            executor.download_calls.load(Ordering::SeqCst),
            calls_before_retry + 1
        );
    }

    #[tokio::test]
    async fn live_enumerates_full_84_item_blender_playlist() {
        let url = "https://www.youtube.com/playlist?list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd";
        let result = inspect_url_async(url)
            .await
            .expect("full Blender 84-item playlist enumeration must succeed");
        assert_eq!(result.kind, InspectionTargetKind::Playlist);
        let playlist = result.playlist.expect("playlist payload must be present");
        assert_eq!(playlist.id, "PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd");
        assert_eq!(playlist.entries.len(), 84);
        assert_eq!(playlist.total_item_count, 84);
        for (i, entry) in playlist.entries.iter().enumerate() {
            assert_eq!(entry.order_index, i as u32);
            assert!(!entry.video_id.is_empty());
            assert!(!entry.title.is_empty());
        }
    }

    #[tokio::test]
    async fn live_downloads_authorized_3_item_blender_hq_playlist_and_verifies_streams_with_ffprobe(
    ) {
        let url = "https://www.youtube.com/playlist?list=PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB";
        let inspection_res = inspect_url_async(url)
            .await
            .expect("Blender HQ playlist inspection must succeed");
        assert_eq!(inspection_res.kind, InspectionTargetKind::Playlist);
        let playlist = inspection_res
            .playlist
            .expect("playlist inspection present");
        assert_eq!(playlist.entries.len(), 3);

        let temp = TempDir::new().expect("temp playlist output dir");
        let manager = PlaylistManager::with_executor(Arc::new(YtDlpPlaylistExecutor));
        let mut rx = manager.subscribe_broadcast();

        let snap = manager
            .start_playlist_download(StartPlaylistDownloadRequest {
                playlist,
                media_mode: PlaylistMediaMode::VideoWithSound,
                quality_cap: PlaylistQualityCap::UpTo480p,
                output_directory: Some(temp.path().to_string_lossy().into_owned()),
            })
            .await
            .expect("start playlist download succeeds");

        let mut completed_paths = Vec::new();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(300);
        while tokio::time::Instant::now() < deadline {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(120), rx.recv())
                .await
                .expect("timed out waiting for playlist event")
                .expect("broadcast channel open");
            if ev.session_id != snap.session_id {
                continue;
            }
            match ev.kind {
                PlaylistEventKind::PlaylistItemCompleted => {
                    if let Some(p) = ev.output_path {
                        completed_paths.push((ev.item_index.unwrap_or(0), p));
                    }
                }
                PlaylistEventKind::PlaylistItemFailed => {
                    panic!(
                        "Playlist item {:?} failed unexpectedly: {:?}",
                        ev.item_index, ev.message
                    );
                }
                PlaylistEventKind::PlaylistCompleted => {
                    assert_eq!(ev.completed_count, 3);
                    assert_eq!(ev.failed_count, 0);
                    break;
                }
                _ => {}
            }
        }

        assert_eq!(
            completed_paths.len(),
            3,
            "All 3 authorized Blender HQ videos must complete"
        );
        completed_paths.sort_by_key(|(idx, _)| *idx);

        let paths = ToolPaths::resolve().expect("tool paths");
        let ffprobe = paths.ffmpeg_dir().join(if cfg!(windows) {
            "ffprobe.exe"
        } else {
            "ffprobe"
        });

        for (i, (idx, file_path)) in completed_paths.iter().enumerate() {
            assert_eq!(*idx, i as u32);
            let p = Path::new(file_path);
            assert!(p.is_file(), "Downloaded file missing: {file_path}");
            let name = p
                .file_name()
                .and_then(|n| n.to_str())
                .expect("UTF-8 filename");
            let expected_prefix = format!("{:03} - ", i + 1);
            assert!(
                name.starts_with(&expected_prefix),
                "Expected ordered prefix '{expected_prefix}' on '{name}'"
            );

            let probe = std::process::Command::new(&ffprobe)
                .args([
                    "-v",
                    "error",
                    "-show_entries",
                    "stream=index,codec_type,codec_name",
                    "-of",
                    "json",
                    file_path,
                ])
                .output()
                .expect("ffprobe executes");
            assert!(probe.status.success(), "ffprobe failed on {file_path}");
            let probe_json: Value =
                serde_json::from_slice(&probe.stdout).expect("valid ffprobe JSON");
            let streams = probe_json["streams"].as_array().expect("streams array");
            assert!(
                streams.iter().any(|s| s["codec_type"] == "video"),
                "Missing video stream in {file_path}"
            );
            assert!(
                streams.iter().any(|s| s["codec_type"] == "audio"),
                "Missing audio stream in {file_path}"
            );
        }

        // Verify persisted manifest recovery returns 3/3 completed items cleanly.
        let recovered =
            load_saved_playlist_session(temp.path(), "PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB")
                .await
                .expect("load saved manifest succeeds")
                .expect("manifest must exist on disk");
        assert_eq!(recovered.completed_count, 3);
        assert_eq!(recovered.items.len(), 3);
    }

    #[test]
    fn transient_http_403_predicate_matches_only_process_403() {
        let forbidden = EngineError::ProcessFailed {
            exit_code: Some(1),
            stderr: "ERROR: unable to download video data: HTTP Error 403: Forbidden".into(),
        };
        assert!(is_transient_http_403(&forbidden));

        let other = EngineError::ProcessFailed {
            exit_code: Some(1),
            stderr: "ERROR: Video unavailable".into(),
        };
        assert!(!is_transient_http_403(&other));
        assert!(!is_transient_http_403(&EngineError::InvalidRequest(
            "HTTP Error 403".into()
        )));
    }

    fn make_muxed_inspection_fixture(id: &str, formats_json: &str) -> MediaInspection {
        make_raw_inspection_json(id, &format!("Title {id}"), Some("en"), formats_json)
    }

    fn entry_for(idx: u32, id: &str, avail: PlaylistEntryAvailability) -> PlaylistEntrySummary {
        PlaylistEntrySummary {
            order_index: idx,
            video_id: id.into(),
            title: format!("Item {idx}"),
            url: format!("https://www.youtube.com/watch?v={id}"),
            uploader: Some("Creator".into()),
            duration_seconds: Some(120.0),
            thumbnail_url: None,
            availability: avail,
            availability_reason: if avail == PlaylistEntryAvailability::Available {
                None
            } else {
                Some("Unavailable".into())
            },
        }
    }

    fn make_playlist_stub(id: &str, entries: Vec<PlaylistEntrySummary>) -> PlaylistInspection {
        PlaylistInspection {
            id: id.into(),
            title: format!("Playlist {id}"),
            uploader: Some("Channel".into()),
            thumbnail_url: None,
            webpage_url: format!("https://www.youtube.com/playlist?list={id}"),
            provider_name: "Youtube".into(),
            total_item_count: entries.len() as u32,
            entries,
        }
    }

    struct CountingInspectExecutor {
        inspections: HashMap<String, MediaInspection>,
        inspect_calls: AtomicU32,
        delay_ms: u64,
    }

    impl PlaylistItemExecutor for CountingInspectExecutor {
        fn inspect_item<'a>(
            &'a self,
            url: &'a str,
            _paths: &'a ToolPaths,
            stop_notify: Arc<Notify>,
        ) -> Pin<Box<dyn Future<Output = Result<MediaInspection, EngineError>> + Send + 'a>>
        {
            Box::pin(async move {
                self.inspect_calls.fetch_add(1, Ordering::SeqCst);
                if self.delay_ms > 0 {
                    tokio::select! {
                        () = tokio::time::sleep(std::time::Duration::from_millis(self.delay_ms)) => {}
                        () = stop_notify.notified() => {
                            return Err(EngineError::InvalidRequest("Canceled".into()));
                        }
                    }
                }
                self.inspections
                    .get(url)
                    .cloned()
                    .ok_or_else(|| EngineError::ProcessFailed {
                        exit_code: Some(1),
                        stderr: format!("Simulated failure for {url}"),
                    })
            })
        }

        fn download_item<'a>(
            &'a self,
            _paths: &'a ToolPaths,
            _request: &'a StartDownloadRequest,
            _output_template: &'a str,
            _job_slot: Arc<Mutex<Option<Arc<ProcessTreeJob>>>>,
            _stop_notify: Arc<Notify>,
            _on_progress: Box<dyn Fn(ItemExecutionProgress) + Send + Sync + 'a>,
        ) -> Pin<Box<dyn Future<Output = Result<String, EngineError>> + Send + 'a>> {
            Box::pin(async move {
                Err(EngineError::InvalidRequest(
                    "Not implemented in test".into(),
                ))
            })
        }
    }

    #[test]
    fn size_aggregation_distinguishes_exact_approx_mixed_unknown_merged_and_unavailable() {
        let playlist = make_playlist_stub(
            "PLmix",
            vec![
                entry_for(0, "exactA", PlaylistEntryAvailability::Available),
                entry_for(1, "exactB", PlaylistEntryAvailability::Available),
                entry_for(2, "privX", PlaylistEntryAvailability::Private),
            ],
        );

        let exact_fmt = r#"[
            {"format_id": "18", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a.40.2", "width": 640, "height": 360, "filesize": 1000000},
            {"format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "tbr": 128.0, "filesize": 250000, "language": "en", "language_preference": 10}
        ]"#;
        let mut results = HashMap::new();
        results.insert(0, Ok(make_muxed_inspection_fixture("exactA", exact_fmt)));
        results.insert(1, Ok(make_muxed_inspection_fixture("exactB", exact_fmt)));

        // All exact combined outputs + 1 unavailable -> Exact!
        let exact_est = build_playlist_size_estimate(
            "e1",
            &playlist,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::BestAvailable,
            &results,
            false,
            false,
        );
        assert_eq!(exact_est.status, PlaylistSizeStatus::Exact);
        assert_eq!(exact_est.known_total_bytes, 2_000_000);
        assert_eq!(exact_est.eligible_count, 2);
        assert_eq!(exact_est.unavailable_count, 1);
        assert_eq!(exact_est.exact_count, 2);
        assert_eq!(exact_est.estimated_count, 0);
        assert!(exact_est.display_summary.contains("(Exact)"));

        // Audio-only uses exact audio stream sizes too (`250_000 * 2 = 500_000`).
        let audio_est = build_playlist_size_estimate(
            "e_aud",
            &playlist,
            PlaylistMediaMode::AudioOnly,
            PlaylistQualityCap::BestAvailable,
            &results,
            false,
            false,
        );
        assert_eq!(audio_est.status, PlaylistSizeStatus::Exact);
        assert_eq!(audio_est.known_total_bytes, 500_000);

        // Approximate muxed outputs -> Estimated.
        let approx_fmt = r#"[
            {"format_id": "18", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a.40.2", "width": 640, "height": 360, "filesize_approx": 1500000}
        ]"#;
        results.insert(1, Ok(make_muxed_inspection_fixture("exactB", approx_fmt)));
        let mixed_approx = build_playlist_size_estimate(
            "e2",
            &playlist,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::BestAvailable,
            &results,
            false,
            false,
        );
        assert_eq!(mixed_approx.status, PlaylistSizeStatus::Estimated);
        assert_eq!(mixed_approx.known_total_bytes, 2_500_000);
        assert_eq!(mixed_approx.exact_count, 1);
        assert_eq!(mixed_approx.estimated_count, 1);
        assert!(mixed_approx.display_summary.contains("(Estimated)"));

        // All approximate outputs -> Estimated.
        results.insert(0, Ok(make_muxed_inspection_fixture("exactA", approx_fmt)));
        let all_approx = build_playlist_size_estimate(
            "e2b",
            &playlist,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::BestAvailable,
            &results,
            false,
            false,
        );
        assert_eq!(all_approx.status, PlaylistSizeStatus::Estimated);
        assert_eq!(all_approx.known_total_bytes, 3_000_000);

        // Separate video + audio merged output MUST be marked Estimated even if both have exact filesize.
        let merged_fmt = r#"[
            {"format_id": "137", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "width": 1920, "height": 1080, "filesize": 5000000},
            {"format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "tbr": 128.0, "filesize": 500000, "language": "en", "language_preference": 10}
        ]"#;
        results.insert(0, Ok(make_muxed_inspection_fixture("exactA", exact_fmt)));
        results.insert(1, Ok(make_muxed_inspection_fixture("exactB", merged_fmt)));
        let merged_est = build_playlist_size_estimate(
            "e3",
            &playlist,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::BestAvailable,
            &results,
            false,
            false,
        );
        assert_eq!(merged_est.status, PlaylistSizeStatus::Estimated);
        assert_eq!(merged_est.known_total_bytes, 1_000_000 + 5_500_000);
        assert_eq!(
            merged_est.item_sizes[1].size_accuracy,
            FileSizeAccuracy::Estimated
        );
        assert_eq!(
            merged_est.item_sizes[1].expected_size_bytes,
            Some(5_500_000)
        );

        // Unknown-size item mixed with known -> Partial ("At least ... · 1 unknown").
        let unknown_fmt = r#"[
            {"format_id": "18", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a.40.2", "width": 640, "height": 360}
        ]"#;
        results.insert(1, Ok(make_muxed_inspection_fixture("exactB", unknown_fmt)));
        let partial_est = build_playlist_size_estimate(
            "e4",
            &playlist,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::BestAvailable,
            &results,
            false,
            false,
        );
        assert_eq!(partial_est.status, PlaylistSizeStatus::Partial);
        assert_eq!(partial_est.known_total_bytes, 1_000_000);
        assert_eq!(partial_est.unknown_count, 1);
        assert!(partial_est.display_summary.starts_with("At least "));
        assert!(partial_est.display_summary.contains("1 unknown"));

        // All unknown -> Unknown.
        results.insert(0, Ok(make_muxed_inspection_fixture("exactA", unknown_fmt)));
        let all_unknown = build_playlist_size_estimate(
            "e5",
            &playlist,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::BestAvailable,
            &results,
            false,
            false,
        );
        assert_eq!(all_unknown.status, PlaylistSizeStatus::Unknown);
        assert_eq!(all_unknown.unknown_count, 2);
    }

    #[test]
    fn size_calculation_follows_quality_caps_and_1080p_to_720p_fallback() {
        let playlist = make_playlist_stub(
            "PLcaps",
            vec![
                entry_for(0, "max1080", PlaylistEntryAvailability::Available),
                entry_for(1, "max720", PlaylistEntryAvailability::Available),
            ],
        );

        let multi_fmt = r#"[
            {"format_id": "137", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "width": 1920, "height": 1080, "filesize": 10000000},
            {"format_id": "136", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "width": 1280, "height": 720, "filesize": 4000000},
            {"format_id": "135", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "width": 854, "height": 480, "filesize": 2000000},
            {"format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "tbr": 128.0, "filesize": 1000000, "language": "en", "language_preference": 10}
        ]"#;
        let only_720_fmt = r#"[
            {"format_id": "136", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "width": 1280, "height": 720, "filesize": 3000000},
            {"format_id": "135", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "width": 854, "height": 480, "filesize": 1500000},
            {"format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "tbr": 128.0, "filesize": 500000, "language": "en", "language_preference": 10}
        ]"#;

        let mut results = HashMap::new();
        results.insert(0, Ok(make_muxed_inspection_fixture("max1080", multi_fmt)));
        results.insert(1, Ok(make_muxed_inspection_fixture("max720", only_720_fmt)));

        // Cap UpTo1080p: item 0 picks 1080p (10M+1M = 11M), item 1 falls back to 720p (3M+0.5M = 3.5M).
        let cap1080 = build_playlist_size_estimate(
            "c1080",
            &playlist,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::UpTo1080p,
            &results,
            false,
            false,
        );
        assert_eq!(cap1080.known_total_bytes, 14_500_000);
        assert_eq!(
            cap1080.item_sizes[1].selected_quality.as_deref(),
            Some("720p MP4")
        );

        // Cap UpTo720p: item 0 drops to 720p (4M+1M = 5M), item 1 uses 720p (3.5M).
        let cap720 = build_playlist_size_estimate(
            "c720",
            &playlist,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::UpTo720p,
            &results,
            false,
            false,
        );
        assert_eq!(cap720.known_total_bytes, 8_500_000);

        // Cap UpTo480p: item 0 uses 480p (3M), item 1 uses 480p (2M).
        let cap480 = build_playlist_size_estimate(
            "c480",
            &playlist,
            PlaylistMediaMode::VideoWithSound,
            PlaylistQualityCap::UpTo480p,
            &results,
            false,
            false,
        );
        assert_eq!(cap480.known_total_bytes, 5_000_000);
    }

    #[tokio::test]
    async fn estimator_caches_inspections_recalculates_instantly_and_supports_large_playlists_and_cancel(
    ) {
        let mut entries = Vec::new();
        let mut inspections = HashMap::new();
        let fmt_json = r#"[
            {"format_id": "136", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "width": 1280, "height": 720, "filesize": 4000000},
            {"format_id": "135", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "width": 854, "height": 480, "filesize": 2000000},
            {"format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "tbr": 128.0, "filesize": 1000000, "language": "en", "language_preference": 10}
        ]"#;

        for i in 0..90u32 {
            let avail = if i < 5 {
                PlaylistEntryAvailability::Private
            } else {
                PlaylistEntryAvailability::Available
            };
            let id = format!("large_{i}");
            let e = entry_for(i, &id, avail);
            if avail == PlaylistEntryAvailability::Available {
                inspections.insert(e.url.clone(), make_muxed_inspection_fixture(&id, fmt_json));
            }
            entries.push(e);
        }
        let playlist = make_playlist_stub("PL90", entries);

        let executor = Arc::new(CountingInspectExecutor {
            inspections,
            inspect_calls: AtomicU32::new(0),
            delay_ms: 0,
        });
        let manager = PlaylistManager::with_executor(executor.clone());
        let mut rx = manager.subscribe_size_broadcast();

        let started = manager
            .estimate_playlist_size(EstimatePlaylistSizeRequest {
                playlist: playlist.clone(),
                media_mode: PlaylistMediaMode::VideoWithSound,
                quality_cap: PlaylistQualityCap::UpTo720p,
            })
            .await
            .expect("estimate starts");
        assert_eq!(started.status, PlaylistSizeStatus::Calculating);

        let mut final_720 = None;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(15);
        while tokio::time::Instant::now() < deadline {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv())
                .await
                .expect("size event")
                .expect("channel open");
            if ev.estimation_id == started.estimation_id
                && ev.status != PlaylistSizeStatus::Calculating
            {
                final_720 = Some(ev);
                break;
            }
        }
        let final_720 = final_720.expect("final estimate received");
        assert_eq!(final_720.status, PlaylistSizeStatus::Estimated);
        assert_eq!(final_720.eligible_count, 85);
        assert_eq!(final_720.unavailable_count, 5);
        assert_eq!(final_720.known_total_bytes, 85 * 5_000_000);
        assert_eq!(executor.inspect_calls.load(Ordering::SeqCst), 85);

        // Changing cap to 480p and mode to AudioOnly must reuse cache with 0 extra executor calls!
        let recapped_480 = manager
            .estimate_playlist_size(EstimatePlaylistSizeRequest {
                playlist: playlist.clone(),
                media_mode: PlaylistMediaMode::VideoWithSound,
                quality_cap: PlaylistQualityCap::UpTo480p,
            })
            .await
            .expect("480p recalculation");
        assert_eq!(recapped_480.status, PlaylistSizeStatus::Estimated);
        assert_eq!(recapped_480.known_total_bytes, 85 * 3_000_000);
        assert_eq!(executor.inspect_calls.load(Ordering::SeqCst), 85);

        let audio_only = manager
            .estimate_playlist_size(EstimatePlaylistSizeRequest {
                playlist,
                media_mode: PlaylistMediaMode::AudioOnly,
                quality_cap: PlaylistQualityCap::BestAvailable,
            })
            .await
            .expect("audio recalculation");
        assert_eq!(audio_only.status, PlaylistSizeStatus::Exact);
        assert_eq!(audio_only.known_total_bytes, 85 * 1_000_000);
        assert_eq!(executor.inspect_calls.load(Ordering::SeqCst), 85);

        // Test cancellation stops slow inspection cleanly.
        let slow_playlist = make_playlist_stub(
            "PLslow",
            (0..6u32)
                .map(|i| {
                    entry_for(
                        i,
                        &format!("slow_{i}"),
                        PlaylistEntryAvailability::Available,
                    )
                })
                .collect(),
        );
        let slow_map: HashMap<String, MediaInspection> = slow_playlist
            .entries
            .iter()
            .map(|e| {
                (
                    e.url.clone(),
                    make_muxed_inspection_fixture(&e.video_id, fmt_json),
                )
            })
            .collect();
        let slow_exec = Arc::new(CountingInspectExecutor {
            inspections: slow_map,
            inspect_calls: AtomicU32::new(0),
            delay_ms: 400,
        });
        let slow_mgr = PlaylistManager::with_executor(slow_exec);
        let mut slow_rx = slow_mgr.subscribe_size_broadcast();

        let slow_est = slow_mgr
            .estimate_playlist_size(EstimatePlaylistSizeRequest {
                playlist: slow_playlist,
                media_mode: PlaylistMediaMode::VideoWithSound,
                quality_cap: PlaylistQualityCap::BestAvailable,
            })
            .await
            .expect("slow estimate starts");
        slow_mgr
            .cancel_size_estimation(&slow_est.estimation_id)
            .await
            .expect("cancel size estimation succeeds");

        let mut saw_canceled = false;
        let cancel_deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
        while tokio::time::Instant::now() < cancel_deadline {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(2), slow_rx.recv())
                .await
                .expect("slow rx")
                .expect("open");
            if ev.estimation_id == slow_est.estimation_id
                && ev.status == PlaylistSizeStatus::Canceled
            {
                saw_canceled = true;
                break;
            }
        }
        assert!(
            saw_canceled,
            "Cancellation must emit PlaylistSizeStatus::Canceled"
        );
    }

    #[tokio::test]
    async fn live_estimates_authorized_3_item_blender_hq_playlist_sizes() {
        let url = "https://www.youtube.com/playlist?list=PLa1F2ddGya_8Geu0rJ4y4dVCc9jZxS2IB";
        let result = inspect_url_async(url)
            .await
            .expect("Blender HQ playlist inspection must succeed");
        let playlist = result.playlist.expect("playlist payload");
        assert_eq!(playlist.entries.len(), 3);

        let manager = PlaylistManager::with_executor(Arc::new(YtDlpPlaylistExecutor));
        let mut rx = manager.subscribe_size_broadcast();
        let initial = manager
            .estimate_playlist_size(EstimatePlaylistSizeRequest {
                playlist: playlist.clone(),
                media_mode: PlaylistMediaMode::VideoWithSound,
                quality_cap: PlaylistQualityCap::UpTo480p,
            })
            .await
            .expect("live size estimation starts");

        let final_est = if initial.status == PlaylistSizeStatus::Calculating {
            let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(90);
            loop {
                assert!(
                    tokio::time::Instant::now() < deadline,
                    "timed out waiting for live Blender HQ size estimate"
                );
                let ev = tokio::time::timeout(std::time::Duration::from_secs(45), rx.recv())
                    .await
                    .expect("rx timeout")
                    .expect("open");
                if ev.estimation_id == initial.estimation_id
                    && ev.status != PlaylistSizeStatus::Calculating
                {
                    break ev;
                }
            }
        } else {
            initial
        };

        assert_eq!(final_est.eligible_count, 3);
        assert_eq!(final_est.failed_count, 0);
        assert_eq!(final_est.item_sizes.len(), 3);
        assert!(
            final_est.known_total_bytes > 0,
            "Blender HQ items must yield non-zero real size metadata: {final_est:?}"
        );
        assert_ne!(
            final_est.status,
            PlaylistSizeStatus::Exact,
            "Merged/approximate streams must not falsely claim exact final size"
        );

        // Verify cached AudioOnly recalculation finishes immediately and returns smaller valid audio total.
        let audio_est = manager
            .estimate_playlist_size(EstimatePlaylistSizeRequest {
                playlist,
                media_mode: PlaylistMediaMode::AudioOnly,
                quality_cap: PlaylistQualityCap::BestAvailable,
            })
            .await
            .expect("cached audio estimate");
        assert_ne!(audio_est.status, PlaylistSizeStatus::Calculating);
        assert_eq!(audio_est.item_sizes.len(), 3);
        assert!(audio_est.known_total_bytes > 0);
        assert!(audio_est.known_total_bytes < final_est.known_total_bytes);
    }
}
