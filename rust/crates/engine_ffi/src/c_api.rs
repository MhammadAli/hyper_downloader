//! Stateless C-ABI JSON bridge exposing the canonical Rust inspection,
//! original-audio selection, playlist parsing, and size-estimation rules to
//! the Android Chaquopy Python worker via `ctypes.CDLL("libengine_ffi.so")`.

use crate::models::{MediaInspection, PlaylistInspection, PlaylistMediaMode, PlaylistQualityCap};
use crate::playlist::{
    build_playlist_size_estimate, is_playlist_url, normalize_playlist_url,
    parse_yt_dlp_playlist_json,
};
use crate::selection::select_playlist_item_option;
use crate::yt_dlp::{parse_yt_dlp_inspection_json, validate_media_url};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[derive(Serialize)]
struct OkEnvelope<T: Serialize> {
    ok: T,
}

#[derive(Serialize)]
struct ErrorEnvelope {
    error: String,
}

#[derive(Serialize)]
struct UrlClassification {
    is_playlist: bool,
    normalized_url: String,
}

#[derive(Deserialize)]
struct PlaylistSizeItemInput {
    order_index: u32,
    #[serde(default)]
    inspection: Option<MediaInspection>,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Deserialize)]
struct BuildPlaylistSizeEstimateInput {
    estimation_id: String,
    playlist: PlaylistInspection,
    media_mode: PlaylistMediaMode,
    quality_cap: PlaylistQualityCap,
    item_results: Vec<PlaylistSizeItemInput>,
    is_calculating: bool,
    was_canceled: bool,
}

fn cstr_to_str<'a>(ptr: *const c_char, arg_name: &str) -> Result<&'a str, String> {
    if ptr.is_null() {
        return Err(format!("Null pointer passed for '{arg_name}'."));
    }
    // SAFETY: Caller guarantees `ptr` points to a valid NUL-terminated UTF-8 C string.
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|e| format!("Invalid UTF-8 in '{arg_name}': {e}"))
}

fn serialize_result<T: Serialize>(result: Result<T, String>) -> *mut c_char {
    let json = match result {
        Ok(value) => serde_json::to_string(&OkEnvelope { ok: value })
            .unwrap_or_else(|e| format!(r#"{{"error":"Serialization failed: {e}"}}"#)),
        Err(message) => serde_json::to_string(&ErrorEnvelope { error: message })
            .unwrap_or_else(|_| r#"{"error":"Unknown engine error"}"#.to_string()),
    };

    // Replace any interior NUL byte defensively before converting to CString.
    let sanitized = if json.as_bytes().contains(&0) {
        json.replace('\0', "")
    } else {
        json
    };
    CString::new(sanitized)
        .unwrap_or_else(|_| CString::new(r#"{"error":"CString conversion failed"}"#).unwrap())
        .into_raw()
}

fn parse_enum_arg<T: DeserializeOwned>(raw: &str, arg_name: &str) -> Result<T, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(format!("Empty value passed for '{arg_name}'."));
    }
    if trimmed.starts_with('"') {
        serde_json::from_str::<T>(trimmed)
            .map_err(|e| format!("Invalid '{arg_name}' value '{trimmed}': {e}"))
    } else {
        let quoted = serde_json::to_string(trimmed).map_err(|e| e.to_string())?;
        serde_json::from_str::<T>(&quoted)
            .map_err(|e| format!("Invalid '{arg_name}' value '{trimmed}': {e}"))
    }
}

/// Parses raw `yt-dlp` single-video JSON into the canonical `MediaInspection`
/// (filtering storyboards/DRM and applying `selection.rs` original-audio rules).
///
/// # Safety
/// `raw_json` must be a valid NUL-terminated UTF-8 C string. Caller must free
/// the returned pointer using [`hyperdl_free_string`].
#[flutter_rust_bridge::frb(ignore)]
#[no_mangle]
pub unsafe extern "C" fn hyperdl_parse_media_inspection_json(
    raw_json: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let raw = cstr_to_str(raw_json, "raw_json")?;
        parse_yt_dlp_inspection_json(raw).map_err(|e| e.to_string())
    })();
    serialize_result(result)
}

/// Parses raw `yt-dlp --flat-playlist` JSON into the canonical `PlaylistInspection`.
///
/// # Safety
/// `raw_json` and `fallback_url` must be valid NUL-terminated UTF-8 C strings.
/// Caller must free the returned pointer using [`hyperdl_free_string`].
#[flutter_rust_bridge::frb(ignore)]
#[no_mangle]
pub unsafe extern "C" fn hyperdl_parse_playlist_inspection_json(
    raw_json: *const c_char,
    fallback_url: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let raw = cstr_to_str(raw_json, "raw_json")?;
        let fallback = cstr_to_str(fallback_url, "fallback_url")?;
        parse_yt_dlp_playlist_json(raw, fallback).map_err(|e| e.to_string())
    })();
    serialize_result(result)
}

