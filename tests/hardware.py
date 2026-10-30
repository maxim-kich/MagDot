#!/usr/bin/env python3
"""Explicit opt-in root hardware tests; writes ACLC only through the controller."""
import os, sys, subprocess, signal, tempfile, time
assert os.geteuid()==0, 'Run with administrator authorization'
helper=os.path.abspath(sys.argv[1])
def launch(args,block=False):
 def mask():
  if block:signal.pthread_sigmask(signal.SIG_BLOCK,{signal.SIGTERM})
 return subprocess.Popen([helper]+args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,preexec_fn=mask)
def finish(p,label):
 out,_=p.communicate(timeout=8)
 assert 'Restored ACLC=0' in out,(label,out)
 print(label+': restoration acknowledged',flush=True)
 return out
p=launch(['working','20'],True);time.sleep(2)
other=subprocess.run([helper,'working','1'],capture_output=True,text=True)
assert other.returncode!=0 and 'Another controller' in other.stderr
p.terminate();finish(p,'Blocked-mask SIGTERM');assert p.returncode==0
p=launch(['working','20']);time.sleep(2);p.kill();finish(p,'SIGKILL watchdog')
# Let the guardian release the process lock before the next controller.
time.sleep(.3)
with tempfile.TemporaryDirectory(prefix='magdot-test-') as folder:
 state=os.path.join(folder,'state')
 with open(state,'w') as f:f.write('working '+str(int(time.time())+2)+'\n')
 p=launch(['watch',state]);finish(p,'Expired app heartbeat');assert p.returncode==0
 with open(state,'w') as f:f.write('working '+str(int(time.time())+4)+'\n')
 p=launch(['watch',state]);time.sleep(1.2)
 with open(state,'w') as f:f.write('quit '+str(int(time.time())+4)+'\n')
 finish(p,'Quit request');assert p.returncode==0
print('All four restoration paths and exclusive ownership passed')
