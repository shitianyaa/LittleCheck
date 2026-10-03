import unittest
from unittest.mock import patch
from rss_sources import parse_feed, plain_text, fetch_rss
from publish_feed import validate
import test_generate_feed as generator_tests


class RssTests(unittest.TestCase):
    source = {'id': 'demo', 'name': '示例', 'url': 'https://example.org/rss', 'max_items': 5}
    rss = b'''<rss><channel><item><title>Title</title><link>https://example.org/a</link>
        <pubDate>Fri, 02 Oct 2026 12:00:00 GMT</pubDate><description>&lt;p&gt;Body&lt;/p&gt;</description>
        </item></channel></rss>'''

    def test_rss_contract_and_stable_ids(self):
        entries = parse_feed(self.rss, self.source)
        self.assertEqual(entries[0]['content'], 'Body')
        self.assertEqual(entries[0]['platform'], 'other')
        self.assertEqual(entries, parse_feed(self.rss, self.source))
        validate({'schema_version': 1, 'generated_at': entries[0]['published_at'], 'items': entries})

    def test_atom_dates_links_and_deduplication(self):
        entry = '<entry><title>T</title><link rel="alternate" href="https://example.org/b"/><updated>2026-10-02T20:00:00+08:00</updated><summary>Summary</summary></entry>'
        result = parse_feed(('<feed xmlns="http://www.w3.org/2005/Atom">'+entry*2+'</feed>').encode(), self.source)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['published_at'], '2026-10-02T12:00:00Z')

    def test_unsafe_xml_and_oversize_rejected(self):
        for raw in (b'<!DOCTYPE rss><rss/>', b'<!ENTITY a "abc"><rss/>', b'a'*(2*1024*1024+1)):
            with self.assertRaises(ValueError):
                parse_feed(raw, self.source)

    def test_transfer_failure_returns_empty_for_retention(self):
        with patch('rss_sources.urllib.request.urlopen', side_effect=OSError('offline')):
            self.assertEqual(fetch_rss(self.source), [])
        self.assertEqual(plain_text('<script>hidden</script><p>visible &amp; text</p>'), 'visible & text')


class RssRetentionTests(unittest.TestCase):
    setUp = generator_tests.GeneratorTests.setUp
    previous = generator_tests.GeneratorTests.previous
    run_main = generator_tests.GeneratorTests.run_main
    def test_failed_source_retains_previous_content(self):
        self.cfg['extra_sources'] = [RssTests.source]
        self.previous([generator_tests.item('rss:demo:old', 'https://example.org/old')])
        with patch('generate_feed.fetch_rss', return_value=[]):
            status, _ = self.run_main([generator_tests.item()])
        self.assertEqual(status, 0)
        import json
        entries = json.loads((self.root / 'candidate.json').read_text())['items']
        self.assertIn('rss:demo:old', [entry['id'] for entry in entries])


if __name__ == '__main__':
    unittest.main()