/// Resolves the best playable format for a single playlist item using the canonical
/// `select_playlist_item_option` logic in `selection.rs`.
///
/// # Safety
/// All pointer arguments must be valid NUL-terminated UTF-8 C strings.
/// Caller must free the returned pointer using [`hyperdl_free_string`].
#[flutter_rust_bridge::frb(ignore)]
#[no_mangle]
pub unsafe extern "C" fn hyperdl_select_playlist_item_option_json(
    inspection_json: *const c_char,
    media_mode: *const c_char,
    quality_cap: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let raw_inspection = cstr_to_str(inspection_json, "inspection_json")?;
        let raw_mode = cstr_to_str(media_mode, "media_mode")?;
        let raw_cap = cstr_to_str(quality_cap, "quality_cap")?;

        let inspection: MediaInspection = serde_json::from_str(raw_inspection)
            .map_err(|e| format!("Invalid MediaInspection JSON: {e}"))?;
        let mode: PlaylistMediaMode = parse_enum_arg(raw_mode, "media_mode")?;
        let cap: PlaylistQualityCap = parse_enum_arg(raw_cap, "quality_cap")?;

        select_playlist_item_option(&inspection, mode, cap)
    })();
    serialize_result(result)
}

/// Computes an aggregate `PlaylistSizeEstimate` from per-item `MediaInspection`
/// results using the canonical `build_playlist_size_estimate` logic.
///
/// # Safety
/// `request_json` must be a valid NUL-terminated UTF-8 C string.
/// Caller must free the returned pointer using [`hyperdl_free_string`].
#[flutter_rust_bridge::frb(ignore)]
#[no_mangle]
pub unsafe extern "C" fn hyperdl_build_playlist_size_estimate_json(
    request_json: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let raw_req = cstr_to_str(request_json, "request_json")?;
        let parsed: BuildPlaylistSizeEstimateInput = serde_json::from_str(raw_req)
            .map_err(|e| format!("Invalid BuildPlaylistSizeEstimateInput JSON: {e}"))?;

        let mut results_map: HashMap<u32, Result<MediaInspection, String>> =
            HashMap::with_capacity(parsed.item_results.len());
        for entry in parsed.item_results {
            if let Some(insp) = entry.inspection {
                results_map.insert(entry.order_index, Ok(insp));
            } else if let Some(err) = entry.error {
                results_map.insert(entry.order_index, Err(err));
            }
        }

        Ok(build_playlist_size_estimate(
            &parsed.estimation_id,
            &parsed.playlist,
            parsed.media_mode,
            parsed.quality_cap,
            &results_map,
            parsed.is_calculating,
            parsed.was_canceled,
        ))
    })();
    serialize_result(result)
}

/// Validates an HTTP/HTTPS URL, detects whether it targets a playlist (ignoring
/// auto-generated YouTube `RD...` mixes), and returns the normalized URL.
///
/// # Safety
/// `raw_url` must be a valid NUL-terminated UTF-8 C string.
/// Caller must free the returned pointer using [`hyperdl_free_string`].
#[flutter_rust_bridge::frb(ignore)]
#[no_mangle]
pub unsafe extern "C" fn hyperdl_classify_url_json(raw_url: *const c_char) -> *mut c_char {
    let result = (|| {
        let raw = cstr_to_str(raw_url, "raw_url")?;
        let validated = validate_media_url(raw).map_err(|e| e.to_string())?;
        let playlist = is_playlist_url(&validated);
        let normalized_url = if playlist {
            normalize_playlist_url(&validated).map_err(|e| e.to_string())?
        } else {
            validated
        };
        Ok(UrlClassification {
            is_playlist: playlist,
            normalized_url,
        })
    })();
    serialize_result(result)
}

