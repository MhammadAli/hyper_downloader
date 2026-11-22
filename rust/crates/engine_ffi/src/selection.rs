//! Original-audio track selection and high-level `VideoQualityOption` /
//! `AudioQualityOption` construction from genuinely discovered `yt-dlp` streams.

use crate::models::{
    AudioQualityOption, AudioSelectionConfidence, AudioTrackMetadata, DiscoveredFormat,
    DownloadFormatSelection, FileSizeAccuracy, FormatSelectionStrategy, MediaInspection,
    PlaylistMediaMode, PlaylistQualityCap, StreamKind, VideoQualityOption,
};
use std::collections::{BTreeMap, HashSet};

/// Enriched stream candidate extracted during `yt-dlp` JSON parsing.
#[derive(Debug, Clone)]
pub struct RawFormatCandidate {
    pub format: DiscoveredFormat,
    pub protocol: Option<String>,
    pub language: Option<String>,
    pub language_preference: Option<i32>,
    pub source_preference: Option<i32>,
    pub xtags_acont: Option<String>,
}

/// Complete high-level option synthesis returned alongside raw discovered formats.
#[derive(Debug, Clone)]
pub struct SynthesizedMediaOptions {
    pub original_audio: Option<AudioTrackMetadata>,
    pub video_options: Vec<VideoQualityOption>,
    pub audio_options: Vec<AudioQualityOption>,
}

