//! Platform detection and canonical URL normalization for supported media hosts.

use crate::yt_dlp::EngineError;
use url::Url;

const RESERVED_INSTAGRAM_ROUTES: &[&str] = &[
    "stories", "explore", "accounts", "direct", "p", "tv", "live", "api", "graphql", "share",
    "reel", "reels",
];

/// High-level media platform inferred from a validated URL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaPlatform {
    YouTube,
    InstagramReel,
    Other,
}

/// Validated URL paired with its canonical downstream form and detected platform.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizedMediaUrl {
    pub platform: MediaPlatform,
    pub normalized_url: String,
    pub shortcode: Option<String>,
}

/// Returns `true` when `host` is `instagram.com` or any subdomain such as `www.` or `m.`.
pub fn is_instagram_host(host: &str) -> bool {
    let lower = host.trim().trim_end_matches('.').to_ascii_lowercase();
    lower == "instagram.com" || lower.ends_with(".instagram.com")
}

/// Returns `true` when `host` belongs to YouTube (`youtube.com`, `youtu.be`, or subdomains).
pub fn is_youtube_host(host: &str) -> bool {
    let lower = host.trim().trim_end_matches('.').to_ascii_lowercase();
    lower == "youtube.com"
        || lower.ends_with(".youtube.com")
        || lower == "youtu.be"
        || lower.ends_with(".youtu.be")
        || lower == "youtube-nocookie.com"
        || lower.ends_with(".youtube-nocookie.com")
}

/// Validates HTTP/HTTPS syntax, identifies supported platforms, normalizes supported
/// Instagram Reel URLs, and rejects unsupported Instagram URL types with clear errors.
pub fn classify_and_normalize_url(raw_url: &str) -> Result<NormalizedMediaUrl, EngineError> {
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

    let host = parsed
        .host_str()
        .filter(|h| !h.is_empty())
        .ok_or_else(|| EngineError::InvalidUrl("Media URL must include a host.".into()))?;

    if is_instagram_host(host) {
        return classify_instagram_url(&parsed);
    }

    let platform = if is_youtube_host(host) {
        MediaPlatform::YouTube
    } else {
        MediaPlatform::Other
    };

    Ok(NormalizedMediaUrl {
        platform,
        normalized_url: trimmed.to_string(),
        shortcode: None,
    })
}

fn classify_instagram_url(parsed: &Url) -> Result<NormalizedMediaUrl, EngineError> {
    let segments: Vec<&str> = parsed.path().split('/').filter(|s| !s.is_empty()).collect();

    let shortcode = match segments.as_slice() {
        [kind, code] if kind.eq_ignore_ascii_case("reel") || kind.eq_ignore_ascii_case("reels") => {
            Some(*code)
        }
        [user, kind, code]
            if (kind.eq_ignore_ascii_case("reel") || kind.eq_ignore_ascii_case("reels"))
                && !is_reserved_route(user) =>
        {
            Some(*code)
        }
        _ => None,
    };

    if let Some(code) = shortcode {
        if !is_valid_instagram_shortcode(code) {
            return Err(EngineError::InvalidUrl(
                "Invalid Instagram Reel URL: missing or malformed Reel shortcode.".into(),
            ));
        }

        #[cfg(target_os = "android")]
        {
            return Err(EngineError::InvalidRequest(
                "Instagram Reels are currently supported on Windows only.".into(),
            ));
        }

        #[cfg(not(target_os = "android"))]
        return Ok(NormalizedMediaUrl {
            platform: MediaPlatform::InstagramReel,
            normalized_url: format!("https://www.instagram.com/reel/{code}/"),
            shortcode: Some(code.to_string()),
        });
    }

    Err(EngineError::InvalidUrl(unsupported_instagram_message(
        &segments,
    )))
}

fn is_reserved_route(segment: &str) -> bool {
    let lower = segment.to_ascii_lowercase();
    RESERVED_INSTAGRAM_ROUTES.iter().any(|r| *r == lower)
}

