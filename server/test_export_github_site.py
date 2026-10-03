import json
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock
from urllib.request import urlopen

from export_github_site import export_site


class ExportTests(unittest.TestCase):
    def test_split_rewrite_cache_and_no_input_mutation(self):
        url = 'https://origin.test/media/0123456789abcdef.webp'
        entry = {'id': 'rss:demo:1', 'title': 't', 'summary': 's', 'content': f'![image]({url})',
                 'source': 'Demo', 'platform': 'other', 'published_at': '2026-10-03T00:00:00Z'}
        feed = {'schema_version': 1, 'generated_at': entry['published_at'], 'items': [entry]}
        download = Mock(return_value=b'RIFF0000WEBPtest')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ['first', 'second']:
                output = root / name
                export_site(feed, output, root/'cache', 'https://user.github.io/repo', 'https://origin.test/media', download)
                self.assertTrue((output/'feeds/rss-demo.json').exists())
                published = json.loads((output/'feed.json').read_text())
                self.assertIn('https://user.github.io/repo/media/', published['items'][0]['content'])
            self.assertEqual(download.call_count, 1)
            self.assertEqual(feed['items'][0]['content'], f'![image]({url})')

    def test_image_failure_aborts_before_feed_publication(self):
        entry = {'id': 'gh:demo', 'title': 't', 'summary': 's', 'content': '![i](https://origin.test/media/0123456789abcdef.webp)',
                 'source': 'GitHub', 'platform': 'github', 'published_at': '2026-10-03T00:00:00Z'}
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(ValueError):
                export_site({'schema_version': 1, 'generated_at': entry['published_at'], 'items': [entry]},
                            root/'site', root/'cache', 'https://user.github.io/repo', 'https://origin.test/media',
                            lambda *_: b'<html>Error</html>')
            self.assertFalse((root/'site/feed.json').exists())

    def test_platform_subscriptions_follow_feed_values_dynamically(self):
        def entry(identity, platform):
            return {'id': identity, 'title': 't', 'summary': 's', 'content': '',
                    'source': 's', 'platform': platform, 'published_at': '2026-10-03T00:00:00Z'}
        feed = {'schema_version': 2, 'generated_at': '2026-10-03T00:00:00Z', 'items': [
            entry('gh:1', 'github'), entry('ma:1', 'Mastodon'), entry('bo:1', '博客'),
            entry('no:1', None), entry('blank:1', '  ')]}
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subscriptions = export_site(feed, root/'site', root/'cache',
                                        'https://user.github.io/repo', 'https://origin.test/media')
            self.assertEqual({s['name'] for s in subscriptions}, {'全部', 'github', 'Mastodon', '博客', 'other'})
            self.assertTrue((root/'site/feeds/github.json').exists())
            self.assertTrue((root/'site/feeds/Mastodon.json').exists())
            chinese_url = next(s['url'] for s in subscriptions if s['name'] == '博客')
            self.assertTrue((root/'site/feeds'/chinese_url.rsplit('/', 1)[-1]).exists())
            self.assertTrue((root/'site/feeds/other.json').exists())

    def test_subscription_urls_work_over_http_and_keep_rss_separate(self):
        platforms = ['博客', '博' * 64, '../博客', 'a/b', 'a%2Fb', 'rss-demo', 'platform-demo']
        entries = [{'id': str(index), 'title': 't', 'summary': '', 'content': '',
                    'source': 'Platform', 'platform': platform, 'published_at': '2026-10-03T00:00:00Z'}
                   for index, platform in enumerate(platforms)]
        entries.append({**entries[0], 'id': 'rss:demo:1', 'source': 'RSS', 'platform': 'other'})
        feed = {'schema_version': 2, 'generated_at': entries[0]['published_at'], 'items': entries}
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            class QuietHandler(SimpleHTTPRequestHandler):
                def log_message(self, *_):
                    pass
            with ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(root/'site'))) as server:
                base = f'https://127.0.0.1:{server.server_port}'
                subscriptions = export_site(feed, root/'site', root/'cache', base, 'https://origin.test/media')
                self.assertEqual(len({s['url'] for s in subscriptions}), len(entries) + 1)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    for subscription in subscriptions:
                        with self.subTest(name=subscription['name']):
                            with urlopen(subscription['url'].replace('https://', 'http://', 1), timeout=5) as response:
                                published = json.load(response)
                            expected = entries if subscription['name'] == '全部' else [
                                entry for entry in entries
                                if (entry['source'] == 'RSS' if subscription['name'] == 'RSS'
                                    else entry['platform'] == subscription['name'] and entry['source'] != 'RSS')]
                            self.assertEqual(published['items'], expected)
                finally:
                    server.shutdown()
                    thread.join(timeout=5)


if __name__ == '__main__':
    unittest.main()