/// Parses `acont=<tag>` from YouTube `xtags` or HLS `sgoap` URL query parameters.
pub fn extract_xtags_acont(raw_url: Option<&str>) -> Option<String> {
    let url = raw_url?.trim();
    if url.is_empty() {
        return None;
    }

    // Check URL-decoded representation so both `xtags=acont%3Doriginal` and raw strings match.
    let decoded = url
        .replace("%3D", "=")
        .replace("%3d", "=")
        .replace("%3A", ":")
        .replace("%3a", ":")
        .replace("%3B", ";")
        .replace("%3b", ";");

    let lower = decoded.to_ascii_lowercase();
    for marker in ["acont=", "acont:"] {
        if let Some(pos) = lower.find(marker) {
            let after = &lower[pos + marker.len()..];
            let value = after
                .split([':', '&', ';', ' '])
                .next()
                .map(str::trim)
                .unwrap_or("");
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    None
}

/// Synthesizes `original_audio`, `video_options` ("Video with Sound"), and
/// `audio_options` ("Audio Only") strictly from genuinely discovered streams.
pub fn build_quality_options(
    candidates: &[RawFormatCandidate],
    video_language: Option<&str>,
) -> SynthesizedMediaOptions {
    build_quality_options_for_platform(candidates, video_language, false)
}

/// Platform-aware variant of [`build_quality_options`] that avoids YouTube-specific
/// original/dubbing heuristics for single-track Instagram Reels while preserving
/// strict audio-required safety and honest option synthesis.
pub fn build_quality_options_for_platform(
    candidates: &[RawFormatCandidate],
    video_language: Option<&str>,
    is_instagram: bool,
) -> SynthesizedMediaOptions {
    let audio_candidates: Vec<&RawFormatCandidate> = candidates
        .iter()
        .filter(|c| c.format.stream_kind == StreamKind::AudioOnly)
        .collect();

    let muxed_candidates: Vec<&RawFormatCandidate> = candidates
        .iter()
        .filter(|c| c.format.stream_kind == StreamKind::MuxedAudioVideo)
        .collect();

    let video_only_candidates: Vec<&RawFormatCandidate> = candidates
        .iter()
        .filter(|c| c.format.stream_kind == StreamKind::VideoOnly)
        .collect();

    let (signals, selected_audio, initial_original_audio, winning_audio_meta) = if is_instagram {
        let signals = AudioEnvironmentSignals::default();
        let selected = select_preferred_audio_candidate(&audio_candidates, &signals, true);
        let meta = if selected.is_some() {
            Some(build_instagram_audio_metadata(selected))
        } else {
            None
        };
        (signals, selected, meta.clone(), meta)
    } else {
        let signals = analyze_audio_environment(&audio_candidates, video_language);
        let selected = select_preferred_audio_candidate(&audio_candidates, &signals, true);
        let (orig, winning) = match selected {
            Some(winner) => {
                let meta = build_audio_metadata(winner, &signals);
                (Some(meta.clone()), Some(meta))
            }
            None => (None, None),
        };
        (signals, selected, orig, winning)
    };
    let _ = selected_audio;

    let audio_options =
        build_audio_only_options(&audio_candidates, &signals, winning_audio_meta.as_ref());

    let video_options = build_video_with_sound_options_inner(
        &muxed_candidates,
        &video_only_candidates,
        &audio_candidates,
        &signals,
        winning_audio_meta.as_ref(),
        is_instagram,
    );

    let original_audio =
        if is_instagram && initial_original_audio.is_none() && !video_options.is_empty() {
            Some(build_instagram_audio_metadata(None))
        } else {
            initial_original_audio
        };

    SynthesizedMediaOptions {
        original_audio,
        video_options,
        audio_options,
    }
}

#[derive(Debug, Clone, Default)]
struct AudioEnvironmentSignals {
    normalized_video_lang: Option<String>,
    has_explicit_multi_audio_markers: bool,
    has_multiple_distinct_languages: bool,
    has_any_non_dub_track: bool,
}

fn analyze_audio_environment(
    audio_candidates: &[&RawFormatCandidate],
    video_language: Option<&str>,
) -> AudioEnvironmentSignals {
    let normalized_video_lang = video_language
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    let mut distinct_langs = HashSet::new();
    let mut has_explicit_multi_audio_markers = false;
    let mut has_any_non_dub_track = false;

    for cand in audio_candidates {
        if let Some(lang) = cand
            .language
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            distinct_langs.insert(primary_lang_tag(lang));
        }
        if is_explicit_original(cand)
            || is_explicit_dub(cand).0
            || cand.language_preference.is_some_and(|p| p > 0)
        {
            has_explicit_multi_audio_markers = true;
        }
        if !is_explicit_dub(cand).0 {
            has_any_non_dub_track = true;
        }
    }

    let has_multiple_distinct_languages = distinct_langs.len() > 1;
    if has_multiple_distinct_languages {
        has_explicit_multi_audio_markers = true;
    }

    AudioEnvironmentSignals {
        normalized_video_lang,
        has_explicit_multi_audio_markers,
        has_multiple_distinct_languages,
        has_any_non_dub_track,
    }
}

fn primary_lang_tag(tag: &str) -> String {
    tag.trim()
        .split(['-', '_'])
        .next()
        .unwrap_or(tag)
        .to_ascii_lowercase()
}

fn languages_match(a: &str, b: &str) -> bool {
    let ta = a.trim();
    let tb = b.trim();
    if ta.eq_ignore_ascii_case(tb) {
        return true;
    }
    primary_lang_tag(ta) == primary_lang_tag(tb)
}

fn is_explicit_original(cand: &RawFormatCandidate) -> bool {
    if cand.xtags_acont.as_deref() == Some("original") {
        return true;
    }
    if let Some(note) = cand.format.format_note.as_deref() {
        let lower = note.to_ascii_lowercase();
        if lower
            .split(|c: char| !c.is_ascii_alphanumeric())
            .any(|word| word == "original")
        {
            return true;
        }
    }
    false
}

/// Returns `(is_dub, is_auto_dub)`.
fn is_explicit_dub(cand: &RawFormatCandidate) -> (bool, bool) {
    match cand.xtags_acont.as_deref() {
        Some("dubbed-auto") => return (true, true),
        Some("dubbed") => return (true, false),
        _ => {}
    }
    if let Some(note) = cand.format.format_note.as_deref() {
        let lower = note.to_ascii_lowercase();
        if lower.contains("dubbed-auto") || lower.contains("auto-dub") {
            return (true, true);
        }
        if lower
            .split(|c: char| !c.is_ascii_alphanumeric())
            .any(|word| word == "dubbed")
        {
            return (true, false);
        }
    }
    (false, false)
}

fn is_default_marked(cand: &RawFormatCandidate) -> bool {
    if cand.language_preference.is_some_and(|p| p > 0) {
        return true;
    }
    cand.format
        .format_note
        .as_deref()
        .is_some_and(|n| n.to_ascii_lowercase().contains("(default)"))
}

fn originality_tier(cand: &RawFormatCandidate, signals: &AudioEnvironmentSignals) -> u8 {
    let (explicit_dub, _) = is_explicit_dub(cand);
    if explicit_dub {
        return 0;
    }
    if is_explicit_original(cand) {
        return 4;
    }
    if cand.language_preference.is_some_and(|p| p > 0) {
        return 3;
    }
    if let (Some(vid_lang), Some(fmt_lang)) = (
        signals.normalized_video_lang.as_deref(),
        cand.language.as_deref(),
    ) {
        if languages_match(vid_lang, fmt_lang) {
            return 2;
        }
    }
    1
}

fn is_https_direct(cand: &RawFormatCandidate) -> bool {
    !cand.protocol.as_deref().is_some_and(|p| p.contains("m3u8"))
}

fn is_drc_variant(cand: &RawFormatCandidate) -> bool {
    cand.format.format_id.ends_with("-drc")
        || cand
            .format
            .format_note
            .as_deref()
            .is_some_and(|n| n.to_ascii_lowercase().contains("drc"))
}

fn audio_container_rank(cand: &RawFormatCandidate, prefer_m4a: bool) -> u8 {
    let is_m4a = cand.format.container.eq_ignore_ascii_case("m4a")
        || cand
            .format
            .acodec
            .as_deref()
            .is_some_and(|c| c.starts_with("mp4a"));
    if prefer_m4a == is_m4a {
        2
    } else {
        1
    }
}

fn select_preferred_audio_candidate<'a>(
    audio_candidates: &[&'a RawFormatCandidate],
    signals: &AudioEnvironmentSignals,
    prefer_m4a: bool,
) -> Option<&'a RawFormatCandidate> {
    if audio_candidates.is_empty() {
        return None;
    }

    audio_candidates
        .iter()
        .copied()
        .max_by(|a, b| compare_audio_candidates(a, b, signals, prefer_m4a))
}

