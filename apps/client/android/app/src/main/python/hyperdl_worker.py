"""Chaquopy Python 3.13 media runtime worker for HyperDownload on Android.

Wraps `yt-dlp`, `yt-dlp-ejs`, `libqjs.so` (QuickJS-NG), `libffmpeg.so`,
and `libffprobe.so` for raw media extraction and download execution.
"""

from collections import OrderedDict
import copy
import importlib.metadata
import json
import math
import os
import re
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

import certifi
import yt_dlp
import yt_dlp_ejs

_SYMLINK_LOCK = threading.Lock()

_CACHE_LOCK = threading.Lock()
_INSPECTION_CACHE = {}
_RAW_INFO_CACHE = OrderedDict()
_RAW_INFO_CACHE_MAX = 64
_RAW_INFO_CACHE_TTL_SECS = 1800.0
_INSTAGRAM_RAW_INFO_CACHE_TTL_SECS = 900.0
_INSTAGRAM_SOCKET_TIMEOUT_SECS = 40
_ANDROID_VP9_MP4_MIN_SDK = 29
_MP4_HEADER_PROBE_BYTES = 65536
_MP4_HEADER_PROBE_TIMEOUT_SECS = 6

_TRACK_LOCK = threading.Lock()
_CURRENT_JOB = threading.local()
_ACTIVE_SUBPROCESSES = {}
_CANCELLED_JOBS = set()
_POPEN_PATCHED = False
_ORIG_POPEN = subprocess.Popen


class _TrackedPopen(_ORIG_POPEN):
    """Tracks child processes (libqjs.so, libffmpeg.so) per job_id for instant cancel."""

    def __init__(self, *args, **kwargs):
        job_id = getattr(_CURRENT_JOB, "job_id", None)
        if job_id is not None and _is_job_cancelled(job_id):
            raise yt_dlp.utils.DownloadCancelled("Canceled by user")
        super().__init__(*args, **kwargs)
        self._hyperdl_job_id = job_id
        if job_id is not None:
            with _TRACK_LOCK:
                _ACTIVE_SUBPROCESSES.setdefault(job_id, set()).add(self)
                cancelled = job_id in _CANCELLED_JOBS
            if cancelled:
                self._terminate_self()
                raise yt_dlp.utils.DownloadCancelled("Canceled by user")

    def _terminate_self(self):
        try:
            if self.poll() is None:
                self.terminate()
                try:
                    self.wait(timeout=0.35)
                except subprocess.TimeoutExpired:
                    self.kill()
        except Exception:
            pass

    def wait(self, timeout=None):
        try:
            return super().wait(timeout=timeout)
        finally:
            if self._hyperdl_job_id is not None and self.poll() is not None:
                with _TRACK_LOCK:
                    procs = _ACTIVE_SUBPROCESSES.get(self._hyperdl_job_id)
                    if procs is not None:
                        procs.discard(self)

    def communicate(self, input=None, timeout=None):
        try:
            return super().communicate(input=input, timeout=timeout)
        finally:
            if self._hyperdl_job_id is not None and self.poll() is not None:
                with _TRACK_LOCK:
                    procs = _ACTIVE_SUBPROCESSES.get(self._hyperdl_job_id)
                    if procs is not None:
                        procs.discard(self)


def _ensure_popen_tracker():
    global _POPEN_PATCHED
    with _TRACK_LOCK:
        if not _POPEN_PATCHED:
            subprocess.Popen = _TrackedPopen
            _POPEN_PATCHED = True


def _is_job_cancelled(job_id: str) -> bool:
    with _TRACK_LOCK:
        return job_id in _CANCELLED_JOBS


def clear_job_cancelled(job_id: str):
    with _TRACK_LOCK:
        _CANCELLED_JOBS.discard(job_id)


def cancel_job(job_id: str):
    """Flags `job_id` as canceled and terminates active child processes."""
    with _TRACK_LOCK:
        _CANCELLED_JOBS.add(job_id)
        procs = list(_ACTIVE_SUBPROCESSES.get(job_id, set()))
    for proc in procs:
        try:
            if proc.poll() is None:
                proc.terminate()
        except Exception:
            pass
    deadline = time.monotonic() + 0.4
    for proc in procs:
        try:
            remaining = max(0.0, deadline - time.monotonic())
            if proc.poll() is None:
                proc.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            try:
                proc.kill()
            except Exception:
                pass
        except Exception:
            pass


def _emit_cb(cb, payload_json: str):
    if cb is None:
        return
    if hasattr(cb, "onEvent"):
        cb.onEvent(payload_json)
    elif callable(cb):
        cb(payload_json)


def _configure_tls_env() -> str:
    ca_path = certifi.where()
    os.environ["SSL_CERT_FILE"] = ca_path
    os.environ["REQUESTS_CA_BUNDLE"] = ca_path
    return ca_path


def ensure_bin_symlinks(native_lib_dir: str, bin_dir: str) -> dict:
    """Creates executable symlinks in `bin_dir` pointing to `nativeLibraryDir` `.so` files."""
    with _SYMLINK_LOCK:
        os.makedirs(bin_dir, exist_ok=True)
        mapping = {
            "ffmpeg": os.path.join(native_lib_dir, "libffmpeg.so"),
            "ffprobe": os.path.join(native_lib_dir, "libffprobe.so"),
            "qjs": os.path.join(native_lib_dir, "libqjs.so"),
        }
        resolved = {}
        for link_name, target_path in mapping.items():
            if not os.path.isfile(target_path):
                raise FileNotFoundError(
                    f"Missing native executable '{target_path}' in nativeLibraryDir"
                )
            link_path = os.path.join(bin_dir, link_name)
            if os.path.lexists(link_path):
                try:
                    current_target = os.readlink(link_path)
                    if current_target != target_path:
                        os.unlink(link_path)
                except OSError:
                    os.unlink(link_path)
            if not os.path.lexists(link_path):
                os.symlink(target_path, link_path)
            resolved[link_name] = link_path
        resolved["qjs_native"] = mapping["qjs"]
        resolved["ffmpeg_native"] = mapping["ffmpeg"]
        resolved["ffprobe_native"] = mapping["ffprobe"]
        return resolved


def _is_instagram_url(url: str) -> bool:
    try:
        host = (urllib.parse.urlparse(url.strip()).hostname or "").lower().rstrip(".")
        return host == "instagram.com" or host.endswith(".instagram.com")
    except Exception:
        return False


def _is_facebook_url(url: str) -> bool:
    try:
        host = (urllib.parse.urlparse(url.strip()).hostname or "").lower().rstrip(".")
        return (
            host == "facebook.com"
            or host.endswith(".facebook.com")
            or host == "fb.watch"
            or host.endswith(".fb.watch")
            or host == "fb.com"
            or host.endswith(".fb.com")
        )
    except Exception:
        return False


def _extract_facebook_numeric_id(url: str) -> str:
    try:
        parsed = urllib.parse.urlparse(url.strip())
        qs = urllib.parse.parse_qs(parsed.query)
        for key in ("v", "story_fbid"):
            val = (qs.get(key) or [""])[0].strip()
            if val.isdigit() and len(val) >= 6:
                return val
        for seg in reversed([s for s in parsed.path.split("/") if s]):
            if seg.isdigit() and len(seg) >= 6:
                return seg
    except Exception:
        pass
    return ""


def _facebook_fallback_urls(url: str) -> list:
    vid = _extract_facebook_numeric_id(url)
    if not vid:
        return []
    norm = url.strip()
    candidates = [
        f"https://www.facebook.com/watch/?v={vid}",
        f"https://www.facebook.com/video/video.php?v={vid}",
    ]
    return [c for c in candidates if c != norm]


def _base_ydl_opts(bins: dict, bin_dir: str, cache_dir: str) -> dict:
    if cache_dir:
        os.makedirs(cache_dir, exist_ok=True)
    return {
        "quiet": True,
        "no_warnings": True,
        "ignoreconfig": True,
        "js_runtimes": {"quickjs": {"path": bins["qjs_native"]}},
        "ffmpeg_location": bin_dir,
        "cachedir": cache_dir or False,
    }


