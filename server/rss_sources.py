"""Admin-configured public RSS/Atom sources; no new runtime dependencies."""
import hashlib
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser


class PlainText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.hidden = 0

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style'):
            self.hidden += 1
        if tag in ('p', 'br', 'div', 'li', 'h1', 'h2', 'h3'):
            self.parts.append('\n')

    def handle_endtag(self, tag):
        if tag in ('script', 'style') and self.hidden:
            self.hidden -= 1
        if tag in ('p', 'div', 'li'):
            self.parts.append('\n')

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def plain_text(value):
    parser = PlainText()
    parser.feed(value)
    return re.sub(r'\n\s*\n+', '\n\n', ''.join(parser.parts)).strip()


def public_link(value):
    parsed = urllib.parse.urlparse(value)
    return parsed.scheme in ('http', 'https') and bool(parsed.hostname) and not parsed.username and not parsed.password


def parse_feed(data, source):
    if len(data) > 2 * 1024 * 1024 or b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
        raise ValueError('RSS size or XML declaration is unsafe')
    root = ET.fromstring(data)
    atom = '{http://www.w3.org/2005/Atom}'
    entries = root.findall('./channel/item') if root.tag == 'rss' else root.findall(atom + 'entry')
    if not entries:
        raise ValueError('Feed contains no supported RSS/Atom entries')
    result = []
    seen = set()
    for entry in entries:
        def text(name):
            return entry.findtext(name, default='').strip()
        title = plain_text(text('title') or text(atom + 'title'))
        url = text('link')
        if not url:
            url = next((el.get('href', '') for el in entry.findall(atom + 'link')
                        if el.get('rel', 'alternate') == 'alternate'), '')
        if not title or not public_link(url):
            continue
        identity = 'rss:' + source['id'] + ':' + hashlib.sha256(url.encode()).hexdigest()[:20]
        if identity in seen:
            continue
        seen.add(identity)
        raw_date = text('pubDate') or text(atom + 'published') or text(atom + 'updated')
        try:
            date = datetime.fromisoformat(raw_date.replace('Z', '+00:00'))
        except ValueError:
            date = parsedate_to_datetime(raw_date)
        if date.tzinfo is None:
            raise ValueError('RSS item date must contain timezone')
        body = plain_text(text('{http://purl.org/rss/1.0/modules/content/}encoded')
                          or text('description') or text(atom + 'content') or text(atom + 'summary'))
        # Bound individual entries, explicitly tell readers when an excerpt is used.
        if len(body) > 12000:
            body = body[:12000] + '\n\n（正文较长，仅显示前 12000 字；请查看原文。）'
        result.append({'id': identity, 'title': title, 'summary': body[:180] or title,
                       'content': body or title, 'source': source['name'], 'platform': 'other',
                       'url': url, 'published_at': date.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z'),
                       'tags': [source['name'], 'RSS']})
        if len(result) >= min(20, max(1, int(source.get('max_items', 5)))):
            break
    return result


def fetch_rss(source):
    if not re.fullmatch(r'[a-z0-9_-]{1,40}', source['id']) or not source.get('name'):
        raise ValueError('RSS source needs a stable id and name')
    if not public_link(source['url']) or not source['url'].startswith('https://'):
        raise ValueError('RSS endpoint must be an HTTPS URL without credentials')
    try:
        request = urllib.request.Request(source['url'], headers={'User-Agent': 'LittleCheck/1.0 RSS Reader'})
        with urllib.request.urlopen(request, timeout=10) as response:
            data = bytearray()
            deadline = time.monotonic() + 20
            while True:
                if time.monotonic() > deadline:
                    raise TimeoutError('RSS transfer exceeded deadline')
                block = response.read1(65536)
                if not block:
                    break
                data.extend(block)
                if len(data) > 2 * 1024 * 1024:
                    raise ValueError('RSS exceeds 2 MiB')
        return parse_feed(bytes(data), source)
    except (OSError, ValueError, TypeError, ET.ParseError) as error:
        print(f"[Warning] RSS {source['id']} failed: {error}", file=sys.stderr)
        return []