fn compare_audio_candidates(
    a: &RawFormatCandidate,
    b: &RawFormatCandidate,
    signals: &AudioEnvironmentSignals,
    prefer_m4a: bool,
) -> std::cmp::Ordering {
    let tier_a = originality_tier(a, signals);
    let tier_b = originality_tier(b, signals);
    tier_a
        .cmp(&tier_b)
        .then_with(|| is_https_direct(a).cmp(&is_https_direct(b)))
        .then_with(|| (!is_drc_variant(a)).cmp(&!is_drc_variant(b)))
        .then_with(|| audio_container_rank(a, prefer_m4a).cmp(&audio_container_rank(b, prefer_m4a)))
        .then_with(|| {
            let bra = a.format.bitrate_kbps.unwrap_or(0.0);
            let brb = b.format.bitrate_kbps.unwrap_or(0.0);
            bra.total_cmp(&brb)
        })
        .then_with(|| b.format.format_id.cmp(&a.format.format_id))
}

fn build_audio_metadata(
    cand: &RawFormatCandidate,
    signals: &AudioEnvironmentSignals,
) -> AudioTrackMetadata {
    let language = cand.language.clone().filter(|s| !s.is_empty());
    let language_display_name = extract_language_display_name(cand, language.as_deref());
    let (explicit_dub, explicit_auto_dub) = is_explicit_dub(cand);
    let explicit_orig = is_explicit_original(cand);
    let is_default = if is_default_marked(cand) {
        Some(true)
    } else {
        None
    };

    let matches_video_lang = matches!(
        (signals.normalized_video_lang.as_deref(), language.as_deref()),
        (Some(v), Some(l)) if languages_match(v, l)
    );

    if explicit_orig && !explicit_dub {
        let label = language_display_name
            .as_deref()
            .or(language.as_deref())
            .map(|l| format!("Audio included automatically · Original: {l}"))
            .unwrap_or_else(|| "Audio included automatically · Original track".to_string());
        return AudioTrackMetadata {
            language,
            language_display_name,
            is_original: Some(true),
            is_default,
            is_auto_dub: Some(false),
            selection_confidence: AudioSelectionConfidence::ConfirmedOriginal,
            status_note: label,
        };
    }

    if !explicit_dub && cand.language_preference.is_some_and(|p| p > 0) {
        let confirmed = matches_video_lang || language.is_some();
        let confidence = if confirmed {
            AudioSelectionConfidence::ConfirmedOriginal
        } else {
            AudioSelectionConfidence::LikelyOriginal
        };
        let label = language_display_name
            .as_deref()
            .or(language.as_deref())
            .map(|l| format!("Audio included automatically · Original: {l}"))
            .unwrap_or_else(|| "Audio included automatically · Original track".to_string());
        return AudioTrackMetadata {
            language,
            language_display_name,
            is_original: Some(true),
            is_default: Some(true),
            is_auto_dub: Some(false),
            selection_confidence: confidence,
            status_note: label,
        };
    }

    if !explicit_dub && matches_video_lang && signals.has_explicit_multi_audio_markers {
        let label = language_display_name
            .as_deref()
            .or(language.as_deref())
            .map(|l| format!("Audio included automatically · Likely original: {l}"))
            .unwrap_or_else(|| "Audio included automatically · Likely original track".to_string());
        return AudioTrackMetadata {
            language,
            language_display_name,
            is_original: None,
            is_default,
            is_auto_dub: Some(false),
            selection_confidence: AudioSelectionConfidence::LikelyOriginal,
            status_note: label,
        };
    }

    if explicit_dub {
        let lang_suffix = language_display_name
            .as_deref()
            .or(language.as_deref())
            .map(|l| format!(" ({l})"))
            .unwrap_or_default();
        return AudioTrackMetadata {
            language,
            language_display_name,
            is_original: Some(false),
            is_default,
            is_auto_dub: Some(explicit_auto_dub),
            selection_confidence: AudioSelectionConfidence::AmbiguousOrUnknown,
            status_note: format!(
                "Audio included automatically · Only dubbed track found{lang_suffix}; original not marked"
            ),
        };
    }

    if signals.has_multiple_distinct_languages {
        return AudioTrackMetadata {
            language,
            language_display_name,
            is_original: None,
            is_default,
            is_auto_dub: None,
            selection_confidence: AudioSelectionConfidence::AmbiguousOrUnknown,
            status_note:
                "Audio included automatically · Original language not marked among multiple audio tracks"
                    .to_string(),
        };
    }

    let suffix = language_display_name
        .as_deref()
        .or(language.as_deref())
        .map(|l| format!(" · Language: {l} (original not marked)"))
        .unwrap_or_else(|| " · Original language not marked in metadata".to_string());
    AudioTrackMetadata {
        language,
        language_display_name,
        is_original: None,
        is_default,
        is_auto_dub: None,
        selection_confidence: AudioSelectionConfidence::SingleOrUnmarked,
        status_note: format!("Audio included automatically{suffix}"),
    }
}