def _cache_put(media_dict: dict, url: str):
    if not media_dict:
        return
    with _CACHE_LOCK:
        vid = str(media_dict.get("id") or "").strip()
        if vid:
            _INSPECTION_CACHE[vid] = media_dict
        if url:
            _INSPECTION_CACHE[url.strip()] = media_dict


def _cache_get(video_id: str, url: str):
    with _CACHE_LOCK:
        if video_id and video_id.strip() in _INSPECTION_CACHE:
            return _INSPECTION_CACHE[video_id.strip()]
        if url and url.strip() in _INSPECTION_CACHE:
            return _INSPECTION_CACHE[url.strip()]
        return None


def _raw_cache_keys(url: str, info_dict=None, video_id=None):
    keys = []
    norm_url = (url or "").strip()
    if norm_url:
        keys.append(f"url:{norm_url}")
    if info_dict:
        wp = str(info_dict.get("webpage_url") or "").strip()
        if wp and wp != norm_url:
            keys.append(f"url:{wp}")
        extractor = str(info_dict.get("extractor_key") or info_dict.get("extractor") or "").lower()
        info_id = str(info_dict.get("id") or "").strip()
        if info_id:
            keys.append(f"id:{info_id}")
            if "facebook" in extractor or _is_facebook_url(norm_url) or _is_facebook_url(wp):
                if info_id.isdigit() and len(info_id) >= 6:
                    for fb_canon in (
                        f"https://www.facebook.com/watch/?v={info_id}",
                        f"https://www.facebook.com/reel/{info_id}/",
                    ):
                        fb_key = f"url:{fb_canon}"
                        if fb_key not in keys:
                            keys.append(fb_key)
    if video_id and str(video_id).strip():
        vid_key = f"id:{str(video_id).strip()}"
        if vid_key not in keys:
            keys.append(vid_key)
    return keys


def _raw_cache_put(
    info_dict: dict,
    url: str,
    extra_urls=None,
    ttl_secs: float = _RAW_INFO_CACHE_TTL_SECS,
):
    if not isinstance(info_dict, dict) or not info_dict:
        return
    keys = _raw_cache_keys(url, info_dict=info_dict)
    for extra in extra_urls or ():
        for k in _raw_cache_keys(extra, info_dict=info_dict):
            if k not in keys:
                keys.append(k)
    if not keys:
        return
    snapshot = copy.deepcopy(info_dict)
    stored_at = time.monotonic()
    with _CACHE_LOCK:
        for key in keys:
            _RAW_INFO_CACHE[key] = (stored_at, float(ttl_secs), snapshot)
            _RAW_INFO_CACHE.move_to_end(key)
        while len(_RAW_INFO_CACHE) > _RAW_INFO_CACHE_MAX:
            _RAW_INFO_CACHE.popitem(last=False)


def _raw_cache_get(url: str, video_id=None):
    keys = _raw_cache_keys(url, video_id=video_id)
    if not keys:
        return None
    now = time.monotonic()
    with _CACHE_LOCK:
        for key in keys:
            entry = _RAW_INFO_CACHE.get(key)
            if entry is None:
                continue
            stored_at, ttl_secs, snapshot = entry
            if now - stored_at > ttl_secs:
                _RAW_INFO_CACHE.pop(key, None)
                continue
            _RAW_INFO_CACHE.move_to_end(key)
            return copy.deepcopy(snapshot)
    return None


def _raw_cache_evict(url: str, video_id=None):
    keys = _raw_cache_keys(url, video_id=video_id)
    if not keys:
        return
    with _CACHE_LOCK:
        extra_keys = set(keys)
        for key in keys:
            entry = _RAW_INFO_CACHE.get(key)
            if entry is not None:
                _, _, snapshot = entry
                extra_keys.update(_raw_cache_keys(url, info_dict=snapshot, video_id=video_id))
        for key in extra_keys:
            _RAW_INFO_CACHE.pop(key, None)


def _prepare_reusable_info(raw_info: dict) -> dict:
    prepared = copy.deepcopy(raw_info)
    for ephemeral_key in (
        "requested_formats",
        "requested_downloads",
        "requested_subtitles",
        "filepath",
        "_filename",
        "filename",
        "format_id",
        "format",
        "ext",
        "__files_to_move",
        "__postprocessors",
    ):
        prepared.pop(ephemeral_key, None)
    return prepared


def _redact_sensitive_diagnostics(raw: str) -> str:
    text = re.sub(
        r"(?im)^(.*?\b(?:cookie|authorization):\s*)(.*)$",
        r"\1[REDACTED]",
        raw,
    )
    return re.sub(
        r"(?i)((?:sessionid|csrftoken|ds_user_id|c_user|xs|fr|datr|oh|_nc_ohc)=)[^&;\"')\s\]]+",
        r"\1[REDACTED]",
        text,
    )


def _classify_instagram_error(raw_error: str) -> dict:
    text = str(raw_error or "").strip()
    lower = text.lower()
    if any(
        t in lower
        for t in (
            "ffmpeg",
            "ffprobe",
            "postprocessing",
            "error merging",
            "[merger]",
            "muxing",
            "moov atom",
        )
    ):
        msg = "Failed to process video and audio streams with FFmpeg."
    elif any(
        t in lower
        for t in ("429", "too many requests", "rate limit", "rate-limit", "please wait a few minutes")
    ):
        msg = "Instagram temporarily rate-limited requests. Please wait a few minutes and try again."
    elif any(
        t in lower
        for t in (
            "http error 404",
            "404: not found",
            "not found",
            "does not exist",
            "has been deleted",
            "been deleted",
            "removed",
            "broken",
            "no longer available",
        )
    ):
        msg = "This Instagram Reel is unavailable or has been deleted."
    elif any(
        t in lower
        for t in (
            "account is private",
            "private reel",
            "private video",
            "this content is private",
            "not available to you",
        )
    ):
        msg = "This Instagram Reel is private or inaccessible."
    elif any(
        t in lower
        for t in (
            "login required",
            "logged-in",
            "locked behind the login page",
            "need to log in",
            "sign in",
            "use --cookies",
            "cookies are needed",
            "cookies-from-browser",
            "authentication",
        )
    ):
        msg = "Instagram requires login to view this Reel. Only public Reels are supported without login."
    elif any(
        t in lower
        for t in (
            "empty media response",
            "checkpoint",
            "challenge_required",
            "http error 403",
            "403",
            "csrf",
            "unable to extract",
            "blocked",
            "automated",
        )
    ):
        msg = "Instagram temporarily restricted this request. Please try again later."
    elif "before media transfer started" in lower:
        msg = "Timed out while connecting to Instagram. Check your internet connection and try again."
    elif any(
        t in lower
        for t in (
            "timed out",
            "timeout",
            "could not resolve",
            "curl: (6)",
            "curl: (7)",
            "curl: (28)",
            "transporterror",
            "urlopen",
            "gaierror",
            "name or service not known",
            "temporary failure in name resolution",
            "nodename nor servname",
            "remote end closed",
            "incompleteread",
            "eof occurred",
            "connection",
            "network",
            "ssl",
            "tls",
            "dns",
            "reset by peer",
        )
    ):
        msg = "Network error while contacting Instagram. Check your internet connection and try again."
    else:
        msg = "Instagram extraction failed. Please verify the Reel is public and try again."

    is_transient = any(
        t in lower
        for t in (
            "curl: (6)",
            "curl: (7)",
            "curl: (28)",
            "transporterror",
            "urlopen",
            "gaierror",
            "temporary failure in name resolution",
            "connection reset",
            "remote end closed",
            "incompleteread",
            "eof occurred",
            "unexpected eof",
            "timed out",
            "could not resolve",
            "failed to connect",
        )
    )
    return {
        "user_message": msg,
        "redacted_diagnostic": _redact_sensitive_diagnostics(text)[:400],
        "is_transient": is_transient,
    }


