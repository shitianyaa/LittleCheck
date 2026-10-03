import copy
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

from PIL import Image
import generate_feed as generator
from publish_feed import validate


def item(identity="gh:new", url="https://github.com/example/repo", content=""):
    return {"id": identity, "title": "test", "summary": "summary", "content": content,
            "source": "test", "url": url, "published_at": "2026-10-02T08:00:00Z"}


class GeneratorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cfg = {"output_feed_path": str(self.root / "feed.json"),
                    "output_candidate_path": str(self.root / "candidate.json"),
                    "media_caching": {"cache_dir": str(self.root / "media"),
                        "base_url": "https://example.org/media", "concurrency": 8,
                        "max_cache_mb": 0}}
        self.cfg["media_caching"]["enabled"] = False

    def previous(self, items):
        feed = {"schema_version": 1, "generated_at": "2026-10-02T07:00:00Z", "items": items}
        (self.root / "feed.json").write_text(json.dumps(feed), encoding="utf-8")

    def run_main(self, github, twitter=None, result=0):
        with patch.object(generator, "load_config", return_value=self.cfg), \
             patch.object(generator, "fetch_github_trending", return_value=github), \
             patch.object(generator, "fetch_twitter_circle_updates", return_value=twitter or []), \
             patch.object(generator, "fetch_pixiv_daily_ranking", return_value=[]), \
             patch.object(generator, "fetch_pixiv_tag_artworks", return_value=[]), \
             patch.object(generator.subprocess, "run", return_value=Mock(returncode=result)), \
             patch.object(generator, "prune_media_cache") as prune:
            status = generator.main()
            return status, prune.call_count

    def test_partial_source_failure_retains_old_items_and_classifies(self):
        old = item("tw:old", "https://x.com/test/status/1")
        self.previous([old])
        status, cleanup = self.run_main([item()])
        self.assertEqual((status, cleanup), (0, 1))
        candidate = json.loads((self.root / "candidate.json").read_text())
        self.assertEqual(candidate["schema_version"], 2)
        self.assertEqual({x["id"]: x["platform"] for x in candidate["items"]},
                         {"gh:new": "github", "tw:old": "twitter"})
        self.assertEqual(candidate["items"][1]["published_at"], old["published_at"])

    def test_publisher_failure_never_prunes_old_cache(self):
        self.previous([item("gh:old")])
        before = (self.root / "feed.json").read_bytes()
        self.assertEqual(self.run_main([item()], result=1), (1, 0))
        self.assertEqual((self.root / "feed.json").read_bytes(), before)

    def test_all_sources_fail_preserves_generated_time_and_candidate(self):
        self.previous([item("gh:old")])
        self.assertEqual(self.run_main([]), (1, 0))
        self.assertFalse((self.root / "candidate.json").exists())
        self.assertEqual(json.loads((self.root / "feed.json").read_text())["generated_at"],
                         "2026-10-02T07:00:00Z")

    def test_cleanup_protects_current_previous_and_recent_images(self):
        cfg = self.cfg["media_caching"]
        cfg["enabled"] = True
        directory = Path(cfg["cache_dir"])
        directory.mkdir()
        for name in ("current", "previous", "recent", "old"):
            path = directory / f"{name}.webp"
            path.write_bytes(b"test")
            if name != "recent": os.utime(path, (time.time() - 9 * 86400,) * 2)
        current = [item(content="![image](https://example.org/media/current.webp)")]
        previous = [item(content="![image](https://example.org/media/previous.webp)")]
        generator.prune_media_cache(current, previous, self.cfg)
        self.assertEqual({p.name for p in directory.iterdir()},
                         {"current.webp", "previous.webp", "recent.webp"})

    def test_cached_urls_skip_download_and_failure_retains_original(self):
        self.cfg["media_caching"]["enabled"] = True
        rows = [item(content="![old](https://example.org/media/old.webp)\n![new](https://i.pximg.net/new.jpg)")]
        with patch.object(generator, "cache_and_compress_image", side_effect=lambda url, _: (url, None)) as download:
            self.assertEqual(generator.process_media_caching(copy.deepcopy(rows), self.cfg), rows)
            self.assertEqual(download.call_count, 1)
            self.assertEqual(download.call_args.args[0], "https://i.pximg.net/new.jpg")

    def test_webp_compression_reuse_and_failed_write_cleanup(self):
        image = io.BytesIO()
        Image.new("RGB", (100, 50), "blue").save(image, "PNG")
        cfg = self.cfg["media_caching"]
        cfg["max_dimension"] = 40
        url = "https://i.pximg.net/image.png"
        opener = Mock()
        opener.open.return_value = io.BytesIO(image.getvalue())
        opener.open.return_value.headers = {}
        with patch.object(generator.urllib.request, "build_opener", return_value=opener):
            _, cached = generator.cache_and_compress_image(url, cfg)
            self.assertIsNotNone(cached)
            request = opener.open.call_args.args[0]
            self.assertEqual(request.get_header("Referer"), "https://www.pixiv.net/")
            with Image.open(next(Path(cfg["cache_dir"]).glob("*.webp"))) as saved:
                self.assertEqual(saved.size, (40, 20))
            generator.cache_and_compress_image(url, cfg)
            self.assertEqual(opener.open.call_count, 1)
        opener.open.return_value = io.BytesIO(image.getvalue())
        opener.open.return_value.headers = {}
        with patch.object(generator.urllib.request, "build_opener", return_value=opener), \
             patch.object(generator.os, "replace", side_effect=OSError("disk failure")):
            self.assertIsNone(generator.cache_and_compress_image("https://i.pximg.net/other.png", cfg)[1])
        self.assertFalse(list(Path(cfg["cache_dir"]).glob(".tmp-*")))

    def test_untrusted_image_hosts_and_redirects_rejected(self):
        self.assertTrue(generator.allowed_image_url("https://i.pximg.net/example.jpg"))
        for value in ("http://127.0.0.1/private", "https://i.pximg.net.example.org/image", "https://user:pass@i.pximg.net/image"):
            self.assertFalse(generator.allowed_image_url(value))
        with self.assertRaises(ValueError):
            generator.ImageRedirects().redirect_request(None, None, 302, "redirect", {}, "http://127.0.0.1/")

    def test_total_image_transfer_deadline_is_enforced(self):
        response = io.BytesIO(b"image")
        response.headers = {}
        opener = Mock()
        opener.open.return_value = response
        with patch.object(generator.urllib.request, "build_opener", return_value=opener), \
             patch.object(generator.time, "monotonic", side_effect=[0, 30]):
            self.assertIsNone(generator.cache_and_compress_image("https://i.pximg.net/image.png", self.cfg["media_caching"])[1])
        self.assertFalse(list(Path(self.cfg["media_caching"]["cache_dir"]).glob("*.webp")))

    def test_pixiv_prefers_regular_preview_and_keeps_original_fallback(self):
        raw = "https://i.pixiv.re/img-original/img/2026/10/02/00/00/00/12345_p1.png"
        urls = generator.image_download_candidates(raw)
        self.assertEqual(urls[0], "https://i.pximg.net/img-master/img/2026/10/02/00/00/00/12345_p1_master1200.jpg")
        self.assertEqual(urls[-1], raw)
        self.assertEqual(generator.image_download_candidates("https://pbs.twimg.com/image.jpg"),
                         ["https://pbs.twimg.com/image.jpg"])
        response = io.BytesIO(b"image")
        response.headers = {}
        opener = Mock()
        opener.open.side_effect = [OSError("preview unavailable"), response]
        with patch.object(generator.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(generator.download_image(raw, {}, 100, 1, time.monotonic()+10), b"image")
        self.assertEqual(opener.open.call_count, 2)

    def test_malformed_config_is_not_replaced_with_defaults(self):
        path = self.root / "config.json"
        path.write_text("{broken")
        with patch.object(generator, "CONFIG_PATH", path), self.assertRaises(RuntimeError):
            generator.load_config()

    def test_publisher_accepts_legacy_items_without_platform(self):
        validate({"schema_version": 1, "generated_at": "2026-10-02T08:00:00Z", "items": [item()]})


if __name__ == "__main__":
    unittest.main()
