import json
import os
import tempfile
import time
import unittest
from unittest import mock

import hyperdl_worker


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


if __name__ == "__main__":
    unittest.main()
