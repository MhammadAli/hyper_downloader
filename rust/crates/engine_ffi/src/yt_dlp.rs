//! `yt-dlp` subprocess wrapper, structured JSON/progress parsing, and single-job
//! lifecycle management for Phase 2B.

use crate::frb_generated::StreamSink;
use crate::models::{
    DiscoveredFormat, DownloadPhase, DownloadProgressEvent, DownloadSelectionKind,
    FileSizeAccuracy, MediaInspection, StartDownloadRequest, StreamKind,
};
use crate::selection::{build_quality_options, extract_xtags_acont, RawFormatCandidate};
use crate::win_job::ProcessTreeJob;
use serde_json::Value;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::{broadcast, Mutex, Notify};
use url::Url;
use uuid::Uuid;

const DOWNLOAD_PROGRESS_TEMPLATE: &str =
    "download:HYPERDL|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s";
const POSTPROCESS_PROGRESS_TEMPLATE: &str =
    "postprocess:HYPERDL_PP|%(progress.status)s|%(progress.postprocessor)s";
const CANCEL_WAIT_TIMEOUT_SECS: u64 = 5;

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

/// Validates that `raw_url` is a syntactically valid `http://` or `https://` URL.
pub fn validate_media_url(raw_url: &str) -> Result<String, EngineError> {
    let trimmed = raw_url.trim();
    if trimmed.is_empty() {
        return Err(EngineError::InvalidUrl("Media URL cannot be empty.".into()));
    }

    let parsed = Url::parse(trimmed).map_err(|err| EngineError::InvalidUrl(err.to_string()))?;
    match parsed.scheme() {
        "http" | "https" => {}
        other => {
            return Err(EngineError::InvalidUrl(format!(
                "Unsupported URL scheme '{other}'. Only http and https URLs are supported."
            )));
        }
    }
    if parsed.host_str().is_none_or(str::is_empty) {
        return Err(EngineError::InvalidUrl(
            "Media URL must include a host.".into(),
        ));
    }

    Ok(trimmed.to_string())
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

    let formats_val = obj.get("formats").and_then(Value::as_array);
    if formats_val.is_none() && obj.get("_type").and_then(Value::as_str) == Some("playlist") {
        return Err(EngineError::InvalidRequest(
            "Playlist URLs are not supported in single-video inspection yet. Please enter a single video URL."
                .into(),
        ));
    }
    let raw_formats = formats_val.ok_or_else(|| {
        EngineError::JsonParse("Missing 'formats' array in yt-dlp output.".into())
    })?;

    let id = json_non_empty_str(obj.get("id"))
        .ok_or_else(|| EngineError::JsonParse("Missing media 'id' in yt-dlp output.".into()))?;
    let title = json_non_empty_str(obj.get("title")).unwrap_or_else(|| id.clone());
    let uploader = json_non_empty_str(obj.get("uploader"))
        .or_else(|| json_non_empty_str(obj.get("channel")))
        .or_else(|| json_non_empty_str(obj.get("creator")));
    let duration_seconds =
        json_f64(obj.get("duration")).or_else(|| json_f64(obj.get("duration_seconds")));
    let thumbnail_url = extract_thumbnail_url(obj);
    let webpage_url = json_non_empty_str(obj.get("webpage_url"))
        .or_else(|| json_non_empty_str(obj.get("original_url")))
        .unwrap_or_default();
    let provider_name = json_non_empty_str(obj.get("extractor_key"))
        .or_else(|| json_non_empty_str(obj.get("extractor")))
        .unwrap_or_else(|| infer_provider_from_url(&webpage_url));
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

    let synthesized = build_quality_options(&candidates, video_language.as_deref());
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

fn extract_thumbnail_url(obj: &serde_json::Map<String, Value>) -> Option<String> {
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

fn infer_provider_from_url(url: &str) -> String {
    Url::parse(url)
        .ok()
        .and_then(|parsed| parsed.host_str().map(str::to_string))
        .map(|host| {
            if host.contains("youtube.com") || host.contains("youtu.be") {
                "YouTube".to_string()
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

    let vcodec = normalize_codec(obj.get("vcodec"));
    let acodec = normalize_codec(obj.get("acodec"));
    let audio_ext = normalize_codec(obj.get("audio_ext"));

    let has_video = vcodec.is_some();
    let has_audio = acodec.is_some()
        || (audio_ext.is_some()
            && json_non_empty_str(obj.get("resolution")).as_deref() == Some("audio only"));

    // Exclude storyboards and container-only entries carrying neither audio nor video.
    if container.eq_ignore_ascii_case("mhtml") || (!has_video && !has_audio) {
        return None;
    }

    let stream_kind = match json_non_empty_str(obj.get("stream_kind")).as_deref() {
        Some("muxed_av") => StreamKind::MuxedAudioVideo,
        Some("video_only") => StreamKind::VideoOnly,
        Some("audio_only") => StreamKind::AudioOnly,
        _ => match (has_video, has_audio) {
            (true, true) => StreamKind::MuxedAudioVideo,
            (true, false) => StreamKind::VideoOnly,
            (false, true) => StreamKind::AudioOnly,
            (false, false) => return None,
        },
    };

    let width = json_u32(obj.get("width"));
    let height = json_u32(obj.get("height"));
    let resolution =
        json_non_empty_str(obj.get("resolution")).unwrap_or_else(|| match (width, height) {
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

fn json_non_empty_str(val: Option<&Value>) -> Option<String> {
    let s = val?.as_str()?.trim();
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

fn json_u64(val: Option<&Value>) -> Option<u64> {
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

fn json_f64(val: Option<&Value>) -> Option<f64> {
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
    args.push(OsString::from("--"));
    args.push(OsString::from(validated_url));

    Ok(args)
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

fn configure_subprocess(cmd: &mut Command) {
    // Ensure Python inside standalone `yt-dlp.exe` always emits valid UTF-8 paths
    // on Windows pipes (critical for Arabic and non-ASCII video titles).
    cmd.env("PYTHONUTF8", "1");
    cmd.env("PYTHONIOENCODING", "utf-8");
    #[cfg(windows)]
    {
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
}

fn shared_runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("hyperdl-engine")
            .build()
            .expect("failed to initialize Tokio runtime")
    })
}

/// Inspects `url` with the local `yt-dlp` binary and returns typed metadata + formats.
pub async fn inspect_media_async(url: &str) -> Result<MediaInspection, EngineError> {
    let validated = validate_media_url(url)?;
    let paths = ToolPaths::resolve()?;
    inspect_media_with_paths(&paths, &validated).await
}

async fn inspect_media_with_paths(
    paths: &ToolPaths,
    validated_url: &str,
) -> Result<MediaInspection, EngineError> {
    let args = build_inspect_args(paths, validated_url);
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
                "yt-dlp inspection exited with non-zero status".into()
            } else {
                stderr
            },
        });
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_yt_dlp_inspection_json(&stdout)
}

#[derive(Debug)]
struct ActiveJobState {
    job_id: String,
    request: StartDownloadRequest,
    output_template: String,
    is_running: bool,
    cancel_requested: Arc<AtomicBool>,
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
        request: StartDownloadRequest,
    ) -> Result<String, EngineError> {
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

        let output_template = output_dir
            .join("%(title).100B [%(id)s] [%(format_id)s].%(ext)s")
            .to_string_lossy()
            .into_owned();

        // Validate arguments before recording active job state.
        let args = build_download_args(&paths, &request, &output_template)?;
        let job_id = Uuid::new_v4().to_string();

        self.launch_job(job_id.clone(), request, output_template, paths, args)
            .await?;
        Ok(job_id)
    }

    /// Cancels an active download job by killing its process tree and releasing `.part` locks.
    pub async fn cancel_download(&self, job_id: &str) -> Result<(), EngineError> {
        let (cancel_flag, process_job, done_notify) = {
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
                state.process_job.clone(),
                state.done_notify.clone(),
            )
        };

        let _ = cancel_flag;
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

        let paths = ToolPaths::resolve()?;
        let args = build_download_args(&paths, &request, &output_template)?;
        self.launch_job(job_id.to_string(), request, output_template, paths, args)
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
    ) -> Result<(), EngineError> {
        let cancel_requested = Arc::new(AtomicBool::new(false));
        let done_notify = Arc::new(Notify::new());

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
                request,
                output_template,
                is_running: true,
                cancel_requested: cancel_requested.clone(),
                process_job: None,
                done_notify: done_notify.clone(),
            });
        }

        let _ = self.tx.send(DownloadProgressEvent {
            job_id: job_id.clone(),
            phase: DownloadPhase::Analyzing,
            downloaded_bytes: 0,
            total_bytes: None,
            is_total_estimated: false,
            speed_bytes_per_sec: None,
            eta_seconds: None,
            output_path: None,
            message: Some("Preparing yt-dlp download...".into()),
        });

        let manager = self.clone();
        shared_runtime().spawn(async move {
            manager
                .run_download_worker(job_id, paths, args, cancel_requested, done_notify)
                .await;
        });

        Ok(())
    }

    async fn run_download_worker(
        self: Arc<Self>,
        job_id: String,
        paths: ToolPaths,
        args: Vec<OsString>,
        cancel_requested: Arc<AtomicBool>,
        done_notify: Arc<Notify>,
    ) {
        let path_record_file = std::env::temp_dir().join(format!("hyperdl_path_{job_id}.txt"));
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
                self.finish_job(&job_id, false, None).await;
                let _ = self.tx.send(DownloadProgressEvent {
                    job_id,
                    phase: DownloadPhase::Failed,
                    downloaded_bytes: 0,
                    total_bytes: None,
                    is_total_estimated: false,
                    speed_bytes_per_sec: None,
                    eta_seconds: None,
                    output_path: None,
                    message: Some(format!("Failed to launch yt-dlp: {err}")),
                });
                done_notify.notify_waiters();
                return;
            }
        };

        if let Ok(proc_job) = ProcessTreeJob::attach(&child) {
            let proc_arc = Arc::new(proc_job);
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

        if let Some(out_stream) = stdout {
            let mut reader = BufReader::new(out_stream);
            let mut raw_buf = Vec::with_capacity(512);
            loop {
                raw_buf.clear();
                match reader.read_until(b'\n', &mut raw_buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                if cancel_requested.load(Ordering::SeqCst) {
                    break;
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
                        if last_phase != DownloadPhase::Merging {
                            last_phase = DownloadPhase::Downloading;
                        }
                        let msg = if status == "finished" {
                            Some("Stream finished, finalizing...".into())
                        } else {
                            None
                        };
                        let _ = self.tx.send(DownloadProgressEvent {
                            job_id: job_id.clone(),
                            phase: DownloadPhase::Downloading,
                            downloaded_bytes,
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
                            job_id: job_id.clone(),
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
                    }
                    ParsedYtDlpLine::Other => {}
                }
            }
        }

        let wait_result = child.wait().await;
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

        self.finish_job(&job_id, false, None).await;

        let final_event = if cancel_requested.load(Ordering::SeqCst) {
            DownloadProgressEvent {
                job_id: job_id.clone(),
                phase: DownloadPhase::Canceled,
                downloaded_bytes: last_downloaded,
                total_bytes: last_total,
                is_total_estimated: last_estimated,
                speed_bytes_per_sec: None,
                eta_seconds: None,
                output_path: recorded_output_path.or(detected_output_path),
                message: Some("Download canceled. Partial data preserved for resume.".into()),
            }
        } else {
            match wait_result {
                Ok(status) if status.success() => {
                    let final_output_path = recorded_output_path.or(detected_output_path);
                    let final_disk_bytes = match final_output_path.as_deref() {
                        Some(path) => tokio::fs::metadata(path).await.ok().map(|m| m.len()),
                        None => None,
                    };
                    let final_total = final_disk_bytes.or(last_total);
                    DownloadProgressEvent {
                        job_id: job_id.clone(),
                        phase: DownloadPhase::Completed,
                        downloaded_bytes: final_total.unwrap_or(last_downloaded),
                        total_bytes: final_total,
                        is_total_estimated: if final_disk_bytes.is_some() {
                            false
                        } else {
                            last_estimated
                        },
                        speed_bytes_per_sec: None,
                        eta_seconds: Some(0),
                        output_path: final_output_path,
                        message: Some("Download completed.".into()),
                    }
                }
                Ok(status) => {
                    let msg = if stderr_text.trim().is_empty() {
                        format!("yt-dlp exited with code {:?}", status.code())
                    } else {
                        stderr_text.trim().to_string()
                    };
                    DownloadProgressEvent {
                        job_id: job_id.clone(),
                        phase: DownloadPhase::Failed,
                        downloaded_bytes: last_downloaded,
                        total_bytes: last_total,
                        is_total_estimated: last_estimated,
                        speed_bytes_per_sec: None,
                        eta_seconds: None,
                        output_path: detected_output_path,
                        message: Some(msg),
                    }
                }
                Err(err) => DownloadProgressEvent {
                    job_id: job_id.clone(),
                    phase: DownloadPhase::Failed,
                    downloaded_bytes: last_downloaded,
                    total_bytes: last_total,
                    is_total_estimated: last_estimated,
                    speed_bytes_per_sec: None,
                    eta_seconds: None,
                    output_path: detected_output_path,
                    message: Some(format!("Failed waiting for yt-dlp process: {err}")),
                },
            }
        };

        let _ = self.tx.send(final_event);
        done_notify.notify_waiters();
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::DownloadFormatSelection;
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
}
