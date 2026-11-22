//! `yt-dlp` subprocess wrapper, structured JSON/progress parsing, and single-job
//! lifecycle management for Phase 2B.

use crate::frb_generated::StreamSink;
use crate::models::{
    DiscoveredFormat, DownloadPhase, DownloadProgressEvent, DownloadSelectionKind,
    FileSizeAccuracy, MediaInspection, StartDownloadRequest, StreamKind,
};
use crate::platform::{
    classify_and_normalize_url, is_instagram_host, is_youtube_host, MediaPlatform,
};
use crate::selection::{
    build_quality_options_for_platform, extract_xtags_acont, RawFormatCandidate,
};
use crate::win_job::ProcessTreeJob;
use serde_json::Value;
use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::{broadcast, Mutex, Notify};
use url::Url;
use uuid::Uuid;

const DOWNLOAD_PROGRESS_TEMPLATE: &str =
    "download:HYPERDL|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s";
const POSTPROCESS_PROGRESS_TEMPLATE: &str =
    "postprocess:HYPERDL_PP|%(progress.status)s|%(progress.postprocessor)s";
const CANCEL_WAIT_TIMEOUT_SECS: u64 = 5;
const INSTAGRAM_SOCKET_TIMEOUT_SECS: &str = "40";
const INSTAGRAM_INFO_CACHE_TTL_SECS: u64 = 900;
const INSTAGRAM_INFO_CACHE_MAX_ENTRIES: usize = 16;
const INSTAGRAM_INSPECT_TIMEOUT_SECS: u64 = 120;
const INSTAGRAM_CACHED_FIRST_BYTE_TIMEOUT_SECS: u64 = 45;
const INSTAGRAM_LIVE_FIRST_BYTE_TIMEOUT_SECS: u64 = 110;
const INSTAGRAM_CONNECTION_SETUP_TIMEOUT_MARKER: &str =
    "Timed out while connecting to Instagram before media transfer started.";

#[derive(Debug, Clone)]
struct CachedInstagramInfoJson {
    cleaned_json: String,
    cached_at: std::time::Instant,
}

fn instagram_info_cache() -> &'static std::sync::Mutex<HashMap<String, CachedInstagramInfoJson>> {
    static CACHE: OnceLock<std::sync::Mutex<HashMap<String, CachedInstagramInfoJson>>> =
        OnceLock::new();
    CACHE.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

pub(crate) fn sanitize_info_json_for_reuse(raw_json: &str) -> Option<String> {
    let mut parsed: Value = serde_json::from_str(raw_json).ok()?;
    let obj = parsed.as_object_mut()?;
    for key in [
        "requested_formats",
        "requested_downloads",
        "format_id",
        "format",
        "ext",
        "_filename",
        "filename",
    ] {
        obj.remove(key);
    }
    serde_json::to_string(&parsed).ok()
}

pub(crate) fn store_cached_instagram_info_json(canonical_url: &str, raw_json: &str) {
    let Some(cleaned_json) = sanitize_info_json_for_reuse(raw_json) else {
        return;
    };
    let Ok(mut guard) = instagram_info_cache().lock() else {
        return;
    };
    let ttl = std::time::Duration::from_secs(INSTAGRAM_INFO_CACHE_TTL_SECS);
    guard.retain(|_, entry| entry.cached_at.elapsed() < ttl);
    if !guard.contains_key(canonical_url) && guard.len() >= INSTAGRAM_INFO_CACHE_MAX_ENTRIES {
        if let Some(oldest_key) = guard
            .iter()
            .min_by_key(|(_, entry)| entry.cached_at)
            .map(|(k, _)| k.clone())
        {
            guard.remove(&oldest_key);
        }
    }
    guard.insert(
        canonical_url.to_string(),
        CachedInstagramInfoJson {
            cleaned_json,
            cached_at: std::time::Instant::now(),
        },
    );
}

pub(crate) fn get_cached_instagram_info_json(canonical_url: &str) -> Option<String> {
    let Ok(mut guard) = instagram_info_cache().lock() else {
        return None;
    };
    let ttl = std::time::Duration::from_secs(INSTAGRAM_INFO_CACHE_TTL_SECS);
    guard.retain(|_, entry| entry.cached_at.elapsed() < ttl);
    guard
        .get(canonical_url)
        .map(|entry| entry.cleaned_json.clone())
}

pub(crate) fn invalidate_cached_instagram_info_json(canonical_url: &str) {
    if let Ok(mut guard) = instagram_info_cache().lock() {
        guard.remove(canonical_url);
    }
}

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Errors returned by the `yt-dlp` integration layer.
#[derive(Debug, Error)]
pub enum EngineError {
    #[error("Invalid media URL: {0}")]
    InvalidUrl(String),

    #[error("Required tool '{tool}' could not be found (searched: {searched})")]
    ToolUnavailable {
        tool: &'static str,
        searched: String,
    },

    #[error("I/O error while executing media tool: {0}")]
    Io(#[from] std::io::Error),

    #[error("Failed to parse media inspection output: {0}")]
    JsonParse(String),

    #[error("Media engine command failed (exit code {exit_code:?}): {stderr}")]
    ProcessFailed {
        exit_code: Option<i32>,
        stderr: String,
    },

    #[error("{0}")]
    Busy(String),

    #[error("Download job not found: {0}")]
    JobNotFound(String),

    #[error("Invalid download request: {0}")]
    InvalidRequest(String),
}

/// Optional explicit binary and directory overrides.
#[derive(Debug, Default, Clone)]
pub struct ToolEnvOverrides {
    pub yt_dlp_path: Option<PathBuf>,
    pub ffmpeg_path: Option<PathBuf>,
    pub node_path: Option<PathBuf>,
    pub output_dir: Option<PathBuf>,
}

impl ToolEnvOverrides {
    fn from_env() -> Self {
        Self {
            yt_dlp_path: std::env::var_os("HYPERDL_YTDLP_PATH").map(PathBuf::from),
            ffmpeg_path: std::env::var_os("HYPERDL_FFMPEG_PATH").map(PathBuf::from),
            node_path: std::env::var_os("HYPERDL_NODE_PATH").map(PathBuf::from),
            output_dir: std::env::var_os("HYPERDL_OUTPUT_DIR").map(PathBuf::from),
        }
    }
}

/// Resolved external tool executable paths reused from `tools/windows_media_prototype`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolPaths {
    pub yt_dlp_exe: PathBuf,
    pub ffmpeg_exe: PathBuf,
    pub node_exe: PathBuf,
    pub default_output_dir: PathBuf,
}

impl ToolPaths {
    /// Resolves local `yt-dlp`, `ffmpeg`, and `node` executables plus a default output directory.
    pub fn resolve() -> Result<Self, EngineError> {
        let mut roots = Vec::new();
        if let Ok(cwd) = std::env::current_dir() {
            roots.push(cwd);
        }
        if let Ok(exe) = std::env::current_exe() {
            if let Some(parent) = exe.parent() {
                roots.push(parent.to_path_buf());
            }
        }
        Self::resolve_from(
            &roots,
            &ToolEnvOverrides::from_env(),
            std::env::var_os("PATH").as_deref(),
        )
    }

    /// Resolves tool binaries using explicit search roots, overrides, and `PATH` for testability.
    pub fn resolve_from(
        search_roots: &[PathBuf],
        overrides: &ToolEnvOverrides,
        path_var: Option<&OsStr>,
    ) -> Result<Self, EngineError> {
        let proto_roots = collect_prototype_roots(search_roots);

        let yt_dlp_name = if cfg!(windows) {
            "yt-dlp.exe"
        } else {
            "yt-dlp"
        };
        let ffmpeg_name = if cfg!(windows) {
            "ffmpeg.exe"
        } else {
            "ffmpeg"
        };
        let node_name = if cfg!(windows) { "node.exe" } else { "node" };

        let yt_dlp_exe = resolve_binary(
            "yt-dlp",
            overrides.yt_dlp_path.as_deref(),
            &proto_roots
                .iter()
                .map(|r| r.join("bin").join(yt_dlp_name))
                .collect::<Vec<_>>(),
            path_var,
            yt_dlp_name,
        )?;

        let ffmpeg_exe = resolve_binary(
            "ffmpeg",
            overrides.ffmpeg_path.as_deref(),
            &proto_roots
                .iter()
                .map(|r| r.join("bin").join(ffmpeg_name))
                .collect::<Vec<_>>(),
            path_var,
            ffmpeg_name,
        )?;

        let mut node_candidates: Vec<PathBuf> = proto_roots
            .iter()
            .map(|r| r.join("bin").join(node_name))
            .collect();
        if cfg!(windows) {
            node_candidates.push(PathBuf::from(r"C:\Program Files\nodejs\node.exe"));
            node_candidates.push(PathBuf::from(r"C:\Program Files (x86)\nodejs\node.exe"));
        }

        let node_exe = resolve_binary(
            "node",
            overrides.node_path.as_deref(),
            &node_candidates,
            path_var,
            node_name,
        )?;

        let default_output_dir = overrides
            .output_dir
            .clone()
            .or_else(|| {
                proto_roots
                    .first()
                    .map(|r| r.join("output").join("app_downloads"))
            })
            .or_else(|| search_roots.first().map(|r| r.join("downloads")))
            .unwrap_or_else(|| PathBuf::from("downloads"));

        Ok(Self {
            yt_dlp_exe,
            ffmpeg_exe,
            node_exe,
            default_output_dir,
        })
    }

    pub fn ffmpeg_dir(&self) -> PathBuf {
        self.ffmpeg_exe
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| self.ffmpeg_exe.clone())
    }
}

fn collect_prototype_roots(search_roots: &[PathBuf]) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for root in search_roots {
        for ancestor in root.ancestors().take(12) {
            let candidate = ancestor.join("tools").join("windows_media_prototype");
            if candidate.is_dir() && !found.contains(&candidate) {
                found.push(candidate);
            }
        }
    }
    found
}