fn extract_language_display_name(
    cand: &RawFormatCandidate,
    lang_code: Option<&str>,
) -> Option<String> {
    if let Some(note) = cand.format.format_note.as_deref() {
        let lower = note.to_ascii_lowercase();
        if let Some(idx) = lower.find(" original") {
            let prefix = note[..idx].trim().trim_end_matches('-').trim();
            if !prefix.is_empty() {
                return Some(prefix.to_string());
            }
        }
        if let Some(idx) = lower.find(" - dubbed") {
            let prefix = note[..idx].trim();
            if !prefix.is_empty() {
                return Some(prefix.to_string());
            }
        }
        if lang_code.is_some() {
            if let Some((first_seg, _)) = note.split_once(',') {
                let candidate = first_seg.trim();
                let cl = candidate.to_ascii_lowercase();
                if !candidate.is_empty()
                    && !matches!(cl.as_str(), "low" | "medium" | "high" | "drc" | "tiny")
                {
                    return Some(candidate.to_string());
                }
            }
        }
    }

    let code = lang_code?;
    Some(match primary_lang_tag(code).as_str() {
        "en" => {
            if code.eq_ignore_ascii_case("en-US") {
                "English (US)".to_string()
            } else if code.eq_ignore_ascii_case("en-GB") {
                "English (UK)".to_string()
            } else {
                "English".to_string()
            }
        }
        "ar" => "Arabic".to_string(),
        "es" => "Spanish".to_string(),
        "fr" => "French".to_string(),
        "de" => "German".to_string(),
        "it" => "Italian".to_string(),
        "pt" => "Portuguese".to_string(),
        "ru" => "Russian".to_string(),
        "ja" => "Japanese".to_string(),
        "ko" => "Korean".to_string(),
        "zh" => "Chinese".to_string(),
        "tr" => "Turkish".to_string(),
        "hi" => "Hindi".to_string(),
        _ => code.to_string(),
    })
}

fn build_audio_only_options(
    audio_candidates: &[&RawFormatCandidate],
    signals: &AudioEnvironmentSignals,
    winning_meta: Option<&AudioTrackMetadata>,
) -> Vec<AudioQualityOption> {
    if audio_candidates.is_empty() {
        return Vec::new();
    }

    let mut filtered: Vec<&RawFormatCandidate> = audio_candidates
        .iter()
        .copied()
        .filter(|c| matches_winning_lineage(c, signals, winning_meta))
        .collect();

    if filtered.is_empty() {
        filtered = audio_candidates.to_vec();
    }

    // Prefer HTTPS direct audio streams when available, and exclude DRC when non-DRC exists.
    let has_direct = filtered.iter().any(|c| is_https_direct(c));
    if has_direct {
        filtered.retain(|c| is_https_direct(c));
    }
    let has_non_drc = filtered.iter().any(|c| !is_drc_variant(c));
    if has_non_drc {
        filtered.retain(|c| !is_drc_variant(c));
    }

    filtered.sort_by(|a, b| {
        let bra = a.format.bitrate_kbps.unwrap_or(0.0);
        let brb = b.format.bitrate_kbps.unwrap_or(0.0);
        brb.total_cmp(&bra)
            .then_with(|| audio_container_rank(b, true).cmp(&audio_container_rank(a, true)))
    });

    // Keep one clean option per (container, rounded bitrate bucket), capped to top 4.
    let mut seen_buckets = HashSet::new();
    let mut out = Vec::new();
    for cand in filtered {
        let br_bucket = cand.format.bitrate_kbps.map(|b| (b / 16.0).round() as u32);
        let key = (cand.format.container.to_ascii_lowercase(), br_bucket);
        if !seen_buckets.insert(key) {
            continue;
        }
        let quality_label = format_audio_quality_label(cand);
        let display_size =
            format_display_size(cand.format.file_size_bytes, cand.format.size_accuracy);
        out.push(AudioQualityOption {
            quality_label,
            container: cand.format.container.to_ascii_lowercase(),
            bitrate_kbps: cand.format.bitrate_kbps,
            display_size,
            file_size_bytes: cand.format.file_size_bytes,
            size_accuracy: cand.format.size_accuracy,
            format_id: cand.format.format_id.clone(),
            audio_language: winning_meta.cloned(),
        });
        if out.len() >= 4 {
            break;
        }
    }

    out
}

fn matches_winning_lineage(
    cand: &RawFormatCandidate,
    signals: &AudioEnvironmentSignals,
    winning_meta: Option<&AudioTrackMetadata>,
) -> bool {
    let (explicit_dub, _) = is_explicit_dub(cand);
    if explicit_dub && signals.has_any_non_dub_track {
        return false;
    }

    if let Some(meta) = winning_meta {
        if let Some(win_lang) = meta.language.as_deref() {
            match cand.language.as_deref() {
                Some(cand_lang) => {
                    if !languages_match(win_lang, cand_lang) {
                        return false;
                    }
                }
                None => {
                    if signals.has_explicit_multi_audio_markers {
                        return false;
                    }
                }
            }
        }
        if meta.selection_confidence == AudioSelectionConfidence::ConfirmedOriginal
            && signals.has_explicit_multi_audio_markers
        {
            // Keep tracks from the winning original tier when multiple languages exist.
            if originality_tier(cand, signals) < 2 {
                return false;
            }
        }
    }

    true
}

