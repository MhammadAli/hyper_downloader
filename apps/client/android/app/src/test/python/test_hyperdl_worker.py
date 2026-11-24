import json
import os
import struct
import tempfile
import time
import unittest
from unittest import mock

import hyperdl_worker


def _box(typ: bytes, payload: bytes) -> bytes:
    return struct.pack(">I4s", 8 + len(payload), typ) + payload


def _build_synthetic_mp4_header(
    vcodec: bytes = b"avc1", acodec: bytes = b"mp4a", width: int = 720, height: int = 1280
) -> bytes:
    ftyp = _box(b"ftyp", b"isom\x00\x00\x02\x00isomiso2mp41")
    video_entry_body = (b"\x00" * 24) + struct.pack(">HH", width, height) + (b"\x00" * 50)
    video_stsd = _box(b"stsd", struct.pack(">II", 0, 1) + _box(vcodec, video_entry_body))
    video_trak = _box(b"trak", _box(b"mdia", _box(b"minf", _box(b"stbl", video_stsd))))

    audio_entry_body = b"\x00" * 28
    audio_stsd = _box(b"stsd", struct.pack(">II", 0, 1) + _box(acodec, audio_entry_body))
    audio_trak = _box(b"trak", _box(b"mdia", _box(b"minf", _box(b"stbl", audio_stsd))))

    moov = _box(b"moov", video_trak + audio_trak)
    return ftyp + moov


class _FakeRustLib:
    def hyperdl_classify_url_json(self, raw_url):
        return 1

    def hyperdl_classify_instagram_error_json(self, raw_err):
        return 1

    def hyperdl_parse_media_inspection_json(self, raw_json):
        return 1