def _classify_facebook_error(raw_error: str) -> dict:
    text = str(raw_error or "").strip()
    lower = text.lower()
    if any(
        t in lower
        for t in ("ffmpeg", "ffprobe", "postprocessing", "error merging", "[merger]", "muxing", "moov atom")
    ):
        msg = "Failed to process Facebook video and audio streams with FFmpeg."
    elif any(
        t in lower
        for t in ("brokenpipeerror", "broken pipe", "errno 22", "errno 32", "file name too long", "no space left", "permission denied")
    ):
        msg = "Local file or stream error while saving media. Please check folder permissions and disk space, then try again."
    elif any(
        t in lower
        for t in ("age-restricted", "age restricted", "age gate", "18+", "mature content", "inappropriate for some users")
    ):
        msg = "This Facebook video is age-restricted and requires an authenticated account."
    elif any(
        t in lower
        for t in (
            "login required",
            "you must log in",
            "must log in to continue",
            "logged-in",
            "need to log in",
            "sign in",
            "use --cookies",
            "cookies are needed",
            "cookies-from-browser",
            "registered users",
            "this video is private",
            "private video",
            "content isn't available right now",
            "content is not available right now",
        )
    ):
        msg = "This Facebook video is private or requires login. Only public Facebook videos and Reels are supported."
    elif any(
        t in lower
        for t in ("429", "too many requests", "rate limit", "rate-limit", "please wait a few minutes")
    ):
        msg = "Facebook temporarily rate-limited requests. Please wait a few minutes and try again."
    elif any(
        t in lower
        for t in (
            "http error 404",
            "404: not found",
            "not found",
            "does not exist",
            "has been deleted",
            "been deleted",
            "removed",
            "expired",
            "no longer available",
            "no video formats found",
            "there's no video",
            "no video on this",
        )
    ):
        msg = "This Facebook video is unavailable, has been deleted, or the post does not contain a playable video."
    elif any(
        t in lower
        for t in (
            "cannot parse data",
            "unable to extract",
            "empty media response",
            "checkpoint",
            "challenge_required",
            "http error 403",
            "403",
            "blocked",
            "automated",
        )
    ):
        msg = "Facebook temporarily restricted or changed this page response. Please try again later."
    elif "before media transfer started" in lower or any(
        t in lower
        for t in (
            "timed out",
            "timeout",
            "could not resolve",
            "curl: (6)",
            "curl: (7)",
            "curl: (28)",
            "transporterror",
            "urlopen",
            "gaierror",
            "name or service not known",
            "temporary failure in name resolution",
            "nodename nor servname",
            "remote end closed",
            "incompleteread",
            "eof occurred",
            "connection",
            "network",
            "ssl",
            "tls",
            "dns",
            "reset by peer",
        )
    ):
        msg = "Network error or timeout while contacting Facebook. Check your internet connection and try again."
    else:
        msg = "Facebook extraction failed. Please verify the video or Reel is public and try again."

    is_transient = any(
        t in lower
        for t in (
            "curl: (6)",
            "curl: (7)",
            "curl: (28)",
            "transporterror",
            "urlopen",
            "gaierror",
            "temporary failure in name resolution",
            "connection reset",
            "remote end closed",
            "incompleteread",
            "eof occurred",
            "unexpected eof",
            "timed out",
            "could not resolve",
            "failed to connect",
        )
    )
    return {
        "user_message": msg,
        "redacted_diagnostic": _redact_sensitive_diagnostics(text)[:400],
        "is_transient": is_transient,
    }


class _QuietCaptureLogger:
    """Per-job yt-dlp logger that captures warnings/errors without touching global state."""

    def __init__(self):
        self.messages = []

    def debug(self, msg):
        pass

    def info(self, msg):
        pass

    def warning(self, msg):
        if msg:
            self.messages.append(str(msg))

    def error(self, msg):
        if msg:
            self.messages.append(str(msg))


class _WorkerJobLogger:
    """Per-job yt-dlp logger providing instant pre-first-byte cancel and stage status updates."""

    def __init__(self, job_id: str, is_instagram: bool, on_stage):
        self.job_id = job_id
        self.is_instagram = is_instagram
        self.on_stage = on_stage
        self.messages = []

    def _check_cancel(self):
        if _is_job_cancelled(self.job_id):
            raise yt_dlp.utils.DownloadCancelled("Canceled by user")

    def _handle_line(self, msg):
        self._check_cancel()
        line = str(msg or "").strip()
        if not line:
            return
        if line.startswith("[Instagram] Setting up session"):
            self.on_stage("Connecting to Instagram...")
        elif line.startswith("[Instagram] "):
            self.on_stage("Resolving media...")
        elif line.lower().startswith("[facebook"):
            self.on_stage("Connecting to Facebook...")
        elif line.startswith("[info] ") and "Downloading" in line and "format(s)" in line:
            self.on_stage("Resolving media...")
        elif line.startswith("[download] Destination: "):
            self.on_stage("Starting download...")

    def debug(self, msg):
        self._handle_line(msg)

    def info(self, msg):
        self._handle_line(msg)

    def warning(self, msg):
        self._check_cancel()
        if msg:
            self.messages.append(str(msg))

    def error(self, msg):
        self._check_cancel()
        if msg:
            self.messages.append(str(msg))


def _sleep_cancelable(job_id: str, seconds: float):
    deadline = time.monotonic() + max(0.0, seconds)
    while time.monotonic() < deadline:
        if _is_job_cancelled(job_id):
            return
        time.sleep(min(0.1, max(0.0, deadline - time.monotonic())))