fn format_audio_quality_label(cand: &RawFormatCandidate) -> String {
    let br = cand.format.bitrate_kbps;
    let tier = match br {
        Some(kbps) if kbps >= 190.0 => "High Quality",
        Some(kbps) if kbps >= 96.0 => "Standard Quality",
        Some(_) => "Compact Quality",
        None => "Audio Stream",
    };
    match br {
        Some(kbps) => format!("{tier} ({} kbps)", kbps.round() as u32),
        None => tier.to_string(),
    }
}

fn build_instagram_audio_metadata(cand: Option<&RawFormatCandidate>) -> AudioTrackMetadata {
    let language = cand
        .and_then(|c| c.language.clone())
        .filter(|s| !s.is_empty());
    AudioTrackMetadata {
        language,
        language_display_name: None,
        is_original: None,
        is_default: None,
        is_auto_dub: None,
        selection_confidence: AudioSelectionConfidence::SingleOrUnmarked,
        status_note: "Audio included automatically".to_string(),
    }
}

fn effective_quality_height(cand: &RawFormatCandidate) -> Option<u32> {
    match (cand.format.width, cand.format.height) {
        (Some(w), Some(h)) if w > 0 && h > 0 => Some(w.min(h)),
        (_, Some(h)) if h > 0 => Some(h),
        _ => None,
    }
}

fn build_video_with_sound_options_inner(
    muxed_candidates: &[&RawFormatCandidate],
    video_only_candidates: &[&RawFormatCandidate],
    audio_candidates: &[&RawFormatCandidate],
    signals: &AudioEnvironmentSignals,
    winning_audio_meta: Option<&AudioTrackMetadata>,
    is_instagram: bool,
) -> Vec<VideoQualityOption> {
    let mut grouped_heights: BTreeMap<u32, (Vec<&RawFormatCandidate>, Vec<&RawFormatCandidate>)> =
        BTreeMap::new();
    let mut unknown_res_muxed: Vec<&RawFormatCandidate> = Vec::new();

    for cand in muxed_candidates {
        if let Some(h) = effective_quality_height(cand) {
            grouped_heights.entry(h).or_default().0.push(*cand);
        } else {
            unknown_res_muxed.push(*cand);
        }
    }
    for cand in video_only_candidates {
        if let Some(h) = effective_quality_height(cand) {
            grouped_heights.entry(h).or_default().1.push(*cand);
        }
    }

    // Iterate highest resolution descending (e.g., 2160p -> 1440p -> 1080p -> 720p -> 480p -> 360p...).
    let mut results = Vec::new();
    for (height, (muxed_at_h, video_only_at_h)) in grouped_heights.into_iter().rev() {
        let best_muxed = select_best_muxed_for_height(&muxed_at_h, signals, winning_audio_meta);
        let best_video_only = select_best_video_only_for_height(&video_only_at_h);

        let paired_option = best_video_only.and_then(|vid| {
            let prefer_m4a = vid.format.container.eq_ignore_ascii_case("mp4");
            let pair_audio = select_audio_for_pairing(
                audio_candidates,
                signals,
                winning_audio_meta,
                prefer_m4a,
            )?;
            Some((vid, pair_audio))
        });

        let chosen = match (best_muxed, paired_option) {
            (Some(muxed), Some((vid, pair_audio))) => {
                // Prefer combined muxed format if its FPS matches/exceeds paired AND there is no audio mismatch;
                // otherwise pair higher-quality/higher-FPS video-only with original audio.
                let mux_fps = muxed.format.fps.unwrap_or(0.0);
                let vid_fps = vid.format.fps.unwrap_or(0.0);
                if vid_fps > mux_fps + 5.0
                    || should_prefer_paired_over_muxed(muxed, winning_audio_meta, signals)
                {
                    build_paired_video_option(height, vid, pair_audio, winning_audio_meta)
                } else {
                    build_combined_video_option(height, muxed, winning_audio_meta, is_instagram)
                }
            }
            (Some(muxed), None) => {
                build_combined_video_option(height, muxed, winning_audio_meta, is_instagram)
            }
            (None, Some((vid, pair_audio))) => {
                build_paired_video_option(height, vid, pair_audio, winning_audio_meta)
            }
            // Silent video without any valid audio track MUST NOT appear in "Video with Sound".
            (None, None) => continue,
        };

        results.push(chosen);
    }

    if results.is_empty() && !unknown_res_muxed.is_empty() {
        if let Some(best_muxed) =
            select_best_muxed_for_height(&unknown_res_muxed, signals, winning_audio_meta)
        {
            results.push(build_unknown_res_combined_video_option(
                best_muxed,
                winning_audio_meta,
                is_instagram,
            ));
        }
    }

    results
}

