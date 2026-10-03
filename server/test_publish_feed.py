import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from publish_feed import publish, validate


def example():
    return {"schema_version": 1, "generated_at": "2026-10-02T08:00:00Z", "items": [
        {"id": "one", "title": "今日内容", "summary": "摘要", "content": "# 正文", "source": "Hermes", "published_at": "2026-10-02T08:00:00Z"}
    ]}


def v2_example():
    feed = example()
    feed["schema_version"] = 2
    feed["title"] = "我的科技订阅"
    feed["description"] = "开源项目与科技动态"
    return feed


class PublishTests(unittest.TestCase):
    def test_publishes_unicode_content(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "feed.json"
            publish(example(), output)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["items"][0]["title"], "今日内容")

    def test_invalid_publish_retains_last_success(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "feed.json"
            publish(example(), output)
            before = output.read_bytes()
            broken = example()
            broken["items"][0]["title"] = ""
            with self.assertRaises(ValueError):
                publish(broken, output)
            self.assertEqual(output.read_bytes(), before)

    def test_replacement_failure_retains_old_file_and_removes_temporary(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "feed.json"
            publish(example(), output)
            before = output.read_bytes()
            with patch("publish_feed.os.replace", side_effect=OSError("disk error")):
                with self.assertRaises(OSError):
                    publish(example(), output)
            self.assertEqual(output.read_bytes(), before)
            self.assertEqual([file.name for file in Path(directory).iterdir()], ["feed.json"])

    def test_rejects_duplicate_ids_bad_dates_and_unsafe_urls(self):
        duplicate = example()
        duplicate["items"].append(copy.deepcopy(duplicate["items"][0]))
        bad_date = example()
        bad_date["generated_at"] = "2026-10-02T08:00:00"
        unsafe = example()
        unsafe["items"][0]["url"] = "javascript:alert(1)"
        bad_tags = example()
        bad_tags["items"][0]["tags"] = [1]
        bad_platform = example()
        bad_platform["items"][0]["platform"] = "unknown"
        for feed in (duplicate, bad_date, unsafe, bad_tags, bad_platform):
            with self.subTest(feed=feed), self.assertRaises(ValueError):
                validate(feed)

    def test_accepts_optional_platform(self):
        for platform in ("github", "pixiv", "twitter", "other"):
            feed = example()
            feed["items"][0]["platform"] = platform
            self.assertEqual(validate(feed), feed)

    def test_accepts_v2_with_free_platform_and_feed_metadata(self):
        feed = v2_example()
        feed["items"][0]["platform"] = "Mastodon"
        self.assertEqual(validate(feed), feed)

    def test_v2_allows_missing_or_null_platform(self):
        null_platform = v2_example()
        null_platform["items"][0]["platform"] = None
        self.assertEqual(validate(null_platform), null_platform)
        self.assertEqual(validate(v2_example()), v2_example())

    def test_v2_rejects_non_string_platform_and_metadata(self):
        bad_platform = v2_example()
        bad_platform["items"][0]["platform"] = 3
        bad_title = v2_example()
        bad_title["title"] = ["not", "a", "string"]
        for feed in (bad_platform, bad_title):
            with self.subTest(feed=feed), self.assertRaises(ValueError):
                validate(feed)


if __name__ == "__main__":
    unittest.main()