def run_diagnostics(native_lib_dir: str, bin_dir: str) -> str:
    """Executes runtime verification across Python, yt-dlp, EJS, QuickJS, FFmpeg, and FFprobe."""
    report = {
        "ok": False,
        "python_version": sys.version,
        "python_major_minor": f"{sys.version_info.major}.{sys.version_info.minor}",
        "yt_dlp_version": getattr(yt_dlp.version, "__version__", "unknown"),
        "yt_dlp_ejs_version": None,
        "certifi_ca_path": None,
        "quickjs_ok": False,
        "quickjs_output": None,
        "ffmpeg_ok": False,
        "ffmpeg_version": None,
        "ffprobe_ok": False,
        "ffprobe_version": None,
        "curl_cffi_available": False,
        "curl_cffi_version": None,
        "request_handlers": [],
        "impersonate_handlers": [],
        "instagram_extractor_available": False,
        "facebook_extractor_available": False,
        "android_dns_ok": False,
        "android_dns_ms": None,
        "android_dns_count": 0,
        "error": None,
    }
    try:
        report["certifi_ca_path"] = _configure_tls_env()
        try:
            report["yt_dlp_ejs_version"] = importlib.metadata.version("yt-dlp-ejs")
        except Exception:
            report["yt_dlp_ejs_version"] = getattr(
                yt_dlp_ejs, "__version__", "imported"
            )

        bins = ensure_bin_symlinks(native_lib_dir, bin_dir)

        qjs_proc = subprocess.run(
            [bins["qjs_native"], "-e", "print(21 * 2)"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        report["quickjs_output"] = qjs_proc.stdout.strip()
        report["quickjs_ok"] = (
            qjs_proc.returncode == 0 and report["quickjs_output"] == "42"
        )
        if not report["quickjs_ok"]:
            raise RuntimeError(
                f"QuickJS failed (rc={qjs_proc.returncode}): {qjs_proc.stderr.strip()}"
            )

        ff_proc = subprocess.run(
            [bins["ffmpeg"], "-version"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        report["ffmpeg_version"] = (
            ff_proc.stdout.splitlines()[0].strip() if ff_proc.stdout else ""
        )
        report["ffmpeg_ok"] = ff_proc.returncode == 0
        if not report["ffmpeg_ok"]:
            raise RuntimeError(
                f"FFmpeg failed (rc={ff_proc.returncode}): {ff_proc.stderr.strip()}"
            )

        fp_proc = subprocess.run(
            [bins["ffprobe"], "-version"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        report["ffprobe_version"] = (
            fp_proc.stdout.splitlines()[0].strip() if fp_proc.stdout else ""
        )
        report["ffprobe_ok"] = fp_proc.returncode == 0
        if not report["ffprobe_ok"]:
            raise RuntimeError(
                f"FFprobe failed (rc={fp_proc.returncode}): {fp_proc.stderr.strip()}"
            )

        try:
            import curl_cffi  # type: ignore

            report["curl_cffi_available"] = True
            report["curl_cffi_version"] = getattr(curl_cffi, "__version__", "unknown")
        except Exception:
            report["curl_cffi_available"] = False

        try:
            from yt_dlp.networking.impersonate import ImpersonateRequestHandler

            with yt_dlp.YoutubeDL(
                {"quiet": True, "no_warnings": True, "ignoreconfig": True}
            ) as probe_ydl:
                handlers = probe_ydl._request_director.handlers
                report["request_handlers"] = [
                    f"{k}:{type(h).__name__}" for k, h in handlers.items()
                ]
                report["impersonate_handlers"] = [
                    f"{k}:{type(h).__name__}"
                    for k, h in handlers.items()
                    if isinstance(h, ImpersonateRequestHandler)
                ]
        except Exception:
            pass

        try:
            from yt_dlp.extractor import InstagramIE  # noqa: F401

            report["instagram_extractor_available"] = True
        except Exception:
            report["instagram_extractor_available"] = False

        try:
            from yt_dlp.extractor import FacebookIE, FacebookReelIE  # noqa: F401

            report["facebook_extractor_available"] = True
        except Exception:
            report["facebook_extractor_available"] = False

        try:
            dns_t0 = time.monotonic()
            infos = socket.getaddrinfo(
                "www.instagram.com", 443, type=socket.SOCK_STREAM
            )
            report["android_dns_ms"] = round((time.monotonic() - dns_t0) * 1000.0, 2)
            report["android_dns_count"] = len(infos)
            report["android_dns_ok"] = len(infos) > 0
        except Exception:
            report["android_dns_ok"] = False

        report["ok"] = True
    except Exception as exc:
        report["error"] = str(exc)

    return json.dumps(report)


def _is_legacy_android_incompatible_vcodec(vcodec) -> bool:
    if not isinstance(vcodec, str):
        return False
    lower = vcodec.strip().lower()
    return lower.startswith(("vp09", "vp9", "vp08", "vp8", "av01", "av1"))


def _is_avc_vcodec(vcodec) -> bool:
    if not isinstance(vcodec, str):
        return False
    lower = vcodec.strip().lower()
    return lower.startswith(("avc1", "avc3", "h264"))


def _is_unset_codec(codec) -> bool:
    if codec is None:
        return True
    if not isinstance(codec, str):
        return False
    return codec.strip().lower() in ("", "unknown")


def _is_audio_only_format(fmt: dict) -> bool:
    vcodec = str(fmt.get("vcodec") or "").strip().lower()
    acodec = str(fmt.get("acodec") or "").strip().lower()
    resolution = str(fmt.get("resolution") or "").strip().lower()
    audio_ext = str(fmt.get("audio_ext") or "").strip().lower()
    if vcodec == "none" and acodec not in ("", "none"):
        return True
    if resolution == "audio only" and audio_ext not in ("", "none"):
        return True
    return False


def _parse_mp4_header_metadata(data: bytes) -> dict:
    """Extracts video/audio codec FourCCs and dimensions from an ISO-BMFF header prefix."""
    result = {"vcodec": None, "acodec": None, "width": None, "height": None}
    if not isinstance(data, (bytes, bytearray)) or len(data) < 8:
        return result

    containers = {b"moov", b"trak", b"mdia", b"minf", b"stbl"}
    video_boxes = {b"avc1", b"avc3", b"hvc1", b"hev1", b"vp09", b"vp08", b"av01", b"mp4v"}
    audio_boxes = {b"mp4a", b"Opus", b"ac-3", b"ec-3"}

    def walk(start: int, end: int):
        pos = start
        while pos + 8 <= end:
            size, typ = struct.unpack(">I4s", data[pos : pos + 8])
            hdr = 8
            if size == 1:
                if pos + 16 > end:
                    break
                size = struct.unpack(">Q", data[pos + 8 : pos + 16])[0]
                hdr = 16
            elif size == 0:
                size = end - pos
            if size < hdr:
                break
            box_end = min(pos + size, end)
            body_start = pos + hdr
            if typ in containers:
                walk(body_start, box_end)
            elif typ == b"stsd":
                if body_start + 8 <= box_end:
                    walk(body_start + 8, box_end)
            elif typ in video_boxes:
                if result["vcodec"] is None:
                    result["vcodec"] = typ.decode("ascii")
                if (
                    result["width"] is None
                    and result["height"] is None
                    and body_start + 28 <= box_end
                ):
                    w, h = struct.unpack(">HH", data[body_start + 24 : body_start + 28])
                    if w > 0 and h > 0:
                        result["width"] = w
                        result["height"] = h
            elif typ in audio_boxes:
                if result["acodec"] is None:
                    result["acodec"] = typ.decode("ascii").lower()
            pos = box_end if pos + size > end else pos + size

    try:
        walk(0, len(data))
    except Exception:
        pass
    return result


def _probe_progressive_mp4_header(url: str, http_headers: dict) -> dict:
    """Fetches only the first 64 KB of a progressive MP4 to read its moov codec/size."""
    try:
        headers = {
            str(k): str(v)
            for k, v in (http_headers or {}).items()
            if str(k).lower() != "range"
        }
        headers["Range"] = f"bytes=0-{_MP4_HEADER_PROBE_BYTES - 1}"
        ctx = ssl.create_default_context(cafile=certifi.where())
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(
            req, timeout=_MP4_HEADER_PROBE_TIMEOUT_SECS, context=ctx
        ) as resp:
            status = getattr(resp, "status", None)
            if status is None and hasattr(resp, "getcode"):
                status = resp.getcode()
            chunk = resp.read(_MP4_HEADER_PROBE_BYTES)
            filesize = None
            content_range = resp.headers.get("Content-Range") if resp.headers else None
            if content_range and "/" in content_range:
                tail = content_range.rsplit("/", 1)[-1].strip()
                if tail.isdigit():
                    filesize = int(tail)
            if filesize is None and status == 200 and resp.headers:
                cl = resp.headers.get("Content-Length")
                if cl and cl.strip().isdigit():
                    filesize = int(cl.strip())
        parsed = _parse_mp4_header_metadata(chunk)
        parsed["filesize"] = filesize
        return parsed
    except Exception:
        return {}


def _adapt_instagram_formats_for_android_sdk(
    sanitized: dict, android_sdk_int: int
) -> dict:
    """Avoids VP9/AV1-in-MP4 first-frame playback stalls on Android < 10 (API < 29)."""
    try:
        sdk = int(android_sdk_int or 0)
    except (TypeError, ValueError):
        sdk = 0
    if not (0 < sdk < _ANDROID_VP9_MP4_MIN_SDK):
        return sanitized

    formats = sanitized.get("formats")
    if not isinstance(formats, list) or not formats:
        return sanitized

    incompatible_count = sum(
        1
        for f in formats
        if isinstance(f, dict)
        and _is_legacy_android_incompatible_vcodec(f.get("vcodec"))
    )
    if incompatible_count == 0:
        return sanitized

    has_explicit_avc = any(
        isinstance(f, dict) and _is_avc_vcodec(f.get("vcodec")) for f in formats
    )
    if has_explicit_avc:
        adapted = dict(sanitized)
        adapted["formats"] = [
            copy.deepcopy(f)
            for f in formats
            if not (
                isinstance(f, dict)
                and _is_legacy_android_incompatible_vcodec(f.get("vcodec"))
            )
        ]
        sys.stderr.write(
            f"[hyperdl][compat] Android API {sdk} < {_ANDROID_VP9_MP4_MIN_SDK}: "
            f"filtered {incompatible_count} non-AVC Instagram format(s); "
            "kept explicit avc1 streams.\n"
        )
        return adapted

    progressive_candidates = []
    for idx, f in enumerate(formats):
        if not isinstance(f, dict):
            continue
        ext = str(f.get("ext") or "").strip().lower()
        video_ext = str(f.get("video_ext") or "").strip().lower()
        vcodec = str(f.get("vcodec") or "").strip().lower()
        acodec = str(f.get("acodec") or "").strip().lower()
        if (
            (ext == "mp4" or video_ext == "mp4")
            and not _is_audio_only_format(f)
            and vcodec != "none"
            and acodec != "none"
            and not _is_legacy_android_incompatible_vcodec(f.get("vcodec"))
        ):
            progressive_candidates.append(idx)

    if not progressive_candidates:
        return sanitized

    top_headers = sanitized.get("http_headers") or {}
    probed_by_url = {}
    probed_count = 0
    for idx in progressive_candidates:
        if probed_count >= 3:
            break
        cand_url = str(formats[idx].get("url") or "").strip()
        if not (
            cand_url.startswith("http://") or cand_url.startswith("https://")
        ):
            continue
        if cand_url in probed_by_url:
            probe = probed_by_url[cand_url]
        else:
            merged_headers = dict(top_headers)
            merged_headers.update(formats[idx].get("http_headers") or {})
            probe = _probe_progressive_mp4_header(cand_url, merged_headers)
            probed_by_url[cand_url] = probe
            probed_count += 1
        if _is_avc_vcodec(probe.get("vcodec")):
            break

    accepted_progressive_by_idx = {}
    chosen_summary = None
    for idx in progressive_candidates:
        cand = copy.deepcopy(formats[idx])
        cand_url = str(cand.get("url") or "").strip()
        probe = probed_by_url.get(cand_url) or {}
        pv = probe.get("vcodec")
        if pv and _is_legacy_android_incompatible_vcodec(pv):
            continue

        pa = probe.get("acodec")
        pw = probe.get("width")
        ph = probe.get("height")
        psize = probe.get("filesize")

        if psize and not cand.get("filesize"):
            cand["filesize"] = psize
        if pw and ph:
            cand["width"] = pw
            cand["height"] = ph
            cand["resolution"] = f"{pw}x{ph}"

        # Never set vcodec without acodec, or Rust would classify it as VideoOnly.
        if pv and pa:
            cand["vcodec"] = pv
            cand["acodec"] = pa
            cand["audio_ext"] = "mp4"
        else:
            if _is_unset_codec(cand.get("vcodec")):
                cand.pop("vcodec", None)
            if _is_unset_codec(cand.get("acodec")):
                cand.pop("acodec", None)

        cand["video_ext"] = "mp4"
        accepted_progressive_by_idx[idx] = cand
        if chosen_summary is None:
            res_str = cand.get("resolution") or "unknown"
            chosen_summary = f"fmt={cand.get('format_id')} ({pv or 'unknown'}/{res_str})"

    if not accepted_progressive_by_idx:
        return sanitized

    filtered_formats = []
    for idx, f in enumerate(formats):
        if not isinstance(f, dict):
            continue
        if _is_audio_only_format(f):
            filtered_formats.append(copy.deepcopy(f))
        elif idx in accepted_progressive_by_idx:
            filtered_formats.append(accepted_progressive_by_idx[idx])

    if not any(not _is_audio_only_format(f) for f in filtered_formats):
        return sanitized

    sys.stderr.write(
        f"[hyperdl][compat] Android API {sdk} < {_ANDROID_VP9_MP4_MIN_SDK}: "
        f"filtered {incompatible_count} non-AVC DASH format(s); selected {chosen_summary}.\n"
    )
    adapted = dict(sanitized)
    adapted["formats"] = filtered_formats
    return adapted


def _extract_raw_info_dict(
    url: str,
    native_lib_dir: str,
    bin_dir: str,
    cache_dir: str = "",
    is_playlist: bool = False,
    is_instagram: bool = False,
    is_facebook: bool = False,
    android_sdk_int: int = 0,
) -> dict:
    _configure_tls_env()
    bins = ensure_bin_symlinks(native_lib_dir, bin_dir)
    target_url = url.strip()
    ig_mode = bool(is_instagram or _is_instagram_url(target_url))
    fb_mode = bool(is_facebook or _is_facebook_url(target_url))
    meta_mode = ig_mode or fb_mode
    classify_fn = _classify_facebook_error if fb_mode else _classify_instagram_error
    platform_label = "Facebook" if fb_mode else "Instagram"

    ydl_opts = _base_ydl_opts(bins, bin_dir, cache_dir)
    if is_playlist:
        ydl_opts["noplaylist"] = False
        ydl_opts["extract_flat"] = "in_playlist"
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(target_url, download=False)
                sanitized = ydl.sanitize_info(info)
            return {"ok": sanitized}
        except Exception as exc:
            return {"error": str(exc)}

    ydl_opts["noplaylist"] = True
    capture_logger = None
    if meta_mode:
        ydl_opts["socket_timeout"] = _INSTAGRAM_SOCKET_TIMEOUT_SECS
        capture_logger = _QuietCaptureLogger()
        ydl_opts["logger"] = capture_logger

    t0 = time.monotonic()
    last_exc = None
    sanitized = None
    max_attempts = 2 if meta_mode else 1
    for attempt in range(1, max_attempts + 1):
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(target_url, download=False)
                sanitized = ydl.sanitize_info(info)
            last_exc = None
            break
        except Exception as exc:
            last_exc = exc
            if meta_mode and attempt < max_attempts:
                combined_err = "\n".join(
                    (capture_logger.messages if capture_logger else []) + [str(exc)]
                )
                classified_err = classify_fn(combined_err)
                if classified_err.get("is_transient"):
                    if capture_logger:
                        capture_logger.messages.clear()
                    time.sleep(1.5)
                    continue
            break

    if last_exc is not None and fb_mode:
        combined_err = "\n".join(
            (capture_logger.messages if capture_logger else []) + [str(last_exc)]
        ).lower()
        if any(
            marker in combined_err
            for marker in ("no video formats", "cannot parse data", "unable to extract")
        ):
            for fallback_url in _facebook_fallback_urls(target_url):
                try:
                    if capture_logger:
                        capture_logger.messages.clear()
                    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                        info = ydl.extract_info(fallback_url, download=False)
                        sanitized = ydl.sanitize_info(info)
                    last_exc = None
                    break
                except Exception as fb_exc:
                    last_exc = fb_exc

    if last_exc is not None:
        if meta_mode:
            combined_err = "\n".join(
                (capture_logger.messages if capture_logger else []) + [str(last_exc)]
            )
            classified_err = classify_fn(combined_err)
            sys.stderr.write(
                f"[hyperdl][diag] Android {platform_label} inspection failed ({time.monotonic() - t0:.2f}s): "
                f"{classified_err.get('redacted_diagnostic', '')}\n"
            )
            return {"error": classified_err["user_message"]}
        return {"error": str(last_exc)}

    sanitized_for_parse = (
        _adapt_instagram_formats_for_android_sdk(sanitized, android_sdk_int)
        if meta_mode
        else sanitized
    )
    ttl = (
        _INSTAGRAM_RAW_INFO_CACHE_TTL_SECS
        if meta_mode
        else _RAW_INFO_CACHE_TTL_SECS
    )
    _raw_cache_put(sanitized, target_url, ttl_secs=ttl)
    _cache_put(sanitized_for_parse, target_url)
    return {"ok": sanitized_for_parse}


def extract_raw_info(
    url: str,
    native_lib_dir: str,
    bin_dir: str,
    cache_dir: str = "",
    is_playlist: bool = False,
    is_instagram: bool = False,
    is_facebook: bool = False,
    android_sdk_int: int = 0,
) -> str:
    """Extracts raw sanitized yt-dlp info JSON for Dart parsing & format synthesis."""
    res = _extract_raw_info_dict(
        url=url,
        native_lib_dir=native_lib_dir,
        bin_dir=bin_dir,
        cache_dir=cache_dir,
        is_playlist=bool(is_playlist),
        is_instagram=bool(is_instagram),
        is_facebook=bool(is_facebook),
        android_sdk_int=int(android_sdk_int or 0),
    )
    if "error" in res:
        return json.dumps({"error": res["error"]})
    return json.dumps({"ok": json.dumps(res["ok"])})


def inspect_media_cached(
    video_id: str,
    url: str,
    native_lib_dir: str,
    bin_dir: str,
    cache_dir: str = "",
    android_sdk_int: int = 0,
) -> str:
    """Returns raw sanitized info dict for background playlist item resolution."""
    cached = _cache_get(video_id, url)
    if cached is not None:
        return json.dumps({"ok": cached})
    res = _extract_raw_info_dict(
        url=url,
        native_lib_dir=native_lib_dir,
        bin_dir=bin_dir,
        cache_dir=cache_dir,
        is_playlist=False,
        is_instagram=_is_instagram_url(url),
        is_facebook=_is_facebook_url(url),
        android_sdk_int=int(android_sdk_int or 0),
    )
    return json.dumps(res)


def _extract_xtags_acont_py(raw_url: str) -> str:
    url = (raw_url or "").strip()
    if not url:
        return ""
    decoded = (
        url.replace("%3D", "=")
        .replace("%3d", "=")
        .replace("%3A", ":")
        .replace("%3a", ":")
        .replace("%3B", ";")
        .replace("%3b", ";")
        .lower()
    )
    for marker in ("acont=", "acont:"):
        idx = decoded.find(marker)
        if idx != -1:
            after = decoded[idx + len(marker) :]
            val = re.split(r"[:&; ]", after, maxsplit=1)[0].strip()
            if val:
                return val
    return ""


def _is_dub_format_py(fmt: dict) -> bool:
    acont = _extract_xtags_acont_py(str(fmt.get("url") or ""))
    if acont in ("dubbed", "dubbed-auto"):
        return True
    note = str(fmt.get("format_note") or "").lower()
    if "dubbed-auto" in note or "auto-dub" in note:
        return True
    return "dubbed" in re.split(r"[^a-z0-9]+", note)


def _is_orig_format_py(fmt: dict) -> bool:
    acont = _extract_xtags_acont_py(str(fmt.get("url") or ""))
    if acont == "original":
        return True
    note = str(fmt.get("format_note") or "").lower()
    return "original" in re.split(r"[^a-z0-9]+", note)


def _audio_rank_key(fmt: dict, video_lang: str, prefer_m4a: bool):
    is_dub = _is_dub_format_py(fmt)
    is_orig = _is_orig_format_py(fmt)
    lang_pref = int(fmt.get("language_preference") or 0)
    fmt_lang = str(fmt.get("language") or "").strip().lower()
    vid_lang = (video_lang or "").strip().lower()
    lang_match = bool(vid_lang and fmt_lang and fmt_lang.split("-")[0] == vid_lang.split("-")[0])
    tier = 0 if is_dub else (4 if is_orig else (3 if lang_pref > 0 else (2 if lang_match else 1)))
    is_direct = "m3u8" not in str(fmt.get("protocol") or "").lower()
    fid = str(fmt.get("format_id") or "")
    is_non_drc = not fid.endswith("-drc") and "drc" not in str(fmt.get("format_note") or "").lower()
    ext = str(fmt.get("ext") or "").lower()
    acodec = str(fmt.get("acodec") or "").lower()
    is_m4a = ext == "m4a" or acodec.startswith("mp4a")
    container_score = 2 if (is_m4a == prefer_m4a) else 1
    abr = float(fmt.get("abr") or fmt.get("tbr") or 0.0)
    return (tier, is_direct, is_non_drc, container_score, abr)


def select_playlist_item_option(
    raw_info_json: str, media_mode: str, quality_cap: str
) -> str:
    """Pure-Python playlist item format resolver for Android background execution."""
    try:
        info = json.loads(raw_info_json)
        formats = [
            f
            for f in (info.get("formats") or [])
            if isinstance(f, dict)
            and not f.get("has_drm")
            and str(f.get("ext") or "").lower() != "mhtml"
            and "storyboard" not in str(f.get("format_note") or "").lower()
        ]
        video_lang = str(info.get("language") or "")

        audios = [f for f in formats if _is_audio_only_format(f)]
        has_non_dub = any(not _is_dub_format_py(a) for a in audios)
        if has_non_dub:
            audios_clean = [a for a in audios if not _is_dub_format_py(a)]
        else:
            audios_clean = audios

        if media_mode == "AudioOnly":
            if not audios_clean:
                return json.dumps({"error": "No downloadable Audio Only stream discovered for this item."})
            direct_audios = [a for a in audios_clean if "m3u8" not in str(a.get("protocol") or "").lower()]
            pool = direct_audios or audios_clean
            best_a = max(pool, key=lambda f: _audio_rank_key(f, video_lang, True))
            ext = str(best_a.get("ext") or "m4a").lower()
            br = best_a.get("abr") or best_a.get("tbr")
            q_label = f"{ext.upper()} · {round(float(br))} kbps" if br else ext.upper()
            return json.dumps({
                "ok": {
                    "selection": {"kind": "Single", "format_id": str(best_a["format_id"])},
                    "quality_label": q_label,
                    "container": ext,
                    "audio_language": None,
                }
            })

        cap_map = {
            "BestAvailable": 100000,
            "UpTo1080p": 1080,
            "UpTo720p": 720,
            "UpTo480p": 480,
        }
        max_h = cap_map.get(quality_cap, 100000)

        muxed = []
        video_only = []
        for f in formats:
            if _is_audio_only_format(f):
                continue
            vc = str(f.get("vcodec") or "").lower()
            ac = str(f.get("acodec") or "").lower()
            if vc == "none":
                continue
            w = int(f.get("width") or 0)
            h = int(f.get("height") or 0)
            eff_h = min(w, h) if (w > 0 and h > 0) else (h if h > 0 else 0)
            if eff_h <= 0:
                continue
            if ac != "none" and (ac != "" or str(f.get("video_ext") or "")):
                muxed.append((eff_h, f))
            else:
                video_only.append((eff_h, f))

        candidates = []
        all_heights = sorted({h for h, _ in muxed} | {h for h, _ in video_only}, reverse=True)
        for h in all_heights:
            v_list = [f for fh, f in video_only if fh == h]
            m_list = [f for fh, f in muxed if fh == h and (not has_non_dub or not _is_dub_format_py(f))]
            if v_list and audios_clean:
                best_v = max(v_list, key=lambda f: (
                    "m3u8" not in str(f.get("protocol") or "").lower(),
                    round(float(f.get("fps") or 0)),
                    1 if str(f.get("ext") or "").lower() == "mp4" else 0,
                    float(f.get("tbr") or 0),
                ))
                prefer_m4a = str(best_v.get("ext") or "").lower() == "mp4"
                best_a = max(audios_clean, key=lambda f: _audio_rank_key(f, video_lang, prefer_m4a))
                container = "mp4" if (prefer_m4a or str(best_a.get("ext") or "").lower() == "m4a") else "webm"
                candidates.append((h, best_v, best_a, container, False))
            elif m_list:
                best_m = max(m_list, key=lambda f: (
                    "m3u8" not in str(f.get("protocol") or "").lower(),
                    round(float(f.get("fps") or 0)),
                    float(f.get("tbr") or 0),
                ))
                container = str(best_m.get("ext") or "mp4").lower()
                candidates.append((h, best_m, None, container, True))

        if not candidates:
            unknown_muxed = [
                f
                for f in formats
                if not _is_audio_only_format(f)
                and str(f.get("vcodec") or "").lower() != "none"
                and str(f.get("acodec") or "").lower() != "none"
                and str(f.get("ext") or "").lower() in ("mp4", "webm", "mkv", "mov")
            ]
            if not unknown_muxed:
                return json.dumps({"error": "No playable Video with Sound formats available for this item."})
            best_unknown = max(
                unknown_muxed,
                key=lambda f: (
                    2 if str(f.get("format_id") or "").lower() == "hd"
                    else (1 if str(f.get("format_id") or "").lower() == "sd" else 0),
                    float(f.get("tbr") or 0),
                ),
            )
            fid = str(best_unknown["format_id"])
            container = str(best_unknown.get("ext") or "mp4").lower()
            res_tag = "HD" if fid.lower() == "hd" else ("SD" if fid.lower() == "sd" else "Standard")
            return json.dumps({
                "ok": {
                    "selection": {"kind": "Single", "format_id": fid},
                    "quality_label": f"{res_tag} {container.upper()}",
                    "container": container,
                    "audio_language": None,
                }
            })

        chosen = next((c for c in candidates if c[0] <= max_h), candidates[-1])
        h, v_fmt, a_fmt, container, is_muxed = chosen
        fps = v_fmt.get("fps")
        fps_part = f" {round(float(fps))}fps" if fps and float(fps) >= 45.0 else ""
        res_label = "4K (2160p)" if h == 2160 else f"{h}p"
        quality_label = f"{res_label}{fps_part} {container.upper()}"

        if is_muxed or a_fmt is None:
            selection = {"kind": "Single", "format_id": str(v_fmt["format_id"])}
        else:
            selection = {
                "kind": "VideoAndAudio",
                "video_format_id": str(v_fmt["format_id"]),
                "audio_format_id": str(a_fmt["format_id"]),
                "merge_container": container,
            }
        return json.dumps({
            "ok": {
                "selection": selection,
                "quality_label": quality_label,
                "container": container,
                "audio_language": None,
            }
        })
    except Exception as exc:
        return json.dumps({"error": str(exc)})


def _cleanup_incomplete_temp_mux_files(staging_dir: str):
    """Removes incomplete *.temp.* mux targets while keeping completed raw stream files & .part files."""
    if not os.path.isdir(staging_dir):
        return
    for name in os.listdir(staging_dir):
        lower = name.lower()
        if ".temp." in lower and not lower.endswith(".part"):
            try:
                os.remove(os.path.join(staging_dir, name))
            except OSError:
                pass


def _find_staged_output_file(staging_dir: str, preferred_paths: list) -> str:
    for candidate in preferred_paths:
        if (
            candidate
            and os.path.isfile(candidate)
            and not candidate.endswith(".part")
            and not candidate.endswith(".ytdl")
            and ".temp." not in os.path.basename(candidate).lower()
            and os.path.getsize(candidate) > 0
        ):
            return candidate
    if os.path.isdir(staging_dir):
        candidates = []
        for name in os.listdir(staging_dir):
            entry = os.path.join(staging_dir, name)
            base = name.lower()
            if (
                os.path.isfile(entry)
                and not base.endswith(".part")
                and not base.endswith(".ytdl")
                and ".temp." not in base
                and os.path.getsize(entry) > 0
            ):
                candidates.append(entry)
        if candidates:
            candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
            return candidates[0]
    return ""


def _build_format_spec(selection: dict) -> tuple:
    kind = selection.get("kind")
    if kind == "VideoAndAudio":
        vid = str(selection.get("video_format_id") or "").strip()
        aid = str(selection.get("audio_format_id") or "").strip()
        container = str(selection.get("merge_container") or "mp4").strip() or "mp4"
        if not vid or not aid:
            raise ValueError("Missing video_format_id or audio_format_id")
        return f"{vid}+{aid}", container
    fid = str(selection.get("format_id") or "").strip()
    if not fid:
        raise ValueError("Missing format_id for single format selection")
    return fid, None


def _run_download_once(
    job_id: str,
    url: str,
    selection: dict,
    staging_dir: str,
    outtmpl: str,
    native_lib_dir: str,
    bin_dir: str,
    cache_dir: str,
    progress_cb,
    cached_info=None,
    is_instagram: bool = False,
    is_facebook: bool = False,
) -> dict:
    _ensure_popen_tracker()
    _configure_tls_env()
    bins = ensure_bin_symlinks(native_lib_dir, bin_dir)
    os.makedirs(staging_dir, exist_ok=True)
    _cleanup_incomplete_temp_mux_files(staging_dir)

    format_expr, merge_container = _build_format_spec(selection)

    state = {
        "last_downloaded": 0,
        "last_total": None,
        "last_estimated": False,
        "last_emit_ts": 0.0,
        "detected_paths": [],
        "phase": "Analyzing",
        "received_first_byte": False,
        "last_stage_msg": None,
    }

    def _emit(
        phase: str,
        downloaded: int,
        total,
        is_est: bool,
        speed=None,
        eta=None,
        output_path=None,
        message=None,
    ):
        if progress_cb is None:
            return
        safe_speed = None
        if speed is not None:
            speed_val = float(speed)
            if math.isfinite(speed_val):
                safe_speed = speed_val
        payload = {
            "job_id": job_id,
            "phase": phase,
            "downloaded_bytes": int(max(0, downloaded)),
            "total_bytes": int(total) if total is not None else None,
            "is_total_estimated": bool(is_est),
            "speed_bytes_per_sec": safe_speed,
            "eta_seconds": int(eta) if eta is not None else None,
            "output_path": output_path,
            "message": message,
        }
        _emit_cb(progress_cb, json.dumps(payload))

    def _emit_stage(message: str):
        if state["received_first_byte"]:
            return
        if state["last_stage_msg"] == message:
            return
        state["last_stage_msg"] = message
        state["phase"] = "Analyzing"
        _emit(
            "Analyzing",
            0,
            state["last_total"],
            state["last_estimated"],
            message=message,
        )

    def _progress_hook(d: dict):
        if _is_job_cancelled(job_id):
            raise yt_dlp.utils.DownloadCancelled("Canceled by user")

        status = d.get("status")
        downloaded = int(d.get("downloaded_bytes") or 0)
        exact_total = d.get("total_bytes")
        est_total = d.get("total_bytes_estimate")
        if exact_total is not None:
            state["last_total"] = int(exact_total)
            state["last_estimated"] = False
        elif est_total is not None:
            state["last_total"] = int(est_total)
            state["last_estimated"] = True

        fn = d.get("filename") or (d.get("info_dict") or {}).get("filepath")
        if fn:
            state["detected_paths"].append(fn)

        if downloaded == 0 and status != "finished":
            if status == "downloading":
                _emit_stage("Connecting to media server...")
            return

        effective_downloaded = (
            downloaded
            if downloaded > 0
            else (state["last_total"] if state["last_total"] is not None else state["last_downloaded"])
        )
        state["last_downloaded"] = effective_downloaded

        if status == "downloading":
            now = time.monotonic()
            is_first_byte = not state["received_first_byte"]
            if is_first_byte:
                state["received_first_byte"] = True
            elif now - state["last_emit_ts"] < 0.15:
                return
            state["last_emit_ts"] = now
            state["phase"] = "Downloading"
            _emit(
                "Downloading",
                effective_downloaded,
                state["last_total"],
                state["last_estimated"],
                speed=d.get("speed"),
                eta=d.get("eta"),
            )
        elif status == "finished":
            if not state["received_first_byte"] and effective_downloaded > 0:
                state["received_first_byte"] = True
            state["phase"] = "Downloading"
            _emit(
                "Downloading",
                effective_downloaded,
                state["last_total"],
                state["last_estimated"],
                message="Stream downloaded, preparing next step...",
            )

    def _postprocessor_hook(d: dict):
        if _is_job_cancelled(job_id):
            raise yt_dlp.utils.DownloadCancelled("Canceled by user")

        pp = d.get("postprocessor") or "Merger"
        status = d.get("status")
        fp = (d.get("info_dict") or {}).get("filepath")
        if fp:
            state["detected_paths"].append(fp)
        if status in ("started", "processing"):
            state["phase"] = "Merging"
            _emit(
                "Merging",
                state["last_downloaded"],
                state["last_total"],
                state["last_estimated"],
                message=f"Running {pp} with FFmpeg...",
            )

    meta_mode = is_instagram or is_facebook
    platform_label = "Facebook" if is_facebook else "Instagram"
    job_logger = _WorkerJobLogger(job_id, meta_mode, _emit_stage)
    ydl_opts = _base_ydl_opts(bins, bin_dir, cache_dir)
    ydl_opts.update(
        {
            "noplaylist": True,
            "continuedl": True,
            "nopart": False,
            "nomtime": True,
            "format": format_expr,
            "outtmpl": outtmpl,
            "progress_hooks": [_progress_hook],
            "postprocessor_hooks": [_postprocessor_hook],
            "logger": job_logger,
        }
    )
    if meta_mode:
        ydl_opts["socket_timeout"] = _INSTAGRAM_SOCKET_TIMEOUT_SECS
    if merge_container:
        ydl_opts["merge_output_format"] = merge_container

    if cached_info is None:
        _emit_stage(
            f"Connecting to {platform_label}..."
            if meta_mode
            else "Preparing yt-dlp download..."
        )

    prev_job = getattr(_CURRENT_JOB, "job_id", None)
    _CURRENT_JOB.job_id = job_id
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            if cached_info is not None:
                _emit_stage("Starting download from cached analysis...")
                prepared = _prepare_reusable_info(cached_info)
                info = ydl.process_ie_result(prepared, download=True)
            else:
                info = ydl.extract_info(url.strip(), download=True)
            if info:
                fp = info.get("filepath")
                if fp:
                    state["detected_paths"].append(fp)
                for req_dl in info.get("requested_downloads") or []:
                    rfp = req_dl.get("filepath")
                    if rfp:
                        state["detected_paths"].append(rfp)
                try:
                    state["detected_paths"].append(ydl.prepare_filename(info))
                except Exception:
                    pass
    except yt_dlp.utils.DownloadCancelled:
        _cleanup_incomplete_temp_mux_files(staging_dir)
        return {
            "canceled": True,
            "downloaded_bytes": state["last_downloaded"],
            "total_bytes": state["last_total"],
            "is_total_estimated": state["last_estimated"],
        }
    except Exception as exc:
        _cleanup_incomplete_temp_mux_files(staging_dir)
        if _is_job_cancelled(job_id):
            return {
                "canceled": True,
                "downloaded_bytes": state["last_downloaded"],
                "total_bytes": state["last_total"],
                "is_total_estimated": state["last_estimated"],
            }
        err_text = "\n".join(job_logger.messages + [str(exc)]) if job_logger.messages else str(exc)
        return {
            "error": err_text,
            "downloaded_bytes": state["last_downloaded"],
            "total_bytes": state["last_total"],
            "is_total_estimated": state["last_estimated"],
        }
    finally:
        _CURRENT_JOB.job_id = prev_job
        with _TRACK_LOCK:
            _ACTIVE_SUBPROCESSES.pop(job_id, None)

    if _is_job_cancelled(job_id):
        _cleanup_incomplete_temp_mux_files(staging_dir)
        return {
            "canceled": True,
            "downloaded_bytes": state["last_downloaded"],
            "total_bytes": state["last_total"],
            "is_total_estimated": state["last_estimated"],
        }

    final_path = _find_staged_output_file(staging_dir, list(reversed(state["detected_paths"])))
    if not final_path:
        return {
            "error": "Download finished cleanly, but output file could not be located in staging."
        }

    size_bytes = os.path.getsize(final_path)
    return {
        "ok": {
            "output_path": final_path,
            "total_bytes": size_bytes,
        }
    }


def execute_single_download(
    job_id: str,
    request_json: str,
    staging_dir: str,
    native_lib_dir: str,
    bin_dir: str,
    cache_dir: str,
    progress_cb,
) -> str:
    """Executes a single-video download + optional FFmpeg merge with cached-info reuse and retries."""
    clear_job_cancelled(job_id)
    req = json.loads(request_json)
    url = str(req["url"])
    selection = req["selection"]
    outtmpl = req.get("output_template") or os.path.join(
        staging_dir, "%(title).60B [%(id)s] [%(format_id)s].%(ext)s"
    )

    normalized_url = url.strip()
    is_instagram = _is_instagram_url(normalized_url)
    is_facebook = _is_facebook_url(normalized_url)
    meta_mode = is_instagram or is_facebook
    platform_label = "Facebook" if is_facebook else "Instagram"
    classify_fn = _classify_facebook_error if is_facebook else _classify_instagram_error

    cached_raw = (
        _raw_cache_get(normalized_url)
        or _raw_cache_get(url)
        or (
            _raw_cache_get("", video_id=_extract_facebook_numeric_id(normalized_url))
            if is_facebook
            else None
        )
    )
    res = _run_download_once(
        job_id,
        normalized_url,
        selection,
        staging_dir,
        outtmpl,
        native_lib_dir,
        bin_dir,
        cache_dir,
        progress_cb,
        cached_info=cached_raw,
        is_instagram=is_instagram,
        is_facebook=is_facebook,
    )
    if "error" in res and not _is_job_cancelled(job_id):
        if meta_mode:
            if cached_raw is not None and int(res.get("downloaded_bytes") or 0) == 0:
                _raw_cache_evict(normalized_url, cached_raw.get("id"))
                _raw_cache_evict(url, cached_raw.get("id"))
                if progress_cb is not None:
                    _emit_cb(
                        progress_cb,
                        json.dumps(
                            {
                                "job_id": job_id,
                                "phase": "Analyzing",
                                "downloaded_bytes": 0,
                                "total_bytes": None,
                                "is_total_estimated": False,
                                "speed_bytes_per_sec": None,
                                "eta_seconds": None,
                                "output_path": None,
                                "message": f"Connecting to {platform_label}...",
                            }
                        ),
                    )
                res = _run_download_once(
                    job_id,
                    normalized_url,
                    selection,
                    staging_dir,
                    outtmpl,
                    native_lib_dir,
                    bin_dir,
                    cache_dir,
                    progress_cb,
                    cached_info=None,
                    is_instagram=is_instagram,
                    is_facebook=is_facebook,
                )
            if (
                "error" in res
                and int(res.get("downloaded_bytes") or 0) == 0
                and not _is_job_cancelled(job_id)
            ):
                classified_err = classify_fn(res["error"])
                if classified_err.get("is_transient"):
                    if progress_cb is not None:
                        _emit_cb(
                            progress_cb,
                            json.dumps(
                                {
                                    "job_id": job_id,
                                    "phase": "Analyzing",
                                    "downloaded_bytes": 0,
                                    "total_bytes": None,
                                    "is_total_estimated": False,
                                    "speed_bytes_per_sec": None,
                                    "eta_seconds": None,
                                    "output_path": None,
                                    "message": f"Retrying connection to {platform_label}...",
                                }
                            ),
                        )
                    _sleep_cancelable(job_id, 1.5)
                    if not _is_job_cancelled(job_id):
                        res = _run_download_once(
                            job_id,
                            normalized_url,
                            selection,
                            staging_dir,
                            outtmpl,
                            native_lib_dir,
                            bin_dir,
                            cache_dir,
                            progress_cb,
                            cached_info=None,
                            is_instagram=is_instagram,
                            is_facebook=is_facebook,
                        )
            if "error" in res and not _is_job_cancelled(job_id):
                classified_err = classify_fn(res["error"])
                sys.stderr.write(
                    f"[hyperdl][diag] Android {platform_label} download failed: "
                    f"{classified_err.get('redacted_diagnostic', '')}\n"
                )
                res["error"] = classified_err["user_message"]
        else:
            if cached_raw is not None:
                _raw_cache_evict(normalized_url, cached_raw.get("id"))
                _raw_cache_evict(url, cached_raw.get("id"))
                res = _run_download_once(
                    job_id,
                    normalized_url,
                    selection,
                    staging_dir,
                    outtmpl,
                    native_lib_dir,
                    bin_dir,
                    cache_dir,
                    progress_cb,
                    cached_info=None,
                    is_instagram=False,
                    is_facebook=False,
                )
            if (
                "error" in res
                and "HTTP Error 403" in res["error"]
                and not _is_job_cancelled(job_id)
            ):
                _sleep_cancelable(job_id, 1.5)
                if not _is_job_cancelled(job_id):
                    res = _run_download_once(
                        job_id,
                        normalized_url,
                        selection,
                        staging_dir,
                        outtmpl,
                        native_lib_dir,
                        bin_dir,
                        cache_dir,
                        progress_cb,
                        cached_info=None,
                        is_instagram=False,
                        is_facebook=False,
                    )
    return json.dumps(res)
