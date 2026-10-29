#!/usr/bin/env python3
"""Read-only T3 lifecycle adapter; never reads message or request bodies."""
import sqlite3, time, pathlib, signal, fcntl
from datetime import datetime

def stamp(value):
 return datetime.fromisoformat(value.replace('Z','+00:00')).timestamp() if value else 0

class Tracker:
 def __init__(self):
  self.active=set()
  self.finished={}
 def update(self, rows, visits, attention, now):
  active={i for i,thread,status,started,completed in rows if status=='running' and now-stamp(started)<3600}
  for i,thread,status,started,completed in rows:
   if i in self.active and status=='completed' and completed:
    self.finished[thread]=stamp(completed)
  self.active=active
  self.finished={thread:t for thread,t in self.finished.items() if now<t+120 and visits.get(thread,0)<t}
  return 'attention' if attention else 'working' if active else 'finished' if self.finished else 'idle'

def main():
 root=pathlib.Path.home()/'.magdot';root.mkdir(mode=0o700,exist_ok=True)
 lock=(root/'watcher.lock').open('w')
 try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError: return
 state=root/'state';db=pathlib.Path.home()/'.t3/userdata/statev2.sqlite'
 running=True
 def stop(*_):
  nonlocal running
  running=False
 signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
 tracker=Tracker()
 while running:
  mode='idle'
  try:
   with sqlite3.connect(f'file:{db}?mode=ro',uri=True,timeout=1) as c:
    rows=c.execute("SELECT p.provider_turn_id,p.thread_id,p.status,p.started_at,p.completed_at FROM orchestration_v2_projection_provider_turns p JOIN orchestration_v2_projection_threads t USING(thread_id) WHERE t.deleted_at IS NULL AND t.archived_at IS NULL AND (p.status='running' OR p.completed_at > strftime('%Y-%m-%dT%H:%M:%fZ','now','-130 seconds'))").fetchall()
    visits={i:stamp(v) for i,v in c.execute("SELECT thread_id,json_extract(payload_json,'$.lastVisitedAt') FROM orchestration_v2_projection_threads")}
    attention=c.execute("SELECT count(*) FROM orchestration_v2_projection_runtime_requests r JOIN orchestration_v2_projection_threads t USING(thread_id) WHERE r.resolved_at IS NULL AND r.status NOT IN ('resolved','cancelled','failed','expired') AND r.kind IN ('user_input','approval','permission') AND t.archived_at IS NULL AND t.deleted_at IS NULL").fetchone()[0]>0
   mode=tracker.update(rows,visits,attention,time.time())
  except (sqlite3.Error,ValueError,TypeError):
   tracker=Tracker()
  tmp=root/'state.tmp';tmp.write_text(f'{mode} {int(time.time())+4}\n');tmp.replace(state)
  time.sleep(1)
 state.write_text('idle 0\n')
if __name__=='__main__':main()
