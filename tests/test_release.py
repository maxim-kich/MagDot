import importlib.util,json,pathlib,tempfile,unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('release',pathlib.Path(__file__).parents[1]/'scripts/release.py')
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)
class ReleaseTests(unittest.TestCase):
 def test_resume_does_not_resubmit(self):
  with tempfile.TemporaryDirectory() as d:
   p=pathlib.Path(d);(p/'dmg-submission.json').write_text('{"id":"saved-id"}')
   with patch.object(r,'capture',return_value='{"status":"Accepted"}') as capture,patch.object(r,'run') as run,patch.object(r.subprocess,'run'):
    r.notarize_file(p,p/'test.dmg','profile','dmg')
    self.assertFalse(any('submit' in c.args for c in capture.call_args_list))
    self.assertTrue(any('staple' in c.args for c in run.call_args_list))
 def test_pending_does_not_staple(self):
  with tempfile.TemporaryDirectory() as d:
   p=pathlib.Path(d);(p/'dmg-submission.json').write_text('{"id":"saved-id"}')
   with patch.object(r,'capture',return_value='{"status":"In Progress"}'),patch.object(r,'run') as run,patch.object(r.subprocess,'run'):
    with self.assertRaises(SystemExit):r.notarize_file(p,p/'test.dmg','profile','dmg')
    run.assert_not_called()
 def test_dirty_draft_refused(self):
  with tempfile.TemporaryDirectory() as d:
   p=pathlib.Path(d);(p/'manifest.json').write_text(json.dumps({'version':'0.1.0','stage':'notarized','dirty':True}))
   with patch.object(r,'run') as run:
    with self.assertRaises(SystemExit):r.draft(p,True)
    run.assert_not_called()
 def test_modified_source_refused_before_network(self):
  with tempfile.TemporaryDirectory() as d:
   p=pathlib.Path(d);(p/'source.tar.gz').write_text('changed')
   (p/'manifest.json').write_text(json.dumps({'source':'source.tar.gz','source_sha256':'wrong'}))
   with patch.object(r,'run') as run:
    with self.assertRaises(SystemExit):r.notarize(p,'profile')
    run.assert_not_called()
if __name__=='__main__':unittest.main()