class HyperdlWorkerInstagramTests(unittest.TestCase):
    def setUp(self):
        with hyperdl_worker._CACHE_LOCK:
            hyperdl_worker._RAW_INFO_CACHE.clear()
            hyperdl_worker._INSPECTION_CACHE.clear()
        with hyperdl_worker._TRACK_LOCK:
            hyperdl_worker._CANCELLED_JOBS.clear()
            hyperdl_worker._ACTIVE_SUBPROCESSES.clear()

    def test_prepare_reusable_info_strips_format_and_ephemeral_keys(self):
        raw = {
            "id": "DTVTvUDj-b1",
            "title": "Reel",
            "format_id": "1",
            "format": "1 - mp4",
            "ext": "mp4",
            "filename": "old.mp4",
            "_filename": "old.mp4",
            "filepath": "/tmp/old.mp4",
            "requested_formats": [{"format_id": "dash-v"}],
            "requested_downloads": [{"filepath": "/tmp/old.mp4"}],
            "requested_subtitles": {},
            "__files_to_move": {},
            "__postprocessors": [],
            "formats": [{"format_id": "dash-a"}],
        }
        cleaned = hyperdl_worker._prepare_reusable_info(raw)
        for key in (
            "format_id",
            "format",
            "ext",
            "filename",
            "_filename",
            "filepath",
            "requested_formats",
            "requested_downloads",
            "requested_subtitles",
            "__files_to_move",
            "__postprocessors",
        ):
            self.assertNotIn(key, cleaned)
        self.assertEqual(cleaned["id"], "DTVTvUDj-b1")
        self.assertEqual(cleaned["formats"], [{"format_id": "dash-a"}])

    def test_raw_cache_respects_instagram_and_youtube_ttls(self):
        url = "https://www.instagram.com/reel/DTVTvUDj-b1/"
        hyperdl_worker._raw_cache_put({"id": "DTVTvUDj-b1"}, url, ttl_secs=0.05)
        self.assertIsNotNone(hyperdl_worker._raw_cache_get(url))
        time.sleep(0.08)
        self.assertIsNone(hyperdl_worker._raw_cache_get(url))

        yt_url = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
        hyperdl_worker._raw_cache_put({"id": "aqz-KE-bpKQ"}, yt_url, ttl_secs=10.0)
        self.assertIsNotNone(hyperdl_worker._raw_cache_get(yt_url))

    def test_cleanup_incomplete_temp_mux_files_preserves_part_and_ytdl(self):
        with tempfile.TemporaryDirectory() as td:
            temp_mux = os.path.join(td, "reel.temp.mp4")
            part_file = os.path.join(td, "reel.f1.mp4.part")
            ytdl_file = os.path.join(td, "reel.mp4.ytdl")
            for p in (temp_mux, part_file, ytdl_file):
                with open(p, "wb") as f:
                    f.write(b"123")
            hyperdl_worker._cleanup_incomplete_temp_mux_files(td)
            self.assertFalse(os.path.exists(temp_mux))
            self.assertTrue(os.path.exists(part_file))
            self.assertTrue(os.path.exists(ytdl_file))

    def test_worker_job_logger_maps_stages_and_cancels_promptly(self):
        stages = []
        logger = hyperdl_worker._WorkerJobLogger("job-1", True, stages.append)
        logger.debug("[Instagram] Setting up session")
        logger.debug("[Instagram] DTVTvUDj-b1: Downloading webpage")
        logger.info("[info] DTVTvUDj-b1: Downloading 1 format(s): dash-v+dash-a")
        logger.debug("[download] Destination: /tmp/out.mp4")
        self.assertEqual(
            stages,
            [
                "Connecting to Instagram...",
                "Resolving media...",
                "Resolving media...",
                "Starting download...",
            ],
        )

        hyperdl_worker._CANCELLED_JOBS.add("job-1")
        with self.assertRaises(hyperdl_worker.yt_dlp.utils.DownloadCancelled):
            logger.debug("anything")

    def test_run_download_once_gates_zero_byte_downloading_and_isolates_youtube_opts(self):
        captured_opts = []
        events = []

        class _FakeYdl:
            def __init__(self, opts):
                self.opts = opts
                captured_opts.append(opts)

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=True):
                self.opts["logger"].debug("[Instagram] Setting up session")
                for hook in self.opts["progress_hooks"]:
                    hook({"status": "downloading", "downloaded_bytes": 0, "total_bytes": 1000})
                    hook(
                        {
                            "status": "downloading",
                            "downloaded_bytes": 500,
                            "total_bytes": 1000,
                            "speed": 250.0,
                            "eta": 2,
                        }
                    )
                    hook({"status": "finished", "downloaded_bytes": 1000, "total_bytes": 1000})
                out_path = self.opts["outtmpl"].replace("%(title).100B [%(id)s] [%(format_id)s].%(ext)s", "out.mp4")
                with open(out_path, "wb") as f:
                    f.write(b"media")
                return {"filepath": out_path}

            def prepare_filename(self, info):
                return info["filepath"]

        with tempfile.TemporaryDirectory() as td:
            with mock.patch.object(
                hyperdl_worker,
                "ensure_bin_symlinks",
                return_value={
                    "qjs_native": "/bin/qjs",
                    "ffmpeg": "/bin/ffmpeg",
                    "ffprobe": "/bin/ffprobe",
                },
            ), mock.patch.object(
                hyperdl_worker, "_configure_tls_env", return_value="/tmp/cacert.pem"
            ), mock.patch.object(
                hyperdl_worker.yt_dlp, "YoutubeDL", _FakeYdl
            ):
                # Instagram job gets socket_timeout=40 and never emits Downloading with 0 bytes.
                res_ig = hyperdl_worker._run_download_once(
                    "job-ig",
                    "https://www.instagram.com/reel/DTVTvUDj-b1/",
                    {"kind": "Single", "format_id": "1"},
                    td,
                    os.path.join(td, "ig.mp4"),
                    "/native",
                    "/bin",
                    "",
                    lambda raw: events.append(json.loads(raw)),
                    is_instagram=True,
                )
                self.assertIn("ok", res_ig)
                self.assertEqual(captured_opts[0].get("socket_timeout"), 40)
                zero_dl = [
                    ev for ev in events if ev["phase"] == "Downloading" and ev["downloaded_bytes"] == 0
                ]
                self.assertEqual(zero_dl, [])
                self.assertTrue(
                    any(ev["phase"] == "Downloading" and ev["downloaded_bytes"] == 500 for ev in events)
                )

                # YouTube job must NOT receive Instagram's socket_timeout=40.
                events.clear()
                res_yt = hyperdl_worker._run_download_once(
                    "job-yt",
                    "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
                    {"kind": "Single", "format_id": "18"},
                    td,
                    os.path.join(td, "yt.mp4"),
                    "/native",
                    "/bin",
                    "",
                    lambda raw: events.append(json.loads(raw)),
                    is_instagram=False,
                )
                self.assertIn("ok", res_yt)
                self.assertNotIn("socket_timeout", captured_opts[1])

    def test_inspect_media_normalizes_instagram_url_and_maps_errors(self):
        fake_lib = _FakeRustLib()
        seen_urls = []

        class _FakeYdl:
            def __init__(self, opts):
                self.opts = opts

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=False):
                seen_urls.append((url, self.opts.get("socket_timeout")))
                raise RuntimeError("ERROR: HTTP Error 429: Too Many Requests")

        def fake_call_rust(_lib, fn, *args):
            if fn == fake_lib.hyperdl_classify_url_json:
                return {
                    "ok": {
                        "is_playlist": False,
                        "normalized_url": "https://www.instagram.com/reel/DTVTvUDj-b1/",
                        "platform": "InstagramReel",
                        "shortcode": "DTVTvUDj-b1",
                    }
                }
            if fn == fake_lib.hyperdl_classify_instagram_error_json:
                return {
                    "ok": {
                        "user_message": "Instagram temporarily rate-limited requests. Please wait a few minutes and try again.",
                        "redacted_diagnostic": "ERROR: HTTP Error 429: Too Many Requests",
                        "is_transient": False,
                    }
                }
            return {"error": "unexpected"}

        with mock.patch.object(
            hyperdl_worker, "_configure_tls_env", return_value="/tmp/cacert.pem"
        ), mock.patch.object(
            hyperdl_worker,
            "ensure_bin_symlinks",
            return_value={"qjs_native": "/bin/qjs", "ffmpeg": "/bin/ffmpeg", "ffprobe": "/bin/ffprobe"},
        ), mock.patch.object(
            hyperdl_worker, "_load_rust_lib", return_value=fake_lib
        ), mock.patch.object(
            hyperdl_worker, "_call_rust_str", side_effect=fake_call_rust
        ), mock.patch.object(
            hyperdl_worker.yt_dlp, "YoutubeDL", _FakeYdl
        ):
            out = hyperdl_worker._inspect_media_dict(
                "https://m.instagram.com/reels/DTVTvUDj-b1/?igsh=xyz",
                "/native",
                "/bin",
                "",
            )
        self.assertEqual(seen_urls, [("https://www.instagram.com/reel/DTVTvUDj-b1/", 40)])
        self.assertIn("rate-limited", out["error"])

    def test_parse_mp4_header_metadata_extracts_codecs_dimensions_and_handles_truncation(self):
        avc_header = _build_synthetic_mp4_header(b"avc1", b"mp4a", 720, 1280)
        self.assertEqual(
            hyperdl_worker._parse_mp4_header_metadata(avc_header),
            {"vcodec": "avc1", "acodec": "mp4a", "width": 720, "height": 1280},
        )

        vp9_header = _build_synthetic_mp4_header(b"vp09", b"mp4a", 1080, 1920)
        self.assertEqual(
            hyperdl_worker._parse_mp4_header_metadata(vp9_header)["vcodec"],
            "vp09",
        )

        # Truncate moov payload before the end of audio_trak -> video_trak still parses cleanly.
        truncated = avc_header[:-18]
        parsed_truncated = hyperdl_worker._parse_mp4_header_metadata(truncated)
        self.assertEqual(parsed_truncated["vcodec"], "avc1")
        self.assertEqual(parsed_truncated["width"], 720)
        self.assertEqual(parsed_truncated["height"], 1280)
        self.assertEqual(
            hyperdl_worker._parse_mp4_header_metadata(b"bad"),
            {"vcodec": None, "acodec": None, "width": None, "height": None},
        )

    def test_android_9_filters_vp9_instagram_dash_and_probes_progressive_mp4(self):
        fake_lib = _FakeRustLib()
        captured_parse_payloads = []
        raw_reel = {
            "id": "DTVTvUDj-b1",
            "title": "Video by rahulmfg",
            "webpage_url": "https://www.instagram.com/reel/DTVTvUDj-b1/",
            "extractor_key": "Instagram",
            "formats": [
                {
                    "format_id": "dash-904995479368697a",
                    "ext": "m4a",
                    "vcodec": "none",
                    "acodec": "mp4a.40.5",
                    "resolution": "audio only",
                    "protocol": "https",
                },
                {
                    "format_id": "1",
                    "ext": "mp4",
                    "video_ext": "mp4",
                    "audio_ext": "none",
                    "vcodec": None,
                    "acodec": None,
                    "url": "https://cdn.example.com/prog1.mp4",
                },
                {
                    "format_id": "2",
                    "ext": "mp4",
                    "video_ext": "mp4",
                    "audio_ext": "none",
                    "vcodec": None,
                    "acodec": None,
                    "url": "https://cdn.example.com/prog2.mp4",
                },
                {
                    "format_id": "dash-3838628822936334v",
                    "ext": "mp4",
                    "vcodec": "vp09.00.40.08",
                    "acodec": "none",
                    "width": 1080,
                    "height": 1920,
                    "url": "https://cdn.example.com/dash_vp9.mp4",
                },
            ],
        }

        class _FakeYdl:
            def __init__(self, opts):
                self.opts = opts

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=False):
                return raw_reel

            def sanitize_info(self, info):
                return info

        def fake_call_rust(_lib, fn, *args):
            if fn == fake_lib.hyperdl_classify_url_json:
                return {
                    "ok": {
                        "is_playlist": False,
                        "normalized_url": "https://www.instagram.com/reel/DTVTvUDj-b1/",
                        "platform": "InstagramReel",
                        "shortcode": "DTVTvUDj-b1",
                    }
                }
            if fn == fake_lib.hyperdl_parse_media_inspection_json:
                parsed_input = json.loads(args[0])
                captured_parse_payloads.append(parsed_input)
                return {
                    "ok": {
                        "id": "DTVTvUDj-b1",
                        "video_options": [{"resolution": "720p", "video_format_id": "1"}],
                        "audio_options": [{"format_id": "dash-904995479368697a"}],
                    }
                }
            return {"error": "unexpected"}

        with mock.patch.object(
            hyperdl_worker, "_configure_tls_env", return_value="/tmp/cacert.pem"
        ), mock.patch.object(
            hyperdl_worker,
            "ensure_bin_symlinks",
            return_value={"qjs_native": "/bin/qjs", "ffmpeg": "/bin/ffmpeg", "ffprobe": "/bin/ffprobe"},
        ), mock.patch.object(
            hyperdl_worker, "_load_rust_lib", return_value=fake_lib
        ), mock.patch.object(
            hyperdl_worker, "_call_rust_str", side_effect=fake_call_rust
        ), mock.patch.object(
            hyperdl_worker.yt_dlp, "YoutubeDL", _FakeYdl
        ), mock.patch.object(
            hyperdl_worker,
            "_probe_progressive_mp4_header",
            return_value={
                "vcodec": "avc1",
                "acodec": "mp4a",
                "width": 720,
                "height": 1280,
                "filesize": 1514829,
            },
        ) as probe_mock:
            out = hyperdl_worker._inspect_media_dict(
                "https://www.instagram.com/reel/DTVTvUDj-b1/",
                "/native",
                "/bin",
                "",
                android_sdk_int=28,
            )

        self.assertIn("ok", out)
        # Stops probing after format 1 is confirmed avc1.
        self.assertEqual(probe_mock.call_count, 1)
        sent_formats = captured_parse_payloads[0]["formats"]
        sent_ids = [f["format_id"] for f in sent_formats]
        self.assertEqual(sent_ids, ["dash-904995479368697a", "1", "2"])
        fmt1 = next(f for f in sent_formats if f["format_id"] == "1")
        self.assertEqual(fmt1["vcodec"], "avc1")
        self.assertEqual(fmt1["acodec"], "mp4a")
        self.assertEqual(fmt1["width"], 720)
        self.assertEqual(fmt1["height"], 1280)
        self.assertEqual(fmt1["resolution"], "720x1280")
        self.assertEqual(fmt1["filesize"], 1514829)
        self.assertEqual(fmt1["audio_ext"], "mp4")

        # Original untouched formats (including dash vp09) stay in _RAW_INFO_CACHE.
        cached = hyperdl_worker._raw_cache_get("https://www.instagram.com/reel/DTVTvUDj-b1/")
        self.assertIsNotNone(cached)
        self.assertEqual(
            [f["format_id"] for f in cached["formats"]],
            ["dash-904995479368697a", "1", "2", "dash-3838628822936334v"],
        )

    def test_android_9_probe_failure_or_missing_acodec_keeps_muxed_progressive_classification_safe(self):
        raw = {
            "id": "DTVTvUDj-b1",
            "formats": [
                {"format_id": "dash-a", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.5", "resolution": "audio only"},
                {"format_id": "1", "ext": "mp4", "video_ext": "mp4", "audio_ext": "none", "vcodec": "unknown", "acodec": "unknown", "url": "https://cdn.example.com/p1.mp4"},
                {"format_id": "dash-v", "ext": "mp4", "vcodec": "vp09.00.40.08", "acodec": "none", "width": 1080, "height": 1920},
            ],
        }
        with mock.patch.object(
            hyperdl_worker,
            "_probe_progressive_mp4_header",
            return_value={"vcodec": "avc1", "acodec": None, "width": 720, "height": 1280, "filesize": 12345},
        ):
            adapted = hyperdl_worker._adapt_instagram_formats_for_android_sdk(raw, 28)

        self.assertEqual([f["format_id"] for f in adapted["formats"]], ["dash-a", "1"])
        fmt1 = adapted["formats"][1]
        self.assertNotIn("vcodec", fmt1)
        self.assertNotIn("acodec", fmt1)
        self.assertEqual(fmt1["video_ext"], "mp4")
        self.assertEqual(fmt1["filesize"], 12345)

        with mock.patch.object(hyperdl_worker, "_probe_progressive_mp4_header", return_value={}):
            adapted_fail = hyperdl_worker._adapt_instagram_formats_for_android_sdk(raw, 28)
        self.assertEqual([f["format_id"] for f in adapted_fail["formats"]], ["dash-a", "1"])
        self.assertNotIn("vcodec", adapted_fail["formats"][1])
        self.assertNotIn("acodec", adapted_fail["formats"][1])

    def test_android_9_keeps_explicit_avc1_dash_and_handles_vp9_only_fallback(self):
        avc_dash_reel = {
            "id": "CDUMkliABpa",
            "formats": [
                {"format_id": "dash-a", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "resolution": "audio only"},
                {"format_id": "1", "ext": "mp4", "video_ext": "mp4", "audio_ext": "none", "vcodec": None, "acodec": None},
                {"format_id": "dash-v720", "ext": "mp4", "vcodec": "avc1.4d401f", "acodec": "none", "width": 720, "height": 1280},
                {"format_id": "dash-vp9", "ext": "mp4", "vcodec": "vp09.00.40.08", "acodec": "none", "width": 1080, "height": 1920},
            ],
        }
        with mock.patch.object(hyperdl_worker, "_probe_progressive_mp4_header") as probe_mock:
            adapted = hyperdl_worker._adapt_instagram_formats_for_android_sdk(avc_dash_reel, 28)
        probe_mock.assert_not_called()
        self.assertEqual([f["format_id"] for f in adapted["formats"]], ["dash-a", "1", "dash-v720"])

        vp9_only_reel = {
            "id": "VP9_ONLY",
            "formats": [
                {"format_id": "dash-a", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.5", "resolution": "audio only"},
                {"format_id": "dash-vp9", "ext": "mp4", "vcodec": "vp09.00.40.08", "acodec": "none", "width": 1080, "height": 1920},
            ],
        }
        adapted_only = hyperdl_worker._adapt_instagram_formats_for_android_sdk(vp9_only_reel, 28)
        self.assertIs(adapted_only, vp9_only_reel)

    def test_android_14_and_default_sdk_and_youtube_leave_vp9_untouched(self):
        vp9_reel = {
            "id": "DTVTvUDj-b1",
            "formats": [
                {"format_id": "dash-a", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.5", "resolution": "audio only"},
                {"format_id": "1", "ext": "mp4", "video_ext": "mp4", "audio_ext": "none", "url": "https://cdn.example.com/p1.mp4"},
                {"format_id": "dash-vp9", "ext": "mp4", "vcodec": "vp09.00.40.08", "acodec": "none", "width": 1080, "height": 1920},
            ],
        }
        with mock.patch.object(hyperdl_worker, "_probe_progressive_mp4_header") as probe_mock:
            self.assertIs(
                hyperdl_worker._adapt_instagram_formats_for_android_sdk(vp9_reel, 34),
                vp9_reel,
            )
            self.assertIs(
                hyperdl_worker._adapt_instagram_formats_for_android_sdk(vp9_reel, 0),
                vp9_reel,
            )
        probe_mock.assert_not_called()

        # YouTube inspection on Android 9 must NOT run Instagram adaptation.
        fake_lib = _FakeRustLib()
        seen_formats = []

        class _FakeYtYdl:
            def __init__(self, opts):
                pass

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=False):
                return {
                    "id": "aqz-KE-bpKQ",
                    "extractor_key": "Youtube",
                    "formats": [
                        {"format_id": "248", "ext": "webm", "vcodec": "vp9", "acodec": "none", "width": 1920, "height": 1080},
                        {"format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "resolution": "audio only"},
                    ],
                }

            def sanitize_info(self, info):
                return info

        def fake_call_yt(_lib, fn, *args):
            if fn == fake_lib.hyperdl_classify_url_json:
                return {
                    "ok": {
                        "is_playlist": False,
                        "normalized_url": "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
                        "platform": "YouTube",
                        "shortcode": None,
                    }
                }
            if fn == fake_lib.hyperdl_parse_media_inspection_json:
                seen_formats.append([f["format_id"] for f in json.loads(args[0])["formats"]])
                return {"ok": {"id": "aqz-KE-bpKQ", "video_options": [], "audio_options": []}}
            return {"error": "unexpected"}

        with mock.patch.object(
            hyperdl_worker, "_configure_tls_env", return_value="/tmp/cacert.pem"
        ), mock.patch.object(
            hyperdl_worker,
            "ensure_bin_symlinks",
            return_value={"qjs_native": "/bin/qjs", "ffmpeg": "/bin/ffmpeg", "ffprobe": "/bin/ffprobe"},
        ), mock.patch.object(
            hyperdl_worker, "_load_rust_lib", return_value=fake_lib
        ), mock.patch.object(
            hyperdl_worker, "_call_rust_str", side_effect=fake_call_yt
        ), mock.patch.object(
            hyperdl_worker.yt_dlp, "YoutubeDL", _FakeYtYdl
        ):
            out = hyperdl_worker._inspect_media_dict(
                "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
                "/native",
                "/bin",
                "",
                android_sdk_int=28,
            )
        self.assertIn("ok", out)
        self.assertEqual(seen_formats, [["248", "140"]])


if __name__ == "__main__":
    unittest.main()