fn is_valid_instagram_shortcode(code: &str) -> bool {
    (5..=40).contains(&code.len())
        && code
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn unsupported_instagram_message(segments: &[&str]) -> String {
    if segments.is_empty() {
        return "Instagram profile, feed, and bulk downloads are not supported. Please paste a single public Instagram Reel URL.".into();
    }

    let first = segments[0].to_ascii_lowercase();
    let second = segments.get(1).map(|s| s.to_ascii_lowercase());

    match first.as_str() {
        "stories" => {
            "Instagram Stories are not supported. Only public individual Instagram Reels are supported."
                .into()
        }
        "p" => {
            "Instagram posts and carousels (/p/) are not supported. Only public individual Instagram Reels are supported."
                .into()
        }
        "tv" => {
            "Instagram IGTV links (/tv/) are not supported. Only public individual Instagram Reels are supported."
                .into()
        }
        "live" => {
            "Instagram Live streams are not supported. Only public individual Instagram Reels are supported."
                .into()
        }
        "reel" | "reels" if segments.len() == 1 => {
            "The Instagram Reels feed cannot be downloaded. Please paste a direct public Instagram Reel URL."
                .into()
        }
        "reel" | "reels" if segments.len() == 2 => {
            "Invalid Instagram Reel URL: missing or malformed Reel shortcode.".into()
        }
        _ if second.as_deref() == Some("live") => {
            "Instagram Live streams are not supported. Only public individual Instagram Reels are supported."
                .into()
        }
        "explore" | "accounts" | "direct" | "share" => {
            "Instagram profile, feed, and bulk downloads are not supported. Please paste a single public Instagram Reel URL."
                .into()
        }
        _ if segments.len() == 1
            || (segments.len() == 2 && matches!(second.as_deref(), Some("reels") | Some("tagged"))) =>
        {
            "Instagram profile, feed, and bulk downloads are not supported. Please paste a single public Instagram Reel URL."
                .into()
        }
        _ => {
            "Unsupported Instagram URL. Only public individual Instagram Reel URLs (/reel/... or /reels/...) are supported."
                .into()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_supported_instagram_reel_url_variants() {
        let cases = [
            (
                "https://www.instagram.com/reel/DTVTvUDj-b1/",
                "https://www.instagram.com/reel/DTVTvUDj-b1/",
                "DTVTvUDj-b1",
            ),
            (
                "https://www.instagram.com/reels/Cop84x6u7CP/",
                "https://www.instagram.com/reel/Cop84x6u7CP/",
                "Cop84x6u7CP",
            ),
            (
                "https://instagram.com/reel/CDUMkliABpa?igsh=MzRlODBiNWFlZA==",
                "https://www.instagram.com/reel/CDUMkliABpa/",
                "CDUMkliABpa",
            ),
            (
                "https://m.instagram.com/reels/CWqAgUZgCku?utm_source=ig_web_copy_link",
                "https://www.instagram.com/reel/CWqAgUZgCku/",
                "CWqAgUZgCku",
            ),
            (
                "http://mobile.instagram.com/reel/AbCdE_12-34",
                "https://www.instagram.com/reel/AbCdE_12-34/",
                "AbCdE_12-34",
            ),
            (
                "https://www.instagram.com/marvelskies.fc/reel/CWqAgUZgCku/",
                "https://www.instagram.com/reel/CWqAgUZgCku/",
                "CWqAgUZgCku",
            ),
            (
                "  https://www.instagram.com/creator_1/reels/Cop84x6u7CP/?igsh=123  ",
                "https://www.instagram.com/reel/Cop84x6u7CP/",
                "Cop84x6u7CP",
            ),
        ];

        for (input, expected_url, expected_code) in cases {
            let parsed = classify_and_normalize_url(input)
                .unwrap_or_else(|e| panic!("Expected '{input}' to succeed, got: {e}"));
            assert_eq!(parsed.platform, MediaPlatform::InstagramReel);
            assert_eq!(parsed.normalized_url, expected_url);
            assert_eq!(parsed.shortcode.as_deref(), Some(expected_code));
        }
    }

    #[test]
    fn preserves_youtube_url_detection_and_avoids_host_spoofing() {
        for yt in [
            "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
            "https://www.youtube.com/shorts/aqz-KE-bpKQ",
            "https://youtu.be/aqz-KE-bpKQ",
            "https://www.youtube.com/playlist?list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd",
        ] {
            let parsed = classify_and_normalize_url(yt).expect("valid YouTube URL");
            assert_eq!(parsed.platform, MediaPlatform::YouTube);
            assert_eq!(parsed.normalized_url, yt);
            assert!(parsed.shortcode.is_none());
        }

        let unrelated = classify_and_normalize_url("https://notinstagram.com/reel/DTVTvUDj-b1/")
            .expect("non-Instagram host remains generic");
        assert_eq!(unrelated.platform, MediaPlatform::Other);
    }

    #[test]
    fn rejects_unsupported_and_invalid_instagram_urls_clearly() {
        let stories = classify_and_normalize_url("https://www.instagram.com/stories/nasa/12345/")
            .unwrap_err()
            .to_string();
        assert!(stories.contains("Stories"));

        let post = classify_and_normalize_url("https://www.instagram.com/p/C9abc123def/")
            .unwrap_err()
            .to_string();
        assert!(post.contains("/p/"));

        let igtv = classify_and_normalize_url("https://www.instagram.com/tv/BkfuX9UB-eK/")
            .unwrap_err()
            .to_string();
        assert!(igtv.contains("IGTV"));

        let live = classify_and_normalize_url("https://www.instagram.com/nasa/live/")
            .unwrap_err()
            .to_string();
        assert!(live.contains("Live"));

        let feed = classify_and_normalize_url("https://www.instagram.com/reels/")
            .unwrap_err()
            .to_string();
        assert!(feed.contains("Reels feed"));

        let profile = classify_and_normalize_url("https://www.instagram.com/nasa/")
            .unwrap_err()
            .to_string();
        assert!(profile.contains("profile"));

        let profile_reels = classify_and_normalize_url("https://www.instagram.com/nasa/reels/")
            .unwrap_err()
            .to_string();
        assert!(profile_reels.contains("profile"));

        let short_code = classify_and_normalize_url("https://www.instagram.com/reel/abc/")
            .unwrap_err()
            .to_string();
        assert!(short_code.contains("shortcode"));

        let extra_segment =
            classify_and_normalize_url("https://www.instagram.com/reel/DTVTvUDj-b1/comments/")
                .unwrap_err()
                .to_string();
        assert!(extra_segment.contains("Unsupported Instagram URL"));

        let bad_scheme =
            classify_and_normalize_url("ftp://www.instagram.com/reel/DTVTvUDj-b1/").unwrap_err();
        assert!(matches!(bad_scheme, EngineError::InvalidUrl(_)));
    }
}
