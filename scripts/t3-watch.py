#!/usr/bin/env python3
"""Read-only T3 adapter. No message text, credentials, or prompts are read."""
import os, sqlite3, time, pathlib, signal, fcntl
root=pathlib.Path.home()/'.magdot'
root.mkdir(mode=0o700,exist_ok=True)
lock=(root/'watcher.lock').open('w')
try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError: raise SystemExit(0)
state=root/'state'
db=pathlib.Path.home()/'.t3/userdata/statev2.sqlite'
running=True
def stop(*_):
 global running
 running=False
signal.signal(signal.SIGTERM,stop)
signal.signal(signal.SIGINT,stop)
last=set(); finished_until=0
while running:
 mode='idle'
 try:
  with sqlite3.connect(f'file:{db}?mode=ro',uri=True,timeout=1) as c:
   rows=c.execute("SELECT provider_turn_id,status,started_at FROM orchestration_v2_projection_provider_turns WHERE status='running' OR completed_at > strftime('%Y-%m-%dT%H:%M:%fZ','now','-30 seconds')").fetchall()
  active={i for i,s,t in rows if s=='running' and time.time()-__import__('datetime').datetime.fromisoformat(t.replace('Z','+00:00')).timestamp()<3600}
  if any(i in last and s=='completed' for i,s,t in rows):finished_until=time.time()+15
  last=active
  mode='working' if active else 'finished' if time.time()<finished_until else 'idle'
 except (sqlite3.Error,ValueError,TypeError):pass
 tmp=root/'state.tmp'
 tmp.write_text(f'{mode} {int(time.time())+4}\n');tmp.replace(state)
 time.sleep(1)
state.write_text('idle 0\n')
