import ctypes, os, pathlib, select, signal, subprocess, tempfile, time, json, sys
ctypes.CDLL(None).prctl(36,1,0,0,0) # Test runner owns orphan cleanup, never host services.
exe=str(pathlib.Path(sys.argv[1]).resolve()/'proof-provider')
results=[]
def alive(pid):
 try:
  status=pathlib.Path(f'/proc/{pid}/stat').read_text().split(') ')[1].split()[0]
  return status!='Z'
 except FileNotFoundError: return False
class Case:
 def __init__(self,mode,pre=False):
  self.tmp=tempfile.TemporaryDirectory(prefix='elogind-native-proof-');self.d=pathlib.Path(self.tmp.name); self.fds={}
  for n in ['ready','release','control','ack']:
   os.mkfifo(self.d/n); self.fds[n]=os.open(self.d/n,os.O_RDWR|os.O_NONBLOCK)
  env=os.environ|{'PROOF_DIR':str(self.d)}
  if pre:env['PROOF_PRE_TOOL']='1'
  self.log=open(self.d/'stderr','wb');self.p=subprocess.Popen([exe,mode],env=env,stdout=self.log,stderr=self.log,start_new_session=True)
 def event(self,n,timeout=2):
  ready,_,_=select.select([self.fds[n]],[],[],timeout)
  if not ready:raise AssertionError(f'no {n} event; exit={self.p.poll()} log={(self.d/"stderr").read_text()}')
  return os.read(self.fds[n],1)
 def value(self,n):return int((self.d/n).read_text())
 def close(self):
  # Cleanup only this fixture's private process group, including predecessor orphans.
  try:os.killpg(self.p.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  self.p.wait(timeout=2)
  deadline=time.monotonic()+2
  while time.monotonic()<deadline:
   try:
    pid,status=os.waitpid(-self.p.pid,os.WNOHANG)
    if pid==0:time.sleep(.01)
   except ChildProcessError:break
  for fd in self.fds.values():os.close(fd)
  self.log.close();self.tmp.cleanup()
def run(name,fn):
 try:fn();results.append({'case':name,'passed':True})
 except Exception as e:results.append({'case':name,'passed':False,'error':str(e)})
def waits():
 c=Case('external')
 try:
  c.event('ready');assert c.p.poll() is None and not(c.d/'result').exists(),'native execute_external returned before tool completion'
  os.write(c.fds['release'],b'x');assert c.p.wait(timeout=2)==0;assert c.value('result')==0
 finally:c.close()
def fallback(configured):
 c=Case('fallback' if configured else 'unconfigured')
 try:
  assert c.p.wait(timeout=2)==0
  sink=(c.d/'kernel').read_text()
  if configured:assert c.value('result')<0 and sink=='',f'result={c.value("result")} kernel={sink!r}'
  else:assert c.value('result')==0 and sink.strip()=='mem',f'unconfigured control result={c.value("result")} sink={sink!r}'
 finally:c.close()
def reaps():
 c=Case('owner')
 try:
  c.event('ready');os.write(c.fds['control'],b'u');c.event('ack')
  assert c.value('false')==0 and c.value('busy')==1 and c.value('outer')>0,'unrelated SIGCHLD/WNOHANG0 cleared owned live action'
  os.write(c.fds['release'],b'x')
  # pidfd provides a concrete owned-child completion event, not equal-timed polls.
  pid=c.value('outerpid');fd=os.pidfd_open(pid)
  try:assert select.select([fd],[],[],2)[0],'outer child failed to complete'
  finally:os.close(fd)
  os.write(c.fds['control'],b'r');c.event('ack')
  assert c.value('false')==1 and c.value('busy')==0 and c.value('outer')==0,'owned completion did not release exactly once'
  os.write(c.fds['control'],b'r');c.event('ack');assert c.value('false')==1
 finally:c.close()
def parent_death(pre):
 c=Case('owner',pre)
 try:
  c.event('ready');outer=c.value('outerpid');tool=None if pre else c.value('toolpid')
  os.write(c.fds['control'],b'q');assert c.p.wait(timeout=2)==0
  fd=os.pidfd_open(outer)
  try:assert select.select([fd],[],[],2)[0],'sleep child remained alive after provider death'
  finally:os.close(fd)
  if tool:
   fd=os.pidfd_open(tool)
   try:assert select.select([fd],[],[],2)[0],'tool remained alive after sleep-child death'
   finally:os.close(fd)
  os.write(c.fds['release'],b'x');assert not(c.d/'commit').exists(),'late tool entry after provider death'
 finally:c.close()
def shutdown_reap():
 c=Case('shutdown-reap')
 try:
  assert c.p.wait(timeout=2)==0
  assert c.value('busy')==0 and c.value('outer')==0 and c.value('false')==0,'completed non-sleep action left provider busy'
 finally:c.close()
run('shared_non_sleep_reap',shutdown_reap)
run('native_waits_for_tool',waits)
run('configured_failure_has_no_kernel_fallback',lambda:fallback(True))
run('unconfigured_native_kernel_control',lambda:fallback(False))
run('owned_child_completion_only',reaps)
run('parent_death_before_tool',lambda:parent_death(True))
run('parent_death_after_tool',lambda:parent_death(False))
print(json.dumps(results,indent=2));raise SystemExit(not all(r['passed'] for r in results))
