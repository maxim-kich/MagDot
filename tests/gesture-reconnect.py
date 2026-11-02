#!/usr/bin/env python3
"""Fixture-only sensor failure/reconnect checks; no live HID or SMC access."""
import json,os,pathlib,subprocess,tempfile,time
app=str(pathlib.Path('build/test/MagDot.app/Contents/MacOS/MagDot').resolve())
with tempfile.TemporaryDirectory(prefix='magdot-reconnect-') as folder:
 root=pathlib.Path(folder)
 for name,value in [('connection','connected'),('permission','allowed'),('sensor','1')]: (root/name).write_text(value)
 env=os.environ|{'MAGDOT_TEST_DIR':folder,'MAGDOT_TEST_CONNECTION_FILE':str(root/'connection'),'MAGDOT_TEST_GESTURE_PERMISSION_FILE':str(root/'permission'),'MAGDOT_TEST_GESTURE_LID_OPEN':'1','MAGDOT_TEST_SENSOR_RESULT_FILE':str(root/'sensor'),'MAGDOT_TEST_PERSONAL_ROOT':str(root/'profiles')}
 with (root/'log').open('w+') as log:
  proc=subprocess.Popen([app,'--experimental'],env=env,stdout=log,stderr=log)
  def state(predicate):
   deadline=time.monotonic()+8
   while time.monotonic()<deadline:
    assert proc.poll() is None,'Fixture app exited'
    try:
     d=json.loads((root/'gesture-status.json').read_text())
     if predicate(d):return d
    except (FileNotFoundError,json.JSONDecodeError):pass
    time.sleep(.1)
   log.seek(0);raise AssertionError(log.read())
  try:
   state(lambda d:not d['running'] and d['allowed'])
   (root/'sensor').write_text('0');time.sleep(1)
   assert not json.loads((root/'gesture-status.json').read_text())['running'],'Failed startup should not spin-retry without a lifecycle transition'
   for _ in range(3):
    (root/'connection').write_text('disconnected');state(lambda d:not d['running'] and 'Connect MagSafe' in d['status'])
    (root/'connection').write_text('connected');d=state(lambda d:d['running'] and d['ready'])
    assert d['lastNavigationAt']==0 and d['groupedVibrations']==0
   print('Gesture startup failure clears on reconnect; three clean reconnects passed',flush=True)
  finally:
   proc.terminate();proc.wait(timeout=10)
