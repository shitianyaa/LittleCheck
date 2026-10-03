"""Export a public Little Check feed for GitHub Pages, with a reusable image cache."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import time
import urllib.parse
import urllib.request

from publish_feed import publish, validate


IMAGE = re.compile(r'!\[([^\]]*)\]\((https?://[^)\s]+)\)')


def fetch(url, limit):
    request = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 LittleCheck Pages Publisher'})
    with urllib.request.urlopen(request, timeout=20) as response:
        data = bytearray()
        deadline = time.monotonic() + 40
        while True:
            if time.monotonic() > deadline:
                raise TimeoutError('public source transfer exceeded deadline')
            block = response.read1(65536)
            if not block:
                return bytes(data)
            data.extend(block)
            if len(data) > limit:
                raise ValueError('public source exceeds size limit')


def export_site(feed, output, cache, public_base, media_base, download=fetch):
    validate(feed)
    for value in (public_base, media_base):
        url = urllib.parse.urlparse(value)
        if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise ValueError('publication and media base must be HTTPS without credentials, query or fragment')
    output, cache = Path(output), Path(cache)
    if output.exists() and any(output.iterdir()):
        raise ValueError('output must be empty; previous site is never overwritten')
    output.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    copied = copy.deepcopy(feed)
    media_prefix = media_base.rstrip('/') + '/'
    mapped = {}
    for item in copied['items']:
        for match in IMAGE.finditer(item['content']):
            url = match.group(2)
            if not url.startswith(media_prefix) or url in mapped:
                continue
            name = url[len(media_prefix):]
            if not re.fullmatch(r'[a-f0-9]{16}\.webp', name):
                raise ValueError('unexpected cached media path')
            path = cache / name
            if path.is_symlink():
                raise ValueError('image cache may not contain symlinks')
            if not path.exists() or path.stat().st_size == 0:
                data = download(url, 2 * 1024 * 1024)
                if len(data) < 12 or data[:4] != b'RIFF' or data[8:12] != b'WEBP':
                    raise ValueError('source image is not WebP')
                temp = path.with_suffix('.tmp')
                temp.write_bytes(data)
                os.replace(temp, path)
            os.utime(path, None)
            mapped[url] = public_base.rstrip('/') + '/media/' + name
    for item in copied['items']:
        item['content'] = IMAGE.sub(lambda m: f'![{m.group(1)}]({mapped.get(m.group(2), m.group(2))})', item['content'])
    # Old image URLs remain available to phones reading a previous snapshot.
    media_dir = output / 'media'
    media_dir.mkdir()
    total = 0
    for path in cache.glob('*.webp'):
        if path.is_symlink() or not re.fullmatch(r'[a-f0-9]{16}\.webp', path.name):
            raise ValueError('unsafe image cache entry')
        if path.stat().st_mtime < time.time() - 7 * 86400:
            path.unlink()
            continue
        total += path.stat().st_size
        if total > 500 * 1024 * 1024:
            raise ValueError('Pages image cache exceeds 500 MiB; publication aborted')
        shutil.copy2(path, media_dir / path.name)
    publish(copied, output / 'feed.json')
    groups = {}
    for item in copied['items']:
        if item['id'].startswith('rss:'):
            source_id = item['id'].split(':')[1]
            if not re.fullmatch(r'[a-z0-9_-]{1,40}', source_id):
                raise ValueError('unsafe RSS source id')
            key, name = ('rss', source_id), item['source']
        else:
            platform = item.get('platform')
            name = platform.strip() if isinstance(platform, str) and platform.strip() else 'other'
            if len(name) > 64:
                raise ValueError('platform name exceeds 64 characters')
            key = ('platform', name)
        groups.setdefault(key, {'name': name, 'items': []})['items'].append(item)
    subscriptions = [{'name': '全部', 'url': public_base.rstrip('/') + '/feed.json'}]
    for key, group in sorted(groups.items()):
        kind, value = key
        if kind == 'rss':
            stem = 'rss-' + value
        elif re.fullmatch(r'[A-Za-z0-9_-]{1,64}', value) and not value.startswith(('rss-', 'platform-')):
            stem = value
        else:
            # ASCII filenames avoid URL decoding and filesystem length issues.
            stem = 'platform-' + hashlib.sha256(value.encode('utf-8')).hexdigest()
        filename = stem + '.json'
        publish({**copied, 'items': group['items']}, output / 'feeds' / filename)
        subscriptions.append({'name': group['name'], 'url': public_base.rstrip('/') + '/feeds/' + filename})
    (output / 'subscriptions.json').write_text(json.dumps(subscriptions, ensure_ascii=False, indent=2), encoding='utf-8')
    (output / '.nojekyll').touch()
    return subscriptions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--media-base', required=True)
    parser.add_argument('--public-base', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--cache', required=True)
    args = parser.parse_args()
    if not args.source.startswith('https://'):
        parser.error('source must be a public HTTPS feed')
    feed = json.loads(fetch(args.source, 2 * 1024 * 1024))
    subscriptions = export_site(feed, args.output, args.cache, args.public_base, args.media_base)
    print(f'Prepared {len(feed["items"])} items and {len(subscriptions)} subscriptions')


if __name__ == '__main__':
    main()
