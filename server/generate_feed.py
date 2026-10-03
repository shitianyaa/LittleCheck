#!/usr/bin/env python3
"""Generate candidate feed for Little Check and publish via publish_feed.py."""
import hashlib
import io
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from PIL import Image as PILImage
from rss_sources import fetch_rss

# Set global socket timeout to prevent any thread from hanging on slow connections
socket.setdefaulttimeout(12.0)


BASE_DIR = Path("/opt/little-check")
CONFIG_PATH = BASE_DIR / "feed_config.json"
CANDIDATE_PATH = BASE_DIR / "candidate.json"
FEED_OUTPUT_PATH = Path("/var/www/little-check/feed.json")


def now_iso() -> str:
    """Return current UTC timestamp in ISO 8601 format with Z."""
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def load_config() -> dict:
    if CONFIG_PATH.exists():
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            raise RuntimeError(f"Cannot load {CONFIG_PATH}; previous feed retained") from e
    return {
        "github_trending": {"enabled": True, "max_items": 15},
        "twitter_circles": {"enabled": True, "circles": ["coser_acgn"], "tweets_per_user": 3, "max_items": 20},
        "pixiv_ranking": {"enabled": True, "mode": "daily", "max_items": 15},
        "pixiv_tags": {"enabled": True, "tags": ["碧蓝档案", "明日方舟"], "items_per_tag": 5, "filter_ai": True, "r18_mode": 0},
        "media_caching": {
            "enabled": True,
            "cache_dir": "/var/www/little-check/media",
            "base_url": "https://feed.hika.cc.cd/media",
            "max_dimension": 1440,
            "quality": 82,
            "timeout_seconds": 12,
            "max_download_bytes": 15728640,
            "max_cache_mb": 500,
            "concurrency": 4,
        },
        "max_total_items": 70,
        "output_candidate_path": str(CANDIDATE_PATH),
        "output_feed_path": str(FEED_OUTPUT_PATH),
    }


def fetch_github_trending(max_items: int = 15) -> list[dict]:
    items = []
    url = "https://github.com/trending"
    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as resp:
            html = resp.read().decode("utf-8")
    except Exception as e:
        print(f"[Warning] Failed to fetch GitHub Trending: {e}", file=sys.stderr)
        return items

    articles = re.findall(r'<article class="Box-row">(.*?)</article>', html, re.DOTALL)
    for a in articles[:max_items]:
        # Repo name
        m_repo = re.search(r'href="/([a-zA-Z0-9_\.-]+/[a-zA-Z0-9_\.-]+)"', a)
        if not m_repo:
            continue
        repo = m_repo.group(1).strip()
        repo_url = f"https://github.com/{repo}"

        # Description
        m_desc = re.search(r'<p class="[^"]*color-fg-muted[^"]*">\s*(.*?)\s*</p>', a, re.DOTALL)
        desc = re.sub(r"<[^>]+>", "", m_desc.group(1)).strip() if m_desc else "暂无项目描述"
        desc = re.sub(r"&amp;", "&", desc)
        desc = re.sub(r"&lt;", "<", desc)
        desc = re.sub(r"&gt;", ">", desc)

        # Stars today
        m_stars = re.search(r"([0-9,]+)\s+stars\s+today", a)
        stars_today = m_stars.group(1).strip() if m_stars else ""

        # Language
        m_lang = re.search(r'itemprop="programmingLanguage">\s*(.*?)\s*</span>', a)
        lang = m_lang.group(1).strip() if m_lang else ""

        # Total stars
        m_total = re.search(r'href="/[a-zA-Z0-9_\.-]+/[a-zA-Z0-9_\.-]+/stargazers"[^>]*>\s*(.*?)\s*</a>', a, re.DOTALL)
        total_stars = re.sub(r"<[^>]+>", "", m_total.group(1)).strip() if m_total else ""

        title = f"🔥 {repo}" + (f" (+{stars_today} stars)" if stars_today else "")
        summary = desc if desc else f"GitHub Trending 项目: {repo}"

        content_lines = [
            f"### [{repo}]({repo_url})",
            "",
            f"> {desc}",
            "",
            "- **今日新增**：" + (f"`+{stars_today} stars`" if stars_today else "榜单推荐"),
        ]
        if total_stars:
            content_lines.append(f"- **总星标数**：`{total_stars}`")
        if lang:
            content_lines.append(f"- **主要语言**：`{lang}`")
        content_lines.extend(["", f"[查看 GitHub 仓库]({repo_url})"])
        content = "\n".join(content_lines)

        tags = ["GitHub", "开源"]
        if lang:
            tags.append(lang)

        item = {
            "id": f"gh:{repo}",
            "title": title,
            "summary": summary,
            "content": content,
            "source": "GitHub Trending",
            "platform": "github",
            "url": repo_url,
            "published_at": now_iso(),
            "tags": tags,
        }
        items.append(item)
    return items


