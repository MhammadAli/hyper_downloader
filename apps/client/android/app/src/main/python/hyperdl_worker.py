"""Chaquopy Python 3.13 media runtime worker for HyperDownload on Android.

Wraps `yt-dlp`, `yt-dlp-ejs`, `libqjs.so` (QuickJS-NG), `libffmpeg.so`,
`libffprobe.so`, and the canonical Rust logic inside `libengine_ffi.so`.
"""

from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
import copy
import ctypes
import importlib.metadata
import json
import math
import os
import socket
import subprocess
import sys
import threading
import time

import certifi
import yt_dlp
import yt_dlp_ejs

_SYMLINK_LOCK = threading.Lock()
_RUST_LIB_LOCK = threading.Lock()
_RUST_LIB = None

_CACHE_LOCK = threading.Lock()
_INSPECTION_CACHE = {}
_RAW_INFO_CACHE = OrderedDict()
_RAW_INFO_CACHE_MAX = 64
_RAW_INFO_CACHE_TTL_SECS = 1800.0
_INSTAGRAM_RAW_INFO_CACHE_TTL_SECS = 900.0
_INSTAGRAM_SOCKET_TIMEOUT_SECS = 40

_TRACK_LOCK = threading.Lock()
_CURRENT_JOB = threading.local()
_ACTIVE_SUBPROCESSES = {}
_CANCELLED_JOBS = set()
_CANCELLED_ESTIMATIONS = set()
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


def cancel_size_estimation(estimation_id: str):
    with _TRACK_LOCK:
        _CANCELLED_ESTIMATIONS.add(estimation_id)


def _is_estimation_cancelled(estimation_id: str) -> bool:
    with _TRACK_LOCK:
        return estimation_id in _CANCELLED_ESTIMATIONS


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


def _load_rust_lib(native_lib_dir: str):
    global _RUST_LIB
    with _RUST_LIB_LOCK:
        if _RUST_LIB is not None:
            return _RUST_LIB

        lib_path = os.path.join(native_lib_dir, "libengine_ffi.so")
        if not os.path.isfile(lib_path):
            raise FileNotFoundError(f"Missing Rust engine library: {lib_path}")

        lib = ctypes.CDLL(lib_path)

        lib.hyperdl_parse_media_inspection_json.argtypes = [ctypes.c_char_p]
        lib.hyperdl_parse_media_inspection_json.restype = ctypes.c_void_p

        lib.hyperdl_parse_playlist_inspection_json.argtypes = [
            ctypes.c_char_p,
            ctypes.c_char_p,
        ]
        lib.hyperdl_parse_playlist_inspection_json.restype = ctypes.c_void_p

        lib.hyperdl_select_playlist_item_option_json.argtypes = [
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_char_p,
        ]
        lib.hyperdl_select_playlist_item_option_json.restype = ctypes.c_void_p

        lib.hyperdl_build_playlist_size_estimate_json.argtypes = [ctypes.c_char_p]
        lib.hyperdl_build_playlist_size_estimate_json.restype = ctypes.c_void_p

        lib.hyperdl_classify_url_json.argtypes = [ctypes.c_char_p]
        lib.hyperdl_classify_url_json.restype = ctypes.c_void_p

        if hasattr(lib, "hyperdl_classify_instagram_error_json"):
            lib.hyperdl_classify_instagram_error_json.argtypes = [ctypes.c_char_p]
            lib.hyperdl_classify_instagram_error_json.restype = ctypes.c_void_p

        lib.hyperdl_free_string.argtypes = [ctypes.c_void_p]
        lib.hyperdl_free_string.restype = None

        _RUST_LIB = lib
        return _RUST_LIB


def _call_rust_str(lib, fn, *str_args: str) -> dict:
    encoded = [arg.encode("utf-8") for arg in str_args]
    ptr = fn(*encoded)
    if not ptr:
        raise RuntimeError("Rust C-ABI call returned a null pointer.")
    try:
        raw_bytes = ctypes.cast(ptr, ctypes.c_char_p).value
        if raw_bytes is None:
            raise RuntimeError("Rust C-ABI call returned empty C string.")
        return json.loads(raw_bytes.decode("utf-8"))
    finally:
        lib.hyperdl_free_string(ptr)


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
        info_id = str(info_dict.get("id") or "").strip()
        if info_id:
            keys.append(f"id:{info_id}")
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


