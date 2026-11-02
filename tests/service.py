#!/usr/bin/env python3
"""Unprivileged IPC tests against a compile-time fake SMC; never touches LEDs."""
import os,subprocess,tempfile,socket,time,signal,pathlib
helper=os.path.abspath('build/test/helper')
app=os.path.abspath('build/test/MagDot.app/Contents/MacOS/MagDot')
with tempfile.TemporaryDirectory(prefix='md-') as directory:
 env=dict(os.environ,MAGDOT_TEST_DIR=directory)
 log=open(os.path.join(directory,'service.log'),'w+')
 daemon=subprocess.Popen([helper,'daemon'],env=env,stdout=log,stderr=log)
 try:
  path=os.path.join(directory,'socket')
  for _ in range(50):
   if os.path.exists(path):break
   time.sleep(.1)
  # Both a deferred registration and an extended approval wait must retain intent.
  for deferred in ['0','1']:
   approval=pathlib.Path(directory)/'approval'
   approval.write_text('pending')
   awaiting=subprocess.Popen([app,'--quit-smoke'],env=dict(env,MAGDOT_TEST_APPROVAL_FILE=str(approval),MAGDOT_TEST_REGISTER_DEFER=deferred),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
   time.sleep(22)
   assert awaiting.poll() is None, 'Approval wait abandoned activation'
   assert not os.path.exists(os.path.join(directory,'status'))
   approval.write_text('enabled')
   stdout,stderr=awaiting.communicate(timeout=15)
   assert awaiting.returncode==0 and 'acknowledged=true' in stdout,(stdout,stderr)
   print('Delayed approval resumes automatically; deferred registration='+deferred,flush=True)
  client=socket.socket(socket.AF_UNIX);client.settimeout(3);client.connect(path)
  assert client.recv(128)==b'', 'Unsigned client must be refused'
  client.close();print('Unsigned client rejected',flush=True)
  for index,mode in enumerate(['--smoke-test','--quit-smoke','--smoke-test','--smoke-test']):
   result=subprocess.run([app,mode],env=dict(env,MAGDOT_TEST_PRESET=str(index)),capture_output=True,text=True,timeout=20)
   print(result.stdout,flush=True)
   assert result.returncode==0 and 'acknowledged=true' in result.stdout,(result.stdout,result.stderr)
   assert not os.path.exists(os.path.join(directory,'status'))
  running=subprocess.Popen([app,'--start'],env=env,stdout=log,stderr=log)
  for _ in range(50):
   if os.path.exists(os.path.join(directory,'status')):break
   time.sleep(.1)
  assert os.path.exists(os.path.join(directory,'status'))
  worker=int(pathlib.Path(directory,"status").read_text().split()[0])
  os.kill(worker,signal.SIGTERM)
  time.sleep(1)
  daemon.terminate();daemon.wait(timeout=5)
  time.sleep(3)
  assert running.poll() is None, 'App quit during helper restart'
  daemon=subprocess.Popen([helper,'daemon'],env=env,stdout=log,stderr=log)
  time.sleep(5)
  assert os.path.exists(os.path.join(directory,'status')), 'Enabled activation did not recover after helper returned'
  assert running.poll() is None
  print('Enabled activation recovers automatically after transient helper failure',flush=True)
  running.terminate();running.wait(timeout=5)
  running=subprocess.Popen([app,'--start'],env=env,stdout=log,stderr=log)
  for _ in range(100):
   if os.path.exists(os.path.join(directory,'status')):break
   time.sleep(.1)
  assert os.path.exists(os.path.join(directory,'status')), 'Explicit relaunch did not activate'
  running.kill();running.wait(timeout=3)
  for _ in range(60):
   if not os.path.exists(os.path.join(directory,'status')):break
   time.sleep(.1)
  assert not os.path.exists(os.path.join(directory,'status')),'App crash did not release session'
  print('App crash releases session; repeated Start/Stop and Quit passed',flush=True)
  connection=pathlib.Path(directory)/'connection'
  connection.write_text('disconnected')
  watcher=subprocess.Popen([app],env=dict(env,MAGDOT_TEST_CONNECTION_FILE=str(connection)),stdout=log,stderr=log)
  def wait_session(expected):
   for _ in range(100):
    assert watcher.poll() is None, 'Watcher unexpectedly quit'
    if os.path.exists(os.path.join(directory,'status')) == expected:return
    time.sleep(.1)
   raise AssertionError(f'Session presence did not become {expected}')
  try:
   time.sleep(2)
   assert not os.path.exists(os.path.join(directory,'status')), 'Unplugged startup opened helper session'
   for _ in range(2):
    connection.write_text('connected');wait_session(True)
    time.sleep(.6)
    connection.write_text('disconnected');wait_session(False)
   # Reconnect while the previous worker may still be restoring.
   connection.write_text('connected');wait_session(True)
   connection.write_text('disconnected');time.sleep(1.1)
   connection.write_text('connected');time.sleep(3);wait_session(True)
   connection.write_text('disconnected');wait_session(False)
   print('Unplugged startup, repeated reconnect, and reconnect during restoration passed',flush=True)
  finally:
   watcher.terminate();watcher.wait(timeout=10)

 finally:
  daemon.terminate();daemon.wait(timeout=3);log.seek(0);print(log.read(),flush=True);log.close()
