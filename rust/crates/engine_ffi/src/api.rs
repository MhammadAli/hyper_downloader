use crate::frb_generated::StreamSink;
pub use crate::models::{
    AudioQualityOption, AudioSelectionConfidence, AudioTrackMetadata, DiscoveredFormat,
    DownloadFormatSelection, DownloadPhase, DownloadProgressEvent, DownloadSelectionKind,
    FileSizeAccuracy, FormatSelectionStrategy, MediaInspection, StartDownloadRequest, StreamKind,
    VideoQualityOption,
};
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