fn resolve_binary(
    tool: &'static str,
    explicit_override: Option<&Path>,
    candidates: &[PathBuf],
    path_var: Option<&OsStr>,
    exe_name: &str,
) -> Result<PathBuf, EngineError> {
    if let Some(override_path) = explicit_override {
        if override_path.is_file() {
            return Ok(override_path.to_path_buf());
        }
        return Err(EngineError::ToolUnavailable {
            tool,
            searched: override_path.display().to_string(),
        });
    }

    let mut searched = Vec::new();
    for candidate in candidates {
        searched.push(candidate.display().to_string());
        if candidate.is_file() {
            return Ok(candidate.clone());
        }
    }

    if let Some(raw_path) = path_var {
        for entry in std::env::split_paths(raw_path) {
            let candidate = entry.join(exe_name);
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
        searched.push(format!("PATH ({exe_name})"));
    }

    Err(EngineError::ToolUnavailable {
        tool,
        searched: searched.join("; "),
    })
}

/// Validates that `raw_url` is a syntactically valid `http://` or `https://` URL
/// and enforces platform normalization / rejection rules.
pub fn validate_media_url(raw_url: &str) -> Result<String, EngineError> {
    Ok(crate::platform::classify_and_normalize_url(raw_url)?.normalized_url)
}

/// Parses structured JSON from `yt-dlp --dump-single-json` (or compatible fixture format)
/// into typed `MediaInspection` models while filtering storyboards and DRM formats.
pub fn parse_yt_dlp_inspection_json(raw_json: &str) -> Result<MediaInspection, EngineError> {
    let cleaned = raw_json.trim_start_matches('\u{feff}').trim();
    let root: Value =
        serde_json::from_str(cleaned).map_err(|err| EngineError::JsonParse(err.to_string()))?;
    let obj = root
        .as_object()
        .ok_or_else(|| EngineError::JsonParse("Expected top-level JSON object.".into()))?;

    let is_instagram_payload = json_non_empty_str(obj.get("extractor_key"))
        .or_else(|| json_non_empty_str(obj.get("extractor")))
        .is_some_and(|e| e.to_ascii_lowercase().starts_with("instagram"))
        || json_non_empty_str(obj.get("webpage_url"))
            .or_else(|| json_non_empty_str(obj.get("original_url")))
            .is_some_and(|u| infer_provider_from_url(&u) == "Instagram");

    let formats_val = obj.get("formats").and_then(Value::as_array);
    if formats_val.is_none() && obj.get("_type").and_then(Value::as_str) == Some("playlist") {
        let msg = if is_instagram_payload {
            "Instagram carousels and multi-item posts are not supported. Only individual public Reels are supported."
        } else {
            "Playlist URLs are not supported in single-video inspection yet. Please enter a single video URL."
        };
        return Err(EngineError::InvalidRequest(msg.into()));
    }
    let raw_formats = formats_val.ok_or_else(|| {
        EngineError::JsonParse("Missing 'formats' array in yt-dlp output.".into())
    })?;

    let id = json_non_empty_str(obj.get("id"))
        .ok_or_else(|| EngineError::JsonParse("Missing media 'id' in yt-dlp output.".into()))?;
    let webpage_url = json_non_empty_str(obj.get("webpage_url"))
        .or_else(|| json_non_empty_str(obj.get("original_url")))
        .unwrap_or_default();
    let raw_provider = json_non_empty_str(obj.get("extractor_key"))
        .or_else(|| json_non_empty_str(obj.get("extractor")))
        .unwrap_or_else(|| infer_provider_from_url(&webpage_url));
    let provider_name = normalize_provider_name(&raw_provider, &webpage_url);
    let is_instagram = provider_name.eq_ignore_ascii_case("Instagram");

    let uploader = json_non_empty_str(obj.get("uploader"))
        .or_else(|| json_non_empty_str(obj.get("channel")))
        .or_else(|| json_non_empty_str(obj.get("creator")))
        .or_else(|| {
            if is_instagram {
                json_non_empty_str(obj.get("uploader_id"))
            } else {
                None
            }
        });
    let title = json_non_empty_str(obj.get("title")).unwrap_or_else(|| {
        if is_instagram {
            uploader
                .as_deref()
                .map(|u| format!("Instagram Reel by {u}"))
                .unwrap_or_else(|| format!("Instagram Reel ({id})"))
        } else {
            id.clone()
        }
    });
    let duration_seconds =
        json_f64(obj.get("duration")).or_else(|| json_f64(obj.get("duration_seconds")));
    let thumbnail_url = extract_thumbnail_url(obj);
    let video_language = json_non_empty_str(obj.get("language"));

    let mut candidates = Vec::with_capacity(raw_formats.len());
    for entry in raw_formats {
        if let Some(candidate) = parse_discovered_candidate(entry) {
            candidates.push(candidate);
        }
    }

    if candidates.is_empty() {
        return Err(EngineError::JsonParse(
            "No usable non-DRM, non-storyboard formats were found for this URL.".into(),
        ));
    }

    let synthesized =
        build_quality_options_for_platform(&candidates, video_language.as_deref(), is_instagram);
    let formats: Vec<DiscoveredFormat> = candidates.into_iter().map(|c| c.format).collect();

    Ok(MediaInspection {
        id,
        title,
        uploader,
        duration_seconds,
        thumbnail_url,
        webpage_url,
        provider_name,
        original_audio: synthesized.original_audio,
        video_options: synthesized.video_options,
        audio_options: synthesized.audio_options,
        formats,
    })
}

fn normalize_provider_name(raw_provider: &str, webpage_url: &str) -> String {
    if raw_provider.eq_ignore_ascii_case("Instagram")
        || raw_provider.eq_ignore_ascii_case("InstagramIOS")
        || infer_provider_from_url(webpage_url) == "Instagram"
    {
        return "Instagram".to_string();
    }
    raw_provider.to_string()
}

pub(crate) fn extract_thumbnail_url(obj: &serde_json::Map<String, Value>) -> Option<String> {
    if let Some(thumb) = json_non_empty_str(obj.get("thumbnail")) {
        return Some(thumb);
    }
    obj.get("thumbnails")
        .and_then(Value::as_array)
        .and_then(|arr| {
            arr.iter()
                .rev()
                .find_map(|item| json_non_empty_str(item.get("url")))
        })
}

pub(crate) fn infer_provider_from_url(url: &str) -> String {
    Url::parse(url)
        .ok()
        .and_then(|parsed| parsed.host_str().map(str::to_string))
        .map(|host| {
            if is_youtube_host(&host) {
                "YouTube".to_string()
            } else if is_instagram_host(&host) {
                "Instagram".to_string()
            } else {
                host
            }
        })
        .unwrap_or_else(|| "Unknown".to_string())
}

fn parse_discovered_candidate(entry: &Value) -> Option<RawFormatCandidate> {
    let obj = entry.as_object()?;

    if is_drm_protected(obj.get("has_drm")) {
        return None;
    }

    let format_id = json_non_empty_str(obj.get("format_id"))?;
    let container = json_non_empty_str(obj.get("ext"))
        .or_else(|| json_non_empty_str(obj.get("container")))
        .unwrap_or_else(|| "unknown".to_string());
    let format_note = json_non_empty_str(obj.get("format_note"));

    let is_storyboard = container.eq_ignore_ascii_case("mhtml")
        || format_note
            .as_deref()
            .is_some_and(|n| n.to_ascii_lowercase().contains("storyboard"));
    if is_storyboard {
        return None;
    }

    let vcodec = normalize_codec(obj.get("vcodec"));
    let acodec = normalize_codec(obj.get("acodec"));
    let vcodec_explicit_none = is_codec_explicitly_none(obj.get("vcodec"));
    let acodec_explicit_none = is_codec_explicitly_none(obj.get("acodec"));
    let audio_ext = normalize_codec(obj.get("audio_ext"));
    let video_ext = normalize_codec(obj.get("video_ext"));
    let resolution_raw = json_non_empty_str(obj.get("resolution"));

    let has_video = vcodec.is_some();
    let has_audio = acodec.is_some()
        || (audio_ext.is_some() && resolution_raw.as_deref() == Some("audio only"));
    let is_unknown_codec_muxed = !vcodec_explicit_none
        && !acodec_explicit_none
        && vcodec.is_none()
        && acodec.is_none()
        && video_ext.is_some()
        && resolution_raw.as_deref() != Some("audio only");

    if !has_video && !has_audio && !is_unknown_codec_muxed {
        return None;
    }

    let stream_kind = match json_non_empty_str(obj.get("stream_kind")).as_deref() {
        Some("muxed_av") => StreamKind::MuxedAudioVideo,
        Some("video_only") => StreamKind::VideoOnly,
        Some("audio_only") => StreamKind::AudioOnly,
        _ if is_unknown_codec_muxed => StreamKind::MuxedAudioVideo,
        _ => match (has_video, has_audio) {
            (true, true) => StreamKind::MuxedAudioVideo,
            (true, false) => StreamKind::VideoOnly,
            (false, true) => StreamKind::AudioOnly,
            (false, false) => return None,
        },
    };

    let width = json_u32(obj.get("width"));
    let height = json_u32(obj.get("height"));
    let resolution = resolution_raw.unwrap_or_else(|| match (width, height) {
        (Some(w), Some(h)) => format!("{w}x{h}"),
        _ if stream_kind == StreamKind::AudioOnly => "audio only".to_string(),
        _ => "unknown".to_string(),
    });

    let fps = json_f64(obj.get("fps"));
    let bitrate_kbps = json_f64(obj.get("tbr"))
        .or_else(|| json_f64(obj.get("tbr_kbps")))
        .or_else(|| json_f64(obj.get("abr")));

    let (file_size_bytes, size_accuracy) = resolve_size_and_accuracy(obj);
    let protocol = json_non_empty_str(obj.get("protocol"));
    let language = json_non_empty_str(obj.get("language"));
    let language_preference = json_i32(obj.get("language_preference"));
    let source_preference = json_i32(obj.get("source_preference"));
    let xtags_acont = extract_xtags_acont(json_non_empty_str(obj.get("url")).as_deref());

    Some(RawFormatCandidate {
        format: DiscoveredFormat {
            format_id,
            container,
            stream_kind,
            resolution,
            width,
            height,
            fps,
            vcodec,
            acodec,
            bitrate_kbps,
            file_size_bytes,
            size_accuracy,
            format_note,
        },
        protocol,
        language,
        language_preference,
        source_preference,
        xtags_acont,
    })
}

fn resolve_size_and_accuracy(
    obj: &serde_json::Map<String, Value>,
) -> (Option<u64>, FileSizeAccuracy) {
    if let Some(exact) = json_u64(obj.get("filesize")) {
        return (Some(exact), FileSizeAccuracy::Exact);
    }
    if let Some(estimated) = json_u64(obj.get("filesize_approx")) {
        return (Some(estimated), FileSizeAccuracy::Estimated);
    }
    // Normalized Phase 2A fixture fallback for unit-test reuse.
    if let Some(fixture_bytes) = json_u64(obj.get("file_size_bytes")) {
        let accuracy = match json_non_empty_str(obj.get("size_accuracy")).as_deref() {
            Some("exact") => FileSizeAccuracy::Exact,
            Some("estimated") => FileSizeAccuracy::Estimated,
            _ => FileSizeAccuracy::Unknown,
        };
        return (Some(fixture_bytes), accuracy);
    }
    (None, FileSizeAccuracy::Unknown)
}

fn is_drm_protected(val: Option<&Value>) -> bool {
    match val {
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => {
            let trimmed = s.trim();
            !trimmed.is_empty() && !trimmed.eq_ignore_ascii_case("false")
        }
        _ => false,
    }
}

fn normalize_codec(val: Option<&Value>) -> Option<String> {
    let raw = json_non_empty_str(val)?;
    if raw.eq_ignore_ascii_case("none") {
        None
    } else {
        Some(raw)
    }
}

fn is_codec_explicitly_none(val: Option<&Value>) -> bool {
    json_non_empty_str(val).is_some_and(|s| s.eq_ignore_ascii_case("none"))
}

pub(crate) fn json_non_empty_str(val: Option<&Value>) -> Option<String> {
    let s = val?.as_str()?.trim();
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

pub(crate) fn json_u64(val: Option<&Value>) -> Option<u64> {
    match val? {
        Value::Number(n) => n.as_u64().or_else(|| {
            n.as_f64()
                .filter(|f| f.is_finite() && *f >= 0.0)
                .map(|f| f.round() as u64)
        }),
        _ => None,
    }
}

fn json_u32(val: Option<&Value>) -> Option<u32> {
    json_u64(val).and_then(|v| u32::try_from(v).ok())
}

fn json_i32(val: Option<&Value>) -> Option<i32> {
    val?.as_i64().and_then(|v| i32::try_from(v).ok())
}

pub(crate) fn json_f64(val: Option<&Value>) -> Option<f64> {
    val?.as_f64().filter(|f| f.is_finite())
}

/// Parsed representation of one `yt-dlp` stdout status line.
#[derive(Debug, Clone, PartialEq)]
pub enum ParsedYtDlpLine {
    DownloadProgress {
        status: String,
        downloaded_bytes: u64,
        total_bytes: Option<u64>,
        is_total_estimated: bool,
        speed_bytes_per_sec: Option<f64>,
        eta_seconds: Option<u64>,
    },
    PostprocessProgress {
        status: String,
        postprocessor: String,
    },
    StageStatus(String),
    OutputPathDetected(String),
    Other,
}

/// Parses structured progress and output path lines emitted by `yt-dlp.exe`.
pub fn parse_progress_line(raw_line: &str) -> ParsedYtDlpLine {
    let line = raw_line.trim();
    if let Some(rest) = line.strip_prefix("HYPERDL|") {
        let parts: Vec<&str> = rest.split('|').collect();
        if parts.len() >= 6 {
            let status = parts[0].trim().to_string();
            let downloaded_bytes = parse_optional_u64(parts[1]).unwrap_or(0);
            let exact_total = parse_optional_u64(parts[2]);
            let estimated_total = parse_optional_u64(parts[3]);
            let (total_bytes, is_total_estimated) = match (exact_total, estimated_total) {
                (Some(t), _) => (Some(t), false),
                (None, Some(est)) => (Some(est), true),
                (None, None) => (None, false),
            };
            let speed_bytes_per_sec = parse_optional_f64(parts[4]);
            let eta_seconds = parse_optional_u64(parts[5]);
            return ParsedYtDlpLine::DownloadProgress {
                status,
                downloaded_bytes,
                total_bytes,
                is_total_estimated,
                speed_bytes_per_sec,
                eta_seconds,
            };
        }
    }

    if let Some(rest) = line.strip_prefix("HYPERDL_PP|") {
        let parts: Vec<&str> = rest.split('|').collect();
        if parts.len() >= 2 {
            return ParsedYtDlpLine::PostprocessProgress {
                status: parts[0].trim().to_string(),
                postprocessor: parts[1].trim().to_string(),
            };
        }
    }

    if let Some(rest) = line.strip_prefix("[Merger] Merging formats into ") {
        let path = rest.trim().trim_matches('"').to_string();
        if !path.is_empty() {
            return ParsedYtDlpLine::OutputPathDetected(path);
        }
    }
    if let Some(rest) = line.strip_prefix("[download] Destination: ") {
        let path = rest.trim().to_string();
        if !path.is_empty() {
            return ParsedYtDlpLine::OutputPathDetected(path);
        }
    }
    if let Some(rest) = line.strip_prefix("[download] ") {
        if let Some(path) = rest.strip_suffix(" has already been downloaded") {
            let cleaned = path.trim().to_string();
            if !cleaned.is_empty() {
                return ParsedYtDlpLine::OutputPathDetected(cleaned);
            }
        }
    }

    if line.starts_with("[Instagram] Setting up session") {
        return ParsedYtDlpLine::StageStatus("Connecting to Instagram...".into());
    }
    if line.starts_with("[Instagram] ") {
        return ParsedYtDlpLine::StageStatus("Resolving media...".into());
    }
    if line.starts_with("[info] ") && line.contains("Downloading") && line.contains("format(s)") {
        return ParsedYtDlpLine::StageStatus("Resolving media...".into());
    }

    ParsedYtDlpLine::Other
}

fn parse_optional_u64(raw: &str) -> Option<u64> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.eq_ignore_ascii_case("NA")
        || trimmed.eq_ignore_ascii_case("None")
    {
        return None;
    }
    if let Ok(val) = trimmed.parse::<u64>() {
        return Some(val);
    }
    trimmed
        .parse::<f64>()
        .ok()
        .filter(|v| v.is_finite() && *v >= 0.0)
        .map(|v| v.round() as u64)
}

fn parse_optional_f64(raw: &str) -> Option<f64> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.eq_ignore_ascii_case("NA")
        || trimmed.eq_ignore_ascii_case("None")
    {
        return None;
    }
    trimmed.parse::<f64>().ok().filter(|v| v.is_finite())
}

/// Builds typed `yt-dlp` inspection command arguments without shell interpolation.
pub fn build_inspect_args(paths: &ToolPaths, url: &str) -> Vec<OsString> {
    vec![
        OsString::from("--dump-single-json"),
        OsString::from("--no-playlist"),
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

/// Builds typed `yt-dlp` download/merge command arguments without shell interpolation.
pub fn build_download_args(
    paths: &ToolPaths,
    request: &StartDownloadRequest,
    output_template: &str,
) -> Result<Vec<OsString>, EngineError> {
    let (mut args, validated_url) = build_common_download_args(paths, request, output_template)?;
    args.push(OsString::from("--"));
    args.push(OsString::from(validated_url));
    Ok(args)
}

pub(crate) fn build_download_args_from_info_json(
    paths: &ToolPaths,
    request: &StartDownloadRequest,
    output_template: &str,
    info_json_path: &Path,
) -> Result<Vec<OsString>, EngineError> {
    let (mut args, _validated_url) = build_common_download_args(paths, request, output_template)?;
    args.push(OsString::from("--socket-timeout"));
    args.push(OsString::from(INSTAGRAM_SOCKET_TIMEOUT_SECS));
    args.push(OsString::from("--load-info-json"));
    args.push(info_json_path.as_os_str().to_os_string());
    Ok(args)
}

fn build_common_download_args(
    paths: &ToolPaths,
    request: &StartDownloadRequest,
    output_template: &str,
) -> Result<(Vec<OsString>, String), EngineError> {
    let validated_url = validate_media_url(&request.url)?;
    let (format_expr, merge_container) = match request.selection.kind {
        DownloadSelectionKind::Single => {
            let trimmed = request
                .selection
                .format_id
                .as_deref()
                .map(str::trim)
                .unwrap_or("");
            validate_format_id(trimmed, "format_id")?;
            (trimmed.to_string(), None)
        }
        DownloadSelectionKind::VideoAndAudio => {
            let video = request
                .selection
                .video_format_id
                .as_deref()
                .map(str::trim)
                .unwrap_or("");
            let audio = request
                .selection
                .audio_format_id
                .as_deref()
                .map(str::trim)
                .unwrap_or("");
            validate_format_id(video, "video_format_id")?;
            validate_format_id(audio, "audio_format_id")?;
            let container = request
                .selection
                .merge_container
                .as_deref()
                .map(str::trim)
                .filter(|c| !c.is_empty())
                .unwrap_or("mp4");
            validate_format_id(container, "merge_container")?;
            (format!("{video}+{audio}"), Some(container.to_string()))
        }
    };

    let mut args = vec![
        OsString::from("--newline"),
        OsString::from("--continue"),
        OsString::from("--no-playlist"),
        OsString::from("--no-mtime"),
        OsString::from("--ignore-config"),
        OsString::from("--js-runtimes"),
        OsString::from(format!("node:{}", paths.node_exe.display())),
        OsString::from("--ffmpeg-location"),
        paths.ffmpeg_dir().into_os_string(),
        OsString::from("--progress-template"),
        OsString::from(DOWNLOAD_PROGRESS_TEMPLATE),
        OsString::from("--progress-template"),
        OsString::from(POSTPROCESS_PROGRESS_TEMPLATE),
        OsString::from("-f"),
        OsString::from(format_expr),
    ];

    if let Some(container) = merge_container {
        args.push(OsString::from("--merge-output-format"));
        args.push(OsString::from(container));
    }

    args.push(OsString::from("-o"));
    args.push(OsString::from(output_template));

    Ok((args, validated_url))
}

fn validate_format_id(value: &str, field_name: &str) -> Result<(), EngineError> {
    if value.is_empty() {
        return Err(EngineError::InvalidRequest(format!(
            "{field_name} cannot be empty."
        )));
    }
    if value.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(EngineError::InvalidRequest(format!(
            "{field_name} contains invalid whitespace or control characters."
        )));
    }
    Ok(())
}

pub(crate) fn configure_subprocess(cmd: &mut Command) {
    // Ensure Python inside standalone `yt-dlp.exe` always emits valid UTF-8 paths
    // on Windows pipes (critical for Arabic and non-ASCII video titles).
    cmd.env("PYTHONUTF8", "1");
    cmd.env("PYTHONIOENCODING", "utf-8");
    #[cfg(windows)]
    {
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
}

pub(crate) fn shared_runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("hyperdl-engine")
            .build()
            .expect("failed to initialize Tokio runtime")
    })
}

/// Redacts sensitive cookies, headers, and signed tokens from developer diagnostic logs.
pub fn redact_sensitive_diagnostics(raw: &str) -> String {
    let line_redacted = redact_markers(raw, &["cookie:", "authorization:"], true);
    redact_markers(
        &line_redacted,
        &["sessionid=", "csrftoken=", "ds_user_id=", "oh=", "_nc_ohc="],
        false,
    )
}

