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

/// Identifies whether an analyzed URL points to a single video or a playlist.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum InspectionTargetKind {
    SingleVideo,
    Playlist,
}

/// Availability state reported for a playlist entry during flat enumeration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PlaylistEntryAvailability {
    Available,
    Private,
    Removed,
    Unavailable,
}

/// Metadata summary for one entry inside an enumerated playlist.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlaylistEntrySummary {
    pub order_index: u32,
    pub video_id: String,
    pub title: String,
    pub url: String,
    pub uploader: Option<String>,
    pub duration_seconds: Option<f64>,
    pub thumbnail_url: Option<String>,
    pub availability: PlaylistEntryAvailability,
    pub availability_reason: Option<String>,
}

/// Complete playlist inspection metadata and ordered entry list.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlaylistInspection {
    pub id: String,
    pub title: String,
    pub uploader: Option<String>,
    pub thumbnail_url: Option<String>,
    pub webpage_url: String,
    pub provider_name: String,
    pub total_item_count: u32,
    pub entries: Vec<PlaylistEntrySummary>,
}

/// Unified result returned when analyzing any single-video or playlist URL.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UrlInspectionResult {
    pub kind: InspectionTargetKind,
    pub video: Option<MediaInspection>,
    pub playlist: Option<PlaylistInspection>,
}

/// Output mode selected for a playlist download batch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PlaylistMediaMode {
    VideoWithSound,
    AudioOnly,
}

/// Upper quality cap applied per playlist item without fabricating unavailable streams.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PlaylistQualityCap {
    BestAvailable,
    UpTo1080p,
    UpTo720p,
    UpTo480p,
}

/// Lifecycle state tracked for each individual playlist item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PlaylistItemStatus {
    Pending,
    Analyzing,
    Ready,
    Downloading,
    Merging,
    Completed,
    Failed,
    Skipped,
    Canceled,
}

/// Per-item runtime and persisted status inside a playlist session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlaylistItemState {
    pub order_index: u32,
    pub video_id: String,
    pub title: String,
    pub url: String,
    pub duration_seconds: Option<f64>,
    pub thumbnail_url: Option<String>,
    pub status: PlaylistItemStatus,
    pub selected_quality: Option<String>,
    pub audio_language: Option<AudioTrackMetadata>,
    pub downloaded_bytes: u64,
    pub total_bytes: Option<u64>,
    pub is_total_estimated: bool,
    pub output_path: Option<String>,
    pub error_message: Option<String>,
}

/// Lightweight persistent manifest & UI snapshot for a playlist download session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlaylistSessionSnapshot {
    pub session_id: String,
    pub playlist_id: String,
    pub playlist_title: String,
    pub playlist_url: String,
    pub uploader: Option<String>,
    pub thumbnail_url: Option<String>,
    pub output_directory: String,
    pub media_mode: PlaylistMediaMode,
    pub quality_cap: PlaylistQualityCap,
    pub is_running: bool,
    pub is_paused: bool,
    pub completed_count: u32,
    pub failed_count: u32,
    pub skipped_count: u32,
    pub total_count: u32,
    pub items: Vec<PlaylistItemState>,
}

/// Request payload to start downloading a previously inspected playlist.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StartPlaylistDownloadRequest {
    pub playlist: PlaylistInspection,
    pub media_mode: PlaylistMediaMode,
    pub quality_cap: PlaylistQualityCap,
    pub output_directory: Option<String>,
}

/// Event discriminator for structured playlist batch progress reporting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PlaylistEventKind {
    PlaylistStarted,
    PlaylistItemStarted,
    PlaylistItemProgress,
    PlaylistItemMerging,
    PlaylistItemCompleted,
    PlaylistItemFailed,
    PlaylistItemSkipped,
    PlaylistPaused,
    PlaylistCanceled,
    PlaylistCompleted,
}

/// Incremental playlist batch and active-item progress streamed to Flutter.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlaylistProgressEvent {
    pub session_id: String,
    pub kind: PlaylistEventKind,
    pub item_index: Option<u32>,
    pub item_status: Option<PlaylistItemStatus>,
    pub selected_quality: Option<String>,
    pub audio_language: Option<AudioTrackMetadata>,
    pub item_downloaded_bytes: u64,
    pub item_total_bytes: Option<u64>,
    pub item_is_total_estimated: bool,
    pub speed_bytes_per_sec: Option<f64>,
    pub eta_seconds: Option<u64>,
    pub output_path: Option<String>,
    pub completed_count: u32,
    pub failed_count: u32,
    pub skipped_count: u32,
    pub total_count: u32,
    pub playlist_output_dir: Option<String>,
    pub message: Option<String>,
}
