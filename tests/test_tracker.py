import importlib.util, unittest
spec=importlib.util.spec_from_file_location('watcher','scripts/t3-watch.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def row(status,completed=None):return ('turn','chat',status,'2026-10-29T20:00:00Z',completed)
class Tests(unittest.TestCase):
 def test_lifecycle(self):
  t=m.Tracker();now=m.stamp('2026-10-29T20:01:00Z')
  self.assertEqual(t.update([row('running')],{},False,now),'working')
  done=[row('completed','2026-10-29T20:01:00Z')]
  self.assertEqual(t.update(done,{},False,now+1),'finished')
  self.assertEqual(t.update(done,{},False,now+119),'finished')
  self.assertEqual(t.update(done,{},False,now+120),'idle')
 def test_visit_and_priority(self):
  t=m.Tracker();now=m.stamp('2026-10-29T20:01:00Z')
  self.assertEqual(t.update([row('running')],{},True,now),'attention')
  self.assertEqual(t.update([row('completed','2026-10-29T20:01:00Z')],{'chat':now+1},False,now+2),'idle')
 def test_no_old_completion_on_startup(self):
  self.assertEqual(m.Tracker().update([row('completed','2026-10-29T20:01:00Z')],{},False,m.stamp('2026-10-29T20:01:01Z')),'idle')
 def test_cancel(self):
  t=m.Tracker();now=m.stamp('2026-10-29T20:01:00Z')
  t.update([row('running')],{},False,now)
  self.assertEqual(t.update([row('cancelled')],{},False,now+1),'idle')
if __name__=='__main__':unittest.main()