def fetch_twitter_circle_updates(circles: list[str], limit_per_user: int = 3, max_items: int = 20) -> list[dict]:
    items = []
    seen_ids = set()
    for circle in circles:
        cmd = ["nitter", "circle", "run", circle, "--limit", str(limit_per_user), "--ndjson"]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if res.returncode != 0:
                print(f"[Warning] nitter circle run {circle} exited with code {res.returncode}: {res.stderr}", file=sys.stderr)
                continue
            for line in res.stdout.splitlines():
                line = line.strip()
                if not line or not line.startswith("{"):
                    continue
                try:
                    envelope = json.loads(line)
                except Exception:
                    continue
                if envelope.get("kind") != "tweet":
                    continue
                tweet = envelope.get("data") or {}
                t_id = tweet.get("id")
                if not t_id or t_id in seen_ids:
                    continue
                seen_ids.add(t_id)

                author_data = tweet.get("author") or {}
                author_name = author_data.get("name") or author_data.get("handle") or "博主"
                handle = author_data.get("handle") or ""
                text = (tweet.get("text") or "").strip()
                t_url = tweet.get("url") or f"https://x.com/{handle}/status/{t_id}"

                first_line = text.split("\n")[0][:40].strip() if text else "发布了新推文"
                title = f"🐦 {author_name} (@{handle}): {first_line}"
                summary = text[:120].strip() if text else f"{author_name} 的最新推特动态"

                content_lines = [
                    f"### {author_name} ([@{handle}](https://x.com/{handle}))",
                    "",
                    text if text else "*(无纯文本，包含附件媒体)*",
                    "",
                ]

                # Media attachments
                media_list = tweet.get("media") or []
                if media_list:
                    content_lines.append("**📷 媒体预览：**")
                    for m in media_list:
                        m_type = m.get("type", "image")
                        m_url = m.get("url")
                        if m_url and m_type == "image":
                            content_lines.append(f"![图片]({m_url})")
                        elif m_url:
                            content_lines.append(f"- [{m_type.upper()} 链接]({m_url})")
                    content_lines.append("")

                # Quote tweet
                quote = tweet.get("quote")
                if quote:
                    q_author = quote.get("author", {}).get("name") or "原作者"
                    q_text = quote.get("text", "")
                    content_lines.append(f"> 引用 **{q_author}**：{q_text}")
                    content_lines.append("")

                content_lines.append(f"[查看原始推文]({t_url})")
                content = "\n".join(content_lines)

                pub_at = tweet.get("published_at") or now_iso()
                if not pub_at.endswith("Z") and "+" not in pub_at:
                    pub_at += "Z"

                item = {
                    "id": f"tw:{t_id}",
                    "title": title,
                    "summary": summary,
                    "content": content,
                    "source": f"Twitter @{handle}",
                    "platform": "twitter",
                    "url": t_url,
                    "published_at": pub_at,
                    "tags": ["Twitter", circle],
                }
                items.append(item)
                if len(items) >= max_items:
                    break
        except Exception as e:
            print(f"[Warning] Failed running circle {circle}: {e}", file=sys.stderr)
        if len(items) >= max_items:
            break
    return items


