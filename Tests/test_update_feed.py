import importlib.util,pathlib,plistlib,unittest
spec=importlib.util.spec_from_file_location('feed',pathlib.Path(__file__).parents[1]/'Scripts/update-feed.py')
feed=importlib.util.module_from_spec(spec);spec.loader.exec_module(feed)
class FeedTests(unittest.TestCase):
    def test_signed_feed_has_required_archive_verification(self):
        info=plistlib.loads((pathlib.Path(__file__).parents[1]/'Sources/Info.plist').read_bytes())
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
    def release(self,tag='v0.2.0-rc.1',draft=False,prerelease=True):
        return {'tag_name':tag,'draft':draft,'prerelease':prerelease,'html_url':'https://github.com/morefreefg/WindowSwitch/releases/tag/'+tag,
            'assets':[{'name':'app.update.json','browser_download_url':tag}]}
    def metadata(self,tag):
        return {'version':tag[1:],'buildVersion':'3' if '-rc' in tag else '2','minimumSystemVersion':'14.0',
            'url':'https://github.com/morefreefg/WindowSwitch/releases/download/'+tag+'/app.zip','edSignature':'A'*86+'==','length':123}
    def test_rc_and_stable_are_ordered_with_separate_channels(self):
        tree=feed.build([self.release('v0.1.0',prerelease=False),self.release()],self.metadata)
        items=tree.findall('./channel/item');self.assertEqual(len(items),2)
        self.assertEqual(items[0].find('{'+feed.SPARKLE+'}channel').text,'rc')
        self.assertIsNone(items[1].find('{'+feed.SPARKLE+'}channel'))
    def test_drafts_and_non_rc_prereleases_are_ignored(self):
        tree=feed.build([self.release(draft=True),self.release('v0.2.0-beta.1')],self.metadata)
        self.assertEqual(tree.findall('./channel/item'),[])
    def test_missing_signature_is_rejected(self):
        def bad(tag):
            value=self.metadata(tag);value['edSignature']='';return value
        with self.assertRaises(ValueError):feed.build([self.release()],bad)
    def test_foreign_download_url_is_rejected(self):
        def bad(tag):
            value=self.metadata(tag);value['url']='https://example.org/app.zip';return value
        with self.assertRaises(ValueError):feed.build([self.release()],bad)
    def test_version_mismatch_is_rejected(self):
        def bad(tag):
            value=self.metadata(tag);value['version']='99.0';return value
        with self.assertRaises(ValueError):feed.build([self.release()],bad)
if __name__=='__main__':unittest.main()
