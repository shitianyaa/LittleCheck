"""Validate feed JSON (schema 1 or 2) and atomically publish a static feed; stdlib only."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
from datetime import datetime
from urllib.parse import urlparse


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamps must include a timezone")
    return parsed


def validate(feed):
    if not isinstance(feed, dict) or type(feed.get("schema_version")) is not int or feed["schema_version"] not in (1, 2):
        raise ValueError("schema_version must be 1 or 2")
    if feed["schema_version"] == 2:
        for key in ("title", "description"):
            if feed.get(key) is not None and not isinstance(feed[key], str):
                raise ValueError(f"{key} must be a string")
    timestamp(feed.get("generated_at"))
    items = feed.get("items")
    if not isinstance(items, list) or len(items) > 500:
        raise ValueError("items must be a list of at most 500 entries")
    ids = set()
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("each item must be an object")
        for key in ("id", "title", "summary", "content", "source", "published_at"):
            if not isinstance(item.get(key), str):
                raise ValueError(f"{key} must be a string")
        if not item["id"].strip() or not item["title"].strip():
            raise ValueError("id and title must be nonempty")
        if item["id"] in ids:
            raise ValueError("duplicate item id")
        ids.add(item["id"])
        timestamp(item["published_at"])
        if item.get("url") is not None:
            if not isinstance(item["url"], str):
                raise ValueError("url must be a string")
            url = urlparse(item["url"])
            if url.scheme not in ("https", "http") or not url.hostname or url.username or url.password:
                raise ValueError("url must be an HTTP(S) URL without credentials")
        if feed["schema_version"] == 1:
            if "platform" in item and item["platform"] not in ("github", "pixiv", "twitter", "other"):
                raise ValueError("platform must be github/pixiv/twitter/other")
        elif item.get("platform") is not None and not isinstance(item["platform"], str):
            raise ValueError("platform must be a string")
        tags = item.get("tags", [])
        if not isinstance(tags, list) or any(not isinstance(tag, str) for tag in tags):
            raise ValueError("tags must be a string list")
    return feed


def publish(feed, output):
    validate(feed)
    content = (json.dumps(feed, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if len(content) > 2 * 1024 * 1024:
        raise ValueError("feed exceeds the 2 MiB client limit")
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".feed-", suffix=".tmp", delete=False) as handle:
            temporary = handle.name
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, output)
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="Hermes JSON output, or - for stdin")
    parser.add_argument("output", help="web-served feed.json path")
    args = parser.parse_args()
    try:
        if args.input == "-":
            source = sys.stdin.read(2 * 1024 * 1024 + 1)
        else:
            with open(args.input, encoding="utf-8") as handle:
                source = handle.read(2 * 1024 * 1024 + 1)
        if len(source.encode("utf-8")) > 2 * 1024 * 1024:
            raise ValueError("input exceeds 2 MiB")
        publish(json.loads(source), args.output)
    except (OSError, ValueError, TypeError) as error:
        print(f"Publish failed; previous feed retained: {error}", file=sys.stderr)
        return 1
    print("Feed published successfully")
    return 0


if __name__ == "__main__":
    sys.exit(main())