def fetch_pixiv_daily_ranking(max_items: int = 15) -> list[dict]:
    items = []
    ranking_url = "https://www.pixiv.net/ranking.php?mode=daily&format=json"
    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
    try:
        req = urllib.request.Request(ranking_url, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        print(f"[Warning] Failed to fetch Pixiv Daily Ranking: {e}", file=sys.stderr)
        return items

    contents = data.get("contents") or []
    for art in contents[:max_items]:
        illust_id = art.get("illust_id")
        if not illust_id:
            continue
        title = art.get("title") or "无题"
        user_name = art.get("user_name") or "Pixiv画师"
        user_id = art.get("user_id", "")
        rank = art.get("rank", 0)
        yes_rank = art.get("yes_rank", 0)
        view_count = art.get("view_count", 0)
        rating_count = art.get("rating_count", 0)
        raw_url = art.get("url", "")
        mirror_img_url = raw_url.replace("https://i.pximg.net", "https://i.pixiv.re")
        artwork_url = f"https://www.pixiv.net/artworks/{illust_id}"
        art_tags = art.get("tags") or []

        item_title = f"🎨 P站日榜#{rank}: {title} (by {user_name})"
        summary = f"Pixiv 每日插画热榜第 {rank} 名，画师：{user_name}，浏览：{view_count}，收藏：{rating_count}"

        tags_str = "、".join(art_tags[:6]) if art_tags else "精选插画"
        content_lines = [
            f"### [{title}]({artwork_url})",
            "",
            f"- **画师**：[{user_name}](https://www.pixiv.net/users/{user_id})" if user_id else f"- **画师**：{user_name}",
            f"- **日榜排名**：`第 {rank} 名`" + (f" (昨日第 {yes_rank} 名)" if yes_rank > 0 else " (新上榜)"),
            f"- **热度数据**：浏览 `{view_count}` / 收藏 `{rating_count}`",
            f"- **作品标签**：`{tags_str}`",
            "",
            f"![插画]({mirror_img_url})",
            "",
            f"[在 Pixiv 浏览原作]({artwork_url})",
        ]

        item = {
            "id": f"px:rank:{illust_id}",
            "title": item_title,
            "summary": summary,
            "content": "\n".join(content_lines),
            "source": "Pixiv 日榜",
            "platform": "pixiv",
            "url": artwork_url,
            "published_at": now_iso(),
            "tags": ["Pixiv", "日榜"] + [t for t in art_tags[:4] if isinstance(t, str)],
        }
        items.append(item)
    return items


def fetch_pixiv_tag_artworks(tags: list[str], items_per_tag: int = 5, filter_ai: bool = True, r18_mode: int = 0) -> list[dict]:
    items = []
    seen_ids = set()
    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
    for tag in tags:
        encoded_tag = urllib.parse.quote(tag)
        url = f"https://api.lolicon.app/setu/v2?tag={encoded_tag}&num={items_per_tag}&r18={r18_mode}"
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            print(f"[Warning] Failed to fetch Pixiv tag '{tag}': {e}", file=sys.stderr)
            continue

        raw_list = data.get("data") or []
        for it in raw_list:
            # AI filter: aiType 2 is AI generated
            if filter_ai and it.get("aiType") == 2:
                continue
            pid = it.get("pid")
            if not pid or pid in seen_ids:
                continue
            seen_ids.add(pid)

            title = it.get("title") or "精选插画"
            author = it.get("author") or "画师"
            uid = it.get("uid", "")
            img_url = it.get("urls", {}).get("original") or it.get("urls", {}).get("regular", "")
            artwork_url = f"https://www.pixiv.net/artworks/{pid}"
            art_tags = it.get("tags") or []

            item_title = f"🎨 [{tag}] {title} (by {author})"
            summary = f"Pixiv 【{tag}】精选优质插画作品，画师：{author}"

            tags_str = "、".join(art_tags[:6]) if art_tags else tag
            content_lines = [
                f"### [{title}]({artwork_url})",
                "",
                f"- **画师**：[{author}](https://www.pixiv.net/users/{uid})" if uid else f"- **画师**：{author}",
                f"- **所属专题**：`{tag}`",
                f"- **作品标签**：`{tags_str}`",
                "",
                f"![插画]({img_url})",
                "",
                f"[在 Pixiv 浏览原作]({artwork_url})",
            ]

            item = {
                "id": f"px:tag:{pid}",
                "title": item_title,
                "summary": summary,
                "content": "\n".join(content_lines),
                "source": f"Pixiv #{tag}",
                "platform": "pixiv",
                "url": artwork_url,
                "published_at": now_iso(),
                "tags": ["Pixiv", tag] + [t for t in art_tags[:3] if t != tag and isinstance(t, str)],
            }
            items.append(item)
    return items


def allowed_image_url(value: str) -> bool:
    url = urllib.parse.urlparse(value)
    host = (url.hostname or "").lower()
    return (url.scheme in ("http", "https") and not url.username and not url.password
            and any(host == domain or host.endswith("." + domain)
                    for domain in ("pximg.net", "pixiv.re", "twimg.com")))


class ImageRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not allowed_image_url(newurl):
            raise ValueError("image redirect is outside trusted source domains")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def image_download_candidates(raw_url: str) -> list[str]:
    url = urllib.parse.urlparse(raw_url)
    if url.hostname not in ("i.pixiv.re", "i.pximg.net"):
        return [raw_url]
    native = url._replace(netloc="i.pximg.net")
    if "/img-original/" in native.path and re.search(r"/\d+_p\d+\.(jpg|jpeg|png|webp)$", native.path, re.I):
        path = re.sub(r"(/\d+_p\d+)\.[^/]+$", r"\1_master1200.jpg", native.path.replace("/img-original/", "/img-master/"))
        return list(dict.fromkeys([native._replace(path=path).geturl(), native.geturl(), raw_url]))
    return list(dict.fromkeys([native.geturl(), raw_url]))


def download_image(raw_url, headers, max_bytes, timeout, deadline):
    last_error = None
    for url in image_download_candidates(raw_url):
        try:
            if time.monotonic() > deadline:
                raise TimeoutError("image exceeded total transfer deadline")
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.build_opener(ImageRedirects()).open(request, timeout=timeout) as response:
                content_length = response.headers.get("Content-Length")
                if content_length and int(content_length) > max_bytes:
                    raise ValueError("image exceeds download limit")
                data = bytearray()
                while True:
                    if time.monotonic() > deadline:
                        raise TimeoutError("image exceeded total transfer deadline")
                    chunk = response.read1(min(65536, max_bytes + 1 - len(data)))
                    if not chunk:
                        return data
                    data.extend(chunk)
                    if len(data) > max_bytes:
                        raise ValueError("image exceeds download limit")
        except (OSError, ValueError) as error:
            last_error = error
    raise last_error


def cache_and_compress_image(raw_url: str, media_cfg: dict) -> tuple[str, str | None]:
    cache_dir = Path(media_cfg.get("cache_dir", "/var/www/little-check/media"))
    cache_dir.mkdir(parents=True, exist_ok=True)
    base_url = media_cfg.get("base_url", "https://feed.hika.cc.cd/media").rstrip("/")
    url_hash = hashlib.sha256(raw_url.encode("utf-8")).hexdigest()[:16]
    final_path = cache_dir / f"{url_hash}.webp"
    new_url = f"{base_url}/{final_path.name}"
    if final_path.exists() and final_path.stat().st_size > 0:
        return raw_url, new_url
    headers = {"User-Agent": "Mozilla/5.0"}
    host = (urllib.parse.urlparse(raw_url).hostname or "").lower()
    if host == "pximg.net" or host.endswith(".pximg.net") or host == "pixiv.re" or host.endswith(".pixiv.re"):
        headers["Referer"] = "https://www.pixiv.net/"
    temporary = None
    try:
        if not allowed_image_url(raw_url):
            raise ValueError("image URL is outside trusted source domains")
        max_bytes = int(media_cfg.get("max_download_bytes", 15 * 1024 * 1024))
        timeout = float(media_cfg.get("timeout_seconds", 12))
        deadline = time.monotonic() + timeout * 2
        data = download_image(raw_url, headers, max_bytes, timeout, deadline)
        with PILImage.open(io.BytesIO(data)) as source:
            max_dim = int(media_cfg.get("max_dimension", 1440))
            # JPEG draft downsamples in the decoder before allocating full pixels.
            source.draft("RGB", (max_dim, max_dim))
            if source.width * source.height > 20_000_000:
                raise ValueError("image exceeds 20 megapixel decode limit")
            mode = "RGBA" if source.mode in ("RGBA", "LA") or (source.mode == "P" and "transparency" in source.info) else "RGB"
            with source.convert(mode) as image:
                image.thumbnail((max_dim, max_dim), PILImage.Resampling.LANCZOS)
                with tempfile.NamedTemporaryFile(dir=cache_dir, prefix=f".tmp-{url_hash}-", suffix=".webp", delete=False) as handle:
                    temporary = handle.name
                image.save(temporary, "WEBP", quality=int(media_cfg.get("quality", 82)), method=4)
        os.chmod(temporary, 0o644)
        os.replace(temporary, final_path)
        temporary = None
        return raw_url, new_url
    except Exception as error:
        print(f"[Warning] Failed to cache image on {host}: {type(error).__name__}: {error}", file=sys.stderr)
        return raw_url, new_url if final_path.exists() and final_path.stat().st_size > 0 else None
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


IMAGE_PATTERN = re.compile(r'!\[([^\]]*)\]\((https?://[^)\s]+)\)')


def process_media_caching(items: list[dict], cfg: dict) -> list[dict]:
    media_cfg = cfg.get("media_caching", {})
    if not media_cfg.get("enabled", True):
        return items
    base_prefix = media_cfg.get("base_url", "https://feed.hika.cc.cd/media").rstrip("/") + "/"
    # Two simultaneous Pillow decoders bound memory on the 2C2G VPS.
    concurrency = min(2, max(1, int(media_cfg.get("concurrency", 2))))
    raw_urls = {match.group(2) for item in items
                for match in IMAGE_PATTERN.finditer(item.get("content", ""))
                if not match.group(2).startswith(base_prefix)}
    url_map = {}
    print(f"[Info] Caching {len(raw_urls)} images with {concurrency} workers", file=sys.stderr)
    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(cache_and_compress_image, url, media_cfg) for url in raw_urls]
        for future in as_completed(futures):
            raw_url, new_url = future.result()
            if new_url:
                url_map[raw_url] = new_url
    for item in items:
        item["content"] = IMAGE_PATTERN.sub(
            lambda match: f"![{match.group(1)}]({url_map.get(match.group(2), match.group(2))})",
            item.get("content", ""))
    return items


