import fcntl,json,os,pathlib,pwd,signal,subprocess,tempfile,time,types
fixture=types.ModuleType('input_fixture')
exec(compile(pathlib.Path('/input-test.py').read_bytes(), '/input-test.py', 'exec'), fixture.__dict__)
P=pathlib.Path
uid=pwd.getpwnam('emacsos-lab').pw_uid
source=P('/source');results=[]
for name in ['logind-only','idle','call','usb','nonblank','unknown','symlink','no-monitor','queued-input','wrong-modem','ambiguous-modem','modem-bus2','race-before-read','race-before-accept','race-before-mem','blocked-entry']:
 with tempfile.TemporaryDirectory(prefix='native-guard-') as directory:
  monitor_fixture=fixture.InputOwnership();monitor_fixture.setUp()
  if name!='no-monitor':monitor_fixture.child()
  root=P(directory);runtime=root/'runtime';runtime.mkdir(mode=0o700);os.chown(runtime,uid,uid)
  for file,text in [('power-state.lock',''),('power-state','blank\n')]:
   p=runtime/file;p.write_text(text);p.chmod(0o600);os.chown(p,uid,uid)
  power=root/'power';power.mkdir()
  for file,text in [('mem_sleep','s2idle [deep]\n'),('sync_on_suspend','1\n'),('wakeup_count','3\n'),('state','')]: (power/file).write_text(text)
  for folder in ['key','axp','supply/axp20x-usb','modem/usb1/1-1/power']:(root/folder).mkdir(parents=True,exist_ok=True)
  for file,text in [('key/wakeup','disabled'),('axp/wakeup','disabled'),('supply/axp20x-usb/online','0'),('supply/axp20x-usb/present','0'),('supply/axp20x-usb/power/wakeup','disabled'),('modem/usb1/1-1/idVendor','2c7c'),('modem/usb1/1-1/idProduct','0125'),('modem/usb1/1-1/power/wakeup','disabled')]:
   p=root/file;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text+'\n')
  calls=root/'calls';calls.write_text('idle')
  call=root/'call';call.write_text('#!/bin/sh\nfor fd in 3 4 5 6 8; do [ ! -e /proc/$$/fd/$fd ] || exit 99; done\n[ "$1" = idle-check ] || exit 99\n[ "$(cat '+str(calls)+')" = idle ] || exit 75\n');call.chmod(0o755)
  monitor=root/'monitor';shell=root/'suspend'
  text=(source/'openrc-power-monitor').read_text().replace("Path('/run/emacsos-ui')",repr(str(runtime)))
  # Only fixed fixture locations are substituted; the actual locks/state code runs.
  text=text.replace('RUNTIME = '+repr(str(runtime)),'RUNTIME = Path('+repr(str(runtime))+')').replace("SUSPEND = '/usr/local/sbin/emacsos-openrc-suspend'",'SUSPEND = '+repr(str(shell))).replace('/run/emacsos-openrc-call.lock',str(root/'call.lock'))
  text=text.replace("CGROUP = Path('/sys/fs/cgroup/openrc.emacsos-ui/cgroup.procs')", 'CGROUP = Path('+repr(str(monitor_fixture.module.CGROUP))+')').replace("MONITOR = '/usr/local/share/emacsos-openrc/power-monitor'", 'MONITOR = '+repr(str(monitor_fixture.child_script)))
  a=text.index('def verify_input(');b=text.index('def verify_guard()',a)
  text=text[:a]+"def verify_input(fd, name, key):\n    assert os.readlink('/proc/self/fd/'+str(fd)) == 'anon_inode:[eventfd]'\n\n\n"+text[b:]
  monitor.write_text(text);monitor.chmod(0o755)
  text=(source/'openrc-suspend-root').read_text().replace('power=/sys/power','power='+str(power))
  replacements={'/sys/devices/platform/gpio-keys/power/wakeup':str(root/'key/wakeup'),'/sys/devices/platform/soc/1f03400.rsb/sunxi-rsb-3a3/axp221-pek/power/wakeup':str(root/'axp/wakeup'),'/sys/devices/platform/soc/1c1b000.usb':str(root/'modem'),'/sys/class/power_supply':str(root/'supply'),'/usr/local/share/emacsos-openrc/power-monitor':str(monitor),'/run/emacsos-openrc-call.lock':str(root/'call.lock'),'/run/emacsos-ui/power-state.lock':str(runtime/'power-state.lock'),'/usr/local/sbin/emacsos-openrc-call':str(call)}
  for old,new in replacements.items():text=text.replace(old,new)
  race=name.startswith('race-')
  if race:
   root.chmod(0o755)
   display=P('/usr/local/share/emacsos-openrc/session-power');display.parent.mkdir(parents=True,exist_ok=True)
   display.write_text('#!/bin/sh\nexec 9<>'+str(runtime/'power-state.lock')+'\nflock -x 9\nprintf "active\\n" >'+str(runtime/'power-state')+'\n');display.chmod(0o755)
   barrier=root/'barrier';os.mkfifo(barrier);barrier_fd=os.open(barrier,os.O_RDWR|os.O_NONBLOCK)
   phase=name.removeprefix('race-')
   marker='touch '+str(root/'reached')+'; read answer <'+str(barrier)+'\n'
   text=text.replace('wakeup_count=$(timeout', (marker if phase=='before-read' else '')+'wakeup_count=$(timeout',1)
   text=text.replace("sed -n '1p' \"$power/wakeup_count\"", '/usr/bin/python3 /counter.py '+str(root)+' read')
   text=text.replace('printf \'%s\\n\' "$wakeup_count" >"$power/wakeup_count"', (marker if phase=='before-accept' else '')+'/usr/bin/python3 /counter.py '+str(root)+' accept "$wakeup_count"')
   text=text.replace('if ! printf \'%s\\n\' mem >"$power/state"; then', (marker if phase=='before-mem' else '')+'if ! /usr/bin/python3 /counter.py '+str(root)+' submit; then')
  if name=='queued-input':
   # Model wakeup_count's wait on an active source without consuming input.
   # The real timeout and child-descriptor closure remain production code.
   counter=root/'counter'
   counter.write_text('import pathlib,time\nwhile int(next(x.split()[1] for x in pathlib.Path("/proc/'+str(monitor_fixture.children[0][0].pid)+'/fdinfo/3").read_text().splitlines() if x.startswith("eventfd-count:")),16):time.sleep(.01)\nprint(3)\n')
   text=text.replace('sed -n \'1p\' "$power/wakeup_count"','/usr/bin/python3 '+str(counter))
   monitor_fixture.command(monitor_fixture.children[0][0],b'w')
  if name=='wrong-modem':(root/'modem/usb1/1-1/idProduct').write_text('bad')
  if name=='ambiguous-modem':
   import shutil
   shutil.copytree(root/'modem/usb1',root/'modem/usb2')
   (root/'modem/usb2/1-1').rename(root/'modem/usb2/2-1')
  if name=='modem-bus2':
   (root/'modem/usb1/1-1').rename(root/'modem/usb1/2-1')
   (root/'modem/usb1').rename(root/'modem/usb2')
  shell.write_text(text);shell.chmod(0o755)
  if name=='call':calls.write_text('active')
  if name=='usb':(root/'supply/axp20x-usb/online').write_text('1\n')
  if name=='nonblank':(runtime/'power-state').write_text('active\n')
  if name=='unknown':calls.unlink()
  if name=='symlink':
   (runtime/'power-state.lock').unlink();(root/'untouched').write_text('preserve');(runtime/'power-state.lock').symlink_to(root/'untouched')
  provider=root/'provider';provider.mkdir()
  env=os.environ|{'PROOF_DIR':str(provider),'PROOF_GUARD':str(shell),'LD_LIBRARY_PATH':'/native/src/shared'}
  # Execute the real sleep.conf parser, not only its internal execute helper.
  config=P('/etc/elogind/sleep.conf.d/50-emacsos-native-sleep.conf');config.parent.mkdir(parents=True,exist_ok=True)
  policy='[Sleep]\nAllowSuspendInterrupts=no\nSuspendByUsing='+str(shell)+'\n'
  config.write_text(policy)
  startup=P('/etc/elogind/logind.conf.d/50-emacsos-native-sleep.conf');startup.parent.mkdir(parents=True,exist_ok=True);startup.write_text(policy)
  if name=='logind-only':config.unlink()
  if name=='logind-only':
   result=subprocess.run(['/native/proof-provider','parsed-guard'],env=env,capture_output=True,text=True,timeout=8)
   assert result.returncode==0,result.stderr
   assert (provider/'prepared_config').read_text().strip()=='1'
   assert (power/'state').read_text()=='',((power/'state').read_text(),(provider/'kernel').read_text(),result.stderr)
   assert (provider/'kernel').read_text().strip()=='mem','negative parser control did not expose fallback'
   results.append({'case':name,'negative_control_configuration_erased_tool':True})
  elif race:
   provider_process=subprocess.Popen(['/native/proof-provider','parsed-guard'],env=env)
   deadline=time.monotonic()+3
   while not (root/'reached').exists() and time.monotonic()<deadline:time.sleep(.01)
   assert (root/'reached').exists(),name+' never reached real shell barrier'
   wake=subprocess.Popen([str(shell),'wake'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
   deadline=time.monotonic()+3
   while time.monotonic()<deadline:
    active=subprocess.run(['/usr/bin/python3','/counter.py',str(root),'sources'],capture_output=True,text=True,check=True).stdout.strip()
    if active:break
    time.sleep(.01)
   assert active,'software wake guard never became active'
   assert (runtime/'power-state').read_text()=='blank\n','wake bypassed display lock'
   os.write(barrier_fd,b'go\n');os.close(barrier_fd)
   assert provider_process.wait(timeout=5)==0
   assert int((provider/'result').read_text())!=0,'native race admitted mem'
   assert wake.wait(timeout=5)==0,wake.stderr.read()
   wake.stderr.close()
   assert (runtime/'power-state').read_text()=='active\n'
   assert (power/'state').read_text()==''
   assert (provider/'kernel').read_text()==''
   results.append({'case':name,'wake_source_vetoed':True,'no_mem':True,'wake_completed_after_lock_release':True})
  elif name=='blocked-entry':
   # Fill a real FIFO so the actual shell builtin blocks at its mem write.
   # This is an interruptible syscall seam, not a claim to simulate kernel sleep.
   state=power/'state';state.unlink();os.mkfifo(state)
   fifo=os.open(state,os.O_RDWR|os.O_NONBLOCK)
   try:
    while True:os.write(fifo,b'x'*4096)
   except BlockingIOError:pass
   provider_process=subprocess.Popen(['/native/proof-provider','parsed-guard'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
   deadline=time.monotonic()+5
   tool=None
   while time.monotonic()<deadline:
    children=P('/proc/'+str(provider_process.pid)+'/task/'+str(provider_process.pid)+'/children').read_text().split()
    for pid in children:
     try:
      if 'pipe_write' in P('/proc/'+pid+'/wchan').read_text():tool=int(pid)
     except FileNotFoundError:pass
    if tool:break
    time.sleep(.01)
   assert tool,('real shell never reached blocked builtin',provider_process.poll(),[(pid,P('/proc/'+pid+'/wchan').read_text()) for pid in children],provider_process.stderr.read() if provider_process.poll() is not None else '')
   assert all(P('/proc/'+str(tool)+'/fd/'+str(fd)).exists() for fd in (3,4,5,6,8))
   # The input producer can disappear without releasing the imported objects.
   monitor_fixture.children[0][0].kill();monitor_fixture.children[0][0].wait(timeout=2)
   os.kill(tool,signal.SIGSTOP)
   provider_process.kill();provider_process.wait(timeout=2)
   provider_process.stdout.close();provider_process.stderr.close()
   # A replacement native operation cannot pass the existing lock owner.
   monitor_fixture.child()
   # Remove dead producer from the synthetic membership list, as cgroup.procs does.
   monitor_fixture.module.CGROUP.write_text(str(monitor_fixture.children[-1][0].pid)+'\n')
   for lock in (root/'call.lock',runtime/'power-state.lock'):
    fd=os.open(lock,os.O_RDWR)
    try:
     try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
     except BlockingIOError:pass
     else:raise AssertionError('actual shell released lock before terminal exit')
    finally:os.close(fd)
   retry=subprocess.run(['/native/proof-provider','parsed-guard'],env=env,capture_output=True,text=True,timeout=5)
   assert retry.returncode==0 and int((provider/'result').read_text())!=0
   os.kill(tool,signal.SIGCONT)
   deadline=time.monotonic()+3
   while P('/proc/'+str(tool)+'/fd/6').exists() and time.monotonic()<deadline:time.sleep(.01)
   assert not P('/proc/'+str(tool)+'/fd/6').exists(),'terminated owner kept locks'
   data=b''
   while True:
    try:data+=os.read(fifo,65536)
    except BlockingIOError:break
   os.close(fifo)
   assert b'mem' not in data,'cancelled blocked write later entered mem'
   assert (provider/'kernel').read_text()=='','provider fell back outside guard'
   results.append({'case':name,'locks_retained_after_monitor_and_provider_death':True,'replacement_vetoed':True,'no_late_mem':True})
  else:
   r=subprocess.run(['/native/proof-provider','parsed-guard'],env=env,capture_output=True,text=True,timeout=8)
   assert r.returncode==0,(name,r.stdout,r.stderr)
   assert (provider/'prepared_config').read_text().strip()=='1','startup preparation config missing'
   accepted=int((provider/'result').read_text())==0
   assert accepted==(name in ('idle','modem-bus2')),(name,accepted,r.stderr)
   assert (power/'state').read_text()==('mem\n' if name in ('idle','modem-bus2') else ''),(name,'wrong kernel effect')
   assert (provider/'kernel').read_text()=='',(name,'provider fell back outside guard')
   if name=='symlink':assert (root/'untouched').read_text()=='preserve'
   results.append({'case':name,'guard_accepted':accepted,'no_provider_fallback':True})
  monitor_fixture.tearDown()
print(json.dumps(results,indent=2))
