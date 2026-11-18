use serde::{Deserialize, Serialize};

/// Precision level reported for a format's byte size.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FileSizeAccuracy {
    Exact,
    Estimated,
    Unknown,
}

/// Kind of media streams contained in a discovered format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum StreamKind {
    MuxedAudioVideo,
    VideoOnly,
    AudioOnly,
}

/// Confidence level for identifying the source video's original audio track.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AudioSelectionConfidence {
    ConfirmedOriginal,
    LikelyOriginal,
    SingleOrUnmarked,
    AmbiguousOrUnknown,
}

/// Metadata describing an audio track's language and originality signals.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AudioTrackMetadata {
    pub language: Option<String>,
    pub language_display_name: Option<String>,
    pub is_original: Option<bool>,
    pub is_default: Option<bool>,
    pub is_auto_dub: Option<bool>,
    pub selection_confidence: AudioSelectionConfidence,
    pub status_note: String,
}

/// Strategy used internally to produce a playable download for a selected quality.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FormatSelectionStrategy {
    CombinedAudioVideo,
    PairVideoAndAudioWithFfmpeg,
    AudioOnlyStream,
}

/// High-level user-facing video quality option representing a complete video with sound.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VideoQualityOption {
    pub resolution: String,
    pub height: Option<u32>,
    pub fps: Option<f64>,
    pub container: String,
    pub display_size: String,
    pub file_size_bytes: Option<u64>,
    pub size_accuracy: FileSizeAccuracy,
    pub video_format_id: String,
    pub selected_audio_format_id: Option<String>,
    pub audio_language: Option<AudioTrackMetadata>,
    pub format_selection_strategy: FormatSelectionStrategy,
}

/// Curated user-facing audio-only quality option using the selected original audio track.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AudioQualityOption {
    pub quality_label: String,
    pub container: String,
    pub bitrate_kbps: Option<f64>,
    pub display_size: String,
    pub file_size_bytes: Option<u64>,
    pub size_accuracy: FileSizeAccuracy,
    pub format_id: String,
    pub audio_language: Option<AudioTrackMetadata>,
}

/// A genuine media format discovered during URL inspection.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiscoveredFormat {
    pub format_id: String,
    pub container: String,
    pub stream_kind: StreamKind,
    pub resolution: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub fps: Option<f64>,
    pub vcodec: Option<String>,
    pub acodec: Option<String>,
    pub bitrate_kbps: Option<f64>,
    pub file_size_bytes: Option<u64>,
    pub size_accuracy: FileSizeAccuracy,
    pub format_note: Option<String>,
}

/// Metadata and genuinely available options/formats extracted for a media URL.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaInspection {
    pub id: String,
    pub title: String,
    pub uploader: Option<String>,
    pub duration_seconds: Option<f64>,
    pub thumbnail_url: Option<String>,
    pub webpage_url: String,
    pub provider_name: String,
    pub original_audio: Option<AudioTrackMetadata>,
    pub video_options: Vec<VideoQualityOption>,
    pub audio_options: Vec<AudioQualityOption>,
    pub formats: Vec<DiscoveredFormat>,
}

/// Distinguishes single-format downloads from separate video+audio FFmpeg merges.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DownloadSelectionKind {
    Single,
    VideoAndAudio,
}

/// User-chosen format specification for a download job.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DownloadFormatSelection {
    pub kind: DownloadSelectionKind,
    pub format_id: Option<String>,
    pub video_format_id: Option<String>,
    pub audio_format_id: Option<String>,
    pub merge_container: Option<String>,
}

impl DownloadFormatSelection {
    /// Constructs a single-stream/muxed format selection by its discovered format ID.
    #[flutter_rust_bridge::frb(ignore)]
    pub fn single(format_id: impl Into<String>) -> Self {
        Self {
            kind: DownloadSelectionKind::Single,
            format_id: Some(format_id.into()),
            video_format_id: None,
            audio_format_id: None,
            merge_container: None,
        }
    }

    /// Constructs a separate video + audio merge selection targeting `merge_container`.
    #[flutter_rust_bridge::frb(ignore)]
    pub fn video_and_audio(
        video_format_id: impl Into<String>,
        audio_format_id: impl Into<String>,
        merge_container: impl Into<String>,
    ) -> Self {
        Self {
            kind: DownloadSelectionKind::VideoAndAudio,
            format_id: None,
            video_format_id: Some(video_format_id.into()),
            audio_format_id: Some(audio_format_id.into()),
            merge_container: Some(merge_container.into()),
        }
    }
}

/// Request payload to start a single download job.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StartDownloadRequest {
    pub url: String,
    pub title: Option<String>,
    pub selection: DownloadFormatSelection,
    pub output_directory: Option<String>,
}

/// High-level lifecycle phase emitted for a download job.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DownloadPhase {
    Analyzing,
    Downloading,
    Merging,
    Completed,
    Canceled,
    Failed,
}

/// Incremental progress update streamed from Rust to Flutter.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DownloadProgressEvent {
    pub job_id: String,
    pub phase: DownloadPhase,
    pub downloaded_bytes: u64,
    pub total_bytes: Option<u64>,
    pub is_total_estimated: bool,
    pub speed_bytes_per_sec: Option<f64>,
    pub eta_seconds: Option<u64>,
    pub output_path: Option<String>,
    pub message: Option<String>,
}