fn redact_markers(input: &str, markers: &[&str], until_eol: bool) -> String {
    let mut out = String::with_capacity(input.len());
    let lower = input.to_ascii_lowercase();
    let mut idx = 0;

    while idx < input.len() {
        let mut matched: Option<&str> = None;
        for marker in markers {
            if lower[idx..].starts_with(marker) {
                matched = Some(marker);
                break;
            }
        }

        if let Some(marker) = matched {
            let prefix_end = idx + marker.len();
            out.push_str(&input[idx..prefix_end]);
            let mut val_start = prefix_end;
            while val_start < input.len() && until_eol && input.as_bytes()[val_start] == b' ' {
                out.push(' ');
                val_start += 1;
            }
            let mut val_end = val_start;
            while val_end < input.len() {
                let b = input.as_bytes()[val_end];
                let stop = if until_eol {
                    b == b'\r' || b == b'\n'
                } else {
                    b == b'&'
                        || b == b';'
                        || b == b'"'
                        || b == b'\''
                        || b == b')'
                        || b == b']'
                        || b.is_ascii_whitespace()
                };
                if stop {
                    break;
                }
                val_end += 1;
            }
            out.push_str("[REDACTED]");
            idx = val_end;
        } else {
            let ch = input[idx..].chars().next().unwrap();
            out.push(ch);
            idx += ch.len_utf8();
        }
    }

    out
}

/// Maps raw `yt-dlp` Instagram stderr failures into short user-facing messages
/// without falsely labeling rate-limit, login, or network failures as private Reels.
pub fn classify_instagram_error(stderr: &str) -> String {
    let lower = stderr.to_ascii_lowercase();

    if contains_any(
        &lower,
        &[
            "ffmpeg",
            "ffprobe",
            "postprocessing",
            "error merging",
            "[merger]",
            "muxing",
            "moov atom",
        ],
    ) {
        return "Failed to process video and audio streams with FFmpeg.".into();
    }

    if contains_any(
        &lower,
        &[
            "429",
            "rate-limit",
            "rate limit",
            "too many requests",
            "please wait a few minutes",
        ],
    ) {
        return "Instagram temporarily rate-limited requests. Please wait a few minutes and try again."
            .into();
    }

    if contains_any(
        &lower,
        &[
            "http error 404",
            "404: not found",
            "not found",
            "does not exist",
            "has been deleted",
            "been deleted",
            "removed",
            "broken",
            "no longer available",
        ],
    ) {
        return "This Instagram Reel is unavailable or has been deleted.".into();
    }

    if contains_any(
        &lower,
        &[
            "account is private",
            "private reel",
            "private video",
            "this content is private",
            "not available to you",
        ],
    ) {
        return "This Instagram Reel is private or inaccessible.".into();
    }

    if contains_any(
        &lower,
        &[
            "login required",
            "logged-in",
            "locked behind the login page",
            "need to log in",
            "sign in",
            "use --cookies",
            "cookies are needed",
            "cookies-from-browser",
            "authentication",
        ],
    ) {
        return "Instagram requires login to view this Reel. Only public Reels are supported without login."
            .into();
    }

    if contains_any(
        &lower,
        &[
            "empty media response",
            "checkpoint",
            "challenge_required",
            "http error 403",
            "403",
            "csrf",
            "unable to extract",
            "blocked",
            "automated",
        ],
    ) {
        return "Instagram temporarily restricted this request. Please try again later.".into();
    }

    if contains_any(&lower, &["before media transfer started"]) {
        return "Timed out while connecting to Instagram. Check your internet connection and try again."
            .into();
    }

    if contains_any(
        &lower,
        &[
            "timed out",
            "timeout",
            "could not resolve",
            "curl: (6)",
            "curl: (7)",
            "curl: (28)",
            "transporterror",
            "connection",
            "network",
            "ssl",
            "tls",
            "dns",
            "reset by peer",
        ],
    ) {
        return "Network error while contacting Instagram. Check your internet connection and try again."
            .into();
    }

    "Instagram extraction failed. Please verify the Reel is public and try again.".into()
}

fn contains_any(haystack_lower: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| haystack_lower.contains(n))
}

pub(crate) fn is_transient_instagram_transport_error(stderr: &str) -> bool {
    let lower = stderr.to_ascii_lowercase();
    contains_any(
        &lower,
        &[
            "curl: (6)",
            "curl: (7)",
            "curl: (28)",
            "transporterror",
            "timed out",
            "could not resolve",
            "failed to connect",
        ],
    )
}

pub(crate) fn build_instagram_network_args(base_args: &[OsString]) -> Vec<OsString> {
    let mut args = Vec::with_capacity(base_args.len() + 2);
    args.push(OsString::from("--socket-timeout"));
    args.push(OsString::from(INSTAGRAM_SOCKET_TIMEOUT_SECS));
    args.extend(base_args.iter().cloned());
    args
}

pub(crate) fn resolve_output_template_for_new_job(
    output_dir: &Path,
    request: &StartDownloadRequest,
    shortcode: Option<&str>,
) -> String {
    let format_tag = match request.selection.kind {
        DownloadSelectionKind::Single => request
            .selection
            .format_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|s| crate::playlist::sanitize_windows_filename(s, 48)),
        DownloadSelectionKind::VideoAndAudio => match (
            request.selection.video_format_id.as_deref().map(str::trim),
            request.selection.audio_format_id.as_deref().map(str::trim),
        ) {
            (Some(v), Some(a)) if !v.is_empty() && !a.is_empty() => Some(
                crate::playlist::sanitize_windows_filename(&format!("{v}+{a}"), 64),
            ),
            _ => None,
        },
    };

    if let (Some(title), Some(code), Some(fmt)) = (
        request
            .title
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty()),
        shortcode.map(str::trim).filter(|s| !s.is_empty()),
        format_tag.as_deref(),
    ) {
        let safe_title = crate::playlist::sanitize_windows_filename(title, 80);
        let safe_code = crate::playlist::sanitize_windows_filename(code, 48);
        let base_stem = format!("{safe_title} [{safe_code}] [{fmt}]");
        let unique_stem = pick_non_colliding_stem(output_dir, &base_stem);
        return output_dir
            .join(format!("{unique_stem}.%(ext)s"))
            .to_string_lossy()
            .into_owned();
    }

    output_dir
        .join("%(title).100B [%(id)s] [%(format_id)s].%(ext)s")
        .to_string_lossy()
        .into_owned()
}

fn pick_non_colliding_stem(output_dir: &Path, base_stem: &str) -> String {
    if !stem_has_completed_file(output_dir, base_stem) {
        return base_stem.to_string();
    }
    for idx in 2..=10_000 {
        let candidate = format!("{base_stem} ({idx})");
        if !stem_has_completed_file(output_dir, &candidate) {
            return candidate;
        }
    }
    format!("{base_stem} ({})", Uuid::new_v4())
}

fn stem_has_completed_file(output_dir: &Path, stem: &str) -> bool {
    let Ok(entries) = std::fs::read_dir(output_dir) else {
        return false;
    };
    let prefix = format!("{stem}.").to_ascii_lowercase();
    for entry in entries.flatten() {
        let Ok(ft) = entry.file_type() else {
            continue;
        };
        if !ft.is_file() {
            continue;
        }
        let name_lower = entry.file_name().to_string_lossy().to_ascii_lowercase();
        if name_lower.starts_with(&prefix)
            && !name_lower.ends_with(".part")
            && !name_lower.ends_with(".ytdl")
            && !name_lower.contains(".temp.")
        {
            return true;
        }
    }
    false
}

/// Inspects `url` with the local `yt-dlp` binary and returns typed metadata + formats.
pub async fn inspect_media_async(url: &str) -> Result<MediaInspection, EngineError> {
    let classified = classify_and_normalize_url(url)?;
    let paths = ToolPaths::resolve()?;
    inspect_media_with_paths(&paths, &classified.normalized_url, classified.platform).await
}

struct InspectCommandOutput {
    status: std::process::ExitStatus,
    stdout: String,
    stderr: String,
    timed_out: bool,
}

async fn run_yt_dlp_inspect_command_with_timeout(
    paths: &ToolPaths,
    args: &[OsString],
    timeout: Option<std::time::Duration>,
) -> Result<InspectCommandOutput, EngineError> {
    let mut cmd = Command::new(&paths.yt_dlp_exe);
    cmd.args(args);
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());
    configure_subprocess(&mut cmd);

    let Some(limit) = timeout else {
        let output = cmd.output().await?;
        return Ok(InspectCommandOutput {
            status: output.status,
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
            timed_out: false,
        });
    };

    let mut child = cmd.spawn()?;
    let proc_job = ProcessTreeJob::attach(&child).ok();
    let mut stdout_pipe = child.stdout.take();
    let mut stderr_pipe = child.stderr.take();

    let stdout_task = tokio::spawn(async move {
        let mut buf = Vec::new();
        if let Some(ref mut pipe) = stdout_pipe {
            let _ = pipe.read_to_end(&mut buf).await;
        }
        String::from_utf8_lossy(&buf).into_owned()
    });
    let stderr_task = tokio::spawn(async move {
        let mut buf = Vec::new();
        if let Some(ref mut pipe) = stderr_pipe {
            let _ = pipe.read_to_end(&mut buf).await;
        }
        String::from_utf8_lossy(&buf).trim().to_string()
    });

    match tokio::time::timeout(limit, child.wait()).await {
        Ok(wait_res) => {
            let status = wait_res?;
            let stdout = stdout_task.await.unwrap_or_default();
            let stderr = stderr_task.await.unwrap_or_default();
            Ok(InspectCommandOutput {
                status,
                stdout,
                stderr,
                timed_out: false,
            })
        }
        Err(_) => {
            if let Some(job) = proc_job {
                let _ = job.terminate();
            } else {
                let _ = child.start_kill();
            }
            let status = tokio::time::timeout(std::time::Duration::from_secs(3), child.wait())
                .await
                .map_err(|_| {
                    std::io::Error::new(std::io::ErrorKind::TimedOut, "yt-dlp inspection timed out")
                })??;
            let stdout = tokio::time::timeout(std::time::Duration::from_secs(2), stdout_task)
                .await
                .ok()
                .and_then(|r| r.ok())
                .unwrap_or_default();
            let mut stderr = tokio::time::timeout(std::time::Duration::from_secs(2), stderr_task)
                .await
                .ok()
                .and_then(|r| r.ok())
                .unwrap_or_default();
            if !stderr.is_empty() {
                stderr.push('\n');
            }
            stderr.push_str("Timed out while contacting Instagram during analysis.");
            Ok(InspectCommandOutput {
                status,
                stdout,
                stderr,
                timed_out: true,
            })
        }
    }
}

async fn inspect_media_with_paths(
    paths: &ToolPaths,
    validated_url: &str,
    platform: MediaPlatform,
) -> Result<MediaInspection, EngineError> {
    let overall_start = std::time::Instant::now();
    let base_args = build_inspect_args(paths, validated_url);
    let (inspect_args, inspect_timeout) = if platform == MediaPlatform::InstagramReel {
        (
            build_instagram_network_args(&base_args),
            Some(std::time::Duration::from_secs(
                INSTAGRAM_INSPECT_TIMEOUT_SECS,
            )),
        )
    } else {
        (base_args, None)
    };

    let attempt1_start = std::time::Instant::now();
    let mut output =
        run_yt_dlp_inspect_command_with_timeout(paths, &inspect_args, inspect_timeout).await?;
    if platform == MediaPlatform::InstagramReel {
        eprintln!(
            "[hyperdl][timing] instagram inspect attempt=1 exit={:?} timed_out={} elapsed={:.2}s json_bytes={}",
            output.status.code(),
            output.timed_out,
            attempt1_start.elapsed().as_secs_f64(),
            output.stdout.len()
        );
    }

    if !output.status.success()
        && platform == MediaPlatform::InstagramReel
        && !output.timed_out
        && is_transient_instagram_transport_error(&output.stderr)
    {
        tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
        let attempt2_start = std::time::Instant::now();
        output =
            run_yt_dlp_inspect_command_with_timeout(paths, &inspect_args, inspect_timeout).await?;
        eprintln!(
            "[hyperdl][timing] instagram inspect attempt=2 exit={:?} timed_out={} elapsed={:.2}s json_bytes={}",
            output.status.code(),
            output.timed_out,
            attempt2_start.elapsed().as_secs_f64(),
            output.stdout.len()
        );
    }

    if !output.status.success() || output.timed_out {
        let stderr = output.stderr.trim().to_string();
        if platform == MediaPlatform::InstagramReel {
            eprintln!(
                "[hyperdl][diag] Instagram inspection failed (elapsed={:.2}s): {}",
                overall_start.elapsed().as_secs_f64(),
                redact_sensitive_diagnostics(&stderr)
            );
            return Err(EngineError::ProcessFailed {
                exit_code: output.status.code(),
                stderr: classify_instagram_error(&stderr),
            });
        }
        return Err(EngineError::ProcessFailed {
            exit_code: output.status.code(),
            stderr: if stderr.is_empty() {
                "yt-dlp inspection exited with non-zero status".into()
            } else {
                stderr
            },
        });
    }

    let parse_start = std::time::Instant::now();
    match parse_yt_dlp_inspection_json(&output.stdout) {
        Ok(inspected) => {
            if platform == MediaPlatform::InstagramReel {
                store_cached_instagram_info_json(validated_url, &output.stdout);
                eprintln!(
                    "[hyperdl][timing] instagram inspect complete: total={:.2}s parse={:.3}s video_options={} audio_options={}",
                    overall_start.elapsed().as_secs_f64(),
                    parse_start.elapsed().as_secs_f64(),
                    inspected.video_options.len(),
                    inspected.audio_options.len()
                );
            }
            Ok(inspected)
        }
        Err(EngineError::JsonParse(detail)) if platform == MediaPlatform::InstagramReel => {
            eprintln!(
                "[hyperdl][diag] Instagram metadata parse failed: {}",
                redact_sensitive_diagnostics(&detail)
            );
            Err(EngineError::JsonParse(
                "Instagram returned an unsupported media format or incomplete response.".into(),
            ))
        }
        Err(other) => Err(other),
    }
}

#[derive(Debug)]
struct ActiveJobState {
    job_id: String,
    request: StartDownloadRequest,
    output_template: String,
    is_running: bool,
    cancel_requested: Arc<AtomicBool>,
    cancel_notify: Arc<Notify>,
    process_job: Option<Arc<ProcessTreeJob>>,
    done_notify: Arc<Notify>,
}

/// Manages the single active Phase 2B download job and broadcasts progress events.
pub struct DownloadManager {
    tx: broadcast::Sender<DownloadProgressEvent>,
    job: Mutex<Option<ActiveJobState>>,
}