def prune_media_cache(items: list[dict], previous_items: list[dict], cfg: dict) -> None:
    """Only called after successful publication; protect both feed generations."""
    media_cfg = cfg.get("media_caching", {})
    if not media_cfg.get("enabled", True):
        return
    cache_dir = Path(media_cfg.get("cache_dir", "/var/www/little-check/media"))
    if not cache_dir.exists():
        return
    base_prefix = media_cfg.get("base_url", "https://feed.hika.cc.cd/media").rstrip("/") + "/"
    referenced = {urllib.parse.urlparse(match.group(2)).path.rsplit("/", 1)[-1]
                  for item in items + previous_items
                  for match in IMAGE_PATTERN.finditer(item.get("content", ""))
                  if match.group(2).startswith(base_prefix)}
    files = [p for p in cache_dir.glob("*.webp") if p.is_file() and not p.is_symlink()]
    total = sum(p.stat().st_size for p in files)
    limit = float(media_cfg.get("max_cache_mb", 500)) * 1024 * 1024
    # Keep recent unreferenced images for phones still displaying older caches.
    cutoff = time.time() - 7 * 24 * 60 * 60
    removable = sorted((p for p in files if p.name not in referenced and p.stat().st_mtime < cutoff),
                       key=lambda p: p.stat().st_mtime)
    for p in removable:
        if total <= limit:
            break
        size = p.stat().st_size
        p.unlink()
        total -= size
    if total > limit:
        print("[Warning] Image cache remains over budget; referenced/recent files retained", file=sys.stderr)


