"""Execute the real fixed idle-check shell/D-Bus branch in an isolated container."""
import json
from pathlib import Path
import subprocess
import sysconfig
import unittest

# Python -I still loads the container's installed site packages. Only this
# disposable fixture module replaces the system D-Bus connection.
Path(sysconfig.get_paths()['purelib'], 'dbus.py').write_text('''
import json,time
from pathlib import Path
case=json.loads(Path('/tmp/call-case.json').read_text())
class SystemBus:
 def __init__(self): self.lookups=0
 def get_name_owner(self,name):
  self.lookups+=1
  return ':1.43' if case.get('owner_change') and self.lookups>1 else ':1.42'
 def get_object(self,owner,path):
  assert owner==':1.42'
  return path
class Interface:
 def __init__(self,path,interface): self.path=path
 def GetManagedObjects(self,timeout):
  if case.get('timeout'):time.sleep(10)
  if case.get('lookup_error'):raise RuntimeError('synthetic lookup failure')
  return case['objects']
 def GetAll(self,interface,timeout):return case['calls'][self.path]
''')
VOICE='org.freedesktop.ModemManager1.Modem.Voice'
CALL='/org/freedesktop/ModemManager1/Call/7'
class CallIdle(unittest.TestCase):
    def check(self, case, allowed):
        Path('/tmp/call-case.json').write_text(json.dumps(case))
        result=subprocess.run(['/bin/sh','/helper','idle-check'],capture_output=True,timeout=7)
        self.assertEqual(result.returncode, 0 if allowed else 75, result.stderr)
    def test_received_call_states_and_unknowns(self):
        for state in (None,7,3,0):
            with self.subTest(state=state):
                self.check({'objects':{'modem':{VOICE:{'Calls':[] if state is None else [CALL]}}},
                            'calls':{CALL:{'State':state}}}, state in (None,7))
    def test_missing_ambiguous_and_unreadable_voice(self):
        for objects in ({},{'a':{VOICE:{} }},{'a':{VOICE:{'Calls':[]}},'b':{VOICE:{'Calls':[]}}}):
            with self.subTest(objects=objects):self.check({'objects':objects,'calls':{}},False)
        self.check({'objects':{'a':{VOICE:{'Calls':[CALL]}}},'calls':{}},False)
    def test_lookup_failure_real_outer_timeout_and_owner_replacement(self):
        for flag in ('lookup_error','timeout','owner_change'):
            with self.subTest(flag=flag):
                self.check({'objects':{'a':{VOICE:{'Calls':[]}}},'calls':{},flag:True},False)

unittest.main()