impl DownloadManager {
    pub fn global() -> &'static Arc<Self> {
        static INSTANCE: OnceLock<Arc<DownloadManager>> = OnceLock::new();
        INSTANCE.get_or_init(Self::new_isolated)
    }

    /// Creates an independent `DownloadManager` instance (isolated for parallel integration tests).
    pub(crate) fn new_isolated() -> Arc<Self> {
        let (tx, _) = broadcast::channel(256);
        Arc::new(Self {
            tx,
            job: Mutex::new(None),
        })
    }

    /// Subscribes a Rust broadcast receiver (useful in integration tests).
    pub fn subscribe_broadcast(&self) -> broadcast::Receiver<DownloadProgressEvent> {
        self.tx.subscribe()
    }

    /// Subscribes an FRB `StreamSink` to all download progress events.
    pub fn subscribe(&self, sink: StreamSink<DownloadProgressEvent>) {
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

    /// Validates `request`, allocates a new `job_id`, and starts `yt-dlp.exe` in the background.
    pub async fn start_download(
        self: &Arc<Self>,
        mut request: StartDownloadRequest,
    ) -> Result<String, EngineError> {
        let classified = classify_and_normalize_url(&request.url)?;
        request.url = classified.normalized_url.clone();

        let paths = ToolPaths::resolve()?;
        let output_dir = match request
            .output_directory
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            Some(custom) => PathBuf::from(custom),
            None => paths.default_output_dir.clone(),
        };
        tokio::fs::create_dir_all(&output_dir).await?;

        let output_template = resolve_output_template_for_new_job(
            &output_dir,
            &request,
            classified.shortcode.as_deref(),
        );

        // Validate arguments before recording active job state.
        let args = build_download_args(&paths, &request, &output_template)?;
        let job_id = Uuid::new_v4().to_string();

        self.launch_job(
            job_id.clone(),
            request,
            output_template,
            paths,
            args,
            classified.platform,
        )
        .await?;
        Ok(job_id)
    }

    /// Cancels an active download job by killing its process tree and releasing `.part` locks.
    pub async fn cancel_download(&self, job_id: &str) -> Result<(), EngineError> {
        let (cancel_flag, cancel_notify, process_job, done_notify) = {
            let guard = self.job.lock().await;
            let state = guard
                .as_ref()
                .ok_or_else(|| EngineError::JobNotFound(job_id.to_string()))?;
            if state.job_id != job_id {
                return Err(EngineError::JobNotFound(job_id.to_string()));
            }
            if !state.is_running {
                return Err(EngineError::InvalidRequest(format!(
                    "Download job '{job_id}' is not currently running."
                )));
            }
            state.cancel_requested.store(true, Ordering::SeqCst);
            (
                state.cancel_requested.clone(),
                state.cancel_notify.clone(),
                state.process_job.clone(),
                state.done_notify.clone(),
            )
        };

        let _ = cancel_flag;
        cancel_notify.notify_waiters();
        if let Some(handle) = process_job {
            let _ = handle.terminate();
        }

        // Wait until the worker exits `child.wait()` so OS `.part` handles are released before Resume.
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(CANCEL_WAIT_TIMEOUT_SECS),
            done_notify.notified(),
        )
        .await;

        Ok(())
    }

    /// Resumes a previously canceled or failed job using `yt-dlp --continue`.
    pub async fn resume_download(self: &Arc<Self>, job_id: &str) -> Result<String, EngineError> {
        let (request, output_template) = {
            let guard = self.job.lock().await;
            let state = guard
                .as_ref()
                .ok_or_else(|| EngineError::JobNotFound(job_id.to_string()))?;
            if state.job_id != job_id {
                return Err(EngineError::JobNotFound(job_id.to_string()));
            }
            if state.is_running {
                return Err(EngineError::Busy(format!(
                    "Download job '{job_id}' is already running."
                )));
            }
            (state.request.clone(), state.output_template.clone())
        };

        let classified = classify_and_normalize_url(&request.url)?;
        let paths = ToolPaths::resolve()?;
        let args = build_download_args(&paths, &request, &output_template)?;
        self.launch_job(
            job_id.to_string(),
            request,
            output_template,
            paths,
            args,
            classified.platform,
        )
        .await?;
        Ok(job_id.to_string())
    }

    async fn launch_job(
        self: &Arc<Self>,
        job_id: String,
        request: StartDownloadRequest,
        output_template: String,
        paths: ToolPaths,
        args: Vec<OsString>,
        platform: MediaPlatform,
    ) -> Result<(), EngineError> {
        let cancel_requested = Arc::new(AtomicBool::new(false));
        let cancel_notify = Arc::new(Notify::new());
        let done_notify = Arc::new(Notify::new());
        let has_cached_ig_info = platform == MediaPlatform::InstagramReel
            && get_cached_instagram_info_json(&request.url).is_some();

        {
            let mut guard = self.job.lock().await;
            if let Some(existing) = guard.as_ref() {
                if existing.is_running {
                    return Err(EngineError::Busy(
                        "Another download is already running. Cancel or finish it first.".into(),
                    ));
                }
            }

            *guard = Some(ActiveJobState {
                job_id: job_id.clone(),
                request: request.clone(),
                output_template: output_template.clone(),
                is_running: true,
                cancel_requested: cancel_requested.clone(),
                cancel_notify: cancel_notify.clone(),
                process_job: None,
                done_notify: done_notify.clone(),
            });
        }

        let initial_message = if platform == MediaPlatform::InstagramReel && !has_cached_ig_info {
            "Connecting to Instagram..."
        } else {
            "Preparing download..."
        };
        self.emit_analyzing_stage(&job_id, initial_message);

        let manager = self.clone();
        let worker_ctx = WorkerLaunchContext {
            job_id,
            request,
            paths,
            args,
            output_template,
            platform,
            cancel_requested,
            cancel_notify,
            done_notify,
        };
        shared_runtime().spawn(async move {
            manager.run_download_worker(worker_ctx).await;
        });

        Ok(())
    }

    fn emit_analyzing_stage(&self, job_id: &str, message: &str) {
        let _ = self.tx.send(DownloadProgressEvent {
            job_id: job_id.to_string(),
            phase: DownloadPhase::Analyzing,
            downloaded_bytes: 0,
            total_bytes: None,
            is_total_estimated: false,
            speed_bytes_per_sec: None,
            eta_seconds: None,
            output_path: None,
            message: Some(message.to_string()),
        });
    }

    async fn emit_launch_failure(
        &self,
        job_id: &str,
        done_notify: &Arc<Notify>,
        launch_err: std::io::Error,
    ) {
        self.finish_job(job_id, false, None).await;
        let _ = self.tx.send(DownloadProgressEvent {
            job_id: job_id.to_string(),
            phase: DownloadPhase::Failed,
            downloaded_bytes: 0,
            total_bytes: None,
            is_total_estimated: false,
            speed_bytes_per_sec: None,
            eta_seconds: None,
            output_path: None,
            message: Some(format!("Failed to launch yt-dlp: {launch_err}")),
        });
        done_notify.notify_waiters();
    }

    async fn execute_instagram_download(
        &self,
        ctx: &WorkerLaunchContext,
        worker_start: std::time::Instant,
    ) -> Result<Option<DownloadAttemptOutcome>, std::io::Error> {
        let WorkerLaunchContext {
            job_id,
            request,
            paths,
            args,
            output_template,
            cancel_requested,
            cancel_notify,
            ..
        } = ctx;

        if let Some(cleaned_json) = get_cached_instagram_info_json(&request.url) {
            let info_json_path = std::env::temp_dir().join(format!("hyperdl_info_{job_id}.json"));
            if tokio::fs::write(&info_json_path, cleaned_json.as_bytes())
                .await
                .is_ok()
            {
                let args_res = build_download_args_from_info_json(
                    paths,
                    request,
                    output_template,
                    &info_json_path,
                );
                if let Ok(cached_args) = args_res {
                    eprintln!(
                        "[hyperdl][timing] instagram download using cached info.json job={job_id}"
                    );
                    let cached_res = self
                        .run_download_attempt(
                            job_id,
                            paths,
                            &cached_args,
                            cancel_requested,
                            cancel_notify,
                            Some(std::time::Duration::from_secs(
                                INSTAGRAM_CACHED_FIRST_BYTE_TIMEOUT_SECS,
                            )),
                            worker_start,
                        )
                        .await;
                    let _ = tokio::fs::remove_file(&info_json_path).await;
                    match cached_res {
                        Ok(attempt)
                            if attempt.succeeded()
                                || cancel_requested.load(Ordering::SeqCst)
                                || attempt.last_downloaded > 0 =>
                        {
                            return Ok(Some(attempt));
                        }
                        Ok(failed_cached) => {
                            eprintln!(
                                "[hyperdl][timing] cached instagram info.json failed at 0 B ({:.2}s); falling back to live extraction: {}",
                                worker_start.elapsed().as_secs_f64(),
                                redact_sensitive_diagnostics(&failed_cached.stderr_text)
                            );
                            invalidate_cached_instagram_info_json(&request.url);
                        }
                        Err(err) => return Err(err),
                    }
                } else {
                    let _ = tokio::fs::remove_file(&info_json_path).await;
                }
            }
        }

        if cancel_requested.load(Ordering::SeqCst) {
            return Ok(None);
        }

        self.emit_analyzing_stage(job_id, "Connecting to Instagram...");
        let live_args = build_instagram_network_args(args);
        let live_timeout = Some(std::time::Duration::from_secs(
            INSTAGRAM_LIVE_FIRST_BYTE_TIMEOUT_SECS,
        ));
        let first_live = self
            .run_download_attempt(
                job_id,
                paths,
                &live_args,
                cancel_requested,
                cancel_notify,
                live_timeout,
                worker_start,
            )
            .await?;

        if !first_live.succeeded()
            && !cancel_requested.load(Ordering::SeqCst)
            && first_live.last_downloaded == 0
            && !first_live.timed_out
            && is_transient_instagram_transport_error(&first_live.stderr_text)
        {
            self.emit_analyzing_stage(job_id, "Retrying connection to Instagram...");
            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_millis(1500)) => {}
                _ = cancel_notify.notified() => {}
            }
            if !cancel_requested.load(Ordering::SeqCst) {
                return Ok(Some(
                    self.run_download_attempt(
                        job_id,
                        paths,
                        &live_args,
                        cancel_requested,
                        cancel_notify,
                        live_timeout,
                        worker_start,
                    )
                    .await?,
                ));
            }
        }

        Ok(Some(first_live))
    }

    async fn run_download_worker(self: Arc<Self>, ctx: WorkerLaunchContext) {
        let worker_start = std::time::Instant::now();
        let job_started = std::time::SystemTime::now();

        let attempt_res = if ctx.platform == MediaPlatform::InstagramReel {
            self.execute_instagram_download(&ctx, worker_start).await
        } else {
            self.run_download_attempt(
                &ctx.job_id,
                &ctx.paths,
                &ctx.args,
                &ctx.cancel_requested,
                &ctx.cancel_notify,
                None,
                worker_start,
            )
            .await
            .map(Some)
        };

        let outcome = match attempt_res {
            Ok(Some(out)) => out,
            Ok(None) => DownloadAttemptOutcome::canceled_before_start(),
            Err(launch_err) => {
                self.emit_launch_failure(&ctx.job_id, &ctx.done_notify, launch_err)
                    .await;
                return;
            }
        };

        let WorkerLaunchContext {
            job_id,
            output_template,
            platform,
            cancel_requested,
            done_notify,
            ..
        } = ctx;

        if cancel_requested.load(Ordering::SeqCst) {
            cleanup_temp_mux_artifacts(&output_template, job_started).await;
        }

        self.finish_job(&job_id, false, None).await;

        let final_event = if cancel_requested.load(Ordering::SeqCst) {
            DownloadProgressEvent {
                job_id: job_id.clone(),
                phase: DownloadPhase::Canceled,
                downloaded_bytes: outcome.last_downloaded,
                total_bytes: outcome.last_total,
                is_total_estimated: outcome.last_estimated,
                speed_bytes_per_sec: None,
                eta_seconds: None,
                output_path: outcome
                    .recorded_output_path
                    .or(outcome.detected_output_path),
                message: Some("Download canceled. Partial data preserved for resume.".into()),
            }
        } else if outcome.timed_out {
            eprintln!(
                "[hyperdl][diag] Instagram download timed out before first byte (elapsed={:.2}s): {}",
                worker_start.elapsed().as_secs_f64(),
                redact_sensitive_diagnostics(&outcome.stderr_text)
            );
            DownloadProgressEvent {
                job_id: job_id.clone(),
                phase: DownloadPhase::Failed,
                downloaded_bytes: outcome.last_downloaded,
                total_bytes: outcome.last_total,
                is_total_estimated: outcome.last_estimated,
                speed_bytes_per_sec: None,
                eta_seconds: None,
                output_path: outcome.detected_output_path,
                message: Some(if platform == MediaPlatform::InstagramReel {
                    classify_instagram_error(&outcome.stderr_text)
                } else {
                    "Timed out before media transfer started.".into()
                }),
            }
        } else {
            match outcome.wait_result {
                Ok(status) if status.success() => {
                    let final_output_path = outcome
                        .recorded_output_path
                        .or(outcome.detected_output_path);
                    let final_disk_bytes = match final_output_path.as_deref() {
                        Some(path) => tokio::fs::metadata(path).await.ok().map(|m| m.len()),
                        None => None,
                    };
                    if final_output_path.is_none() || final_disk_bytes.unwrap_or(0) == 0 {
                        DownloadProgressEvent {
                            job_id: job_id.clone(),
                            phase: DownloadPhase::Failed,
                            downloaded_bytes: outcome.last_downloaded,
                            total_bytes: outcome.last_total,
                            is_total_estimated: outcome.last_estimated,
                            speed_bytes_per_sec: None,
                            eta_seconds: None,
                            output_path: final_output_path,
                            message: Some(
                                "Download finished, but the output file is missing or empty."
                                    .into(),
                            ),
                        }
                    } else {
                        let final_total = final_disk_bytes.or(outcome.last_total);
                        DownloadProgressEvent {
                            job_id: job_id.clone(),
                            phase: DownloadPhase::Completed,
                            downloaded_bytes: final_total.unwrap_or(outcome.last_downloaded),
                            total_bytes: final_total,
                            is_total_estimated: if final_disk_bytes.is_some() {
                                false
                            } else {
                                outcome.last_estimated
                            },
                            speed_bytes_per_sec: None,
                            eta_seconds: Some(0),
                            output_path: final_output_path,
                            message: Some("Download completed.".into()),
                        }
                    }
                }
                Ok(status) => {
                    let msg = if platform == MediaPlatform::InstagramReel {
                        eprintln!(
                            "[hyperdl][diag] Instagram download failed: {}",
                            redact_sensitive_diagnostics(&outcome.stderr_text)
                        );
                        classify_instagram_error(&outcome.stderr_text)
                    } else if outcome.stderr_text.trim().is_empty() {
                        format!("yt-dlp exited with code {:?}", status.code())
                    } else {
                        outcome.stderr_text.trim().to_string()
                    };
                    DownloadProgressEvent {
                        job_id: job_id.clone(),
                        phase: DownloadPhase::Failed,
                        downloaded_bytes: outcome.last_downloaded,
                        total_bytes: outcome.last_total,
                        is_total_estimated: outcome.last_estimated,
                        speed_bytes_per_sec: None,
                        eta_seconds: None,
                        output_path: outcome.detected_output_path,
                        message: Some(msg),
                    }
                }
                Err(err) => DownloadProgressEvent {
                    job_id: job_id.clone(),
                    phase: DownloadPhase::Failed,
                    downloaded_bytes: outcome.last_downloaded,
                    total_bytes: outcome.last_total,
                    is_total_estimated: outcome.last_estimated,
                    speed_bytes_per_sec: None,
                    eta_seconds: None,
                    output_path: outcome.detected_output_path,
                    message: Some(format!("Failed waiting for yt-dlp process: {err}")),
                },
            }
        };

        let _ = self.tx.send(final_event);
        done_notify.notify_waiters();
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_download_attempt(
        &self,
        job_id: &str,
        paths: &ToolPaths,
        args: &[OsString],
        cancel_requested: &Arc<AtomicBool>,
        cancel_notify: &Arc<Notify>,
        first_byte_timeout: Option<std::time::Duration>,
        worker_start: std::time::Instant,
    ) -> Result<DownloadAttemptOutcome, std::io::Error> {
        let path_record_file = std::env::temp_dir().join(format!("hyperdl_path_{job_id}.txt"));
        let _ = tokio::fs::remove_file(&path_record_file).await;

        let mut cmd = Command::new(&paths.yt_dlp_exe);
        cmd.arg("--no-quiet")
            .arg("--print-to-file")
            .arg("after_move:%(filepath)s")
            .arg(&path_record_file)
            .args(args);
        cmd.stdin(std::process::Stdio::null());
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        configure_subprocess(&mut cmd);

        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(err) => {
                let _ = tokio::fs::remove_file(&path_record_file).await;
                return Err(err);
            }
        };
        eprintln!(
            "[hyperdl][timing] download process spawned: job={job_id} elapsed={:.2}s",
            worker_start.elapsed().as_secs_f64()
        );

        let proc_handle = ProcessTreeJob::attach(&child).ok().map(Arc::new);
        if let Some(ref proc_arc) = proc_handle {
            let mut guard = self.job.lock().await;
            if let Some(state) = guard.as_mut().filter(|s| s.job_id == job_id) {
                state.process_job = Some(proc_arc.clone());
            }
            if cancel_requested.load(Ordering::SeqCst) {
                let _ = proc_arc.terminate();
            }
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
        let mut last_phase = DownloadPhase::Analyzing;
        let mut received_first_byte = false;
        let mut timed_out = false;
        let mut last_stage_msg: Option<String> = None;
        let first_byte_deadline = first_byte_timeout.map(|dur| tokio::time::Instant::now() + dur);

        if let Some(out_stream) = stdout {
            let mut reader = BufReader::new(out_stream);
            let mut raw_buf = Vec::with_capacity(512);
            loop {
                raw_buf.clear();
                let read_res = if !received_first_byte {
                    if let Some(deadline) = first_byte_deadline {
                        tokio::select! {
                            res = reader.read_until(b'\n', &mut raw_buf) => res,
                            _ = tokio::time::sleep_until(deadline) => {
                                timed_out = true;
                                terminate_process_or_child(&proc_handle, &mut child);
                                break;
                            }
                            _ = cancel_notify.notified() => {
                                terminate_process_or_child(&proc_handle, &mut child);
                                break;
                            }
                        }
                    } else {
                        tokio::select! {
                            res = reader.read_until(b'\n', &mut raw_buf) => res,
                            _ = cancel_notify.notified() => {
                                terminate_process_or_child(&proc_handle, &mut child);
                                break;
                            }
                        }
                    }
                } else {
                    reader.read_until(b'\n', &mut raw_buf).await
                };
                match read_res {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                if cancel_requested.load(Ordering::SeqCst) {
                    break;
                }
                let line = String::from_utf8_lossy(&raw_buf);
                match parse_progress_line(&line) {
                    ParsedYtDlpLine::StageStatus(msg) => {
                        if !received_first_byte && last_stage_msg.as_deref() != Some(msg.as_str()) {
                            last_stage_msg = Some(msg.clone());
                            self.emit_analyzing_stage(job_id, &msg);
                        }
                    }
                    ParsedYtDlpLine::DownloadProgress {
                        status,
                        downloaded_bytes,
                        total_bytes,
                        is_total_estimated,
                        speed_bytes_per_sec,
                        eta_seconds,
                    } => {
                        if total_bytes.is_some() {
                            last_total = total_bytes;
                            last_estimated = is_total_estimated;
                        }
                        if downloaded_bytes == 0 && status != "finished" {
                            if !received_first_byte
                                && last_stage_msg.as_deref()
                                    != Some("Connecting to media server...")
                            {
                                last_stage_msg = Some("Connecting to media server...".into());
                                let _ = self.tx.send(DownloadProgressEvent {
                                    job_id: job_id.to_string(),
                                    phase: DownloadPhase::Analyzing,
                                    downloaded_bytes: 0,
                                    total_bytes: last_total,
                                    is_total_estimated: last_estimated,
                                    speed_bytes_per_sec: None,
                                    eta_seconds: None,
                                    output_path: detected_output_path.clone(),
                                    message: Some("Connecting to media server...".into()),
                                });
                            }
                            continue;
                        }

                        let effective_downloaded = if downloaded_bytes > 0 {
                            downloaded_bytes
                        } else {
                            last_total.unwrap_or(last_downloaded)
                        };
                        if !received_first_byte {
                            received_first_byte = true;
                            eprintln!(
                                "[hyperdl][timing] download first_byte: job={job_id} elapsed={:.2}s bytes={effective_downloaded}",
                                worker_start.elapsed().as_secs_f64()
                            );
                        }
                        last_downloaded = effective_downloaded;
                        if last_phase != DownloadPhase::Merging {
                            last_phase = DownloadPhase::Downloading;
                        }
                        let msg = if status == "finished" {
                            Some("Stream finished, finalizing...".into())
                        } else {
                            None
                        };
                        let _ = self.tx.send(DownloadProgressEvent {
                            job_id: job_id.to_string(),
                            phase: DownloadPhase::Downloading,
                            downloaded_bytes: effective_downloaded,
                            total_bytes: last_total,
                            is_total_estimated: last_estimated,
                            speed_bytes_per_sec,
                            eta_seconds,
                            output_path: detected_output_path.clone(),
                            message: msg,
                        });
                    }
                    ParsedYtDlpLine::PostprocessProgress {
                        status: _,
                        postprocessor,
                    } => {
                        last_phase = DownloadPhase::Merging;
                        let _ = self.tx.send(DownloadProgressEvent {
                            job_id: job_id.to_string(),
                            phase: DownloadPhase::Merging,
                            downloaded_bytes: last_downloaded,
                            total_bytes: last_total,
                            is_total_estimated: last_estimated,
                            speed_bytes_per_sec: None,
                            eta_seconds: None,
                            output_path: detected_output_path.clone(),
                            message: Some(format!("Running {postprocessor} with FFmpeg...")),
                        });
                    }
                    ParsedYtDlpLine::OutputPathDetected(path) => {
                        detected_output_path = Some(path);
                        if !received_first_byte
                            && last_stage_msg.as_deref() != Some("Starting download...")
                        {
                            last_stage_msg = Some("Starting download...".into());
                            self.emit_analyzing_stage(job_id, "Starting download...");
                        }
                    }
                    ParsedYtDlpLine::Other => {}
                }
            }
        }

        let wait_result = child.wait().await;
        let mut stderr_text = stderr_task.await.unwrap_or_default();
        if timed_out {
            if !stderr_text.is_empty() {
                stderr_text.push('\n');
            }
            stderr_text.push_str(INSTAGRAM_CONNECTION_SETUP_TIMEOUT_MARKER);
        }
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

        Ok(DownloadAttemptOutcome {
            wait_result,
            stderr_text,
            recorded_output_path,
            detected_output_path,
            last_downloaded,
            last_total,
            last_estimated,
            timed_out,
        })
    }

    async fn finish_job(
        &self,
        job_id: &str,
        is_running: bool,
        process_job: Option<Arc<ProcessTreeJob>>,
    ) {
        let mut guard = self.job.lock().await;
        if let Some(state) = guard.as_mut().filter(|s| s.job_id == job_id) {
            state.is_running = is_running;
            state.process_job = process_job;
        }
    }
}

fn terminate_process_or_child(
    proc_handle: &Option<Arc<ProcessTreeJob>>,
    child: &mut tokio::process::Child,
) {
    if let Some(ref handle) = proc_handle {
        let _ = handle.terminate();
    } else {
        let _ = child.start_kill();
    }
}

struct WorkerLaunchContext {
    job_id: String,
    request: StartDownloadRequest,
    paths: ToolPaths,
    args: Vec<OsString>,
    output_template: String,
    platform: MediaPlatform,
    cancel_requested: Arc<AtomicBool>,
    cancel_notify: Arc<Notify>,
    done_notify: Arc<Notify>,
}

struct DownloadAttemptOutcome {
    wait_result: Result<std::process::ExitStatus, std::io::Error>,
    stderr_text: String,
    recorded_output_path: Option<String>,
    detected_output_path: Option<String>,
    last_downloaded: u64,
    last_total: Option<u64>,
    last_estimated: bool,
    timed_out: bool,
}

impl DownloadAttemptOutcome {
    fn succeeded(&self) -> bool {
        !self.timed_out && matches!(&self.wait_result, Ok(s) if s.success())
    }

    fn canceled_before_start() -> Self {
        Self {
            wait_result: Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "canceled before start",
            )),
            stderr_text: String::new(),
            recorded_output_path: None,
            detected_output_path: None,
            last_downloaded: 0,
            last_total: None,
            last_estimated: false,
            timed_out: false,
        }
    }
}