fn should_prefer_paired_over_muxed(
    muxed: &RawFormatCandidate,
    winning_meta: Option<&AudioTrackMetadata>,
    signals: &AudioEnvironmentSignals,
) -> bool {
    if is_explicit_dub(muxed).0 {
        return true;
    }
    if let Some(meta) = winning_meta {
        if let Some(orig_lang) = meta.language.as_deref() {
            match muxed.language.as_deref() {
                Some(mux_lang) if !languages_match(orig_lang, mux_lang) => return true,
                None if signals.has_explicit_multi_audio_markers
                    && meta.selection_confidence == AudioSelectionConfidence::ConfirmedOriginal =>
                {
                    return true;
                }
                _ => {}
            }
        }
    }
    false
}

fn select_best_muxed_for_height<'a>(
    muxed_list: &[&'a RawFormatCandidate],
    signals: &AudioEnvironmentSignals,
    winning_meta: Option<&AudioTrackMetadata>,
) -> Option<&'a RawFormatCandidate> {
    muxed_list
        .iter()
        .copied()
        .filter(|m| is_muxed_audio_acceptable(m, signals, winning_meta))
        .max_by(|a, b| compare_video_streams(a, b))
}

fn is_muxed_audio_acceptable(
    muxed: &RawFormatCandidate,
    signals: &AudioEnvironmentSignals,
    winning_meta: Option<&AudioTrackMetadata>,
) -> bool {
    if is_explicit_dub(muxed).0 && signals.has_any_non_dub_track {
        return false;
    }
    if let (Some(meta), Some(mux_lang)) = (winning_meta, muxed.language.as_deref()) {
        if let Some(orig_lang) = meta.language.as_deref() {
            if !languages_match(orig_lang, mux_lang) {
                return false;
            }
        }
    }
    true
}

fn select_best_video_only_for_height<'a>(
    video_list: &[&'a RawFormatCandidate],
) -> Option<&'a RawFormatCandidate> {
    video_list
        .iter()
        .copied()
        .max_by(|a, b| compare_video_streams(a, b))
}

fn compare_video_streams(a: &RawFormatCandidate, b: &RawFormatCandidate) -> std::cmp::Ordering {
    is_https_direct(a)
        .cmp(&is_https_direct(b))
        .then_with(|| {
            let fps_a = a.format.fps.map(|f| f.round() as u32).unwrap_or(0);
            let fps_b = b.format.fps.map(|f| f.round() as u32).unwrap_or(0);
            fps_a.cmp(&fps_b)
        })
        .then_with(|| video_container_codec_rank(a).cmp(&video_container_codec_rank(b)))
        .then_with(|| {
            a.format
                .file_size_bytes
                .is_some()
                .cmp(&b.format.file_size_bytes.is_some())
        })
        .then_with(|| {
            let bra = a.format.bitrate_kbps.unwrap_or(0.0);
            let brb = b.format.bitrate_kbps.unwrap_or(0.0);
            bra.total_cmp(&brb)
        })
}

fn video_container_codec_rank(cand: &RawFormatCandidate) -> u8 {
    let is_mp4 = cand.format.container.eq_ignore_ascii_case("mp4");
    let vcodec = cand.format.vcodec.as_deref().unwrap_or("");
    if is_mp4 && vcodec.starts_with("avc1") {
        4
    } else if is_mp4 {
        3
    } else if cand.format.container.eq_ignore_ascii_case("webm") {
        2
    } else {
        1
    }
}

fn select_audio_for_pairing<'a>(
    audio_candidates: &[&'a RawFormatCandidate],
    signals: &AudioEnvironmentSignals,
    winning_meta: Option<&AudioTrackMetadata>,
    prefer_m4a: bool,
) -> Option<&'a RawFormatCandidate> {
    let lineage_matches: Vec<&RawFormatCandidate> = audio_candidates
        .iter()
        .copied()
        .filter(|c| matches_winning_lineage(c, signals, winning_meta))
        .collect();

    let pool = if lineage_matches.is_empty() {
        audio_candidates
    } else {
        &lineage_matches
    };

    select_preferred_audio_candidate(pool, signals, prefer_m4a)
}

fn build_combined_video_option(
    height: u32,
    muxed: &RawFormatCandidate,
    winning_audio_meta: Option<&AudioTrackMetadata>,
    is_instagram: bool,
) -> VideoQualityOption {
    let audio_meta = winning_audio_meta.cloned().unwrap_or_else(|| {
        if is_instagram {
            build_instagram_audio_metadata(Some(muxed))
        } else {
            build_muxed_fallback_audio_metadata(muxed)
        }
    });
    let display_size =
        format_display_size(muxed.format.file_size_bytes, muxed.format.size_accuracy);

    VideoQualityOption {
        resolution: format_resolution_label(height),
        height: Some(height),
        fps: muxed.format.fps,
        container: muxed.format.container.to_ascii_lowercase(),
        display_size,
        file_size_bytes: muxed.format.file_size_bytes,
        size_accuracy: muxed.format.size_accuracy,
        video_format_id: muxed.format.format_id.clone(),
        selected_audio_format_id: None,
        audio_language: Some(audio_meta),
        format_selection_strategy: FormatSelectionStrategy::CombinedAudioVideo,
    }
}