def _classify_instagram_error(rust_lib, raw_error: str) -> dict:
    text = str(raw_error or "").strip()
    if rust_lib is not None and hasattr(rust_lib, "hyperdl_classify_instagram_error_json"):
        try:
            res = _call_rust_str(
                rust_lib, rust_lib.hyperdl_classify_instagram_error_json, text
            )
            if "ok" in res and isinstance(res["ok"], dict):
                return res["ok"]
        except Exception:
            pass
    lower = text.lower()
    if any(t in lower for t in ("429", "too many requests", "rate limit", "rate-limit")):
        msg = "Instagram temporarily rate-limited requests. Please wait a few minutes and try again."
    elif any(t in lower for t in ("404", "not found", "does not exist", "deleted", "removed")):
        msg = "This Instagram Reel is unavailable or has been deleted."
    elif any(t in lower for t in ("account is private", "private reel", "private video")):
        msg = "This Instagram Reel is private or inaccessible."
    elif any(t in lower for t in ("login required", "logged-in", "sign in", "cookies")):
        msg = "Instagram requires login to view this Reel. Only public Reels are supported without login."
    elif any(t in lower for t in ("ffmpeg", "ffprobe", "postprocessing", "muxing")):
        msg = "Failed to process video and audio streams with FFmpeg."
    elif any(t in lower for t in ("timed out", "timeout", "urlopen", "gaierror", "ssl", "dns")):
        msg = "Network error while contacting Instagram. Check your internet connection and try again."
    else:
        msg = "Instagram extraction failed. Please verify the Reel is public and try again."
    return {
        "user_message": msg,
        "redacted_diagnostic": text[:240],
        "is_transient": any(t in lower for t in ("timed out", "timeout", "urlopen", "gaierror", "reset")),
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
    """Executes Phase A runtime verification across Python, yt-dlp, EJS, QuickJS, FFmpeg, FFprobe, and Rust."""
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
        "rust_c_api_ok": False,
        "rust_instagram_classify_ok": False,
        "curl_cffi_available": False,
        "curl_cffi_version": None,
        "request_handlers": [],
        "impersonate_handlers": [],
        "instagram_extractor_available": False,
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

        rust_lib = _load_rust_lib(native_lib_dir)
        cls_res = _call_rust_str(
            rust_lib,
            rust_lib.hyperdl_classify_url_json,
            "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
        )
        report["rust_c_api_ok"] = (
            "ok" in cls_res and cls_res["ok"].get("is_playlist") is False
        )
        if not report["rust_c_api_ok"]:
            raise RuntimeError(f"Rust C-ABI check failed: {cls_res}")

        ig_cls_res = _call_rust_str(
            rust_lib,
            rust_lib.hyperdl_classify_url_json,
            "https://m.instagram.com/reels/DTVTvUDj-b1/?igsh=test",
        )
        report["rust_instagram_classify_ok"] = (
            "ok" in ig_cls_res
            and ig_cls_res["ok"].get("platform") == "InstagramReel"
            and ig_cls_res["ok"].get("shortcode") == "DTVTvUDj-b1"
            and ig_cls_res["ok"].get("is_playlist") is False
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


def _inspect_media_dict(
    url: str, native_lib_dir: str, bin_dir: str, cache_dir: str = ""
) -> dict:
    _configure_tls_env()
    bins = ensure_bin_symlinks(native_lib_dir, bin_dir)
    rust_lib = _load_rust_lib(native_lib_dir)

    cls_res = _call_rust_str(rust_lib, rust_lib.hyperdl_classify_url_json, url)
    if "error" in cls_res:
        return {"error": cls_res["error"]}

    normalized_url = cls_res["ok"].get("normalized_url") or url.strip()
    is_instagram = cls_res["ok"].get("platform") == "InstagramReel"

    ydl_opts = _base_ydl_opts(bins, bin_dir, cache_dir)
    ydl_opts["noplaylist"] = True
    capture_logger = None
    if is_instagram:
        ydl_opts["socket_timeout"] = _INSTAGRAM_SOCKET_TIMEOUT_SECS
        capture_logger = _QuietCaptureLogger()
        ydl_opts["logger"] = capture_logger

    t0 = time.monotonic()
    last_exc = None
    sanitized = None
    max_attempts = 2 if is_instagram else 1
    for attempt in range(1, max_attempts + 1):
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(normalized_url, download=False)
                sanitized = ydl.sanitize_info(info)
            last_exc = None
            break
        except Exception as exc:
            last_exc = exc
            if is_instagram and attempt < max_attempts:
                combined_err = "\n".join(
                    (capture_logger.messages if capture_logger else []) + [str(exc)]
                )
                classified_err = _classify_instagram_error(rust_lib, combined_err)
                if classified_err.get("is_transient"):
                    if capture_logger:
                        capture_logger.messages.clear()
                    time.sleep(1.5)
                    continue
            break

    if last_exc is not None:
        if is_instagram:
            combined_err = "\n".join(
                (capture_logger.messages if capture_logger else []) + [str(last_exc)]
            )
            classified_err = _classify_instagram_error(rust_lib, combined_err)
            sys.stderr.write(
                f"[hyperdl][diag] Android Instagram inspection failed ({time.monotonic() - t0:.2f}s): "
                f"{classified_err.get('redacted_diagnostic', '')}\n"
            )
            return {"error": classified_err["user_message"]}
        return {"error": str(last_exc)}

    try:
        raw_json = json.dumps(sanitized)
        parsed = _call_rust_str(
            rust_lib, rust_lib.hyperdl_parse_media_inspection_json, raw_json
        )
        if "ok" in parsed:
            _cache_put(parsed["ok"], normalized_url)
            if normalized_url != url.strip():
                _cache_put(parsed["ok"], url)
            ttl = (
                _INSTAGRAM_RAW_INFO_CACHE_TTL_SECS
                if is_instagram
                else _RAW_INFO_CACHE_TTL_SECS
            )
            _raw_cache_put(
                sanitized,
                normalized_url,
                extra_urls=[url] if normalized_url != url.strip() else None,
                ttl_secs=ttl,
            )
            if is_instagram:
                insp = parsed["ok"]
                sys.stderr.write(
                    f"[hyperdl][timing] android instagram inspect complete: total={time.monotonic() - t0:.2f}s "
                    f"video_options={len(insp.get('video_options') or [])} "
                    f"audio_options={len(insp.get('audio_options') or [])}\n"
                )
        elif is_instagram and "error" in parsed:
            err_msg = str(parsed["error"])
            if not any(
                k in err_msg.lower()
                for k in ("carousel", "unsupported", "not supported", "private")
            ):
                classified_err = _classify_instagram_error(rust_lib, err_msg)
                sys.stderr.write(
                    f"[hyperdl][diag] Android Instagram metadata parse failed: "
                    f"{classified_err.get('redacted_diagnostic', '')}\n"
                )
                return {
                    "error": "Instagram returned an unsupported media format or incomplete response."
                }
        return parsed
    except Exception as exc:
        if is_instagram:
            classified_err = _classify_instagram_error(rust_lib, str(exc))
            sys.stderr.write(
                f"[hyperdl][diag] Android Instagram inspection error: "
                f"{classified_err.get('redacted_diagnostic', '')}\n"
            )
            return {"error": classified_err["user_message"]}
        return {"error": str(exc)}


def inspect_media(
    url: str, native_lib_dir: str, bin_dir: str, cache_dir: str = ""
) -> str:
    """Inspects a single video URL via yt-dlp + QuickJS and parses via canonical Rust rules."""
    return json.dumps(_inspect_media_dict(url, native_lib_dir, bin_dir, cache_dir))


def _inspect_playlist_dict(
    url: str, native_lib_dir: str, bin_dir: str, cache_dir: str = ""
) -> dict:
    _configure_tls_env()
    bins = ensure_bin_symlinks(native_lib_dir, bin_dir)
    rust_lib = _load_rust_lib(native_lib_dir)

    cls_res = _call_rust_str(rust_lib, rust_lib.hyperdl_classify_url_json, url)
    if "error" in cls_res:
        return {"error": cls_res["error"]}
    target_url = cls_res["ok"].get("normalized_url") or url.strip()

    ydl_opts = _base_ydl_opts(bins, bin_dir, cache_dir)
    ydl_opts["noplaylist"] = False
    ydl_opts["extract_flat"] = "in_playlist"
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(target_url, download=False)
            sanitized = ydl.sanitize_info(info)
        raw_json = json.dumps(sanitized)
        return _call_rust_str(
            rust_lib,
            rust_lib.hyperdl_parse_playlist_inspection_json,
            raw_json,
            target_url,
        )
    except Exception as exc:
        return {"error": str(exc)}


def inspect_playlist(
    url: str, native_lib_dir: str, bin_dir: str, cache_dir: str = ""
) -> str:
    """Enumerates all accessible entries in a playlist via canonical Rust rules."""
    return json.dumps(_inspect_playlist_dict(url, native_lib_dir, bin_dir, cache_dir))


def inspect_url(
    url: str, native_lib_dir: str, bin_dir: str, cache_dir: str = ""
) -> str:
    """Classifies URL as SingleVideo or Playlist and runs the matching inspection."""
    _configure_tls_env()
    rust_lib = _load_rust_lib(native_lib_dir)
    cls_res = _call_rust_str(rust_lib, rust_lib.hyperdl_classify_url_json, url)
    if "error" in cls_res:
        return json.dumps({"error": cls_res["error"]})

    is_playlist = bool(cls_res["ok"].get("is_playlist"))
    normalized = cls_res["ok"].get("normalized_url") or url.strip()
    if is_playlist:
        pl_res = _inspect_playlist_dict(normalized, native_lib_dir, bin_dir, cache_dir)
        if "error" in pl_res:
            return json.dumps({"error": pl_res["error"]})
        return json.dumps(
            {
                "ok": {
                    "kind": "Playlist",
                    "video": None,
                    "playlist": pl_res["ok"],
                }
            }
        )

    vid_res = _inspect_media_dict(normalized, native_lib_dir, bin_dir, cache_dir)
    if "error" in vid_res:
        return json.dumps({"error": vid_res["error"]})
    return json.dumps(
        {
            "ok": {
                "kind": "SingleVideo",
                "video": vid_res["ok"],
                "playlist": None,
            }
        }
    )


def select_playlist_item_option(
    inspection_json: str, media_mode: str, quality_cap: str, native_lib_dir: str
) -> str:
    """Resolves the exact format selection for a playlist item via Rust `selection.rs`."""
    rust_lib = _load_rust_lib(native_lib_dir)
    res = _call_rust_str(
        rust_lib,
        rust_lib.hyperdl_select_playlist_item_option_json,
        inspection_json,
        media_mode,
        quality_cap,
    )
    return json.dumps(res)


def inspect_media_cached(
    video_id: str, url: str, native_lib_dir: str, bin_dir: str, cache_dir: str = ""
) -> str:
    """Returns a cached `MediaInspection` if present or runs `inspect_media`."""
    cached = _cache_get(video_id, url)
    if cached is not None:
        return json.dumps({"ok": cached})
    return json.dumps(_inspect_media_dict(url, native_lib_dir, bin_dir, cache_dir))


def estimate_playlist_size(
    estimation_id: str,
    request_json: str,
    native_lib_dir: str,
    bin_dir: str,
    cache_dir: str,
    estimate_cb,
) -> str:
    """Computes progressive playlist total size reusing cached per-item inspections."""
    _configure_tls_env()
    rust_lib = _load_rust_lib(native_lib_dir)
    req = json.loads(request_json)
    playlist = req["playlist"]
    media_mode = req["media_mode"]
    quality_cap = req["quality_cap"]
    entries = playlist.get("entries", [])

    item_results = {}
    uncached = []
    for entry in entries:
        if entry.get("availability") != "Available":
            continue
        order_idx = int(entry["order_index"])
        vid = str(entry.get("video_id") or "")
        entry_url = str(entry.get("url") or "")
        hit = _cache_get(vid, entry_url)
        if hit is not None:
            item_results[order_idx] = {"order_index": order_idx, "inspection": hit}
        else:
            uncached.append(entry)

    def _build_snapshot(is_calc: bool, was_canceled: bool) -> dict:
        payload = {
            "estimation_id": estimation_id,
            "playlist": playlist,
            "media_mode": media_mode,
            "quality_cap": quality_cap,
            "item_results": list(item_results.values()),
            "is_calculating": is_calc,
            "was_canceled": was_canceled,
        }
        res = _call_rust_str(
            rust_lib,
            rust_lib.hyperdl_build_playlist_size_estimate_json,
            json.dumps(payload),
        )
        if "error" in res:
            raise RuntimeError(res["error"])
        return res["ok"]

    if not uncached:
        final_snap = _build_snapshot(False, False)
        final_json = json.dumps(final_snap)
        _emit_cb(estimate_cb, final_json)
        return json.dumps({"ok": final_snap})

    initial_snap = _build_snapshot(True, False)
    _emit_cb(estimate_cb, json.dumps(initial_snap))

    lock = threading.Lock()

    def _inspect_entry(entry: dict):
        if _is_estimation_cancelled(estimation_id):
            return None
        order_idx = int(entry["order_index"])
        entry_url = str(entry.get("url") or "")
        res = _inspect_media_dict(entry_url, native_lib_dir, bin_dir, cache_dir)
        if _is_estimation_cancelled(estimation_id):
            return None
        with lock:
            if "ok" in res:
                item_results[order_idx] = {
                    "order_index": order_idx,
                    "inspection": res["ok"],
                }
            else:
                item_results[order_idx] = {
                    "order_index": order_idx,
                    "error": res.get("error", "Inspection failed"),
                }
            if not _is_estimation_cancelled(estimation_id) and estimate_cb is not None:
                snap = _build_snapshot(True, False)
                _emit_cb(estimate_cb, json.dumps(snap))
        return order_idx

    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(_inspect_entry, e) for e in uncached]
        for fut in as_completed(futures):
            try:
                fut.result()
            except Exception:
                pass

    was_canceled = _is_estimation_cancelled(estimation_id)
    final_snap = _build_snapshot(False, was_canceled)
    _emit_cb(estimate_cb, json.dumps(final_snap))
    return json.dumps({"ok": final_snap})


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

    job_logger = _WorkerJobLogger(job_id, is_instagram, _emit_stage)
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
    if is_instagram:
        ydl_opts["socket_timeout"] = _INSTAGRAM_SOCKET_TIMEOUT_SECS
    if merge_container:
        ydl_opts["merge_output_format"] = merge_container

    if cached_info is None:
        _emit_stage(
            "Connecting to Instagram..."
            if is_instagram
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
        staging_dir, "%(title).100B [%(id)s] [%(format_id)s].%(ext)s"
    )

    rust_lib = _load_rust_lib(native_lib_dir)
    cls_res = _call_rust_str(rust_lib, rust_lib.hyperdl_classify_url_json, url)
    if "error" in cls_res:
        return json.dumps({"error": cls_res["error"]})

    normalized_url = cls_res["ok"].get("normalized_url") or url.strip()
    is_instagram = cls_res["ok"].get("platform") == "InstagramReel"

    cached_raw = _raw_cache_get(normalized_url) or _raw_cache_get(url)
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
    )
    if "error" in res and not _is_job_cancelled(job_id):
        if is_instagram:
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
                                "message": "Connecting to Instagram...",
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
                    is_instagram=True,
                )
            if (
                "error" in res
                and int(res.get("downloaded_bytes") or 0) == 0
                and not _is_job_cancelled(job_id)
            ):
                classified_err = _classify_instagram_error(rust_lib, res["error"])
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
                                    "message": "Retrying connection to Instagram...",
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
                            is_instagram=True,
                        )
            if "error" in res and not _is_job_cancelled(job_id):
                classified_err = _classify_instagram_error(rust_lib, res["error"])
                sys.stderr.write(
                    f"[hyperdl][diag] Android Instagram download failed: "
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
                    )
    return json.dumps(res)