async fn cleanup_temp_mux_artifacts(output_template: &str, since: std::time::SystemTime) {
    let Some(parent_dir) = Path::new(output_template).parent() else {
        return;
    };
    let Ok(mut entries) = tokio::fs::read_dir(parent_dir).await else {
        return;
    };
    let stem_prefix = Path::new(output_template)
        .file_name()
        .and_then(|n| n.to_str())
        .map(|s| s.split("%(").next().unwrap_or(s).trim_end_matches('.'))
        .filter(|s| !s.is_empty())
        .map(str::to_ascii_lowercase);

    while let Ok(Some(entry)) = entries.next_entry().await {
        let name_lower = entry.file_name().to_string_lossy().to_ascii_lowercase();
        if !name_lower.contains(".temp.")
            || name_lower.ends_with(".part")
            || name_lower.ends_with(".ytdl")
        {
            continue;
        }
        if let Some(prefix) = stem_prefix.as_deref() {
            if !name_lower.starts_with(prefix) {
                continue;
            }
        } else if let Ok(meta) = entry.metadata().await {
            if meta.modified().ok().is_some_and(|mtime| mtime < since) {
                continue;
            }
        }
        let _ = tokio::fs::remove_file(entry.path()).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{DownloadFormatSelection, FormatSelectionStrategy};
    use std::path::PathBuf;
    use tempfile::TempDir;

    fn sample_raw_yt_dlp_json() -> &'static str {
        r#"{
            "id": "aqz-KE-bpKQ",
            "title": "Big Buck Bunny 60fps 4K",
            "uploader": "Blender",
            "duration": 635.0,
            "thumbnail": "https://i.ytimg.com/vi_webp/aqz-KE-bpKQ/maxresdefault.webp",
            "webpage_url": "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
            "extractor_key": "Youtube",
            "formats": [
                {
                    "format_id": "sb0",
                    "ext": "mhtml",
                    "vcodec": "none",
                    "acodec": "none",
                    "format_note": "storyboard"
                },
                {
                    "format_id": "drm-1",
                    "ext": "mp4",
                    "vcodec": "avc1",
                    "acodec": "mp4a.40.2",
                    "width": 1280,
                    "height": 720,
                    "filesize": 10485760,
                    "has_drm": true
                },
                {
                    "format_id": "139-drc",
                    "ext": "m4a",
                    "vcodec": "none",
                    "acodec": "mp4a.40.5",
                    "tbr": 48.79,
                    "filesize": 3871021,
                    "format_note": "low, DRC"
                },
                {
                    "format_id": "396",
                    "ext": "mp4",
                    "vcodec": "av01.0.01M.08",
                    "acodec": "none",
                    "width": 640,
                    "height": 360,
                    "fps": 30.0,
                    "tbr": 200.5,
                    "filesize_approx": 15400000,
                    "format_note": "360p"
                },
                {
                    "format_id": "18",
                    "ext": "mp4",
                    "vcodec": "avc1.42001E",
                    "acodec": "mp4a.40.2",
                    "width": 640,
                    "height": 360,
                    "fps": 30.0
                }
            ]
        }"#
    }

    #[test]
    fn parses_raw_yt_dlp_json_excludes_storyboards_and_drm_and_maps_size_accuracy() {
        let parsed = parse_yt_dlp_inspection_json(sample_raw_yt_dlp_json()).expect("valid JSON");

        assert_eq!(parsed.id, "aqz-KE-bpKQ");
        assert_eq!(parsed.title, "Big Buck Bunny 60fps 4K");
        assert_eq!(parsed.uploader.as_deref(), Some("Blender"));
        assert_eq!(parsed.duration_seconds, Some(635.0));
        assert_eq!(parsed.provider_name, "Youtube");
        // Storyboard (`sb0`) and DRM (`drm-1`) must be filtered out.
        assert_eq!(parsed.formats.len(), 3);

        let audio = &parsed.formats[0];
        assert_eq!(audio.format_id, "139-drc");
        assert_eq!(audio.stream_kind, StreamKind::AudioOnly);
        assert_eq!(audio.resolution, "audio only");
        assert_eq!(audio.file_size_bytes, Some(3_871_021));
        assert_eq!(audio.size_accuracy, FileSizeAccuracy::Exact);

        let video_only = &parsed.formats[1];
        assert_eq!(video_only.format_id, "396");
        assert_eq!(video_only.stream_kind, StreamKind::VideoOnly);
        assert_eq!(video_only.resolution, "640x360");
        assert_eq!(video_only.file_size_bytes, Some(15_400_000));
        assert_eq!(video_only.size_accuracy, FileSizeAccuracy::Estimated);

        let muxed = &parsed.formats[2];
        assert_eq!(muxed.format_id, "18");
        assert_eq!(muxed.stream_kind, StreamKind::MuxedAudioVideo);
        assert_eq!(muxed.file_size_bytes, None);
        assert_eq!(muxed.size_accuracy, FileSizeAccuracy::Unknown);
    }

    #[test]
    fn parses_phase_2a_video_inspection_fixture() {
        let fixture_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../tools/windows_media_prototype/fixtures/video_inspection_sample.json");
        let raw = std::fs::read_to_string(&fixture_path)
            .expect("Phase 2A fixture video_inspection_sample.json must exist");

        let parsed = parse_yt_dlp_inspection_json(&raw).expect("fixture should parse cleanly");
        assert_eq!(parsed.id, "aqz-KE-bpKQ");
        assert_eq!(parsed.formats.len(), 54);
        assert!(parsed.formats.iter().any(|f| f.format_id == "139"));
        assert!(parsed
            .formats
            .iter()
            .any(|f| f.stream_kind == StreamKind::VideoOnly));
        assert!(parsed
            .formats
            .iter()
            .any(|f| f.size_accuracy == FileSizeAccuracy::Exact));
    }

    #[test]
    fn parses_structured_progress_and_output_lines() {
        let exact_line = "HYPERDL|downloading|1048576|4194304|NA|524288.5|6\r";
        assert_eq!(
            parse_progress_line(exact_line),
            ParsedYtDlpLine::DownloadProgress {
                status: "downloading".into(),
                downloaded_bytes: 1_048_576,
                total_bytes: Some(4_194_304),
                is_total_estimated: false,
                speed_bytes_per_sec: Some(524_288.5),
                eta_seconds: Some(6),
            }
        );

        let estimated_line = "HYPERDL|downloading|512000|NA|2048000|256000.0|6";
        assert_eq!(
            parse_progress_line(estimated_line),
            ParsedYtDlpLine::DownloadProgress {
                status: "downloading".into(),
                downloaded_bytes: 512_000,
                total_bytes: Some(2_048_000),
                is_total_estimated: true,
                speed_bytes_per_sec: Some(256_000.0),
                eta_seconds: Some(6),
            }
        );

        let postprocess_line = "HYPERDL_PP|started|Merger";
        assert_eq!(
            parse_progress_line(postprocess_line),
            ParsedYtDlpLine::PostprocessProgress {
                status: "started".into(),
                postprocessor: "Merger".into(),
            }
        );

        let merger_dest = r#"[Merger] Merging formats into "C:\out\bunny [aqz].mp4""#;
        assert_eq!(
            parse_progress_line(merger_dest),
            ParsedYtDlpLine::OutputPathDetected(r"C:\out\bunny [aqz].mp4".into())
        );

        let download_dest = r"[download] Destination: C:\out\audio.m4a";
        assert_eq!(
            parse_progress_line(download_dest),
            ParsedYtDlpLine::OutputPathDetected(r"C:\out\audio.m4a".into())
        );

        assert_eq!(
            parse_progress_line("[Instagram] Setting up session"),
            ParsedYtDlpLine::StageStatus("Connecting to Instagram...".into())
        );
        assert_eq!(
            parse_progress_line("[Instagram] DTVTvUDj-b1: Downloading JSON metadata"),
            ParsedYtDlpLine::StageStatus("Resolving media...".into())
        );
        assert_eq!(
            parse_progress_line("[info] DTVTvUDj-b1: Downloading 1 format(s): dash-v+dash-a"),
            ParsedYtDlpLine::StageStatus("Resolving media...".into())
        );
    }

    #[test]
    fn builds_instagram_network_and_cached_info_json_args_without_affecting_youtube() {
        let paths = ToolPaths::resolve().expect("prototype binaries must resolve in workspace");
        let base_inspect =
            build_inspect_args(&paths, "https://www.instagram.com/reel/DTVTvUDj-b1/");
        let ig_inspect = build_instagram_network_args(&base_inspect);
        let ig_strings: Vec<String> = ig_inspect
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(ig_strings
            .windows(2)
            .any(|w| w == ["--socket-timeout", "40"]));
        assert!(!ig_strings.contains(&"--force-ipv4".to_string()));
        assert!(!ig_strings.contains(&"--impersonate".to_string()));

        let yt_inspect = build_inspect_args(&paths, "https://www.youtube.com/watch?v=aqz-KE-bpKQ");
        let yt_strings: Vec<String> = yt_inspect
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(!yt_strings.contains(&"--socket-timeout".to_string()));

        let raw_info = r#"{
            "id": "DTVTvUDj-b1",
            "format_id": "1",
            "format": "1 - unknown",
            "ext": "mp4",
            "_filename": "old.mp4",
            "filename": "old.mp4",
            "requested_formats": [{"format_id": "1"}],
            "requested_downloads": [{"filepath": "old.mp4"}],
            "formats": [{"format_id": "dash-a", "ext": "m4a"}]
        }"#;
        let canonical = "https://www.instagram.com/reel/CACHE_TEST_1/";
        invalidate_cached_instagram_info_json(canonical);
        store_cached_instagram_info_json(canonical, raw_info);
        let cached = get_cached_instagram_info_json(canonical).expect("cached cleaned info.json");
        let cached_val: Value = serde_json::from_str(&cached).expect("valid json");
        assert!(cached_val.get("requested_formats").is_none());
        assert!(cached_val.get("requested_downloads").is_none());
        assert!(cached_val.get("format_id").is_none());
        assert!(cached_val.get("formats").is_some());

        let ig_req = StartDownloadRequest {
            url: canonical.into(),
            title: Some("Cache Test".into()),
            selection: DownloadFormatSelection::video_and_audio("dash-v", "dash-a", "mp4"),
            output_directory: None,
        };
        let info_path = std::path::Path::new("temp_info.json");
        let cached_args =
            build_download_args_from_info_json(&paths, &ig_req, "out/%(id)s.%(ext)s", info_path)
                .expect("valid info json download args");
        let cached_strings: Vec<String> = cached_args
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(cached_strings
            .windows(2)
            .any(|w| w == ["--load-info-json", "temp_info.json"]));
        assert!(cached_strings
            .windows(2)
            .any(|w| w == ["--socket-timeout", "40"]));
        assert!(!cached_strings.contains(&canonical.to_string()));
        assert!(!cached_strings.contains(&"--force-ipv4".to_string()));
        assert!(!cached_strings.contains(&"--impersonate".to_string()));

        invalidate_cached_instagram_info_json(canonical);
        assert!(get_cached_instagram_info_json(canonical).is_none());
    }

    #[test]
    fn validates_urls_and_rejects_bad_schemes() {
        assert!(validate_media_url("https://www.youtube.com/watch?v=aqz-KE-bpKQ").is_ok());
        assert!(validate_media_url("").is_err());
        assert!(validate_media_url("not-a-valid-url").is_err());
        assert!(validate_media_url("file:///C:/secret.mp4").is_err());
        assert!(validate_media_url("ftp://example.com/video.mp4").is_err());
    }

    #[test]
    fn reports_missing_tools_with_typed_error() {
        let missing_root = TempDir::new().expect("temp dir");
        let empty_overrides = ToolEnvOverrides::default();
        let err =
            ToolPaths::resolve_from(&[missing_root.path().to_path_buf()], &empty_overrides, None)
                .expect_err("missing yt-dlp should return ToolUnavailable");
        match err {
            EngineError::ToolUnavailable { tool, .. } => assert_eq!(tool, "yt-dlp"),
            other => panic!("unexpected error variant: {other:?}"),
        }
    }

    #[test]
    fn resolves_local_prototype_tools_and_builds_typed_args() {
        let paths = ToolPaths::resolve().expect("prototype binaries must resolve in workspace");
        assert!(paths.yt_dlp_exe.is_file());
        assert!(paths.ffmpeg_exe.is_file());
        assert!(paths.node_exe.is_file());

        let single_req = StartDownloadRequest {
            url: "https://www.youtube.com/watch?v=aqz-KE-bpKQ".into(),
            title: None,
            selection: DownloadFormatSelection::single("139"),
            output_directory: None,
        };
        let single_args =
            build_download_args(&paths, &single_req, "out/%(id)s.%(ext)s").expect("valid args");
        let as_strings: Vec<String> = single_args
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(as_strings.windows(2).any(|w| w == ["-f", "139"]));
        assert!(!as_strings.contains(&"--merge-output-format".to_string()));

        let merge_req = StartDownloadRequest {
            url: "https://www.youtube.com/watch?v=aqz-KE-bpKQ".into(),
            title: None,
            selection: DownloadFormatSelection::video_and_audio("396", "139", "mp4"),
            output_directory: None,
        };
        let merge_args =
            build_download_args(&paths, &merge_req, "out/%(id)s.%(ext)s").expect("valid args");
        let merge_strings: Vec<String> = merge_args
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(merge_strings.windows(2).any(|w| w == ["-f", "396+139"]));
        assert!(merge_strings
            .windows(2)
            .any(|w| w == ["--merge-output-format", "mp4"]));

        let bad_req = StartDownloadRequest {
            url: "https://www.youtube.com/watch?v=aqz-KE-bpKQ".into(),
            title: None,
            selection: DownloadFormatSelection::single("139 --exec calc"),
            output_directory: None,
        };
        assert!(build_download_args(&paths, &bad_req, "out.mp4").is_err());
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn terminates_attached_windows_process_tree_via_job_object() {
        let mut cmd = Command::new("cmd.exe");
        cmd.args(["/C", "ping -n 30 127.0.0.1 >nul"]);
        cmd.creation_flags(CREATE_NO_WINDOW);
        let mut child = cmd.spawn().expect("spawn cmd.exe sleep process");

        let job = ProcessTreeJob::attach(&child).expect("attach Win32 Job Object");
        job.terminate().expect("terminate job object");

        let status = tokio::time::timeout(std::time::Duration::from_secs(3), child.wait())
            .await
            .expect("terminated process must exit promptly")
            .expect("wait succeeds");
        assert!(!status.success());
    }

    #[tokio::test]
    async fn live_youtube_inspect_download_cancel_and_resume() {
        let test_url = "https://www.youtube.com/watch?v=aqz-KE-bpKQ";
        let inspection = inspect_media_async(test_url)
            .await
            .expect("live inspection of authorized CC video must succeed");
        assert_eq!(inspection.id, "aqz-KE-bpKQ");
        assert!(!inspection.title.is_empty());
        assert!(!inspection.formats.is_empty());

        // Pick a genuine medium-sized audio/video HTTPS stream (~10-25 MB) for cancel + resume,
        // or fall back to the smallest audio format.
        let chosen_format = inspection
            .formats
            .iter()
            .filter(|f| {
                f.size_accuracy != FileSizeAccuracy::Unknown
                    && f.file_size_bytes.unwrap_or(0) >= 8_000_000
                    && f.file_size_bytes.unwrap_or(u64::MAX) <= 30_000_000
            })
            .min_by_key(|f| f.file_size_bytes.unwrap_or(u64::MAX))
            .or_else(|| {
                inspection
                    .formats
                    .iter()
                    .filter(|f| {
                        f.stream_kind == StreamKind::AudioOnly && f.file_size_bytes.is_some()
                    })
                    .min_by_key(|f| f.file_size_bytes.unwrap_or(u64::MAX))
            })
            .expect("at least one downloadable format must exist")
            .format_id
            .clone();

        let temp_dir = TempDir::new().expect("temp download directory");
        let manager = DownloadManager::new_isolated();
        let mut rx = manager.subscribe_broadcast();

        let job_id = manager
            .start_download(StartDownloadRequest {
                url: test_url.to_string(),
                title: Some(inspection.title.clone()),
                selection: DownloadFormatSelection::single(&chosen_format),
                output_directory: Some(temp_dir.path().to_string_lossy().into_owned()),
            })
            .await
            .expect("start_download must succeed");

        let mut canceled_mid_flight = false;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(90);

        while tokio::time::Instant::now() < deadline {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(30), rx.recv())
                .await
                .expect("timed out waiting for progress event")
                .expect("broadcast channel open");
            if ev.job_id != job_id {
                continue;
            }
            if ev.phase == DownloadPhase::Downloading
                && ev.downloaded_bytes > 0
                && !canceled_mid_flight
            {
                canceled_mid_flight = true;
                manager
                    .cancel_download(&job_id)
                    .await
                    .expect("cancel_download must terminate active tree cleanly");
            } else if ev.phase == DownloadPhase::Canceled {
                break;
            } else if ev.phase == DownloadPhase::Completed {
                // If network completed immediately before cancel fired, file exists and test passes.
                return;
            } else if ev.phase == DownloadPhase::Failed {
                panic!(
                    "Download failed unexpectedly before completion: {:?}",
                    ev.message
                );
            }
        }

        assert!(
            canceled_mid_flight,
            "expected download progress before cancel"
        );

        // Verify resume via `--continue` completes the transfer cleanly.
        let resumed_id = manager
            .resume_download(&job_id)
            .await
            .expect("resume_download must succeed after cancel");
        assert_eq!(resumed_id, job_id);

        let resume_deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(120);
        let mut completed_output: Option<String> = None;
        while tokio::time::Instant::now() < resume_deadline {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(30), rx.recv())
                .await
                .expect("timed out waiting for resumed progress")
                .expect("broadcast channel open");
            if ev.job_id != job_id {
                continue;
            }
            match ev.phase {
                DownloadPhase::Completed => {
                    completed_output = ev.output_path;
                    break;
                }
                DownloadPhase::Failed => {
                    panic!("Resumed download failed: {:?}", ev.message);
                }
                _ => {}
            }
        }

        let output_path = completed_output.expect("resumed download must emit Completed with path");
        let meta = std::fs::metadata(&output_path).expect("downloaded output file must exist");
        assert!(meta.len() > 0, "downloaded file must be non-empty");
    }

    #[test]
    fn prefers_confirmed_original_audio_over_first_arabic_auto_dub_and_dubbed_muxed() {
        let multi_audio_json = r#"{
            "id": "multi-vid",
            "title": "Multi Language Test",
            "language": "en-US",
            "extractor_key": "Youtube",
            "formats": [
                {
                    "format_id": "140-0",
                    "ext": "m4a",
                    "vcodec": "none",
                    "acodec": "mp4a.40.2",
                    "tbr": 129.5,
                    "filesize": 23429324,
                    "language": "ar",
                    "language_preference": -1,
                    "protocol": "https",
                    "format_note": "Arabic, medium",
                    "url": "https://example.com/audio?xtags=acont%3Ddubbed-auto%3Alang%3Dar"
                },
                {
                    "format_id": "140-15",
                    "ext": "m4a",
                    "vcodec": "none",
                    "acodec": "mp4a.40.2",
                    "tbr": 129.5,
                    "filesize": 23429324,
                    "language": "ru",
                    "language_preference": -1,
                    "protocol": "https",
                    "format_note": "Russian, medium",
                    "url": "https://example.com/audio?xtags=acont%3Ddubbed-auto%3Alang%3Dru"
                },
                {
                    "format_id": "140-19",
                    "ext": "m4a",
                    "vcodec": "none",
                    "acodec": "mp4a.40.2",
                    "tbr": 129.5,
                    "filesize": 23427071,
                    "language": "en-US",
                    "language_preference": 10,
                    "protocol": "https",
                    "format_note": "English (US) original (default), medium",
                    "url": "https://example.com/audio?xtags=acont%3Doriginal%3Alang%3Den-US"
                },
                {
                    "format_id": "251-19",
                    "ext": "webm",
                    "vcodec": "none",
                    "acodec": "opus",
                    "tbr": 132.0,
                    "filesize": 23500000,
                    "language": "en-US",
                    "language_preference": 10,
                    "protocol": "https",
                    "format_note": "English (US) original (default), medium",
                    "url": "https://example.com/audio?xtags=acont%3Doriginal%3Alang%3Den-US"
                },
                {
                    "format_id": "18",
                    "ext": "mp4",
                    "vcodec": "avc1.42001E",
                    "acodec": "mp4a.40.2",
                    "width": 640,
                    "height": 360,
                    "fps": 25.0,
                    "language": "ar",
                    "language_preference": -1,
                    "protocol": "https",
                    "format_note": "360p"
                },
                {
                    "format_id": "134",
                    "ext": "mp4",
                    "vcodec": "avc1.4D401E",
                    "acodec": "none",
                    "width": 640,
                    "height": 360,
                    "fps": 25.0,
                    "filesize": 50000000,
                    "protocol": "https"
                },
                {
                    "format_id": "137",
                    "ext": "mp4",
                    "vcodec": "avc1.640028",
                    "acodec": "none",
                    "width": 1920,
                    "height": 1080,
                    "fps": 30.0,
                    "filesize": 120000000,
                    "protocol": "https"
                }
            ]
        }"#;

        let parsed =
            parse_yt_dlp_inspection_json(multi_audio_json).expect("valid multi-audio JSON");
        let orig = parsed
            .original_audio
            .as_ref()
            .expect("original audio metadata must exist");
        assert_eq!(orig.language.as_deref(), Some("en-US"));
        assert_eq!(orig.is_original, Some(true));
        assert_eq!(orig.is_auto_dub, Some(false));
        assert_eq!(
            orig.selection_confidence,
            crate::models::AudioSelectionConfidence::ConfirmedOriginal
        );
        assert!(orig.status_note.contains("Original: English (US)"));

        // Ensure unavailable 4K is not fabricated; only discovered 1080p and 360p exist.
        assert_eq!(parsed.video_options.len(), 2);
        assert_eq!(parsed.video_options[0].resolution, "1080p");
        assert_eq!(parsed.video_options[1].resolution, "360p");

        // Ensure dubbed combined format `18` (ar) is NOT chosen; `134+140-19` is paired instead.
        let p360 = &parsed.video_options[1];
        assert_eq!(
            p360.format_selection_strategy,
            crate::models::FormatSelectionStrategy::PairVideoAndAudioWithFfmpeg
        );
        assert_eq!(p360.video_format_id, "134");
        assert_eq!(p360.selected_audio_format_id.as_deref(), Some("140-19"));

        // Audio-only options must only contain original-lineage tracks, never dubbed ar/ru.
        assert!(!parsed.audio_options.is_empty());
        assert!(parsed
            .audio_options
            .iter()
            .all(|o| o.format_id.ends_with("-19")));
    }

    #[test]
    fn uses_combined_muxed_format_when_no_dub_mismatch_exists() {
        let muxed_json = r#"{
            "id": "combined-vid",
            "title": "Combined Format Test",
            "formats": [
                {
                    "format_id": "139",
                    "ext": "m4a",
                    "vcodec": "none",
                    "acodec": "mp4a.40.5",
                    "tbr": 48.8,
                    "filesize": 3871021,
                    "protocol": "https"
                },
                {
                    "format_id": "18",
                    "ext": "mp4",
                    "vcodec": "avc1.42001E",
                    "acodec": "mp4a.40.2",
                    "width": 640,
                    "height": 360,
                    "fps": 30.0,
                    "filesize": 12000000,
                    "protocol": "https"
                },
                {
                    "format_id": "134",
                    "ext": "mp4",
                    "vcodec": "avc1.4D401E",
                    "acodec": "none",
                    "width": 640,
                    "height": 360,
                    "fps": 30.0,
                    "filesize": 10000000,
                    "protocol": "https"
                }
            ]
        }"#;

        let parsed = parse_yt_dlp_inspection_json(muxed_json).expect("valid JSON");
        assert_eq!(parsed.video_options.len(), 1);
        let opt = &parsed.video_options[0];
        assert_eq!(opt.resolution, "360p");
        assert_eq!(
            opt.format_selection_strategy,
            crate::models::FormatSelectionStrategy::CombinedAudioVideo
        );
        assert_eq!(opt.video_format_id, "18");
        assert_eq!(opt.selected_audio_format_id, None);

        // Missing original marker must be reported honestly as SingleOrUnmarked.
        let meta = parsed.original_audio.expect("audio metadata exists");
        assert_eq!(
            meta.selection_confidence,
            crate::models::AudioSelectionConfidence::SingleOrUnmarked
        );
        assert_eq!(meta.is_original, None);
    }

    #[test]
    fn missing_audio_track_produces_no_video_with_sound_options() {
        let silent_json = r#"{
            "id": "silent-vid",
            "title": "Silent Video Only",
            "formats": [
                {
                    "format_id": "137",
                    "ext": "mp4",
                    "vcodec": "avc1.640028",
                    "acodec": "none",
                    "width": 1920,
                    "height": 1080,
                    "fps": 30.0,
                    "filesize": 50000000,
                    "protocol": "https"
                }
            ]
        }"#;

        let parsed = parse_yt_dlp_inspection_json(silent_json).expect("valid silent video JSON");
        assert!(parsed.video_options.is_empty());
        assert!(parsed.audio_options.is_empty());
        assert!(parsed.original_audio.is_none());
    }

    #[test]
    fn ambiguous_multi_language_without_original_markers_does_not_claim_original() {
        let ambiguous_json = r#"{
            "id": "ambiguous-vid",
            "title": "Unmarked Multi Language",
            "formats": [
                {
                    "format_id": "140-ar",
                    "ext": "m4a",
                    "vcodec": "none",
                    "acodec": "mp4a.40.2",
                    "tbr": 128.0,
                    "language": "ar",
                    "language_preference": -1,
                    "protocol": "https"
                },
                {
                    "format_id": "140-en",
                    "ext": "m4a",
                    "vcodec": "none",
                    "acodec": "mp4a.40.2",
                    "tbr": 128.0,
                    "language": "en",
                    "language_preference": -1,
                    "protocol": "https"
                }
            ]
        }"#;

        let parsed = parse_yt_dlp_inspection_json(ambiguous_json).expect("valid JSON");
        let meta = parsed.original_audio.expect("audio meta present");
        assert_eq!(meta.is_original, None);
        assert_eq!(
            meta.selection_confidence,
            crate::models::AudioSelectionConfidence::AmbiguousOrUnknown
        );
        assert!(!meta.status_note.contains("Original:"));
    }

    #[tokio::test]
    async fn live_multi_audio_video_selects_original_and_merges_with_ffmpeg() {
        let url = "https://www.youtube.com/watch?v=TsT1ntGyj4Q";
        let inspection = inspect_media_async(url)
            .await
            .expect("live multi-audio inspection must succeed");

        let orig_audio = inspection
            .original_audio
            .as_ref()
            .expect("original audio metadata must be extracted");
        assert_eq!(orig_audio.language.as_deref(), Some("en-US"));
        assert_eq!(orig_audio.is_original, Some(true));
        assert_eq!(orig_audio.is_auto_dub, Some(false));
        assert_eq!(
            orig_audio.selection_confidence,
            crate::models::AudioSelectionConfidence::ConfirmedOriginal
        );

        // No 4K option should be fabricated on this max-1080p video.
        assert!(
            !inspection
                .video_options
                .iter()
                .any(|v| v.resolution.contains("2160")),
            "4K must not be fabricated when max genuine resolution is 1080p"
        );

        // Audio-only options must all use the original `-19` / non-dub track, never Arabic dub `140-0`.
        assert!(!inspection.audio_options.is_empty());
        assert!(
            !inspection
                .audio_options
                .iter()
                .any(|a| a.format_id == "140-0"),
            "Arabic auto-dub 140-0 must not be exposed in Audio Only"
        );

        // Pick the smallest paired MP4 option (e.g., 144p) and merge with FFmpeg.
        let paired_opt = inspection
            .video_options
            .iter()
            .filter(|v| {
                v.format_selection_strategy
                    == crate::models::FormatSelectionStrategy::PairVideoAndAudioWithFfmpeg
                    && v.selected_audio_format_id.is_some()
            })
            .min_by_key(|v| v.height.unwrap_or(u32::MAX))
            .expect("must find a paired video+original-audio option");

        assert_ne!(
            paired_opt.selected_audio_format_id.as_deref(),
            Some("140-0"),
            "must never select Arabic auto-dub 140-0"
        );

        let temp_dir = TempDir::new().expect("temp download directory");
        let manager = DownloadManager::new_isolated();
        let mut rx = manager.subscribe_broadcast();

        let job_id = manager
            .start_download(StartDownloadRequest {
                url: url.to_string(),
                title: Some(inspection.title.clone()),
                selection: DownloadFormatSelection::video_and_audio(
                    &paired_opt.video_format_id,
                    paired_opt.selected_audio_format_id.as_ref().unwrap(),
                    &paired_opt.container,
                ),
                output_directory: Some(temp_dir.path().to_string_lossy().into_owned()),
            })
            .await
            .expect("start_download for paired multi-audio merge must succeed");

        let mut saw_merging = false;
        let mut output_path: Option<String> = None;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(180);
        while tokio::time::Instant::now() < deadline {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(60), rx.recv())
                .await
                .expect("timed out waiting for merge progress")
                .expect("broadcast channel open");
            if ev.job_id != job_id {
                continue;
            }
            match ev.phase {
                DownloadPhase::Merging => saw_merging = true,
                DownloadPhase::Completed => {
                    output_path = ev.output_path;
                    break;
                }
                DownloadPhase::Failed => panic!("Merged download failed: {:?}", ev.message),
                _ => {}
            }
        }

        assert!(saw_merging, "FFmpeg merge phase should run");
        let final_file = output_path.expect("merged MP4 path must be reported on completion");
        assert!(std::path::Path::new(&final_file).is_file());

        // Probe the actual output MP4 with `ffprobe.exe` to confirm both video and audio streams exist.
        let paths = ToolPaths::resolve().expect("tool paths");
        let ffprobe = paths.ffmpeg_dir().join(if cfg!(windows) {
            "ffprobe.exe"
        } else {
            "ffprobe"
        });
        let probe = std::process::Command::new(ffprobe)
            .args([
                "-v",
                "error",
                "-show_entries",
                "stream=index,codec_type,codec_name",
                "-of",
                "json",
                &final_file,
            ])
            .output()
            .expect("ffprobe execution succeeds");
        assert!(probe.status.success(), "ffprobe failed on merged MP4");
        let probe_json: Value =
            serde_json::from_slice(&probe.stdout).expect("valid ffprobe JSON output");
        let streams = probe_json["streams"]
            .as_array()
            .expect("ffprobe streams array");
        assert!(
            streams.iter().any(|s| s["codec_type"] == "video"),
            "final merged file must contain a video stream: {probe_json}"
        );
        assert!(
            streams.iter().any(|s| s["codec_type"] == "audio"),
            "final merged file must contain an audio stream: {probe_json}"
        );
    }

    fn ffprobe_streams(file_path: &str) -> Vec<Value> {
        let paths = ToolPaths::resolve().expect("tool paths");
        let ffprobe = paths.ffmpeg_dir().join(if cfg!(windows) {
            "ffprobe.exe"
        } else {
            "ffprobe"
        });
        let probe = std::process::Command::new(ffprobe)
            .args([
                "-v",
                "error",
                "-show_entries",
                "stream=index,codec_type,codec_name,width,height",
                "-of",
                "json",
                file_path,
            ])
            .output()
            .expect("ffprobe execution succeeds");
        assert!(probe.status.success(), "ffprobe failed on {file_path}");
        let json: Value = serde_json::from_slice(&probe.stdout).expect("valid ffprobe JSON");
        json["streams"]
            .as_array()
            .expect("ffprobe streams array")
            .clone()
    }

    #[test]
    fn parses_instagram_reel_dash_and_progressive_with_vertical_resolutions() {
        let raw = r#"{
            "id": "DTVTvUDj-b1",
            "title": "Video by rahulmfg",
            "uploader": "Rahul",
            "uploader_id": "194665093",
            "channel": "rahulmfg",
            "thumbnail": "https://instagram.example.com/cover.jpg",
            "webpage_url": "https://www.instagram.com/reel/DTVTvUDj-b1/",
            "extractor_key": "Instagram",
            "formats": [
                {
                    "format_id": "dash-904995479368697a",
                    "ext": "m4a",
                    "vcodec": "none",
                    "acodec": "mp4a.40.5",
                    "tbr": 67.941,
                    "abr": 67.941,
                    "protocol": "https",
                    "format_note": "DASH audio",
                    "resolution": "audio only"
                },
                {
                    "format_id": "1",
                    "ext": "mp4",
                    "vcodec": null,
                    "acodec": null,
                    "video_ext": "mp4",
                    "audio_ext": "none",
                    "protocol": "https"
                },
                {
                    "format_id": "dash-1754072528592597v",
                    "ext": "mp4",
                    "vcodec": "vp09.00.21.08",
                    "acodec": "none",
                    "width": 360,
                    "height": 640,
                    "tbr": 162.7,
                    "protocol": "https"
                },
                {
                    "format_id": "dash-1399043958518950v",
                    "ext": "mp4",
                    "vcodec": "vp09.00.30.08",
                    "acodec": "none",
                    "width": 540,
                    "height": 960,
                    "tbr": 537.5,
                    "protocol": "https"
                },
                {
                    "format_id": "dash-1550201829567087v",
                    "ext": "mp4",
                    "vcodec": "vp09.00.31.08",
                    "acodec": "none",
                    "width": 720,
                    "height": 1280,
                    "tbr": 1022.4,
                    "protocol": "https"
                },
                {
                    "format_id": "dash-3838628822936334v",
                    "ext": "mp4",
                    "vcodec": "vp09.00.40.08",
                    "acodec": "none",
                    "width": 1080,
                    "height": 1920,
                    "tbr": 1490.8,
                    "protocol": "https"
                }
            ]
        }"#;

        let parsed = parse_yt_dlp_inspection_json(raw).expect("valid Instagram JSON");
        assert_eq!(parsed.provider_name, "Instagram");
        assert_eq!(parsed.uploader.as_deref(), Some("Rahul"));
        assert!(parsed.duration_seconds.is_none());
        assert_eq!(
            parsed
                .original_audio
                .as_ref()
                .map(|a| a.status_note.as_str()),
            Some("Audio included automatically")
        );

        let resolutions: Vec<&str> = parsed
            .video_options
            .iter()
            .map(|o| o.resolution.as_str())
            .collect();
        assert_eq!(resolutions, vec!["1080p", "720p", "540p", "360p"]);
        assert_eq!(
            parsed.video_options[0].format_selection_strategy,
            FormatSelectionStrategy::PairVideoAndAudioWithFfmpeg
        );
        assert_eq!(
            parsed.video_options[0].selected_audio_format_id.as_deref(),
            Some("dash-904995479368697a")
        );
        assert_eq!(parsed.audio_options.len(), 1);
        assert_eq!(parsed.audio_options[0].format_id, "dash-904995479368697a");
    }

    #[test]
    fn parses_instagram_progressive_only_and_silent_and_missing_metadata_cases() {
        let progressive_only = r#"{
            "id": "PROG123",
            "title": null,
            "uploader": null,
            "uploader_id": "creator_xyz",
            "duration": null,
            "thumbnail": null,
            "webpage_url": "https://www.instagram.com/reel/PROG123/",
            "extractor_key": "InstagramIOS",
            "formats": [
                {
                    "format_id": "1",
                    "ext": "mp4",
                    "vcodec": null,
                    "acodec": null,
                    "video_ext": "mp4",
                    "audio_ext": "none",
                    "protocol": "https"
                }
            ]
        }"#;

        let insp = parse_yt_dlp_inspection_json(progressive_only).expect("progressive parses");
        assert_eq!(insp.provider_name, "Instagram");
        assert_eq!(insp.title, "Instagram Reel by creator_xyz");
        assert_eq!(insp.uploader.as_deref(), Some("creator_xyz"));
        assert!(insp.duration_seconds.is_none());
        assert!(insp.thumbnail_url.is_none());
        assert_eq!(insp.video_options.len(), 1);
        assert_eq!(insp.video_options[0].resolution, "Standard");
        assert_eq!(
            insp.video_options[0].format_selection_strategy,
            FormatSelectionStrategy::CombinedAudioVideo
        );
        assert!(insp.audio_options.is_empty());

        let missing_all_meta = r#"{
            "id": "NOUPLOADER",
            "webpage_url": "https://www.instagram.com/reel/NOUPLOADER/",
            "formats": [
                {
                    "format_id": "dash-v",
                    "ext": "mp4",
                    "vcodec": "avc1",
                    "acodec": "none",
                    "width": 720,
                    "height": 1280
                }
            ]
        }"#;
        let silent = parse_yt_dlp_inspection_json(missing_all_meta).expect("silent parses");
        assert_eq!(silent.title, "Instagram Reel (NOUPLOADER)");
        assert!(silent.video_options.is_empty());
        assert!(silent.audio_options.is_empty());

        let carousel = r#"{
            "id": "CAR1",
            "_type": "playlist",
            "extractor_key": "Instagram",
            "webpage_url": "https://www.instagram.com/reel/CAR1/"
        }"#;
        let err = parse_yt_dlp_inspection_json(carousel).unwrap_err();
        assert!(err.to_string().contains("carousels"));
    }

    #[test]
    fn classifies_instagram_errors_and_redacts_tokens() {
        assert!(
            classify_instagram_error("ERROR: Postprocessing: ffmpeg exited with code 1")
                .contains("FFmpeg")
        );
        assert!(
            classify_instagram_error("HTTP Error 429: Too Many Requests").contains("rate-limited")
        );
        assert!(
            classify_instagram_error("ERROR: [Instagram] XYZ: HTTP Error 404: Not Found")
                .contains("deleted")
        );
        assert!(classify_instagram_error("ERROR: This account is private").contains("private"));
        assert!(
            classify_instagram_error("ERROR: Main webpage is locked behind the login page")
                .contains("requires login")
        );
        assert!(
            classify_instagram_error("ERROR: Instagram sent an empty media response")
                .contains("restricted")
        );
        assert!(
            classify_instagram_error("curl: (28) Connection timed out after 15000 ms")
                .contains("Network error")
        );
        assert!(classify_instagram_error("unexpected fatal extractor crash")
            .contains("Instagram extraction failed"));

        assert!(is_transient_instagram_transport_error(
            "curl: (6) Could not resolve host: instagram.fna.fbcdn.net"
        ));
        assert!(!is_transient_instagram_transport_error(
            "HTTP Error 429: Too Many Requests"
        ));

        let raw_diag = concat!(
            "Cookie: sessionid=secret123; csrftoken=tok999; ds_user_id=42\n",
            "Authorization: Bearer abc.def.ghi\n",
            "https://cdn.example.com/v.mp4?oh=00_SECRET_HASH&_nc_ohc=SECRET2&ccb=17-1"
        );
        let scrubbed = redact_sensitive_diagnostics(raw_diag);
        assert!(!scrubbed.contains("secret123"));
        assert!(!scrubbed.contains("tok999"));
        assert!(!scrubbed.contains("abc.def.ghi"));
        assert!(!scrubbed.contains("00_SECRET_HASH"));
        assert!(!scrubbed.contains("SECRET2"));
        assert!(scrubbed.contains("[REDACTED]"));
        assert!(scrubbed.contains("ccb=17-1"));
    }

    #[tokio::test]
    async fn handles_instagram_collisions_unicode_filenames_and_cancel_cleanup() {
        let dir = TempDir::new().expect("temp dir");
        let req = StartDownloadRequest {
            url: "https://www.instagram.com/reel/CDUMkliABpa/".into(),
            title: Some("تجربة: Alina Jäger / Reel?".into()),
            selection: DownloadFormatSelection::single("1"),
            output_directory: Some(dir.path().to_string_lossy().into_owned()),
        };

        let tpl1 = resolve_output_template_for_new_job(dir.path(), &req, Some("CDUMkliABpa"));
        assert!(tpl1.contains("تجربة Alina Jäger Reel [CDUMkliABpa] [1].%(ext)s"));

        // Existing .part must NOT increment collision index, but completed .mp4 MUST increment to (2).
        let partial = tpl1.replace(".%(ext)s", ".mp4.part");
        std::fs::write(&partial, b"partial").unwrap();
        let tpl_with_part =
            resolve_output_template_for_new_job(dir.path(), &req, Some("CDUMkliABpa"));
        assert_eq!(tpl_with_part, tpl1);

        let completed = tpl1.replace(".%(ext)s", ".mp4");
        std::fs::write(&completed, b"complete").unwrap();
        let tpl2 = resolve_output_template_for_new_job(dir.path(), &req, Some("CDUMkliABpa"));
        assert!(tpl2.contains("[CDUMkliABpa] [1] (2).%(ext)s"));

        // Cancel temp cleanup removes .temp. mux files while preserving .part & completed files.
        let started = std::time::SystemTime::now();
        let temp_mux = tpl1.replace(".%(ext)s", ".temp.mp4");
        std::fs::write(&temp_mux, b"mux_junk").unwrap();
        cleanup_temp_mux_artifacts(&tpl1, started).await;
        assert!(!std::path::Path::new(&temp_mux).exists());
        assert!(std::path::Path::new(&partial).exists());
        assert!(std::path::Path::new(&completed).exists());
    }

    #[tokio::test]
    async fn live_instagram_inspect_download_audio_only_and_collision() {
        let reel_url = "https://www.instagram.com/reel/DTVTvUDj-b1/";
        let inspect_t0 = std::time::Instant::now();
        let inspection = inspect_media_async(reel_url)
            .await
            .expect("live Instagram Reel inspection must succeed");
        let inspect_secs = inspect_t0.elapsed().as_secs_f64();
        eprintln!(
            "[live_test] Instagram inspect elapsed={inspect_secs:.2}s options={} cached={}",
            inspection.video_options.len(),
            get_cached_instagram_info_json(reel_url).is_some()
        );
        assert_eq!(inspection.id, "DTVTvUDj-b1");
        assert_eq!(inspection.provider_name, "Instagram");
        assert!(!inspection.video_options.is_empty());

        let chosen_video = inspection
            .video_options
            .iter()
            .find(|o| o.resolution == "720p")
            .unwrap_or(&inspection.video_options[0]);
        let selection = if let Some(audio_id) = chosen_video.selected_audio_format_id.as_deref() {
            DownloadFormatSelection::video_and_audio(
                &chosen_video.video_format_id,
                audio_id,
                &chosen_video.container,
            )
        } else {
            DownloadFormatSelection::single(&chosen_video.video_format_id)
        };

        let temp_dir = TempDir::new().expect("temp dir");
        let manager = DownloadManager::new_isolated();
        let mut rx = manager.subscribe_broadcast();

        let dl_t0 = std::time::Instant::now();
        let job_id = manager
            .start_download(StartDownloadRequest {
                url: reel_url.into(),
                title: Some(inspection.title.clone()),
                selection: selection.clone(),
                output_directory: Some(temp_dir.path().to_string_lossy().into_owned()),
            })
            .await
            .expect("start_download succeeds");
        let start_call_secs = dl_t0.elapsed().as_secs_f64();

        let mut first_output: Option<String> = None;
        let mut first_byte_secs: Option<f64> = None;
        let mut prev_bytes = 0u64;
        let mut saw_progress_increase = false;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(180);
        while tokio::time::Instant::now() < deadline {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(90), rx.recv())
                .await
                .expect("progress timeout")
                .expect("channel open");
            if ev.job_id != job_id {
                continue;
            }
            assert!(
                !(ev.phase == DownloadPhase::Downloading && ev.downloaded_bytes == 0),
                "must never report Downloading with 0 transferred bytes"
            );
            if ev.phase == DownloadPhase::Downloading && ev.downloaded_bytes > 0 {
                if first_byte_secs.is_none() {
                    first_byte_secs = Some(dl_t0.elapsed().as_secs_f64());
                }
                if ev.downloaded_bytes > prev_bytes {
                    saw_progress_increase = true;
                }
                prev_bytes = ev.downloaded_bytes;
            }
            match ev.phase {
                DownloadPhase::Completed => {
                    first_output = ev.output_path;
                    break;
                }
                DownloadPhase::Failed => panic!("Instagram download failed: {:?}", ev.message),
                _ => {}
            }
        }
        eprintln!(
            "[live_test] Instagram start_download={start_call_secs:.3}s first_byte={:?}s total_dl={:.2}s",
            first_byte_secs,
            dl_t0.elapsed().as_secs_f64()
        );
        assert!(
            first_byte_secs.is_some() && saw_progress_increase,
            "expected active byte progress before completion"
        );
        let first_path = first_output.expect("completed output path");
        assert!(std::path::Path::new(&first_path).is_file());
        let streams = ffprobe_streams(&first_path);
        assert!(streams.iter().any(|s| s["codec_type"] == "video"));
        assert!(streams.iter().any(|s| s["codec_type"] == "audio"));

        // Second download in same directory must produce non-colliding ` (2)` filename.
        let job2 = manager
            .start_download(StartDownloadRequest {
                url: reel_url.into(),
                title: Some(inspection.title.clone()),
                selection,
                output_directory: Some(temp_dir.path().to_string_lossy().into_owned()),
            })
            .await
            .expect("second start_download succeeds");
        let mut second_output: Option<String> = None;
        while tokio::time::Instant::now() < deadline {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(90), rx.recv())
                .await
                .expect("progress timeout")
                .expect("channel open");
            if ev.job_id != job2 {
                continue;
            }
            assert!(!(ev.phase == DownloadPhase::Downloading && ev.downloaded_bytes == 0));
            match ev.phase {
                DownloadPhase::Completed => {
                    second_output = ev.output_path;
                    break;
                }
                DownloadPhase::Failed => panic!("Second download failed: {:?}", ev.message),
                _ => {}
            }
        }
        let second_path = second_output.expect("second completed path");
        assert_ne!(second_path, first_path);
        assert!(second_path.contains(" (2)"));
        assert!(std::path::Path::new(&second_path).is_file());

        // Audio-only download when available.
        if let Some(audio_opt) = inspection.audio_options.first() {
            let audio_job = manager
                .start_download(StartDownloadRequest {
                    url: reel_url.into(),
                    title: Some(format!("Audio {}", inspection.title)),
                    selection: DownloadFormatSelection::single(&audio_opt.format_id),
                    output_directory: Some(temp_dir.path().to_string_lossy().into_owned()),
                })
                .await
                .expect("audio download starts");
            let mut audio_out: Option<String> = None;
            while tokio::time::Instant::now() < deadline {
                let ev = tokio::time::timeout(std::time::Duration::from_secs(90), rx.recv())
                    .await
                    .expect("progress timeout")
                    .expect("channel open");
                if ev.job_id != audio_job {
                    continue;
                }
                assert!(!(ev.phase == DownloadPhase::Downloading && ev.downloaded_bytes == 0));
                match ev.phase {
                    DownloadPhase::Completed => {
                        audio_out = ev.output_path;
                        break;
                    }
                    DownloadPhase::Failed => panic!("Audio download failed: {:?}", ev.message),
                    _ => {}
                }
            }
            let audio_path = audio_out.expect("audio output path");
            let a_streams = ffprobe_streams(&audio_path);
            assert!(a_streams.iter().any(|s| s["codec_type"] == "audio"));
        }
    }

    #[tokio::test]
    async fn live_instagram_second_reel_unicode_cancel_and_error_cases() {
        let reel2 = "https://www.instagram.com/reel/CDUMkliABpa/";
        let insp2 = inspect_media_async(reel2)
            .await
            .expect("second public Instagram Reel inspection must succeed");
        assert_eq!(insp2.id, "CDUMkliABpa");
        assert_eq!(insp2.provider_name, "Instagram");
        let chosen = &insp2.video_options[0];
        let selection = if let Some(aid) = chosen.selected_audio_format_id.as_deref() {
            DownloadFormatSelection::video_and_audio(
                &chosen.video_format_id,
                aid,
                &chosen.container,
            )
        } else {
            DownloadFormatSelection::single(&chosen.video_format_id)
        };

        let temp_dir = TempDir::new().expect("temp dir");
        let manager = DownloadManager::new_isolated();
        let mut rx = manager.subscribe_broadcast();

        // Download with non-English Arabic + German filename.
        let job_id = manager
            .start_download(StartDownloadRequest {
                url: reel2.into(),
                title: Some("تجربة_Alina Jäger".into()),
                selection,
                output_directory: Some(temp_dir.path().to_string_lossy().into_owned()),
            })
            .await
            .expect("start_download succeeds");

        let mut completed_path: Option<String> = None;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(180);
        while tokio::time::Instant::now() < deadline {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(90), rx.recv())
                .await
                .expect("progress timeout")
                .expect("channel open");
            if ev.job_id != job_id {
                continue;
            }
            assert!(!(ev.phase == DownloadPhase::Downloading && ev.downloaded_bytes == 0));
            match ev.phase {
                DownloadPhase::Completed => {
                    completed_path = ev.output_path;
                    break;
                }
                DownloadPhase::Failed => panic!("Second Reel download failed: {:?}", ev.message),
                _ => {}
            }
        }
        let path2 = completed_path.expect("unicode output path");
        assert!(path2.contains("تجربة_Alina Jäger"));
        let streams = ffprobe_streams(&path2);
        assert!(streams.iter().any(|s| s["codec_type"] == "video"));
        assert!(streams.iter().any(|s| s["codec_type"] == "audio"));

        // Error handling check against missing/deleted shortcode and unsupported Stories URL.
        let err_missing = inspect_media_async("https://www.instagram.com/reel/ZZZZZZZZZZZ/")
            .await
            .expect_err("non-existent Reel must fail gracefully")
            .to_string();
        assert!(!err_missing.trim().is_empty());

        let err_story = inspect_media_async("https://www.instagram.com/stories/instagram/123456/")
            .await
            .expect_err("Stories URL must fail before invoking yt-dlp")
            .to_string();
        assert!(err_story.contains("Stories"));
    }

    #[tokio::test]
    async fn live_instagram_cancel_and_resume() {
        let reel_url = "https://www.instagram.com/reel/DTVTvUDj-b1/";
        let inspection = inspect_media_async(reel_url)
            .await
            .expect("live Instagram inspection succeeds");
        let chosen = inspection
            .video_options
            .iter()
            .find(|o| o.resolution == "720p")
            .unwrap_or(&inspection.video_options[0]);
        let selection = if let Some(aid) = chosen.selected_audio_format_id.as_deref() {
            DownloadFormatSelection::video_and_audio(
                &chosen.video_format_id,
                aid,
                &chosen.container,
            )
        } else {
            DownloadFormatSelection::single(&chosen.video_format_id)
        };

        let temp_dir = TempDir::new().expect("temp dir");
        let manager = DownloadManager::new_isolated();
        let mut rx = manager.subscribe_broadcast();

        // Part 1: Cancel immediately BEFORE first byte arrives.
        let early_job_id = manager
            .start_download(StartDownloadRequest {
                url: reel_url.into(),
                title: Some("Early Cancel".into()),
                selection: selection.clone(),
                output_directory: Some(temp_dir.path().to_string_lossy().into_owned()),
            })
            .await
            .expect("early cancel start_download succeeds");
        manager
            .cancel_download(&early_job_id)
            .await
            .expect("cancel before first byte succeeds");
        let mut early_canceled = false;
        let early_deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
        while tokio::time::Instant::now() < early_deadline {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(15), rx.recv())
                .await
                .expect("early cancel event timeout")
                .expect("channel open");
            if ev.job_id != early_job_id {
                continue;
            }
            if ev.phase == DownloadPhase::Canceled {
                early_canceled = true;
                break;
            } else if ev.phase == DownloadPhase::Failed {
                panic!(
                    "Early cancel emitted Failed instead of Canceled: {:?}",
                    ev.message
                );
            }
        }
        assert!(
            early_canceled,
            "expected Canceled event after cancel before first byte"
        );
        let leaked_info = std::env::temp_dir().join(format!("hyperdl_info_{early_job_id}.json"));
        assert!(
            !leaked_info.exists(),
            "temp info.json must be cleaned up after cancel"
        );

        // Part 2: Cancel DURING active transfer (if mid-flight progress arrives before completion) and resume.
        let job_id = manager
            .start_download(StartDownloadRequest {
                url: reel_url.into(),
                title: Some(inspection.title.clone()),
                selection,
                output_directory: Some(temp_dir.path().to_string_lossy().into_owned()),
            })
            .await
            .expect("start_download succeeds");

        let mut canceled_mid_flight = false;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(180);
        let mut final_output: Option<String> = None;

        while tokio::time::Instant::now() < deadline {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(90), rx.recv())
                .await
                .expect("progress timeout")
                .expect("channel open");
            if ev.job_id != job_id {
                continue;
            }
            assert!(!(ev.phase == DownloadPhase::Downloading && ev.downloaded_bytes == 0));
            if ev.phase == DownloadPhase::Downloading
                && ev.downloaded_bytes > 0
                && !canceled_mid_flight
            {
                canceled_mid_flight = true;
                if manager.cancel_download(&job_id).await.is_ok() {
                    continue;
                }
            } else if ev.phase == DownloadPhase::Canceled {
                let resumed = manager
                    .resume_download(&job_id)
                    .await
                    .expect("resume_download succeeds after cancel");
                assert_eq!(resumed, job_id);
            } else if ev.phase == DownloadPhase::Completed {
                final_output = ev.output_path;
                break;
            } else if ev.phase == DownloadPhase::Failed {
                panic!("Instagram cancel/resume failed: {:?}", ev.message);
            }
        }

        let path = final_output.expect("completed output path after cancel/resume");
        let streams = ffprobe_streams(&path);
        assert!(streams.iter().any(|s| s["codec_type"] == "video"));
        assert!(streams.iter().any(|s| s["codec_type"] == "audio"));
    }
}