def main() -> int:
    cfg = load_config()
    feed_output = Path(cfg.get("output_feed_path", str(FEED_OUTPUT_PATH)))
    previous_items = json.loads(feed_output.read_text(encoding="utf-8")).get("items", []) if feed_output.exists() else []
    all_items = []
    fresh_count = 0

    def retain_source(items, prefix):
        nonlocal fresh_count
        fresh_count += len(items)
        if items:
            return items
        previous = [dict(item) for item in previous_items if item.get("id", "").startswith(prefix)]
        print(f"[Warning] Source {prefix} returned no items; retaining {len(previous)} previous items", file=sys.stderr)
        return previous

    gh = cfg.get("github_trending", {})
    if gh.get("enabled", True):
        all_items.extend(retain_source(fetch_github_trending(max_items=gh.get("max_items", 15)), "gh:"))
    tw = cfg.get("twitter_circles", {})
    if tw.get("enabled", True):
        all_items.extend(retain_source(fetch_twitter_circle_updates(
            circles=tw.get("circles", ["coser_acgn"]), limit_per_user=tw.get("tweets_per_user", 3),
            max_items=tw.get("max_items", 20)), "tw:"))
    ranking = cfg.get("pixiv_ranking", {})
    if ranking.get("enabled", True):
        all_items.extend(retain_source(fetch_pixiv_daily_ranking(max_items=ranking.get("max_items", 15)), "px:rank:"))
    tags = cfg.get("pixiv_tags", {})
    if tags.get("enabled", True):
        all_items.extend(retain_source(fetch_pixiv_tag_artworks(
            tags=tags.get("tags", ["碧蓝档案", "明日方舟"]), items_per_tag=tags.get("items_per_tag", 5),
            filter_ai=tags.get("filter_ai", True), r18_mode=tags.get("r18_mode", 0)), "px:tag:"))
    for source in cfg.get("extra_sources", []):
        if source.get("enabled", True):
            all_items.extend(retain_source(fetch_rss(source), "rss:" + source["id"] + ":"))
    if not fresh_count:
        print("[Error] All enabled sources returned no new results; previous feed/time retained", file=sys.stderr)
        return 1
    seen_ids = set()
    final_items = []
    for item in all_items:
        if item.get("id") and item["id"] not in seen_ids:
            seen_ids.add(item["id"])
            if "platform" not in item:
                host = (urllib.parse.urlparse(item.get("url", "")).hostname or "").lower()
                item["platform"] = "github" if host == "github.com" or host.endswith(".github.com") else "pixiv" if host == "pixiv.net" or host.endswith(".pixiv.net") else "twitter" if any(host == d or host.endswith("." + d) for d in ("x.com", "twitter.com")) else "other"
            final_items.append(item)
    final_items = final_items[:int(cfg.get("max_total_items", 70))]
    final_items = process_media_caching(final_items, cfg)
    feed = {"schema_version": 2, "generated_at": now_iso(), "items": final_items}
    candidate_file = Path(cfg.get("output_candidate_path", str(CANDIDATE_PATH)))
    from publish_feed import publish
    publish(feed, candidate_file)
    result = subprocess.run([sys.executable, str(BASE_DIR / "publish_feed.py"), str(candidate_file), str(feed_output)])
    if result.returncode:
        print(f"[Error] Publisher failed with code {result.returncode}; previous feed retained", file=sys.stderr)
        return result.returncode
    try:
        prune_media_cache(final_items, previous_items, cfg)
    except Exception as error:
        print(f"[Warning] Published successfully but cache cleanup failed: {error}", file=sys.stderr)
    print(f"[Success] Published {len(final_items)} items to {feed_output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