/// Frees a C string previously allocated by `hyperdl_*` functions.
///
/// # Safety
/// `ptr` must either be null or have been returned by a `hyperdl_*` function
/// and not yet freed.
#[flutter_rust_bridge::frb(ignore)]
#[no_mangle]
pub unsafe extern "C" fn hyperdl_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: `ptr` was produced by `CString::into_raw()` in `serialize_result`.
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{
        AudioSelectionConfidence, FileSizeAccuracy, FormatSelectionStrategy, PlaylistSizeEstimate,
        PlaylistSizeStatus,
    };
    use crate::selection::ResolvedPlaylistSelection;

    unsafe fn take_and_free(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null());
        // SAFETY: `ptr` is valid and allocated by `CString::into_raw`.
        let text = unsafe { CStr::from_ptr(ptr) }
            .to_str()
            .expect("valid utf8")
            .to_string();
        // SAFETY: Reclaiming pointer returned by `hyperdl_*`.
        unsafe { hyperdl_free_string(ptr) };
        text
    }

    #[derive(Deserialize)]
    struct TestOk<T> {
        ok: T,
    }

    #[test]
    fn c_api_parses_media_inspection_preserving_original_audio_over_dub() {
        let raw_json = r#"{
            "id": "multi-audio-1",
            "title": "Documentary",
            "language": "es",
            "webpage_url": "https://www.youtube.com/watch?v=multi-audio-1",
            "extractor_key": "Youtube",
            "formats": [
                {
                    "format_id": "251-dub",
                    "ext": "webm",
                    "vcodec": "none",
                    "acodec": "opus",
                    "abr": 160.0,
                    "filesize": 6000000,
                    "language": "en",
                    "url": "https://rr.example/videoplayback?xtags=acont%3Ddubbed-auto",
                    "format_note": "English - dubbed-auto"
                },
                {
                    "format_id": "140-orig",
                    "ext": "m4a",
                    "vcodec": "none",
                    "acodec": "mp4a.40.2",
                    "abr": 128.0,
                    "filesize": 5000000,
                    "language": "es",
                    "url": "https://rr.example/videoplayback?xtags=acont%3Doriginal",
                    "format_note": "Spanish original"
                },
                {
                    "format_id": "299",
                    "ext": "mp4",
                    "vcodec": "avc1.64002a",
                    "acodec": "none",
                    "width": 1920,
                    "height": 1080,
                    "fps": 60.0,
                    "filesize": 50000000
                }
            ]
        }"#;

        let c_raw = CString::new(raw_json).unwrap();
        let out_str = unsafe { take_and_free(hyperdl_parse_media_inspection_json(c_raw.as_ptr())) };
        let parsed: TestOk<MediaInspection> = serde_json::from_str(&out_str).expect("valid JSON");

        let insp = parsed.ok;
        let orig = insp.original_audio.as_ref().expect("original audio");
        assert_eq!(orig.language.as_deref(), Some("es"));
        assert_eq!(orig.is_original, Some(true));
        assert_eq!(
            orig.selection_confidence,
            AudioSelectionConfidence::ConfirmedOriginal
        );
        assert_eq!(insp.video_options.len(), 1);
        assert_eq!(
            insp.video_options[0].selected_audio_format_id.as_deref(),
            Some("140-orig")
        );
        assert_eq!(
            insp.video_options[0].format_selection_strategy,
            FormatSelectionStrategy::PairVideoAndAudioWithFfmpeg
        );
        assert_eq!(insp.audio_options.len(), 1);
        assert_eq!(insp.audio_options[0].format_id, "140-orig");
    }

    #[test]
    fn c_api_classifies_urls_and_parses_playlist_and_size_estimate() {
        let pl_url = CString::new("https://www.youtube.com/watch?v=abc&list=PL12345").unwrap();
        let cls_out = unsafe { take_and_free(hyperdl_classify_url_json(pl_url.as_ptr())) };
        let cls_val: serde_json::Value = serde_json::from_str(&cls_out).unwrap();
        assert_eq!(cls_val["ok"]["is_playlist"], true);
        assert_eq!(
            cls_val["ok"]["normalized_url"],
            "https://www.youtube.com/playlist?list=PL12345"
        );

        let mix_url = CString::new("https://www.youtube.com/watch?v=abc&list=RDabc").unwrap();
        let mix_out = unsafe { take_and_free(hyperdl_classify_url_json(mix_url.as_ptr())) };
        let mix_val: serde_json::Value = serde_json::from_str(&mix_out).unwrap();
        assert_eq!(mix_val["ok"]["is_playlist"], false);

        let pl_json = CString::new(
            r#"{
            "id": "PL12345",
            "title": "Test Playlist",
            "extractor_key": "YoutubeTab",
            "entries": [
                {"id": "v1", "title": "First", "url": "https://www.youtube.com/watch?v=v1"},
                {"id": "v2", "title": "[Private video]", "availability": "private"}
            ]
        }"#,
        )
        .unwrap();
        let fallback = CString::new("https://www.youtube.com/playlist?list=PL12345").unwrap();
        let pl_out = unsafe {
            take_and_free(hyperdl_parse_playlist_inspection_json(
                pl_json.as_ptr(),
                fallback.as_ptr(),
            ))
        };
        let pl_parsed: TestOk<PlaylistInspection> = serde_json::from_str(&pl_out).unwrap();
        assert_eq!(pl_parsed.ok.entries.len(), 2);

        let item_json = CString::new(
            r#"{
            "id": "v1",
            "title": "First",
            "webpage_url": "https://www.youtube.com/watch?v=v1",
            "provider_name": "Youtube",
            "video_options": [
                {
                    "resolution": "1080p",
                    "height": 1080,
                    "fps": 30.0,
                    "container": "mp4",
                    "display_size": "20.00 MB (Exact)",
                    "file_size_bytes": 20971520,
                    "size_accuracy": "Exact",
                    "video_format_id": "137",
                    "selected_audio_format_id": "140",
                    "audio_language": null,
                    "format_selection_strategy": "PairVideoAndAudioWithFfmpeg"
                },
                {
                    "resolution": "720p",
                    "height": 720,
                    "fps": 30.0,
                    "container": "mp4",
                    "display_size": "10.00 MB (Exact)",
                    "file_size_bytes": 10485760,
                    "size_accuracy": "Exact",
                    "video_format_id": "22",
                    "selected_audio_format_id": null,
                    "audio_language": null,
                    "format_selection_strategy": "CombinedAudioVideo"
                }
            ],
            "audio_options": [],
            "formats": []
        }"#,
        )
        .unwrap();
        let mode = CString::new("VideoWithSound").unwrap();
        let cap = CString::new("UpTo720p").unwrap();
        let sel_out = unsafe {
            take_and_free(hyperdl_select_playlist_item_option_json(
                item_json.as_ptr(),
                mode.as_ptr(),
                cap.as_ptr(),
            ))
        };
        let sel_parsed: TestOk<ResolvedPlaylistSelection> = serde_json::from_str(&sel_out).unwrap();
        assert_eq!(sel_parsed.ok.selection.format_id.as_deref(), Some("22"));
        assert_eq!(sel_parsed.ok.expected_size_bytes, Some(10_485_760));
        assert_eq!(sel_parsed.ok.size_accuracy, FileSizeAccuracy::Exact);

        let est_req = serde_json::json!({
            "estimation_id": "est-1",
            "playlist": pl_parsed.ok,
            "media_mode": "VideoWithSound",
            "quality_cap": "UpTo720p",
            "item_results": [
                {
                    "order_index": 0,
                    "inspection": serde_json::from_str::<serde_json::Value>(item_json.to_str().unwrap()).unwrap()
                }
            ],
            "is_calculating": false,
            "was_canceled": false
        });
        let c_est_req = CString::new(est_req.to_string()).unwrap();
        let est_out = unsafe {
            take_and_free(hyperdl_build_playlist_size_estimate_json(
                c_est_req.as_ptr(),
            ))
        };
        let est_parsed: TestOk<PlaylistSizeEstimate> = serde_json::from_str(&est_out).unwrap();
        assert_eq!(est_parsed.ok.status, PlaylistSizeStatus::Exact);
        assert_eq!(est_parsed.ok.known_total_bytes, 10_485_760);
        assert_eq!(est_parsed.ok.unavailable_count, 1);
    }
}
