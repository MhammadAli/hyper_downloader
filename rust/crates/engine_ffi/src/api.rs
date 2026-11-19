use crate::frb_generated::StreamSink;
pub use crate::models::{
    AudioQualityOption, AudioSelectionConfidence, AudioTrackMetadata, DiscoveredFormat,
    DownloadFormatSelection, DownloadPhase, DownloadProgressEvent, DownloadSelectionKind,
    EstimatePlaylistSizeRequest, FileSizeAccuracy, FormatSelectionStrategy, InspectionTargetKind,
    MediaInspection, PlaylistEntryAvailability, PlaylistEntrySummary, PlaylistEventKind,
    PlaylistInspection, PlaylistItemSizeInfo, PlaylistItemState, PlaylistItemStatus,
    PlaylistMediaMode, PlaylistProgressEvent, PlaylistQualityCap, PlaylistSessionSnapshot,
    PlaylistSizeEstimate, PlaylistSizeStatus, StartDownloadRequest, StartPlaylistDownloadRequest,
    StreamKind, UrlInspectionResult, VideoQualityOption,
};
use crate::playlist::{inspect_url_async, PlaylistManager};
use crate::yt_dlp::{inspect_media_async, DownloadManager};

/// Health check exposed over Flutter Rust Bridge.
#[flutter_rust_bridge::frb(sync)]
pub fn ping() -> String {
    "pong".to_string()
}

/// Returns the Rust engine crate version.
#[flutter_rust_bridge::frb(sync)]
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Initializes FRB defaults for the Rust engine.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Inspects any URL and detects whether it is a single video or a full playlist.
pub async fn inspect_url(url: String) -> Result<UrlInspectionResult, String> {
    inspect_url_async(&url).await.map_err(|err| err.to_string())
}

/// Inspects a media URL using the local `yt-dlp` binary and returns metadata and formats.
pub async fn inspect_media(url: String) -> Result<MediaInspection, String> {
    inspect_media_async(&url)
        .await
        .map_err(|err| err.to_string())
}

/// Starts a single download (or video+audio FFmpeg merge) job and returns its job ID.
pub async fn start_download(request: StartDownloadRequest) -> Result<String, String> {
    DownloadManager::global()
        .start_download(request)
        .await
        .map_err(|err| err.to_string())
}

/// Cancels a running download job by terminating its full subprocess tree.
pub async fn cancel_download(job_id: String) -> Result<(), String> {
    DownloadManager::global()
        .cancel_download(&job_id)
        .await
        .map_err(|err| err.to_string())
}

/// Resumes a canceled or failed download job via `yt-dlp --continue`.
pub async fn resume_download(job_id: String) -> Result<String, String> {
    DownloadManager::global()
        .resume_download(&job_id)
        .await
        .map_err(|err| err.to_string())
}

/// Subscribes a Flutter stream sink to incremental Rust download progress events.
pub fn subscribe_download_progress(sink: StreamSink<DownloadProgressEvent>) -> Result<(), String> {
    DownloadManager::global().subscribe(sink);
    Ok(())
}

/// Starts sequential batch downloading for an enumerated playlist.
pub async fn start_playlist_download(
    request: StartPlaylistDownloadRequest,
) -> Result<PlaylistSessionSnapshot, String> {
    PlaylistManager::global()
        .start_playlist_download(request)
        .await
        .map_err(|err| err.to_string())
}

/// Pauses an active playlist download session while retaining completed files and partial progress.
pub async fn pause_playlist_download(session_id: String) -> Result<(), String> {
    PlaylistManager::global()
        .pause_playlist(&session_id)
        .await
        .map_err(|err| err.to_string())
}

/// Resumes a paused, canceled, or recovered playlist download session.
pub async fn resume_playlist_download(
    session_id: String,
) -> Result<PlaylistSessionSnapshot, String> {
    PlaylistManager::global()
        .resume_playlist(&session_id)
        .await
        .map_err(|err| err.to_string())
}

/// Cancels remaining playlist items cleanly while preserving completed downloads.
pub async fn cancel_playlist_download(session_id: String) -> Result<(), String> {
    PlaylistManager::global()
        .cancel_playlist(&session_id)
        .await
        .map_err(|err| err.to_string())
}

/// Retries all failed items inside a playlist download session without re-downloading completed items.
pub async fn retry_failed_playlist_items(
    session_id: String,
) -> Result<PlaylistSessionSnapshot, String> {
    PlaylistManager::global()
        .retry_failed(&session_id)
        .await
        .map_err(|err| err.to_string())
}

/// Loads any saved persistent playlist manifest from disk so interrupted batches can resume.
pub async fn load_saved_playlist_session(
    playlist_id: String,
    output_directory: Option<String>,
) -> Result<Option<PlaylistSessionSnapshot>, String> {
    PlaylistManager::global()
        .load_saved_session(&playlist_id, output_directory)
        .await
        .map_err(|err| err.to_string())
}

/// Subscribes a Flutter stream sink to incremental playlist batch progress events.
pub fn subscribe_playlist_progress(sink: StreamSink<PlaylistProgressEvent>) -> Result<(), String> {
    PlaylistManager::global().subscribe(sink);
    Ok(())
}

/// Calculates or recalculates total expected playlist size using cached per-item format metadata.
pub async fn estimate_playlist_size(
    request: EstimatePlaylistSizeRequest,
) -> Result<PlaylistSizeEstimate, String> {
    PlaylistManager::global()
        .estimate_playlist_size(request)
        .await
        .map_err(|err| err.to_string())
}

/// Cancels an active playlist size calculation while retaining already-cached item inspections.
pub async fn cancel_playlist_size_estimation(estimation_id: String) -> Result<(), String> {
    PlaylistManager::global()
        .cancel_size_estimation(&estimation_id)
        .await
        .map_err(|err| err.to_string())
}

/// Subscribes a Flutter stream sink to progressive playlist total size estimation updates.
pub fn subscribe_playlist_size_estimate(
    sink: StreamSink<PlaylistSizeEstimate>,
) -> Result<(), String> {
    PlaylistManager::global().subscribe_size_estimates(sink);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ping_returns_pong() {
        assert_eq!(ping(), "pong");
    }

    #[test]
    fn engine_version_matches_cargo_package() {
        assert_eq!(engine_version(), "0.1.0");
    }
}