fn build_unknown_res_combined_video_option(
    muxed: &RawFormatCandidate,
    winning_audio_meta: Option<&AudioTrackMetadata>,
    is_instagram: bool,
) -> VideoQualityOption {
    let audio_meta = winning_audio_meta.cloned().unwrap_or_else(|| {
        if is_instagram {
            build_instagram_audio_metadata(Some(muxed))
        } else {
            build_muxed_fallback_audio_metadata(muxed)
        }
    });
    let display_size =
        format_display_size(muxed.format.file_size_bytes, muxed.format.size_accuracy);

    VideoQualityOption {
        resolution: "Standard".to_string(),
        height: None,
        fps: muxed.format.fps,
        container: muxed.format.container.to_ascii_lowercase(),
        display_size,
        file_size_bytes: muxed.format.file_size_bytes,
        size_accuracy: muxed.format.size_accuracy,
        video_format_id: muxed.format.format_id.clone(),
        selected_audio_format_id: None,
        audio_language: Some(audio_meta),
        format_selection_strategy: FormatSelectionStrategy::CombinedAudioVideo,
    }
}

fn build_muxed_fallback_audio_metadata(muxed: &RawFormatCandidate) -> AudioTrackMetadata {
    let lang = muxed.language.clone();
    let display = extract_language_display_name(muxed, lang.as_deref());
    let (explicit_dub, explicit_auto_dub) = is_explicit_dub(muxed);
    let note = if explicit_dub {
        "Audio included automatically · Dubbed track only; original not marked".to_string()
    } else {
        display
            .as_deref()
            .or(lang.as_deref())
            .map(|l| format!("Audio included automatically · Language: {l} (original not marked)"))
            .unwrap_or_else(|| {
                "Audio included automatically · Original language not marked in metadata"
                    .to_string()
            })
    };
    AudioTrackMetadata {
        language: lang,
        language_display_name: display,
        is_original: if explicit_dub { Some(false) } else { None },
        is_default: None,
        is_auto_dub: if explicit_dub {
            Some(explicit_auto_dub)
        } else {
            None
        },
        selection_confidence: AudioSelectionConfidence::SingleOrUnmarked,
        status_note: note,
    }
}

fn build_paired_video_option(
    height: u32,
    video: &RawFormatCandidate,
    audio: &RawFormatCandidate,
    winning_audio_meta: Option<&AudioTrackMetadata>,
) -> VideoQualityOption {
    let target_container = if video.format.container.eq_ignore_ascii_case("mp4")
        || audio.format.container.eq_ignore_ascii_case("m4a")
    {
        "mp4".to_string()
    } else if video.format.container.eq_ignore_ascii_case("webm")
        && audio.format.container.eq_ignore_ascii_case("webm")
    {
        "webm".to_string()
    } else {
        "mp4".to_string()
    };

    let (file_size_bytes, size_accuracy) = combine_sizes(
        (video.format.file_size_bytes, video.format.size_accuracy),
        (audio.format.file_size_bytes, audio.format.size_accuracy),
    );
    let display_size = format_display_size(file_size_bytes, size_accuracy);

    VideoQualityOption {
        resolution: format_resolution_label(height),
        height: Some(height),
        fps: video.format.fps,
        container: target_container,
        display_size,
        file_size_bytes,
        size_accuracy,
        video_format_id: video.format.format_id.clone(),
        selected_audio_format_id: Some(audio.format.format_id.clone()),
        audio_language: winning_audio_meta.cloned(),
        format_selection_strategy: FormatSelectionStrategy::PairVideoAndAudioWithFfmpeg,
    }
}

fn combine_sizes(
    video: (Option<u64>, FileSizeAccuracy),
    audio: (Option<u64>, FileSizeAccuracy),
) -> (Option<u64>, FileSizeAccuracy) {
    match (video, audio) {
        ((Some(vb), va), (Some(ab), aa))
            if va != FileSizeAccuracy::Unknown && aa != FileSizeAccuracy::Unknown =>
        {
            let accuracy = if va == FileSizeAccuracy::Exact && aa == FileSizeAccuracy::Exact {
                FileSizeAccuracy::Exact
            } else {
                FileSizeAccuracy::Estimated
            };
            (vb.checked_add(ab), accuracy)
        }
        _ => (None, FileSizeAccuracy::Unknown),
    }
}

fn format_resolution_label(height: u32) -> String {
    match height {
        2160 => "4K (2160p)".to_string(),
        4320 => "8K (4320p)".to_string(),
        other => format!("{other}p"),
    }
}

/// Formats a user-facing file size string with explicit exact vs. estimated indication.
pub fn format_display_size(bytes: Option<u64>, accuracy: FileSizeAccuracy) -> String {
    match (bytes, accuracy) {
        (Some(b), FileSizeAccuracy::Exact) => format!("{} (Exact)", format_bytes_human(b)),
        (Some(b), FileSizeAccuracy::Estimated) => {
            format!("~{} (Estimated)", format_bytes_human(b))
        }
        _ => "Unknown size".to_string(),
    }
}

pub(crate) fn format_bytes_human(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = 1024.0 * 1024.0;
    const GB: f64 = 1024.0 * 1024.0 * 1024.0;
    let val = bytes as f64;
    if val < KB {
        format!("{bytes} B")
    } else if val < MB {
        format!("{:.1} KB", val / KB)
    } else if val < GB {
        format!("{:.2} MB", val / MB)
    } else {
        format!("{:.2} GB", val / GB)
    }
}

/// Concrete format selection resolved for one playlist item after applying the requested cap.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ResolvedPlaylistSelection {
    pub selection: DownloadFormatSelection,
    pub quality_label: String,
    pub container: String,
    pub audio_language: Option<AudioTrackMetadata>,
    pub expected_size_bytes: Option<u64>,
    pub size_accuracy: FileSizeAccuracy,
}

/// Selects the best playable option for an individually inspected playlist video
/// using its genuinely discovered formats, original-audio metadata, and quality cap.
pub fn select_playlist_item_option(
    inspection: &MediaInspection,
    mode: PlaylistMediaMode,
    cap: PlaylistQualityCap,
) -> Result<ResolvedPlaylistSelection, String> {
    match mode {
        PlaylistMediaMode::VideoWithSound => {
            if inspection.video_options.is_empty() {
                return Err(
                    "No playable Video with Sound formats (valid audio track unavailable) for this item."
                        .into(),
                );
            }
            let max_height = match cap {
                PlaylistQualityCap::BestAvailable => u32::MAX,
                PlaylistQualityCap::UpTo1080p => 1080,
                PlaylistQualityCap::UpTo720p => 720,
                PlaylistQualityCap::UpTo480p => 480,
            };

            let chosen = inspection
                .video_options
                .iter()
                .find(|opt| opt.height.is_some_and(|h| h <= max_height))
                .or_else(|| inspection.video_options.last())
                .ok_or_else(|| "No playable video options available.".to_string())?;

            let (selection, expected_size_bytes, size_accuracy) = match chosen
                .format_selection_strategy
            {
                FormatSelectionStrategy::CombinedAudioVideo => (
                    DownloadFormatSelection::single(&chosen.video_format_id),
                    chosen.file_size_bytes,
                    chosen.size_accuracy,
                ),
                FormatSelectionStrategy::PairVideoAndAudioWithFfmpeg => {
                    let audio_id = chosen.selected_audio_format_id.as_deref().ok_or_else(|| {
                        "Internal format pairing error: missing original audio format ID."
                            .to_string()
                    })?;
                    // Separate video/audio merges are always estimated due to container/mux overhead.
                    let (bytes, accuracy) = match (chosen.file_size_bytes, chosen.size_accuracy) {
                        (Some(b), FileSizeAccuracy::Exact | FileSizeAccuracy::Estimated) => {
                            (Some(b), FileSizeAccuracy::Estimated)
                        }
                        _ => (None, FileSizeAccuracy::Unknown),
                    };
                    (
                        DownloadFormatSelection::video_and_audio(
                            &chosen.video_format_id,
                            audio_id,
                            &chosen.container,
                        ),
                        bytes,
                        accuracy,
                    )
                }
                FormatSelectionStrategy::AudioOnlyStream => {
                    return Err("Unexpected AudioOnly strategy inside video options.".into());
                }
            };

            let fps_part = chosen
                .fps
                .filter(|f| *f >= 45.0)
                .map(|f| format!(" {}fps", f.round() as u32))
                .unwrap_or_default();
            let quality_label = format!(
                "{}{} {}",
                chosen.resolution,
                fps_part,
                chosen.container.to_ascii_uppercase()
            );

            Ok(ResolvedPlaylistSelection {
                selection,
                quality_label,
                container: chosen.container.clone(),
                audio_language: chosen
                    .audio_language
                    .clone()
                    .or_else(|| inspection.original_audio.clone()),
                expected_size_bytes,
                size_accuracy,
            })
        }
        PlaylistMediaMode::AudioOnly => {
            let chosen = inspection.audio_options.first().ok_or_else(|| {
                "No downloadable Audio Only stream discovered for this item.".to_string()
            })?;
            let quality_label = format!(
                "{} · {}",
                chosen.container.to_ascii_uppercase(),
                chosen.quality_label
            );

            Ok(ResolvedPlaylistSelection {
                selection: DownloadFormatSelection::single(&chosen.format_id),
                quality_label,
                container: chosen.container.clone(),
                audio_language: chosen
                    .audio_language
                    .clone()
                    .or_else(|| inspection.original_audio.clone()),
                expected_size_bytes: chosen.file_size_bytes,
                size_accuracy: chosen.size_accuracy,
            })
        }
    }
}
